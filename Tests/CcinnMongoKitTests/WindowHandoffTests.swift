import Foundation
import Testing
@testable import CcinnMongoKit

@Suite("Window handoff")
@MainActor
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret in use")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(request) == "secret in use")
        #expect(handoff.take(request) == nil)
        #expect(handoff.pendingCount == 0)
    }

    @Test func aRequestThisProcessDidNotCreateHasNoPayload() throws {
        let handoff = WindowHandoff<String>()
        let profileID = UUID()
        _ = handoff.request(profileID: profileID, payload: "pending")
        // A restored window: same profile, decoded from what SwiftUI persisted, but not handed off here.
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(WindowRequest(profileID: profileID)))
        #expect(handoff.take(restored) == nil)
        #expect(handoff.pendingCount == 1)
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<Int>()
        let profileID = UUID()
        let first = handoff.request(profileID: profileID, payload: 1)
        let second = handoff.request(profileID: profileID, payload: 2)
        #expect(first != second)
        #expect(first.profileID == profileID && second.profileID == profileID)
        #expect(handoff.take(second) == 2)
        #expect(handoff.take(first) == 1)
        #expect(handoff.pendingCount == 0)
    }

    @Test func unclaimedPayloadsExpireSoTheirSecretsDoNotLinger() {
        let clock = ManualClock()
        let handoff = WindowHandoff<String>(lifetime: .seconds(60), now: { clock.now })
        let abandoned = handoff.request(profileID: UUID(), payload: "password of a window that never opened")
        clock.advance(by: .seconds(61))
        let fresh = handoff.request(profileID: UUID(), payload: "fresh")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(abandoned) == nil)
        #expect(handoff.take(fresh) == "fresh")
    }

    @Test func aPayloadIsDeliveredWithinItsLifetimeButNotAfter() {
        let clock = ManualClock()
        let handoff = WindowHandoff<Int>(lifetime: .seconds(60), now: { clock.now })
        let prompt = handoff.request(profileID: UUID(), payload: 1)
        let late = handoff.request(profileID: UUID(), payload: 2)
        clock.advance(by: .seconds(59))
        #expect(handoff.take(prompt) == 1)
        clock.advance(by: .seconds(2))
        #expect(handoff.take(late) == nil)
        #expect(handoff.pendingCount == 0)
    }

    @Test func aDecodedCopyOfAHandedOffRequestStillFindsItsPayload() throws {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "value")
        let copy = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(handoff.take(copy) == "value")
    }
}

/// A clock the test moves by hand.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) { now += duration }
}
