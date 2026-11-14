import CcinnMongoKit
import Foundation
import MongoKit
import os

/// One pooled session per profile for the life of the MCP process.
///
/// The actor only stores opening tasks; DNS, SSH, TLS and authentication run outside it, and concurrent
/// first calls for a profile share one opening. A profile edit (URI, SSH or TLS settings) reopens.
public actor MCPConnectionManager: MCPSessionSource {
    private struct Entry {
        let token: UInt64
        let fingerprint: Fingerprint
        let task: Task<OpenedSession, any Error>
    }

    /// The settings that determine how a profile connects.
    struct Fingerprint: Hashable {
        let uri: String
        let ssh: SSHTunnelConfiguration?
        let allowLegacyTLS: Bool

        init(_ profile: ConnectionProfile) {
            uri = profile.uri
            ssh = profile.ssh
            allowLegacyTLS = profile.allowLegacyTLS
        }
    }

    private let opener: any MCPSessionOpening
    private var entries: [UUID: Entry] = [:]
    private var nextToken: UInt64 = 0
    private var isClosed = false

    public init(opener: any MCPSessionOpening) {
        self.opener = opener
    }

    public func session(for profile: ConnectionProfile) async throws -> MongoSession {
        guard !isClosed else { throw MongoError(.connectionClosed, "The MCP server is shutting down") }
        let fingerprint = Fingerprint(profile)
        let entry: Entry
        if let existing = entries[profile.id], existing.fingerprint == fingerprint {
            entry = existing
        } else {
            if let stale = entries.removeValue(forKey: profile.id) { Self.closeInBackground(stale) }
            nextToken &+= 1
            let opener = self.opener
            entry = Entry(token: nextToken, fingerprint: fingerprint, task: Task { try await opener.open(profile) })
            entries[profile.id] = entry
        }
        do {
            let opened = try await CancellableWait.value(of: entry.task)
            return MongoSession(id: entry.token, client: opened.session.client, server: opened.session.server)
        } catch {
            // A failed opening is not cached; a cancelled waiter leaves the shared opening running.
            if !Task.isCancelled, entries[profile.id]?.token == entry.token {
                entries.removeValue(forKey: profile.id)
            }
            throw error
        }
    }

    public func evict(_ profileID: UUID, sessionID: UInt64) {
        guard let entry = entries[profileID], entry.token == sessionID else { return }
        entries.removeValue(forKey: profileID)
        Self.closeInBackground(entry)
    }

    /// Convenience for tests and shutdown paths that do not track session ids.
    public func evict(_ profileID: UUID) {
        guard let entry = entries.removeValue(forKey: profileID) else { return }
        Self.closeInBackground(entry)
    }

    /// Closes every session (and SSH tunnel); later calls fail.
    public func closeAll() async {
        isClosed = true
        let all = entries.values
        entries.removeAll()
        for entry in all {
            entry.task.cancel()
            if let opened = try? await entry.task.value { await opened.close() }
        }
    }

    private static func closeInBackground(_ entry: Entry) {
        Task {
            if let opened = try? await entry.task.value { await opened.close() }
        }
    }
}

/// Awaits a shared task's value while staying responsive to cancellation of the waiting task
/// (`Task.value` alone would keep waiting until the shared task finishes).
enum CancellableWait {
    static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let state = WaitState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                state.install(continuation)
                Task { state.resume(with: await task.result) }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    /// Resumes the continuation exactly once, whichever of result, cancellation or installation comes first.
    private final class WaitState<T: Sendable>: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<T, any Error>?
            var pending: Result<T, any Error>?
            var finished = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let ready = lock.withLock { state -> Result<T, any Error>? in
                if let pending = state.pending {
                    state.pending = nil
                    return pending
                }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }

        func resume(with result: Result<T, any Error>) {
            let continuation = lock.withLock { state -> CheckedContinuation<T, any Error>? in
                guard !state.finished else { return nil }
                state.finished = true
                if let continuation = state.continuation {
                    state.continuation = nil
                    return continuation
                }
                state.pending = result
                return nil
            }
            continuation?.resume(with: result)
        }
    }
}

/// Runs an operation with a time limit; on expiry the operation's task is cancelled, which closes the
/// MongoDB socket it is waiting on.
enum MCPDeadline {
    struct Expired: Error, Sendable {}

    static func run<T: Sendable>(milliseconds: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(max(1, milliseconds)))
                throw Expired()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Expired() }
            return result
        }
    }
}
