import Foundation
import MongoKit

/// Opens a MongoDB connection for a profile (optionally through an SSH tunnel).
public enum ConnectionOpener {
    public struct Opened: Sendable {
        public let client: MongoClient
        public let info: ServerInfo
        public let tunnel: SSHTunnel?

        public init(client: MongoClient, info: ServerInfo, tunnel: SSHTunnel?) {
            self.client = client
            self.info = info
            self.tunnel = tunnel
        }

        /// Closes the client and then the tunnel it runs through.
        public func close() async {
            await client.close()
            tunnel?.close()
        }
    }

    public static func open(uri: ConnectionString, ssh: SSHTunnelConfiguration?, sshSecret: String?, allowLegacyTLS: Bool,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Opened {
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
