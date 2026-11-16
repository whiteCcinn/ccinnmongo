import Foundation

/// Hands the connection to open (profile, credentials in use, …) to a window this process opens. A `WindowRequest`
/// only carries ids, because SwiftUI may persist and restore it, so the payload stays here, in memory, until the new
/// window takes it, exactly once.
///
/// A request without a payload was not created by this process: it is a window macOS restored after a relaunch.
/// Such a window shows the connection screen and never connects by itself.
@MainActor
public final class WindowHandoff<Payload> {
    private var pending: [UUID: Payload] = [:]

    public init() {}

    /// Stores `payload` and returns a new, unique request for it.
    public func request(profileID: UUID, payload: Payload) -> WindowRequest {
        let request = WindowRequest(profileID: profileID)
        pending[request.nonce] = payload
        return request
    }

    /// The payload handed off for `request`, removed so that it is delivered only once; `nil` when there is none.
    public func take(_ request: WindowRequest) -> Payload? {
        pending.removeValue(forKey: request.nonce)
    }

    /// Payloads not taken yet.
    public var pendingCount: Int { pending.count }
}
