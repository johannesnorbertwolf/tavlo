import Foundation
import XCTest
@testable import TavliEngine

/// People, presence, one-tap challenges, handles (#301): the pure rules (handles, search
/// queries, row status, list order, the remembered choice) and two devices on
/// `FakeTavtavServer` with presence sockets — challenge → live card → accept opens the match
/// on both, decline / cancel / crossed taps, presence live, pin / remove / block / search.
@MainActor
final class ServerPeopleTests: XCTestCase {
    // MARK: - Pure rules

    func testHandleRuleMatchesTheServer() {
        XCTAssertNil(HandleRule.problem("Alice_K"))
        XCTAssertNil(HandleRule.problem("abc"))
        XCTAssertEqual(HandleRule.problem("ab"), .invalid)
        XCTAssertEqual(HandleRule.problem(String(repeating: "a", count: 21)), .invalid)
        XCTAssertEqual(HandleRule.problem("alice k"), .invalid)
        XCTAssertEqual(HandleRule.problem("αβγ"), .invalid)
        XCTAssertEqual(HandleRule.problem("Admin"), .reserved)
        XCTAssertEqual(HandleRule.problem("TavTav_team"), .reserved)
    }

    func testHandleSuggestionsTransliterate() {
        XCTAssertEqual(HandleRule.suggest(from: "Alice K."), "Alice_K")
        XCTAssertEqual(HandleRule.suggest(from: "José María"), "Jose_Maria")
        XCTAssertEqual(HandleRule.suggest(from: "Σάμης"), "Sames")
        XCTAssertNotNil(HandleRule.suggest(from: "سام رضایی"))
        XCTAssertNil(HandleRule.suggest(from: "Al"))
        XCTAssertNil(HandleRule.suggest(from: "admin"))
        XCTAssertEqual(HandleRule.suggest(from: String(repeating: "Bob ", count: 10))?.count, 19)   // trailing _ trimmed
    }

    func testSearchQueries() {
        XCTAssertEqual(HandleRule.searchQuery(" @Alex "), "alex")
        XCTAssertNil(HandleRule.searchQuery("al"))
        XCTAssertNil(HandleRule.searchQuery("@al"))
        XCTAssertNil(HandleRule.searchQuery("al ex"))
    }

    private func person(_ id: String, pinned: Bool = false, played: Int64? = 10, presence: ServerAPI.Presence? = nil,
                        challenge: ServerAPI.PersonChallenge? = nil) -> ServerAPI.Person {
        ServerAPI.Person(playerID: id, handle: id, displayName: id.capitalized, pinned: pinned, lastPlayedAt: played,
                         presence: presence, challenge: challenge)
    }

    func testRowStatusAndOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(person("a", presence: .init(online: true, lastSeenAt: ms)).status(now: now), .online)
        XCTAssertEqual(person("a", presence: .init(online: false, lastSeenAt: ms - 7_200_000)).status(now: now),
                       .lastSeen(now.addingTimeInterval(-7200)))
        XCTAssertEqual(person("a").status(now: now), .none)
        let incoming = ServerAPI.PersonChallenge(matchID: "m1", direction: .incoming, variant: "fevga", targetWins: 2, expiresAt: ms + 1)
        XCTAssertEqual(person("a", challenge: incoming).status(now: now), .wantsToPlay(matchID: "m1"))
        var outgoing = incoming
        outgoing.direction = .outgoing
        XCTAssertEqual(person("a", challenge: outgoing).status(now: now), .waitingForAnswer(matchID: "m1"))
        outgoing.expiresAt = ms - 1
        XCTAssertEqual(person("a", challenge: outgoing).status(now: now), .none)   // expired: back to presence

