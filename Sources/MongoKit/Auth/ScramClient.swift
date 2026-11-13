import CommonCrypto
import CryptoKit
import Foundation
import os

/// RFC 5802 / RFC 7677 SCRAM client state machine (pure; no I/O).
///
/// The caller supplies the already-prepared password: for MongoDB SCRAM-SHA-1 that is the hex MD5
/// digest of `user:mongo:password`, for SCRAM-SHA-256 the SASLprep-ed password.
struct ScramClient: Sendable {
    enum Variant: Sendable {
        case sha1
        case sha256

        var mechanismName: String { self == .sha1 ? "SCRAM-SHA-1" : "SCRAM-SHA-256" }
    }

    let variant: Variant
    private let username: String
    private let password: String
    private let clientNonce: String
    private var expectedServerSignature: [UInt8]?

    init(variant: Variant, username: String, password: String, clientNonce: String = ScramClient.makeNonce()) {
        self.variant = variant
        self.username = username
        self.password = password
        self.clientNonce = clientNonce
    }

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    private var clientFirstBare: String { "n=\(Self.escape(username)),r=\(clientNonce)" }

    var clientFirstMessage: String { "n,," + clientFirstBare }

    mutating func clientFinalMessage(serverFirst: String) throws -> String {
        let attributes = Self.parseAttributes(serverFirst)
        if let error = attributes["e"] {
            throw MongoError(.authentication, "Server rejected authentication: \(error)")
        }
        guard let serverNonce = attributes["r"], let saltText = attributes["s"], let iterationText = attributes["i"],
              let salt = Data(base64Encoded: saltText), let iterations = Int(iterationText) else {
            throw MongoError(.authentication, "Invalid SCRAM server-first message")
        }
        guard serverNonce.hasPrefix(clientNonce), serverNonce.count > clientNonce.count else {
            throw MongoError(.authentication, "Server nonce does not extend the client nonce; authentication aborted")
        }
        // An absurd count from a hostile server would pin a CPU for minutes in uncancellable PBKDF2.
        guard iterations <= 10_000_000 else {
            throw MongoError(.authentication, "Server requested \(iterations) SCRAM iterations, more than the allowed 10,000,000")
        }
        guard iterations >= 4096 else {
            throw MongoError(.authentication, "Server requested only \(iterations) SCRAM iterations (minimum 4096)")
        }

        let keys = try ScramKeyCache.shared.keys(variant: variant, password: password, salt: [UInt8](salt), iterations: iterations)
        let clientFinalWithoutProof = "c=biws,r=\(serverNonce)"
        let authMessage = Array("\(clientFirstBare),\(serverFirst),\(clientFinalWithoutProof)".utf8)

        let storedKey = hash(keys.clientKey)
        let clientSignature = hmac(key: storedKey, message: authMessage)
        let proof = zip(keys.clientKey, clientSignature).map { $0 ^ $1 }
        expectedServerSignature = hmac(key: keys.serverKey, message: authMessage)

        return clientFinalWithoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verifyServerFinal(_ serverFinal: String) throws {
        let attributes = Self.parseAttributes(serverFinal)
        if let error = attributes["e"] {
            throw MongoError(.authentication, "Server rejected authentication: \(error)")
        }
        guard let expected = expectedServerSignature,
              let signatureText = attributes["v"], let signature = Data(base64Encoded: signatureText),
              Self.constantTimeEquals([UInt8](signature), expected) else {
            throw MongoError(.authentication, "The server's SCRAM signature could not be verified; the server may not be genuine")
        }
    }

    // MARK: Crypto helpers

    private func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        switch variant {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        }
    }

    private func hash(_ data: [UInt8]) -> [UInt8] {
        switch variant {
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        }
    }

    static func escape(_ username: String) -> String {
        username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    static func parseAttributes(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let equals = part.firstIndex(of: "="), part.distance(from: part.startIndex, to: equals) == 1 else { continue }
            result[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        return result
    }

    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// Caches PBKDF2-derived SCRAM keys so pooled connections authenticate without redoing
/// thousands of iterations. Keys never include the plaintext password (it is hashed first).
final class ScramKeyCache: Sendable {
    static let shared = ScramKeyCache()

    struct Keys: Sendable {
        let clientKey: [UInt8]
        let serverKey: [UInt8]
    }

    private let storage = OSAllocatedUnfairLock<[String: Keys]>(initialState: [:])

    func keys(variant: ScramClient.Variant, password: String, salt: [UInt8], iterations: Int) throws -> Keys {
        let passwordDigest = SHA256.hash(data: Array(password.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheKey = "\(variant.mechanismName):\(iterations):\(Data(salt).base64EncodedString()):\(passwordDigest)"
        if let cached = storage.withLock({ $0[cacheKey] }) { return cached }

        let salted = try Self.pbkdf2(variant: variant, password: Array(password.utf8), salt: salt, iterations: iterations)
        let keys: Keys
        switch variant {
        case .sha1:
            keys = Keys(clientKey: Array(HMAC<Insecure.SHA1>.authenticationCode(for: Array("Client Key".utf8), using: SymmetricKey(data: salted))),
                        serverKey: Array(HMAC<Insecure.SHA1>.authenticationCode(for: Array("Server Key".utf8), using: SymmetricKey(data: salted))))
        case .sha256:
            keys = Keys(clientKey: Array(HMAC<SHA256>.authenticationCode(for: Array("Client Key".utf8), using: SymmetricKey(data: salted))),
                        serverKey: Array(HMAC<SHA256>.authenticationCode(for: Array("Server Key".utf8), using: SymmetricKey(data: salted))))
        }
        storage.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[cacheKey] = keys
        }
        return keys
    }

    static func pbkdf2(variant: ScramClient.Variant, password: [UInt8], salt: [UInt8], iterations: Int) throws -> [UInt8] {
        let length = variant == .sha1 ? 20 : 32
        let prf = variant == .sha1 ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1) : CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        var derived = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     saltBytes.baseAddress, salt.count,
                                     prf, UInt32(clamping: iterations), &derived, length)
            }
        }
        guard status == kCCSuccess else {
            throw MongoError(.authentication, "Key derivation failed (status \(status))")
        }
        return derived
    }
}
