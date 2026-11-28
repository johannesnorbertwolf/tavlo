import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

// Server v1 accounts (#285): the app's side of sign-in, sessions and the account
// endpoints (`server/REFERENCE.md` "Accounts"). `AuthClient` is the testable state
// machine (signed out → signing in → signed in) over two seams: `ServerTransport` (HTTP)
// and `AuthTokenStore` (Keychain in the app, memory in tests). The provider UIs (Sign in
// with Apple sheet, Google's ASWebAuthenticationSession) live in the app target; they
// hand their tokens to `completeAppleSignIn` / `completeGoogleSignIn`. Pure helpers for
// both providers (`AuthNonce`, `GoogleOAuth` PKCE) and the display-name rule are here.

// MARK: - Display name

/// The server's display-name rule (`normalizeDisplayName` in `server/src/accounts.ts`):
/// NFC, whitespace runs → one space, trimmed, 1…24 UTF-16 units, no control, private-use,
/// unassigned or invisible format characters except ZWNJ/ZWJ (Persian needs ZWNJ).
public enum DisplayNameRule {
    public static let maxLength = 24

    /// The name as the server will store it, or nil when the server would reject it.
    public static func normalize(_ raw: String) -> String? {
        let collapsed = raw.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.utf16.count <= maxLength else { return nil }
        for scalar in collapsed.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned:
                return nil
            case .format where scalar.value != 0x200C && scalar.value != 0x200D:
                return nil
            default:
                continue
            }
        }
        return collapsed
    }
}

// MARK: - Nonce + PKCE

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func random(bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return encode(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &g) }))
    }
}

/// The sign-in nonce: the provider request carries `hash` (SHA-256, lowercase hex), the
/// server gets `raw` and checks the token's `nonce` claim against its hash. Same for Apple
/// and Google, so the raw value never appears in a provider URL.
public struct AuthNonce: Equatable, Sendable {
    public let raw: String
    public var hash: String { Self.sha256Hex(raw) }

    public init(raw: String = Base64URL.random(bytes: 32)) { self.raw = raw }

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sign in with Google without the Google SDK (#285): OAuth 2.0 authorization code + PKCE
/// for an **iOS** OAuth client, run in `ASWebAuthenticationSession` by the app. The app
/// exchanges the code at Google's token endpoint itself (iOS clients have no secret) and
/// sends the `id_token` to our server.
public struct GoogleOAuth: Equatable, Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// `<id>.apps.googleusercontent.com`.
    public let clientID: String

    /// nil for an empty / placeholder client id (Google sign-in not set up yet).
    public init?(clientID: String) {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard id.hasSuffix(".apps.googleusercontent.com"), !id.contains("REPLACE"),
              id.count > ".apps.googleusercontent.com".count else { return nil }
        self.clientID = id
    }

    /// The reversed client id, Google's redirect scheme for iOS clients.
    public var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    public var redirectURI: String { "\(callbackScheme):/oauthredirect" }

    /// One sign-in attempt's secrets.
    public struct Attempt: Equatable, Sendable {
        public let state: String
        public let codeVerifier: String
        public let nonce: AuthNonce
        public var codeChallenge: String { GoogleOAuth.codeChallenge(for: codeVerifier) }

        public init(state: String = Base64URL.random(bytes: 16),
                    codeVerifier: String = Base64URL.random(bytes: 32),
                    nonce: AuthNonce = AuthNonce()) {
            self.state = state
            self.codeVerifier = codeVerifier
            self.nonce = nonce
        }
    }

    /// RFC 7636 S256: base64url(SHA-256(verifier)).
    public static func codeChallenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public func authorizationURL(for attempt: Attempt) -> URL {
        var c = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: attempt.nonce.hash),
            URLQueryItem(name: "code_challenge", value: attempt.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return c.url!
    }

    /// The authorization code from the redirect, after checking `state`.
    public func code(fromCallback url: URL, attempt: Attempt) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.providerFailed(error)
        }
        guard url.scheme == callbackScheme, value("state") == attempt.state, let code = value("code"), !code.isEmpty
        else { throw AuthError.providerFailed("bad_callback") }
        return code
    }

    /// The code → token exchange request (form-encoded POST, PKCE verifier, no secret).
    public func tokenRequest(code: String, attempt: Attempt) -> URLRequest {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: attempt.codeVerifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return request
    }

    /// The `id_token` from the token endpoint's answer.
    public static func idToken(fromTokenResponse data: Data) throws -> String {
        struct Answer: Decodable { let id_token: String? }
        guard let token = (try? JSONDecoder().decode(Answer.self, from: data))?.id_token, !token.isEmpty
        else { throw AuthError.providerFailed("no_id_token") }
        return token
    }
}

