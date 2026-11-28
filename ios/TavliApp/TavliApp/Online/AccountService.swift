import AuthenticationServices
import SwiftUI
import TavliEngine

// Server v1 accounts (#285), the app side: which server to talk to, the app's one
// `AuthClient` (Keychain-backed), and the two provider flows (Sign in with Apple via
// AuthenticationServices, Google via ASWebAuthenticationSession + PKCE, no Google SDK).
// The state machine and the HTTP logic live in TavliEngine (`ServerAuth.swift`).
// Online play through the server (#286) uses it behind a developer switch; Game Center stays
// the default path until #287/#288. The
// account screen is reachable from Settings while developer tools are on.

/// Which server and which Google client the build talks to. Values come from Info.plist,
/// which takes them from build settings in `project.yml`:
///   `TavtavServerURL`            the default server (`TAVTAV_SERVER_URL`: Debug = staging,
///                                Release = production; Developer card → Local = `wrangler dev`)
///   `TavtavServerURLStaging` / `TavtavServerURLProduction`  for the DEBUG server picker
///   `TavtavGoogleClientID`       the iOS OAuth client id (`GOOGLE_IOS_CLIENT_ID`; empty or a
///                                placeholder = Sign in with Google unavailable)
/// DEBUG builds can switch servers at runtime (Account screen → Developer).
enum ServerConfig {
    enum Choice: String, CaseIterable, Identifiable {
        case standard, local, staging, production
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "Build default"
            case .local: return "Local (wrangler dev)"
            case .staging: return "Staging"
            case .production: return "Production"
            }
        }
    }

    static let localURL = URL(string: "http://localhost:8787")!
    static let debugChoiceKey = "debug.serverChoice"

    private static func plistURL(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty, !raw.contains("REPLACE"), let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    static func url(for choice: Choice) -> URL? {
        switch choice {
        case .standard: return plistURL("TavtavServerURL")
        case .local: return localURL
        case .staging: return plistURL("TavtavServerURLStaging")
        case .production: return plistURL("TavtavServerURLProduction")
        }
    }

    static var debugChoice: Choice {
        #if DEBUG
        Choice(rawValue: UserDefaults.standard.string(forKey: debugChoiceKey) ?? "") ?? .standard
        #else
        .standard
        #endif
    }

    /// The server in use; nil when this build has none configured (production URL still
    /// a placeholder): the account screen then says the server is not available yet.
    static var baseURL: URL? { url(for: debugChoice) }

    static var googleOAuth: GoogleOAuth? {
        GoogleOAuth(clientID: Bundle.main.object(forInfoDictionaryKey: "TavtavGoogleClientID") as? String ?? "")
    }

    /// `X-Tavtav-Client: ios/1.0.1 (330)`.
    static var clientHeader: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "ios/\(version) (\(build))"
    }

    /// True for a `wrangler dev` server (the development sign-in works only there).
    static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
}

/// The app's account state: one `AuthClient` per server (DEBUG can switch servers).
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var client: AuthClient?

    private init() { rebuild() }

    /// Re-creates the client for `ServerConfig.baseURL` (after the DEBUG server picker).
    func rebuild() {
        client = ServerConfig.baseURL.map { url in
            AuthClient(baseURL: url, clientHeader: ServerConfig.clientHeader, transport: URLSessionTransport(),
                       store: KeychainAuthTokenStore(serverURL: url))
        }
    }
}

// MARK: - Sign in with Apple

enum AppleSignIn {
    /// Configures Apple's request: full name only (no e-mail), our nonce's hash.
    static func prepare(_ request: ASAuthorizationAppleIDRequest, nonce: AuthNonce) {
        request.requestedScopes = [.fullName]
        request.nonce = nonce.hash
    }

    /// Hands Apple's result to the client. Cancel → `AuthError.cancelled`.
    @MainActor
    static func complete(_ result: Result<ASAuthorization, Error>, nonce: AuthNonce, client: AuthClient) async throws {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { throw AuthError.cancelled }
            throw AuthError.providerFailed((error as NSError).localizedDescription)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else { throw AuthError.providerFailed("no_identity_token") }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            // Apple sends the name only the very first time; the name prompt covers the rest.
            let name = credential.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }.flatMap { $0.isEmpty ? nil : $0 }
            try await client.completeAppleSignIn(identityToken: token, nonce: nonce, displayName: name,
                                                 authorizationCode: code)
        }
    }
}

// MARK: - Sign in with Google (ASWebAuthenticationSession + PKCE)

@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    /// Google's page → code → token endpoint (from the app; iOS clients have no secret) →
    /// our server with the `id_token`.
    func signIn(client: AuthClient) async throws {
        guard let google = ServerConfig.googleOAuth else { throw AuthError.providerUnavailable }
        let attempt = GoogleOAuth.Attempt()
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: google.authorizationURL(for: attempt),
                                                     callbackURLScheme: google.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.providerFailed(error?.localizedDescription ?? "unknown"))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: AuthError.providerFailed("start")) }
        }
        session = nil
        let code = try google.code(fromCallback: callback, attempt: attempt)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: google.tokenRequest(code: code, attempt: attempt))
        } catch {
            throw AuthError.network
        }
        let idToken = try GoogleOAuth.idToken(fromTokenResponse: data)
        try await client.completeGoogleSignIn(idToken: idToken, nonce: attempt.nonce)
    }
}
