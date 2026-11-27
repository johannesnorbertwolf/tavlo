import XCTest
@testable import TavliEngine

/// A scripted server: answers each request from `handler`, records what was sent.
private final class FakeServer: ServerTransport, @unchecked Sendable {
    struct Sent {
        let method: String
        let path: String
        let bearer: String?
        let body: [String: Any]?
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    var handler: (Sent) throws -> (Int, Any?) = { _ in (500, nil) }
    /// Suspends each request this long (to make concurrent requests overlap).
    var delayNanos: UInt64 = 0

    var sent: [Sent] { lock.withLock { _sent } }
    func paths() -> [String] { sent.map { "\($0.method) \($0.path)" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let entry = Sent(method: request.httpMethod ?? "GET", path: request.url!.path,
                         bearer: auth.map { String($0.dropFirst("Bearer ".count)) }, body: body)
        lock.withLock { _sent.append(entry) }
        XCTAssertEqual(request.value(forHTTPHeaderField: ServerAPI.clientHeader), "ios/test")
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        let (status, json) = try handler(entry)
        let data = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let t0: Int64 = 1_800_000_000_000

private func accountJSON(name: String = "Player 0042", providers: [String] = ["apple"]) -> [String: Any] {
    ["id": "acc_test", "displayName": name, "providers": providers, "createdAt": t0]
}

private func sessionJSON(_ n: Int, isNew: Bool = false, name: String = "Player 0042",
                         accessTTL: Int64 = 3_600_000) -> [String: Any] {
    ["accessToken": "at_access\(n)_padding_padding", "accessExpiresAt": t0 + accessTTL,
     "refreshToken": "rt_refresh\(n)_padding_padding", "refreshExpiresAt": t0 + 86_400_000 * 60,
     "account": accountJSON(name: name), "isNewAccount": isNew]
}

private func errorJSON(_ code: String) -> [String: Any] { ["error": ["code": code, "message": "x"]] }

@MainActor
final class AuthClientTests: XCTestCase {
    private var server: FakeServer!
    private var store: MemoryAuthTokenStore!
    private var clock = Date(timeIntervalSince1970: Double(t0) / 1000)

    override func setUp() async throws {
        server = FakeServer()
        store = MemoryAuthTokenStore()
    }

    private func makeClient() -> AuthClient {
        AuthClient(baseURL: URL(string: "http://localhost:8787")!, clientHeader: "ios/test",
                   transport: server, store: store, now: { [unowned self] in self.clock })
    }

    private func signedInClient(isNew: Bool = false) async throws -> AuthClient {
        server.handler = { _ in (200, sessionJSON(1, isNew: isNew)) }
        let client = makeClient()
        try await client.completeAppleSignIn(identityToken: "apple.jwt.sig", nonce: AuthNonce(raw: "raw-nonce-1234567890"),
                                             displayName: nil, authorizationCode: "code")
        return client
    }

    // MARK: Sign-in

    func testAppleSignInSendsTheContractBodyAndStoresTheSession() async throws {
        server.handler = { _ in (200, sessionJSON(1, isNew: true)) }
        let client = makeClient()
        XCTAssertEqual(client.state, .signedOut)
        try await client.completeAppleSignIn(identityToken: "apple.jwt.sig", nonce: AuthNonce(raw: "raw-nonce-1234567890"),
                                             displayName: "  Alex  ", authorizationCode: "code-1")
        let sent = try XCTUnwrap(server.sent.first)
        XCTAssertEqual("\(sent.method) \(sent.path)", "POST /v1/auth/apple")
        XCTAssertNil(sent.bearer)
        XCTAssertEqual(sent.body?["identityToken"] as? String, "apple.jwt.sig")
        XCTAssertEqual(sent.body?["nonce"] as? String, "raw-nonce-1234567890")
        XCTAssertEqual(sent.body?["displayName"] as? String, "Alex")
        XCTAssertEqual(sent.body?["authorizationCode"] as? String, "code-1")

        XCTAssertEqual(client.state.account?.id, "acc_test")
        XCTAssertTrue(client.needsDisplayName, "a new account asks for a name")
        XCTAssertEqual(store.session?.refreshToken, "rt_refresh1_padding_padding")
        XCTAssertEqual(store.session?.needsDisplayName, true)
    }

    func testSessionSurvivesARestartIncludingThePendingNamePrompt() async throws {
        _ = try await signedInClient(isNew: true)
        let relaunched = makeClient()
        XCTAssertEqual(relaunched.state.account?.id, "acc_test")
        XCTAssertTrue(relaunched.needsDisplayName)
    }

    func testAnExpiredRefreshTokenRestoresSignedOut() async throws {
        _ = try await signedInClient()
        clock = clock.addingTimeInterval(61 * 86_400)
        let relaunched = makeClient()
        XCTAssertEqual(relaunched.state, .signedOut)
        XCTAssertNil(store.session)
    }

    func testARejectedSignInReturnsToSignedOut() async throws {
        server.handler = { _ in (401, errorJSON("unauthorized")) }
        let client = makeClient()
        do {
            try await client.completeGoogleSignIn(idToken: "g.jwt.sig", nonce: AuthNonce(raw: "raw-nonce-1234567890"))
            XCTFail("expected an error")
        } catch let error as AuthError {
            XCTAssertEqual(error, .server(code: "unauthorized", status: 401))
        }
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertEqual(server.paths(), ["POST /v1/auth/google"])
    }

    func testBeginAndCancelSignIn() {
        let client = makeClient()
        client.beginSignIn(.google)
        XCTAssertEqual(client.state, .signingIn(.google))
        client.cancelSignIn()
        XCTAssertEqual(client.state, .signedOut)
    }

    func testNetworkFailureMapsToNetwork() async throws {
        server.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient()
        do {
            try await client.developmentSignIn(subject: "sim")
            XCTFail("expected an error")
        } catch let error as AuthError {
            XCTAssertEqual(error, .network)
        }
    }

    // MARK: Account

    func testDisplayNameUpdateClearsThePrompt() async throws {
        let client = try await signedInClient(isNew: true)
        server.handler = { sent in
            XCTAssertEqual(sent.bearer, "at_access1_padding_padding")
            return (200, accountJSON(name: sent.body?["displayName"] as! String))
        }
        try await client.updateDisplayName("  Νίκος   Π. ")
        XCTAssertEqual(server.sent.last?.method, "PATCH")
        XCTAssertEqual(server.sent.last?.body?["displayName"] as? String, "Νίκος Π.")
        XCTAssertEqual(client.state.account?.displayName, "Νίκος Π.")
        XCTAssertFalse(client.needsDisplayName)
        XCTAssertEqual(store.session?.account.displayName, "Νίκος Π.")
        XCTAssertEqual(store.session?.needsDisplayName, false)
    }

    func testAnInvalidNameNeverReachesTheServer() async throws {
        let client = try await signedInClient()
        let before = server.sent.count
        for bad in ["   ", String(repeating: "x", count: 25), "a\u{7}b"] {
            do {
                try await client.updateDisplayName(bad)
                XCTFail("accepted \(bad.debugDescription)")
            } catch let error as AuthError {
                XCTAssertEqual(error, .invalidDisplayName)
            }
        }
        XCTAssertEqual(server.sent.count, before)
    }

    func testKeepingThePlaceholderNameClearsThePrompt() async throws {
        let client = try await signedInClient(isNew: true)
        client.keepCurrentDisplayName()
        XCTAssertFalse(client.needsDisplayName)
        XCTAssertFalse(makeClient().needsDisplayName)
    }

    // MARK: Refresh

    func testExpiredAccessTokenRefreshesOnceAndRetries() async throws {
        let client = try await signedInClient()
        server.handler = { sent in
            switch (sent.method, sent.path, sent.bearer) {
            case ("GET", "/v1/account", "at_access1_padding_padding"): return (401, errorJSON("token_expired"))
            case ("POST", "/v1/auth/refresh", nil):
                XCTAssertEqual(sent.body?["refreshToken"] as? String, "rt_refresh1_padding_padding")
                return (200, sessionJSON(2, name: "Renamed"))
            case ("GET", "/v1/account", "at_access2_padding_padding"): return (200, accountJSON(name: "Renamed"))
            default: return (500, nil)
            }
        }
        try await client.reloadAccount()
        XCTAssertEqual(server.paths().suffix(3), ["GET /v1/account", "POST /v1/auth/refresh", "GET /v1/account"])
        XCTAssertEqual(store.session?.accessToken, "at_access2_padding_padding")
        XCTAssertEqual(store.session?.refreshToken, "rt_refresh2_padding_padding")
        XCTAssertEqual(client.state.account?.displayName, "Renamed")
    }

    func testRefreshesAheadOfExpiry() async throws {
        let client = try await signedInClient()
        clock = clock.addingTimeInterval(3_600 - 30)  // 30 s left < 60 s margin
        server.handler = { sent in
            sent.path == "/v1/auth/refresh" ? (200, sessionJSON(2, accessTTL: 7_200_000)) : (200, accountJSON())
        }
        try await client.reloadAccount()
        XCTAssertEqual(server.paths().suffix(2), ["POST /v1/auth/refresh", "GET /v1/account"])
        XCTAssertEqual(server.sent.last?.bearer, "at_access2_padding_padding")
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let client = try await signedInClient()
        clock = clock.addingTimeInterval(3_600 + 1)
        server.delayNanos = 20_000_000
        server.handler = { sent in
            sent.path == "/v1/auth/refresh" ? (200, sessionJSON(2, accessTTL: 7_200_000)) : (200, accountJSON())
        }
        async let a: Void = client.reloadAccount()
        async let b: Void = client.reloadAccount()
        async let c: Void = client.reloadAccount()
        _ = try await (a, b, c)
        XCTAssertEqual(server.paths().filter { $0 == "POST /v1/auth/refresh" }.count, 1)
        XCTAssertEqual(server.sent.filter { $0.path == "/v1/account" }.map(\.bearer),
                       Array(repeating: "at_access2_padding_padding", count: 3))
    }

    func testARefusedRefreshSignsOut() async throws {
        let client = try await signedInClient()
        server.handler = { sent in
            sent.path == "/v1/auth/refresh" ? (401, errorJSON("unauthorized")) : (401, errorJSON("token_expired"))
        }
        do {
            try await client.reloadAccount()
            XCTFail("expected notSignedIn")
        } catch let error as AuthError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertNil(store.session)
    }

    func testAnUnauthorizedAnswerSignsOut() async throws {
        let client = try await signedInClient()
        server.handler = { _ in (401, errorJSON("unauthorized")) }
        await XCTAssertThrowsAsync(try await client.reloadAccount())
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertFalse(server.paths().contains("POST /v1/auth/refresh"))
    }

    func testOtherServerErrorsKeepTheSession() async throws {
        let client = try await signedInClient()
        server.handler = { _ in (503, errorJSON("unavailable")) }
        do {
            try await client.reloadAccount()
            XCTFail("expected an error")
        } catch let error as AuthError {
            XCTAssertEqual(error.serverCode, .unavailable)
        }
        XCTAssertEqual(client.state.account?.id, "acc_test")
    }

    // MARK: Sign out / delete

    func testSignOutRevokesOnTheServerAndClearsLocally() async throws {
        let client = try await signedInClient()
        server.handler = { _ in (204, nil) }
        await client.signOut()
        XCTAssertEqual(server.sent.last?.path, "/v1/auth/logout")
        XCTAssertEqual(server.sent.last?.body?["refreshToken"] as? String, "rt_refresh1_padding_padding")
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertNil(store.session)
    }

    func testSignOutWorksOffline() async throws {
        let client = try await signedInClient()
        server.handler = { _ in throw URLError(.timedOut) }
        await client.signOut()
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertNil(store.session)
    }

    func testDeleteAccountSignsOutOnlyWhenTheServerDeleted() async throws {
        let client = try await signedInClient()
        server.handler = { _ in (503, errorJSON("unavailable")) }
        await XCTAssertThrowsAsync(try await client.deleteAccount())
        XCTAssertEqual(client.state.account?.id, "acc_test", "a failed delete keeps the account")

        server.handler = { sent in
            XCTAssertEqual("\(sent.method) \(sent.path)", "DELETE /v1/account")
            return (204, nil)
        }
        try await client.deleteAccount()
        XCTAssertEqual(client.state, .signedOut)
        XCTAssertNil(store.session)
    }

    func testRequestsNeedASession() async {
        let client = makeClient()
        do {
            try await client.reloadAccount()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? AuthError, .notSignedIn)
        }
        XCTAssertTrue(server.sent.isEmpty)
    }
}

// MARK: - Pure helpers

final class AuthHelpersTests: XCTestCase {
    func testDisplayNameRuleMatchesTheServer() {
        XCTAssertEqual(DisplayNameRule.normalize("  a\t b \n"), "a b")
        XCTAssertEqual(DisplayNameRule.normalize("می\u{200C}خواهم"), "می\u{200C}خواهم")
        XCTAssertEqual(DisplayNameRule.normalize("e\u{301}"), "é")
        XCTAssertEqual(DisplayNameRule.normalize(String(repeating: "x", count: 24))?.count, 24)
        XCTAssertNil(DisplayNameRule.normalize(String(repeating: "x", count: 25)))
        XCTAssertNil(DisplayNameRule.normalize("   "))
        XCTAssertNil(DisplayNameRule.normalize("\u{202E}evil"))
        XCTAssertNil(DisplayNameRule.normalize("hid\u{200B}den"))
        XCTAssertNil(DisplayNameRule.normalize("bad\u{7}name"))
        XCTAssertEqual(DisplayNameRule.normalize("Βασίλης"), "Βασίλης")
    }

    func testNonceHashIsLowercaseHexSHA256() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        XCTAssertEqual(AuthNonce(raw: "abc").hash,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertGreaterThanOrEqual(AuthNonce().raw.count, 43)
        XCTAssertNotEqual(AuthNonce().raw, AuthNonce().raw)
    }

    func testPKCEChallengeIsRFC7636() {
        XCTAssertEqual(GoogleOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGoogleClientIDPlaceholderMeansUnavailable() {
        XCTAssertNil(GoogleOAuth(clientID: ""))
        XCTAssertNil(GoogleOAuth(clientID: "REPLACE_WITH_GOOGLE_IOS_CLIENT_ID.apps.googleusercontent.com"))
        XCTAssertNil(GoogleOAuth(clientID: ".apps.googleusercontent.com"))
        XCTAssertNotNil(GoogleOAuth(clientID: "123-abc.apps.googleusercontent.com"))
    }

    func testGoogleAuthorizationURLAndCallback() throws {
        let google = try XCTUnwrap(GoogleOAuth(clientID: "123-abc.apps.googleusercontent.com"))
        XCTAssertEqual(google.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(google.redirectURI, "com.googleusercontent.apps.123-abc:/oauthredirect")

        let attempt = GoogleOAuth.Attempt(state: "st4te", codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                                          nonce: AuthNonce(raw: "abc"))
        let url = google.authorizationURL(for: attempt)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["client_id"], "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid")
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["nonce"], AuthNonce(raw: "abc").hash, "the URL carries the nonce hash, not the raw nonce")
        XCTAssertEqual(items["state"], "st4te")

        let ok = URL(string: "com.googleusercontent.apps.123-abc:/oauthredirect?state=st4te&code=4/0Abc")!
        XCTAssertEqual(try google.code(fromCallback: ok, attempt: attempt), "4/0Abc")
        let forged = URL(string: "com.googleusercontent.apps.123-abc:/oauthredirect?state=other&code=x")!
        XCTAssertThrowsError(try google.code(fromCallback: forged, attempt: attempt))
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauthredirect?error=access_denied&state=st4te")!
        XCTAssertThrowsError(try google.code(fromCallback: denied, attempt: attempt)) {
            XCTAssertEqual($0 as? AuthError, .cancelled)
        }
    }

    func testGoogleTokenExchange() throws {
        let google = try XCTUnwrap(GoogleOAuth(clientID: "123-abc.apps.googleusercontent.com"))
        let attempt = GoogleOAuth.Attempt(state: "s", codeVerifier: "verifier-verifier-verifier-verifier-1234", nonce: AuthNonce())
        let request = google.tokenRequest(code: "4/0Abc", attempt: attempt)
        XCTAssertEqual(request.url, GoogleOAuth.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("code=4/0Abc"))
        XCTAssertTrue(form.contains("code_verifier=verifier-verifier-verifier-verifier-1234"))
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertFalse(form.contains("client_secret"))

        XCTAssertEqual(try GoogleOAuth.idToken(fromTokenResponse: Data(#"{"id_token":"a.b.c","expires_in":3599}"#.utf8)), "a.b.c")
        XCTAssertThrowsError(try GoogleOAuth.idToken(fromTokenResponse: Data(#"{"error":"invalid_grant"}"#.utf8)))
    }
}

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