// MARK: - Seams

/// HTTP for the server client; the app uses `URLSessionTransport`, tests a fake.
public protocol ServerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: ServerTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// What survives an app restart: our tokens + the account, and whether the player still
/// has to pick a display name (a new account whose prompt was not finished).
public struct StoredAuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var accessExpiresAt: Int64
    public var refreshToken: String
    public var refreshExpiresAt: Int64
    public var account: ServerAPI.Account
    public var needsDisplayName: Bool

    public init(_ session: ServerAPI.AuthSession, needsDisplayName: Bool) {
        accessToken = session.accessToken
        accessExpiresAt = session.accessExpiresAt
        refreshToken = session.refreshToken
        refreshExpiresAt = session.refreshExpiresAt
        account = session.account
        self.needsDisplayName = needsDisplayName
    }
}

/// Where the session is kept. `KeychainAuthTokenStore` in the app; `MemoryAuthTokenStore` in tests.
public protocol AuthTokenStore: AnyObject {
    func load() -> StoredAuthSession?
    func save(_ session: StoredAuthSession)
    func clear()
}

public final class MemoryAuthTokenStore: AuthTokenStore {
    public private(set) var session: StoredAuthSession?
    public private(set) var saves = 0
    public init(_ session: StoredAuthSession? = nil) { self.session = session }
    public func load() -> StoredAuthSession? { session }
    public func save(_ session: StoredAuthSession) { self.session = session; saves += 1 }
    public func clear() { session = nil }
}

#if canImport(Security)
/// One generic-password Keychain item per server (so local / staging / production sessions
/// never mix), readable after first unlock, never synced or migrated to another device.
public final class KeychainAuthTokenStore: AuthTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "com.plakoto.TavliApp.server-session", serverURL: URL) {
        self.service = service
        self.account = serverURL.absoluteString
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> StoredAuthSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(StoredAuthSession.self, from: data)
    }

    public func save(_ session: StoredAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}
#endif

// MARK: - Errors + state

public enum AuthError: Error, Equatable, Sendable {
    /// The player closed the provider sheet.
    case cancelled
    /// No connection / timeout; the session (if any) is kept.
    case network
    /// The server said no. `code` is the contract's error code (`ServerAPI.ErrorCode`).
    case server(code: String?, status: Int)
    /// The provider UI failed (Apple / Google error or a bad callback).
    case providerFailed(String)
    /// Google's iOS client id is not set in this build.
    case providerUnavailable
    /// Fails `DisplayNameRule` (checked before any request).
    case invalidDisplayName
    /// Fails `HandleRule` (#301, checked before any request).
    case invalidHandle
    /// Needs a session and there is none (or the server ended it).
    case notSignedIn

    public var serverCode: ServerAPI.ErrorCode? {
        if case .server(let code?, _) = self { return ServerAPI.ErrorCode(rawValue: code) }
        return nil
    }
}

public enum AuthProviderKind: String, Codable, Sendable {
    case apple, google, development
}

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signingIn(AuthProviderKind)
    case signedIn(ServerAPI.Account)

    public var account: ServerAPI.Account? {
        if case .signedIn(let account) = self { return account }
        return nil
    }
}

// MARK: - Client

/// The account state machine + authorized requests. Publishes `state`, `needsDisplayName`
/// (a new account must pick a name) and `isWorking`. Requests carry the bearer token,
/// refresh it ahead of expiry (`refreshMargin`) and once on `401 token_expired`; a refresh
/// that the server refuses signs out. Concurrent requests share one refresh.
@MainActor
public final class AuthClient: ObservableObject {
    @Published public private(set) var state: AuthState = .signedOut
    @Published public private(set) var needsDisplayName = false
    @Published public private(set) var isWorking = false

    public let baseURL: URL
    public let clientHeader: String
    private let transport: ServerTransport
    private let store: AuthTokenStore
    private let now: () -> Date
    /// Refresh this long before the access token expires.
    public var refreshMargin: TimeInterval = 60

    private var session: StoredAuthSession?
    private var refreshTask: Task<StoredAuthSession, Error>?

