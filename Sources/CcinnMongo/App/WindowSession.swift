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

    func connect(profile: ConnectionProfile, store: ProfileStore) {
        connectError = nil
        let uri: ConnectionString
        do {
            uri = try store.connectionString(for: profile)
        } catch {
            connectError = (error as? MongoError)?.message ?? error.localizedDescription
            return
        }
        let name = profile.displayName
        phase = .connecting(name: name, status: "Connecting…")
        let sshSecret = profile.ssh != nil ? store.sshSecret(for: profile) : nil
        // `self` is main-actor isolated (and therefore Sendable); the task ends when connecting does.
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let opened = try await ConnectionOpener.open(uri: uri, ssh: profile.ssh, sshSecret: sshSecret,
                                                             allowLegacyTLS: profile.allowLegacyTLS, progress: report)
                if Task.isCancelled {
                    await opened.client.close()
                    opened.tunnel?.close()
                    return
                }
                store.markConnected(profile.id)
                self.phase = .connected(WorkspaceModel(profile: profile, client: opened.client, serverInfo: opened.info, tunnel: opened.tunnel))
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

    /// Connects to a URI without a saved profile (used by the `--connect` launch argument).
    func connect(uri: ConnectionString, then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        let name = uri.hosts.map(\.description).joined(separator: ",")
        let profile = ConnectionProfile(name: name, uri: { var copy = uri; copy.password = nil; return copy.description }(), color: .green)
        phase = .connecting(name: name, status: "Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let opened = try await ConnectionOpener.open(uri: uri, ssh: nil, sshSecret: nil, allowLegacyTLS: false, progress: report)
                let workspace = WorkspaceModel(profile: profile, client: opened.client, serverInfo: opened.info, tunnel: nil)
                self.phase = .connected(workspace)
                then?(workspace)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
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
