import Foundation
import Testing
@testable import CcinnMongoKit

@Suite("Window requests")
struct WindowRequestTests {
    @Test func everyRequestIsUniqueEvenForTheSameProfile() {
        let profileID = UUID()
        let first = WindowRequest(profileID: profileID)
        let second = WindowRequest(profileID: profileID)
        #expect(first.profileID == second.profileID)
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }

    @Test func survivesACodableRoundTrip() throws {
        let request = WindowRequest(profileID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func decodesARequestWithoutANonce() throws {
        let profileID = UUID()
        let json = Data(#"{"profileID":"\#(profileID.uuidString)"}"#.utf8)
        let first = try JSONDecoder().decode(WindowRequest.self, from: json)
        let second = try JSONDecoder().decode(WindowRequest.self, from: json)
        #expect(first.profileID == profileID)
        #expect(first != second)
    }

    @Test func rejectsARequestWithoutAProfile() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"nonce":"\#(UUID().uuidString)"}"#.utf8))
        }
    }
}