        let list = [person("old", played: 1), person("added", played: nil), person("star", pinned: true, played: 2),
                    person("new", played: 30)].sorted(by: ServerAPI.Person.listOrder)
        XCTAssertEqual(list.map(\.playerID), ["star", "new", "old", "added"])
    }

    func testTheLastChoiceIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ServerPeopleTests-\(UUID().uuidString)"))
        let fallback = ChallengeChoice(variant: "plakoto_standard", targetWins: 2)
        XCTAssertEqual(ChallengeChoice.load(from: defaults, fallback: fallback), fallback)
        ChallengeChoice(variant: "fevga", targetWins: 1).save(to: defaults)
        XCTAssertEqual(ChallengeChoice.load(from: defaults, fallback: fallback), ChallengeChoice(variant: "fevga", targetWins: 1))
        defaults.set("chess", forKey: ChallengeChoice.variantKey)
        XCTAssertEqual(ChallengeChoice.load(from: defaults, fallback: fallback).variant, "plakoto_standard")
    }

    func testChallengePushesAreRecognised() throws {
        let data = try Data(contentsOf: ServerAPITests.fixturesDir.appendingPathComponent("push-payload-challenge.json"))
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
        XCTAssertEqual(PushSupport.challengeMatchID(fromUserInfo: userInfo), "m_c1a2b3c4d5e6")
        XCTAssertFalse(PushSupport.shouldPresentInForeground(kind: .challengeReceived, pushMatchID: "m_x", openMatchID: nil,
                                                             showsChallengesInApp: true))
        XCTAssertTrue(PushSupport.shouldPresentInForeground(kind: .challengeReceived, pushMatchID: "m_x", openMatchID: nil,
                                                            showsChallengesInApp: false))
        XCTAssertTrue(PushSupport.shouldPresentInForeground(kind: .challengeAccepted, pushMatchID: "m_x", openMatchID: nil,
                                                            showsChallengesInApp: true))
        XCTAssertFalse(PushSupport.shouldPresentInForeground(kind: .yourTurn, pushMatchID: "m_x", openMatchID: "m_x",
                                                             showsChallengesInApp: true))
    }

    // MARK: - Two devices on the fake server

    private var server: FakeTavtavServer!
    private var devices: [(people: ServerPeople, presence: ServerPresenceConnection)] = []

    override func setUp() async throws {
        server = FakeTavtavServer()
        server.names = ["acc_alice": "Alice", "acc_bob": "Bob", "acc_sam": "Sam"]
        server.handles = ["acc_alice": "alice", "acc_bob": "bob_b", "acc_sam": "sam", "acc_alex": "alex"]
        server.names["acc_alex"] = "Alex"
        server.people = [
            "acc_alice": [ServerAPI.Person(playerID: "acc_bob", handle: "bob_b", displayName: "Bob", lastPlayedAt: 100)],
            "acc_bob": [ServerAPI.Person(playerID: "acc_alice", handle: "alice", displayName: "Alice", lastPlayedAt: 100)],
        ]
    }

    override func tearDown() async throws {
        for d in devices {
            d.presence.stop()
            d.people.lobby.controller.close()
            d.people.service.close()
        }
        devices = []
    }

    private func device(_ account: String) async -> ServerPeople {
        let service = ServerMatchService(client: FakeServerClient(account, server: server), sockets: server.sockets)
        let controller = OnlineMatchController(service: service)
        service.controller = controller
        let lobby = ServerLobby(service: service, controller: controller)
        let people = ServerPeople(service: service, lobby: lobby)
        let presence = ServerPresenceConnection(service: service, sockets: server.sockets)
        presence.onMessage = { [weak people] in people?.handle($0) }
        presence.start()
        devices.append((people, presence))
        await settle()
        await people.refresh()
        await lobby.refresh()
        return people
    }

    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    /// Waits (up to ~1 s) for `condition`.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testChallengeArrivesLiveAndAcceptStartsTheMatchOnBoth() async throws {
        let alice = await device("acc_alice")
        let bob = await device("acc_bob")
        var accepted: [OutgoingChallenge] = []
        alice.onAccepted = { accepted.append($0) }
        var cards: [IncomingChallenge] = []
        bob.onIncoming = { cards.append($0) }

        let sent = await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "fevga", targetWins: 2)
        XCTAssertTrue(sent)
        XCTAssertEqual(alice.waiting?.state, .waiting)
        XCTAssertEqual(alice.person("acc_bob")?.status(), .waitingForAnswer(matchID: try XCTUnwrap(alice.waiting?.matchID)))
        await settle()
        let card = try XCTUnwrap(bob.incoming.first)
        XCTAssertEqual(cards, [card])
        XCTAssertEqual(card.fromName, "Alice")
        XCTAssertEqual(card.variant, "fevga")
        XCTAssertEqual(card.targetWins, 2)
        XCTAssertEqual(bob.person("acc_alice")?.status(), .wantsToPlay(matchID: card.matchID))

        let opened = await bob.accept(card)
        XCTAssertTrue(opened)
        XCTAssertTrue(bob.incoming.isEmpty)
        // Bob's game is open (Alice moves first, so it waits for her opening turn).
        await until { bob.lobby.controller.activeMatchID != nil }
        XCTAssertEqual(bob.lobby.controller.activeMatchID, card.matchID)
        await settle()
        XCTAssertEqual(alice.waiting?.state, .accepted)
        XCTAssertEqual(accepted.map(\.matchID), [card.matchID])
        let openedForAlice = await alice.openAccepted()
        XCTAssertTrue(openedForAlice)
        XCTAssertNil(alice.waiting)
        await until { alice.lobby.controller.session != nil }
        XCTAssertEqual(alice.lobby.controller.activeMatchID, card.matchID)
        XCTAssertNotNil(alice.lobby.controller.session, "the challenger holds the opening turn")
        // Both seats are active on the server: the match runs.
        XCTAssertEqual(server.matches[card.matchID]?.snap.participants.map(\.status), [.active, .active])
    }

    func testASecondTapAnswersThePendingChallenge() async throws {
        let alice = await device("acc_alice")
        _ = await device("acc_bob")
        await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "portes", targetWins: 1)
        let first = alice.waiting?.matchID
        await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "portes", targetWins: 1)
        XCTAssertEqual(alice.waiting?.matchID, first)
        XCTAssertEqual(server.challenges.count, 1)
    }

    func testDeclineTellsTheChallengerLive() async throws {
        let alice = await device("acc_alice")
        let bob = await device("acc_bob")
        await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "fevga", targetWins: 1)
        await settle()
        let card = try XCTUnwrap(bob.incoming.first)
        await bob.decline(card)
        XCTAssertTrue(bob.incoming.isEmpty)
        await settle()
        XCTAssertEqual(alice.waiting?.state, .declined)
        XCTAssertNil(alice.person("acc_bob")?.challenge)
        XCTAssertEqual(server.challenges[card.matchID]?.status, "declined")
    }

    func testCancelRemovesTheCardLive() async throws {
        let alice = await device("acc_alice")
        let bob = await device("acc_bob")
        await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "fevga", targetWins: 1)
        await settle()
        XCTAssertEqual(bob.incoming.count, 1)
        await alice.cancelWaiting()
        XCTAssertNil(alice.waiting)
        await settle()
        XCTAssertTrue(bob.incoming.isEmpty)
    }

    func testCrossedTapsOpenTheMatchAtOnce() async throws {
        let alice = await device("acc_alice")
        let bob = await device("acc_bob")
        var accepted: [OutgoingChallenge] = []
        bob.onAccepted = { accepted.append($0) }
        await alice.challenge(playerID: "acc_bob", name: "Bob", variant: "fevga", targetWins: 2)
        await settle()
        // Bob taps Alice for the same game before seeing her card.
        await bob.challenge(playerID: "acc_alice", name: "Alice", variant: "fevga", targetWins: 2)
        XCTAssertEqual(bob.waiting?.state, .accepted)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(bob.incoming.isEmpty)
        await settle()
        XCTAssertEqual(alice.waiting?.state, .accepted)
    }

    func testAStrangersChallengeShowsFromTheLobbyAndCanBeBlocked() async throws {
        let bob = await device("acc_bob")
        let sam = await device("acc_sam")
        bob.presenceStopForTest(devices)
        await sam.challenge(playerID: "acc_bob", name: "Bob", variant: "portes", targetWins: 1)
        await settle()
        XCTAssertTrue(bob.incoming.isEmpty)   // socket off: nothing live
        await bob.lobby.refresh()
        bob.syncWithLobby()
        let card = try XCTUnwrap(bob.incoming.first)
        XCTAssertEqual(card.fromName, "Sam")
        await bob.block(playerID: "acc_sam")
        XCTAssertTrue(bob.incoming.isEmpty)
        XCTAssertEqual(bob.blocked.map(\.playerID), ["acc_sam"])
        let sentWhileBlocked = await sam.challenge(playerID: "acc_bob", name: "Bob", variant: "portes", targetWins: 2)
        XCTAssertFalse(sentWhileBlocked)
        if case .failed = sam.waiting?.state {} else { XCTFail("blocked challenge must fail") }
        await bob.unblock(playerID: "acc_sam")
        XCTAssertTrue(bob.blocked.isEmpty)
    }

    func testPresenceUpdatesLive() async throws {
        let alice = await device("acc_alice")
        XCTAssertFalse(alice.person("acc_bob")?.isOnline ?? true)
        server.presenceChange(to: "acc_alice", playerID: "acc_bob", online: true)
        await settle()
        XCTAssertTrue(alice.person("acc_bob")?.isOnline ?? false)
        server.presenceChange(to: "acc_alice", playerID: "acc_bob", online: false)
        await settle()
        XCTAssertEqual(alice.person("acc_bob")?.status(), .lastSeen(ServerAPI.date(1_800_000_000_000)))
    }

    func testPresenceRunsOnlyWhileStarted() async throws {
        let alice = await device("acc_alice")
        _ = alice
        let presence = devices[0].presence
        XCTAssertTrue(presence.isConnected)
        XCTAssertEqual(server.sockets.live("acc_alice"), 1)
        presence.stop()
        XCTAssertFalse(presence.isConnected)
        XCTAssertEqual(server.sockets.live("acc_alice"), 0)
        // A drop while in front reconnects; after stop it doesn't.
        presence.reconnectBase = 0.01
        presence.start()
        await settle()
        server.sockets.dropAll()
        try await Task.sleep(nanoseconds: 80_000_000)
        await settle()
        XCTAssertTrue(presence.isConnected)
        presence.stop()
        server.sockets.dropAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(presence.isConnected)
        XCTAssertEqual(server.sockets.live("acc_alice"), 0)
    }

    func testPinRemoveAndSearchAdd() async throws {
        let alice = await device("acc_alice")
        await alice.search("al")
        XCTAssertTrue(alice.searchResults.isEmpty)   // too short: nothing sent
        XCTAssertFalse(server.log.contains { $0.hasPrefix("GET /v1/players") })
        await alice.search("@ALE")
        XCTAssertEqual(alice.searchResults.map(\.handle), ["alex"])
        XCTAssertFalse(alice.searchResults[0].isPerson)
        await alice.setPinned(true, playerID: "acc_alex")
        XCTAssertEqual(alice.people.map(\.playerID), ["acc_alex", "acc_bob"])   // ⭐ first
        XCTAssertTrue(alice.searchResults[0].isPerson)
        await alice.setPinned(true, playerID: "acc_bob")
        XCTAssertEqual(alice.people.first?.playerID, "acc_bob")   // both pinned: newest game first
        await alice.remove(playerID: "acc_bob")
        XCTAssertEqual(alice.people.map(\.playerID), ["acc_alex"])
        await alice.refresh()
        XCTAssertEqual(alice.people.map(\.playerID), ["acc_alex"])
    }
}

private extension ServerPeople {
    /// Turns this device's presence socket off (a test helper: the app is in the background).
    func presenceStopForTest(_ devices: [(people: ServerPeople, presence: ServerPresenceConnection)]) {
        devices.first { $0.people === self }?.presence.stop()
    }
}
