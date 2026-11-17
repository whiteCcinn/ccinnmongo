import Foundation

/// Hands the connection to open (profile, credentials in use, …) to a window this process opens. A `WindowRequest`
/// only carries ids, because SwiftUI may persist and restore it, so the payload stays here, in memory, until the new
/// window takes it, exactly once.
///
/// A request without a payload was not created by this process: it is a window macOS restored after a relaunch.
/// Such a window shows the connection screen and never connects by itself.
///
/// A window takes its payload as soon as it appears. A payload still waiting after `lifetime` belongs to a window
/// that never opened; it is dropped rather than kept, with its secrets, until the app quits.
@MainActor
public final class WindowHandoff<Payload> {
    private struct Entry {
        let payload: Payload
        let expiresAt: ContinuousClock.Instant
    }

    private var pending: [UUID: Entry] = [:]
    private let lifetime: Duration
    private let now: () -> ContinuousClock.Instant

    public init(lifetime: Duration = .seconds(60), now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.lifetime = lifetime
        self.now = now
    }

    /// Stores `payload` and returns a new, unique request for it.
    public func request(profileID: UUID, payload: Payload) -> WindowRequest {
        removeExpired()
        let request = WindowRequest(profileID: profileID)
        pending[request.nonce] = Entry(payload: payload, expiresAt: now() + lifetime)
        return request
    }

    /// The payload handed off for `request`, removed so that it is delivered only once; `nil` when there is none
    /// (or it expired).
    public func take(_ request: WindowRequest) -> Payload? {
        removeExpired()
        return pending.removeValue(forKey: request.nonce)?.payload
    }

    /// Payloads not taken yet.
    public var pendingCount: Int { pending.count }

    private func removeExpired() {
        guard !pending.isEmpty else { return }
        let current = now()
        pending = pending.filter { $0.value.expiresAt > current }
    }
}