    public init(baseURL: URL, clientHeader: String, transport: ServerTransport, store: AuthTokenStore,
                now: @escaping () -> Date = Date.init) {
        self.baseURL = baseURL
        self.clientHeader = clientHeader
        self.transport = transport
        self.store = store
        self.now = now
        restore()
    }

    private var nowMillis: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    /// Loads the stored session (also run by `init`). An expired refresh token = signed out.
    public func restore() {
        guard let stored = store.load(), stored.refreshExpiresAt > nowMillis else {
            if store.load() != nil { store.clear() }
            adopt(nil)
            return
        }
        adopt(stored)
    }

    private func adopt(_ stored: StoredAuthSession?) {
        session = stored
        needsDisplayName = stored?.needsDisplayName ?? false
        state = stored.map { .signedIn($0.account) } ?? .signedOut
    }

    private func persist(_ stored: StoredAuthSession) {
        store.save(stored)
        adopt(stored)
    }

    private func signOutLocally() {
        refreshTask?.cancel()
        refreshTask = nil
        store.clear()
        adopt(nil)
    }

    // MARK: Sign-in

    /// The provider UI is up.
    public func beginSignIn(_ provider: AuthProviderKind) {
        if session == nil { state = .signingIn(provider) }
    }

    /// The provider UI ended without a token (cancel or error).
    public func cancelSignIn() {
        if session == nil { state = .signedOut }
    }

    public func completeAppleSignIn(identityToken: String, nonce: AuthNonce, displayName: String?,
                                    authorizationCode: String?) async throws {
        let name = displayName.flatMap(DisplayNameRule.normalize)
        try await signIn(.apple, path: "/v1/auth/apple",
                         body: ServerAPI.AppleSignInRequest(identityToken: identityToken, nonce: nonce.raw,
                                                            displayName: name, authorizationCode: authorizationCode))
    }

    public func completeGoogleSignIn(idToken: String, nonce: AuthNonce) async throws {
        try await signIn(.google, path: "/v1/auth/google",
                         body: ServerAPI.GoogleSignInRequest(idToken: idToken, nonce: nonce.raw))
    }

    /// Development servers only (`wrangler dev`): sign in without a provider.
    public func developmentSignIn(subject: String) async throws {
        try await signIn(.development, path: "/v1/auth/dev", body: ServerAPI.DevSignInRequest(subject: subject))
    }

    private func signIn<B: Encodable>(_ provider: AuthProviderKind, path: String, body: B) async throws {
        state = .signingIn(provider)
        isWorking = true
        defer { isWorking = false }
        do {
            let answer: ServerAPI.AuthSession = try await perform(method: "POST", path: path, body: body, token: nil)
            persist(StoredAuthSession(answer, needsDisplayName: answer.isNewAccount))
        } catch {
            adopt(session)
            throw error
        }
    }

    // MARK: Account

    public var account: ServerAPI.Account? { session?.account }

    /// Reloads the account from the server.
    public func reloadAccount() async throws {
        let account: ServerAPI.Account = try await authorized(method: "GET", path: "/v1/account", body: Optional<Int>.none)
        updateStored { $0.account = account }
    }

    /// Validates locally (`DisplayNameRule`), then PATCHes; clears `needsDisplayName`.
    public func updateDisplayName(_ raw: String) async throws {
        guard let name = DisplayNameRule.normalize(raw) else { throw AuthError.invalidDisplayName }
        isWorking = true
        defer { isWorking = false }
        let account: ServerAPI.Account = try await authorized(
            method: "PATCH", path: "/v1/account", body: ServerAPI.UpdateAccountRequest(displayName: name))
        updateStored {
            $0.account = account
            $0.needsDisplayName = false
        }
    }

    /// #301: change the handle (once; validated by `HandleRule` first), "show when I'm
    /// online" or "who can challenge me". Server errors (`handle_taken` 409, a second
    /// handle change 403) are thrown as `AuthError.server`.
    public func updateAccount(handle: String? = nil, hidePresence: Bool? = nil,
                              whoCanChallenge: ServerAPI.ChallengePolicy? = nil) async throws {
        if let handle, HandleRule.problem(handle) != nil { throw AuthError.invalidHandle }
        isWorking = true
        defer { isWorking = false }
        let account: ServerAPI.Account = try await authorized(
            method: "PATCH", path: "/v1/account",
            body: ServerAPI.UpdateAccountRequest(hidePresence: hidePresence, handle: handle,
                                                 whoCanChallenge: whoCanChallenge?.rawValue))
        updateStored { $0.account = account }
    }

