import Foundation
import CcinnMongoKit
import MongoKit
import Observation

/// Opens a MongoDB connection for a profile (optionally through an SSH tunnel).
enum ConnectionOpener {
    struct Opened: Sendable {
        let client: MongoClient
        let info: ServerInfo
        let tunnel: SSHTunnel?
    }

    static func open(uri: ConnectionString, ssh: SSHTunnelConfiguration?, sshSecret: String?, allowLegacyTLS: Bool,
                     progress: @escaping @Sendable (String) -> Void) async throws -> Opened {
        var effective = uri
        var tunnel: SSHTunnel?
        if let ssh {
            guard let target = uri.hosts.first, uri.scheme == .standard else {
                throw MongoError(.sshTunnel, "SSH tunnels require a mongodb:// connection string with a host")
            }
            progress("Opening SSH tunnel through \(ssh.host)…")
            let opened = try await SSHTunnel.open(configuration: ssh, secret: sshSecret, remote: target)
            tunnel = opened
            effective.hosts = [opened.localAddress]
            effective.setOption("directConnection", "true")
            if effective.tls {
                // The certificate names the real host, not 127.0.0.1; the SSH channel is already authenticated.
                effective.setOption("tlsAllowInvalidHostnames", "true")
            }
        }
        let client = MongoClient(effective, options: MongoClientOptions(allowLegacyTLS: allowLegacyTLS))
        do {
            let info = try await client.connect { stage in
                switch stage {
                case .resolvingSRV: progress("Resolving DNS seed list…")
                case .selectingServer: progress("Connecting to \(uri.hosts.map(\.description).joined(separator: ", "))…")
                case .authenticating: progress(uri.username == nil ? "Opening connection…" : "Authenticating as \(uri.username ?? "")…")
                case .loadingServerInfo: progress("Loading server information…")
                }
            }
            return Opened(client: client, info: info, tunnel: tunnel)
        } catch {
            await client.close()
            tunnel?.close()
            throw error
        }
    }
}

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
