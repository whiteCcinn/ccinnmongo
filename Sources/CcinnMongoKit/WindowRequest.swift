import Foundation

/// Asks for a new window that connects right away. Every window has its own connection; the nonce makes each
/// request unique, because SwiftUI brings an existing window to the front instead of opening a new one when the
/// requested value is equal.
///
/// Only ids travel in the request: SwiftUI persists it for window restoration, so it must never carry a secret.
/// The connection itself is handed over in memory through `WindowHandoff`.
public struct WindowRequest: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let nonce: UUID

    public init(profileID: UUID) {
        self.profileID = profileID
        nonce = UUID()
    }

    private enum CodingKeys: String, CodingKey { case profileID, nonce }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        // A value without a nonce (older or foreign data) still opens its own window and is never handed off.
        nonce = try container.decodeIfPresent(UUID.self, forKey: .nonce) ?? UUID()
    }
}