    /// Keeps the server's placeholder name (the prompt was skipped).
    public func keepCurrentDisplayName() {
        updateStored { $0.needsDisplayName = false }
    }

    private func updateStored(_ change: (inout StoredAuthSession) -> Void) {
        guard var stored = session else { return }
        change(&stored)
        persist(stored)
    }

    /// Ends the session here and (best effort) on the server. Always signs out locally.
    public func signOut() async {
        if let stored = session {
            isWorking = true
            let logout: () async throws -> Empty? = {
                try await self.authorized(method: "POST", path: "/v1/auth/logout",
                                          body: ServerAPI.RefreshRequest(refreshToken: stored.refreshToken))
            }
            _ = try? await logout()
            isWorking = false
        }
        signOutLocally()
    }

    /// Deletes the account on the server; signs out only when that worked.
    public func deleteAccount() async throws {
        isWorking = true
        defer { isWorking = false }
        let _: Empty? = try await authorized(method: "DELETE", path: "/v1/account", body: Optional<Int>.none)
        signOutLocally()
    }

    // MARK: Requests

    private struct Empty: Decodable {}

    /// An authorized request for later tickets' endpoints (#286/#287): bearer token,
    /// proactive refresh, one retry after `token_expired`, sign-out when the server ends
    /// the session. `R?` decodes an empty (204) body as nil.
    public func authorized<B: Encodable, R: Decodable>(method: String, path: String, body: B?,
                                                       allowRefresh: Bool = true) async throws -> R {
        guard var current = session else { throw AuthError.notSignedIn }
        if allowRefresh, Double(current.accessExpiresAt - nowMillis) / 1000 < refreshMargin {
            current = try await refreshed(from: current)
        }
        do {
            return try await perform(method: method, path: path, body: body, token: current.accessToken)
        } catch AuthError.server(let code, 401) {
            guard allowRefresh, code == ServerAPI.ErrorCode.tokenExpired.rawValue else {
                signOutLocally()
                throw AuthError.notSignedIn
            }
            let fresh = try await refreshed(from: current)
            do {
                return try await perform(method: method, path: path, body: body, token: fresh.accessToken)
            } catch AuthError.server(_, 401) {
                signOutLocally()
                throw AuthError.notSignedIn
            }
        }
    }

    /// One shared refresh; a refused refresh signs out.
    private func refreshed(from stale: StoredAuthSession) async throws -> StoredAuthSession {
        if let current = session, current.accessToken != stale.accessToken { return current }
        if let task = refreshTask { return try await task.value }
        let task = Task { () throws -> StoredAuthSession in
            let answer: ServerAPI.AuthSession = try await self.perform(
                method: "POST", path: "/v1/auth/refresh",
                body: ServerAPI.RefreshRequest(refreshToken: stale.refreshToken), token: nil)
            return StoredAuthSession(answer, needsDisplayName: stale.needsDisplayName)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            persist(fresh)
            return fresh
        } catch AuthError.server(_, let status) where status == 401 {
            signOutLocally()
            throw AuthError.notSignedIn
        }
    }

    /// A valid access token (refreshed first when it is about to expire), e.g. for the
    /// match WebSocket's upgrade request (#286). Throws `.notSignedIn` without a session.
    public func accessToken() async throws -> String {
        guard var current = session else { throw AuthError.notSignedIn }
        if Double(current.accessExpiresAt - nowMillis) / 1000 < refreshMargin {
            current = try await refreshed(from: current)
        }
        return current.accessToken
    }

    /// `baseURL` + `path`, which may carry a query (`/v1/matches?state=active`).
    public func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let url = baseURL.appendingPathComponent(String((parts.first ?? "").dropFirst()))
        guard parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.percentEncodedQuery = parts[1]
        return c.url ?? url
    }

    private func perform<B: Encodable, R: Decodable>(method: String, path: String, body: B?,
                                                     token: String?) async throws -> R {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(clientHeader, forHTTPHeaderField: ServerAPI.clientHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try ServerAPI.encoder().encode(body)
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.network
        }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? ServerAPI.decoder().decode(ServerAPI.ErrorResponse.self, from: data))?.error.code
            throw AuthError.server(code: code, status: response.statusCode)
        }
        do {
            // An empty (204) body reads as JSON null, so `R?` decodes it as nil.
            return try ServerAPI.decoder().decode(R.self, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            throw AuthError.server(code: nil, status: response.statusCode)
        }
    }
}
