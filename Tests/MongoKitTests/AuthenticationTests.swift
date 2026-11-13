import Foundation
import Testing
@testable import MongoKit

@Suite("Authentication primitives")
struct AuthenticationTests {
    /// RFC 5802 §5 example.
    @Test func scramSHA1MatchesRFC5802() throws {
        var client = ScramClient(variant: .sha1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        #expect(client.clientFirstMessage == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")
        let final = try client.clientFinalMessage(
            serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096")
        #expect(final == "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
        try client.verifyServerFinal("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=")
    }

    /// RFC 7677 §3 example.
    @Test func scramSHA256MatchesRFC7677() throws {
        var client = ScramClient(variant: .sha256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        let final = try client.clientFinalMessage(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func forgedServerSignatureIsRejected() throws {
        var client = ScramClient(variant: .sha1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        _ = try client.clientFinalMessage(serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096")
        #expect {
            try client.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        } throws: { error in
            (error as? MongoError)?.message.contains("could not be verified") == true
        }
    }

    @Test func serverNonceMustExtendClientNonce() {
        var client = ScramClient(variant: .sha1, username: "user", password: "pencil", clientNonce: "abc")
        #expect(throws: MongoError.self) { try client.clientFinalMessage(serverFirst: "r=xyz123,s=QSXCR+Q6sek8bf92,i=4096") }
    }

    @Test func lowIterationCountIsRejected() {
        var client = ScramClient(variant: .sha1, username: "user", password: "pencil", clientNonce: "abc")
        #expect(throws: MongoError.self) { try client.clientFinalMessage(serverFirst: "r=abcdef,s=QSXCR+Q6sek8bf92,i=1000") }
    }

    @Test func serverErrorAttributeIsReported() throws {
        var client = ScramClient(variant: .sha1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        _ = try client.clientFinalMessage(serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096")
        #expect(throws: MongoError.self) { try client.verifyServerFinal("e=invalid-proof") }
    }

    @Test func usernameIsEscaped() {
        let client = ScramClient(variant: .sha256, username: "a=b,c", password: "x", clientNonce: "n")
        #expect(client.clientFirstMessage == "n,,n=a=3Db=2Cc,r=n")
    }

    @Test func mongoPasswordDigest() {
        // md5("user:mongo:pencil")
        #expect(MongoCRAuthenticator.passwordDigest(username: "user", password: "pencil") == "1c33006ec1ffd90f9cadcbcc0e118200")
    }

    @Test func mongoCRKey() {
        let digest = MongoCRAuthenticator.passwordDigest(username: "user", password: "pencil")
        // md5(nonce + user + digest)
        #expect(MongoCRAuthenticator.key(nonce: "2375531c32080ae8", username: "user", passwordDigest: digest) == "21742f26431831d5cfca035a08c5bdf6")
    }

    @Test func saslPrep() throws {
        #expect(try SASLPrep.prepare("plain") == "plain")
        #expect(try SASLPrep.prepare("I\u{00AD}X") == "IX")          // soft hyphen mapped to nothing
        #expect(try SASLPrep.prepare("user\u{00A0}name") == "user name") // non-ASCII space mapped to space
        #expect(try SASLPrep.prepare("\u{00AA}") == "a")               // NFKC
        #expect(try SASLPrep.prepare("\u{2168}") == "IX")              // NFKC
        #expect(throws: MongoError.self) { try SASLPrep.prepare("\u{0007}") }
    }

    @Test func mechanismNegotiation() {
        #expect(AuthMechanism.negotiate(requested: nil, maxWireVersion: 7, saslSupportedMechs: ["SCRAM-SHA-1", "SCRAM-SHA-256"]) == .scramSHA256)
        #expect(AuthMechanism.negotiate(requested: nil, maxWireVersion: 7, saslSupportedMechs: ["SCRAM-SHA-1"]) == .scramSHA1)
        #expect(AuthMechanism.negotiate(requested: nil, maxWireVersion: 5, saslSupportedMechs: nil) == .scramSHA1)
        #expect(AuthMechanism.negotiate(requested: nil, maxWireVersion: 3, saslSupportedMechs: nil) == .scramSHA1)
        #expect(AuthMechanism.negotiate(requested: nil, maxWireVersion: 2, saslSupportedMechs: nil) == .mongoCR)
        #expect(AuthMechanism.negotiate(requested: .plain, maxWireVersion: 25, saslSupportedMechs: nil) == .plain)
    }
}
