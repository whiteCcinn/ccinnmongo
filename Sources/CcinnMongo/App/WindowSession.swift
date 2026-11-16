import Foundation
import CcinnMongoKit
import MongoKit
import Observation

/// State of one window: choosing a connection, connecting, or connected to a workspace.
@MainActor
@Observable
final class WindowSession {
    enum Phase {
        case connections
        case connecting(name: String, status: String)
        case connected(WorkspaceModel)
    }

    var phase: Phase = .connections
    var connectError: String?
    private var connectTask: Task<Void, Never>?

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    /// Connects to a saved profile, reading its secrets from the store.
    func connect(profile: ConnectionProfile, store: ProfileStore) {
        connectError = nil
        let uri: ConnectionString
        do {
            uri = try store.connectionString(for: profile)
        } catch {
            connectError = (error as? MongoError)?.message ?? error.localizedDescription
            return
        }
        let sshSecret = profile.ssh != nil ? store.sshSecret(for: profile) : nil
        open(profile: profile, credentials: ConnectionCredentials(uri: uri, sshSecret: sshSecret), store: store)
    }

    /// Connects to a URI without a saved profile (used by the `--connect` launch argument).
    func connect(uri: ConnectionString, then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        let name = uri.hosts.map(\.description).joined(separator: ",")
        let profile = ConnectionProfile(name: name, uri: { var copy = uri; copy.password = nil; return copy.description }(), color: .green)
        open(profile: profile, credentials: ConnectionCredentials(uri: uri, sshSecret: nil), store: nil, then: then)
    }

    /// Connects a window opened by a request of this process and returns `true`. A request without a handed-off
    /// connection is a window macOS restored after a relaunch: it returns `false`, stays on the connection screen
    /// and never connects by itself.
    @discardableResult
    func connect(_ request: WindowRequest, store: ProfileStore) -> Bool {
        guard let connection = Self.handoff.take(request) else { return false }
        if let credentials = connection.credentials {
            open(profile: connection.profile, credentials: credentials, store: store)
        } else {
            connect(profile: connection.profile, store: store)
        }
        return true
    }

    /// A request for another window connected like this one: the same profile and the credentials in use (so
    /// unsaved connections and secrets that are not in the Keychain work too). The new window opens its own
    /// connection, and its own SSH tunnel. `nil` when this window is not connected.
    func duplicateRequest() -> WindowRequest? {
        guard let workspace else { return nil }
        return Self.handoff.request(profileID: workspace.profile.id,
                                    payload: WindowConnection(profile: workspace.profile, credentials: workspace.credentials))
    }

    /// A request for a new window that connects to a saved profile, reading its secrets from the store as Connect does.
    static func request(opening profile: ConnectionProfile) -> WindowRequest {
        handoff.request(profileID: profile.id, payload: WindowConnection(profile: profile, credentials: nil))
    }

    /// Connections handed to windows this process opens (see `WindowHandoff`). Memory only, never persisted.
    private static let handoff = WindowHandoff<WindowConnection>()

    private func open(profile: ConnectionProfile, credentials: ConnectionCredentials, store: ProfileStore?,
                      then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        connectTask?.cancel()
        let name = profile.displayName
        phase = .connecting(name: name, status: "Connecting…")
        // `self` is main-actor isolated (and therefore Sendable); the task ends when connecting does.
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let opened = try await ConnectionOpener.open(uri: credentials.uri, ssh: profile.ssh, sshSecret: credentials.sshSecret,
                                                             allowLegacyTLS: profile.allowLegacyTLS, progress: report)
                if Task.isCancelled {
                    await opened.close()
                    return
                }
                store?.markConnected(profile.id)
                let workspace = WorkspaceModel(profile: profile, client: opened.client, serverInfo: opened.info,
                                               tunnel: opened.tunnel, credentials: credentials)
                self.phase = .connected(workspace)
                then?(workspace)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
    }

    private func updateStatus(name: String, status: String) {
        guard case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .connections
    }

    func disconnect() {
        if let workspace {
            workspace.shutdown()
        }
        phase = .connections
    }
}

/// What a window connected with, kept in memory only: the connection string before any SSH tunnel rewrote it, with
/// every secret (password, TLS key password, other secret options), and the SSH secret.
struct ConnectionCredentials: Sendable {
    let uri: ConnectionString
    let sshSecret: String?
}

/// The connection a new window opens: a profile and, when duplicating, the credentials in use (`nil` = read them
/// from the store, as Connect does).
struct WindowConnection {
    let profile: ConnectionProfile
    let credentials: ConnectionCredentials?
}
