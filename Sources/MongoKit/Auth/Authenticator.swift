import BSON
import Foundation

/// Runs an authentication conversation on a freshly handshaken connection.
enum Authenticator {
    static func authenticate(_ connection: MongoConnection, credential: MongoCredential, hello: HelloResponse) async throws {
        let mechanism = AuthMechanism.negotiate(requested: credential.mechanism,
                                                maxWireVersion: hello.maxWireVersion,
                                                saslSupportedMechs: hello.saslSupportedMechs)
        do {
            switch mechanism {
            case .scramSHA1:
                let password = MongoCRAuthenticator.passwordDigest(username: credential.username, password: credential.password)
                try await scram(connection, variant: .sha1, credential: credential, preparedPassword: password, hello: hello)
            case .scramSHA256:
                guard hello.maxWireVersion >= 7 else {
                    throw MongoError(.authentication, "SCRAM-SHA-256 requires MongoDB 4.0 or later")
                }
                let password = try SASLPrep.prepare(credential.password)
                try await scram(connection, variant: .sha256, credential: credential, preparedPassword: password, hello: hello)
            case .mongoCR:
                try await mongoCR(connection, credential: credential)
            case .plain:
                try await plain(connection, credential: credential)
            }
        } catch let error as MongoError where error.kind == .command || error.kind == .authentication {
            let detail = error.kind == .authentication ? error.message : error.message
            throw MongoError(.authentication,
                             "Authentication failed (\(mechanism.rawValue) on \(credential.source)): \(detail)",
                             code: error.code, codeName: error.codeName)
        }
    }

    private static func scram(_ connection: MongoConnection, variant: ScramClient.Variant, credential: MongoCredential,
                              preparedPassword: String, hello: HelloResponse) async throws {
        var client = ScramClient(variant: variant, username: credential.username, password: preparedPassword)
        var start: BSONDocument = [
            "saslStart": 1,
            "mechanism": .string(variant.mechanismName),
            "payload": .binary(BSONBinary(subtype: .generic, data: Data(client.clientFirstMessage.utf8))),
            "autoAuthorize": 1,
        ]
        if hello.maxWireVersion >= 9 { start["options"] = ["skipEmptyExchange": true] }

        let first = try await connection.runCommand(start, database: credential.source)
        guard let conversationID = first["conversationId"], let serverFirst = payloadString(first) else {
            throw MongoError(.authentication, "Invalid saslStart reply")
        }
        let clientFinal = try client.clientFinalMessage(serverFirst: serverFirst)

        var reply = try await connection.runCommand([
            "saslContinue": 1,
            "conversationId": conversationID,
            "payload": .binary(BSONBinary(subtype: .generic, data: Data(clientFinal.utf8))),
        ], database: credential.source)
        guard let serverFinal = payloadString(reply) else {
            throw MongoError(.authentication, "Invalid saslContinue reply")
        }
        try client.verifyServerFinal(serverFinal)

        // Servers before 4.4 expect one more empty exchange.
        var rounds = 0
        while reply["done"]?.isTruthy != true {
            rounds += 1
            guard rounds <= 3 else { throw MongoError(.authentication, "SCRAM conversation did not complete") }
            reply = try await connection.runCommand([
                "saslContinue": 1,
                "conversationId": conversationID,
                "payload": .binary(BSONBinary(subtype: .generic, data: Data())),
            ], database: credential.source)
        }
    }

    private static func mongoCR(_ connection: MongoConnection, credential: MongoCredential) async throws {
        let nonceReply = try await connection.runCommand(["getnonce": 1], database: credential.source)
        guard let nonce = nonceReply["nonce"]?.stringValue else {
            throw MongoError(.authentication, "Server did not return a nonce")
        }
        let digest = MongoCRAuthenticator.passwordDigest(username: credential.username, password: credential.password)
        let key = MongoCRAuthenticator.key(nonce: nonce, username: credential.username, passwordDigest: digest)
        _ = try await connection.runCommand([
            "authenticate": 1,
            "user": .string(credential.username),
            "nonce": .string(nonce),
            "key": .string(key),
        ], database: credential.source)
    }

    private static func plain(_ connection: MongoConnection, credential: MongoCredential) async throws {
        var payload = Data([0])
        payload.append(contentsOf: Array(credential.username.utf8))
        payload.append(0)
        payload.append(contentsOf: Array(credential.password.utf8))
        _ = try await connection.runCommand([
            "saslStart": 1,
            "mechanism": "PLAIN",
            "payload": .binary(BSONBinary(subtype: .generic, data: payload)),
            "autoAuthorize": 1,
        ], database: credential.source)
    }

    private static func payloadString(_ reply: BSONDocument) -> String? {
        switch reply["payload"] {
        case let .binary(binary)?: String(decoding: binary.data, as: UTF8.self)
        case let .string(text)?: Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) } ?? text
        default: nil
        }
    }
}
