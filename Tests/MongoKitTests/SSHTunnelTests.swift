import Foundation
import Testing
@testable import MongoKit

@Suite("SSH tunnel")
struct SSHTunnelTests {
    @Test func buildsArgumentsForPrivateKey() throws {
        let configuration = SSHTunnelConfiguration(host: "bastion.example.com", port: 2222, username: "deploy",
                                                   authentication: .privateKey, privateKeyPath: "~/.ssh/id_ed25519")
        let arguments = try SSHTunnel.arguments(for: configuration, localPort: 40001, remote: ServerAddress(host: "10.0.0.5", port: 27017))
        #expect(arguments.contains("-N"))
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.joined(separator: " ").contains("-L 127.0.0.1:40001:10.0.0.5:27017"))
        #expect(arguments.joined(separator: " ").contains("-p 2222"))
        #expect(arguments.contains((("~/.ssh/id_ed25519") as NSString).expandingTildeInPath))
        #expect(arguments.last == "deploy@bastion.example.com")
    }

    @Test func passwordAuthenticationDisablesPublicKeys() throws {
        let configuration = SSHTunnelConfiguration(host: "b", username: "u", authentication: .password)
        let arguments = try SSHTunnel.arguments(for: configuration, localPort: 1, remote: ServerAddress(host: "::1", port: 27018))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.joined(separator: " ").contains("-L 127.0.0.1:1:[::1]:27018"))
    }

    @Test(arguments: ["-oProxyCommand=evil", "", "a b"])
    func rejectsArgumentInjection(host: String) {
        let configuration = SSHTunnelConfiguration(host: host, username: "u", authentication: .agent)
        #expect(throws: MongoError.self) {
            _ = try SSHTunnel.arguments(for: configuration, localPort: 1, remote: ServerAddress(host: "h"))
        }
    }

    @Test func rejectsUsernameInjection() {
        let configuration = SSHTunnelConfiguration(host: "h", username: "-oProxyCommand=x", authentication: .agent)
        #expect(throws: MongoError.self) {
            _ = try SSHTunnel.arguments(for: configuration, localPort: 1, remote: ServerAddress(host: "h"))
        }
    }

    @Test func findsAFreeLocalPort() throws {
        let port = try SSHTunnel.freeLocalPort()
        #expect((1024...65535).contains(port))
    }

    @Test func unreachableBastionFailsWithSSHError() async throws {
        let configuration = SSHTunnelConfiguration(host: "127.0.0.1", port: 1, username: "nobody", authentication: .agent)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect {
            _ = try await SSHTunnel.open(configuration: configuration, secret: nil, remote: ServerAddress(host: "127.0.0.1"), timeout: 10)
        } throws: { error in
            (error as? MongoError)?.kind == .sshTunnel
        }
        #expect(clock.now - start < .seconds(10))
    }
}
