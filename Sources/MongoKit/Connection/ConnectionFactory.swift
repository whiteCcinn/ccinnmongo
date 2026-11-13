import Foundation
import os

/// Creates handshaken, authenticated connections. Shared by all pools of one client.
struct ConnectionFactory: Sendable {
    let transportFactory: TransportFactory
    let transportOptions: TransportOptions
    let credential: MongoCredential?
    let appName: String?
    let readPreference: ReadPreferenceMode

    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    static func nextConnectionID() -> Int {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    /// Opens a connection and performs the handshake only (used for server discovery).
    func probe(_ address: ServerAddress) async throws -> (HelloResponse, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let transport = try await transportFactory(address, transportOptions)
        let connection = MongoConnection(id: Self.nextConnectionID(), address: address, transport: transport)
        defer { connection.forceClose() }
        let hello = try await connection.handshake(appName: appName, saslSupportedMechsFor: nil)
        return (hello, clock.now - start)
    }

    func makeConnection(to address: ServerAddress) async throws -> MongoConnection {
        let transport = try await transportFactory(address, transportOptions)
        let connection = MongoConnection(id: Self.nextConnectionID(), address: address, transport: transport)
        do {
            let saslUser = credential.flatMap { $0.mechanism == nil ? "\($0.source).\($0.username)" : nil }
            let hello = try await connection.handshake(appName: appName, saslSupportedMechsFor: saslUser)
            await connection.configureReadPreference(readPreference)
            if let credential {
                try await Authenticator.authenticate(connection, credential: credential, hello: hello)
            }
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }
}
