import BSON
import Foundation
import Testing
@testable import MongoKit

@Suite("Topology and SRV")
struct TopologyTests {
    /// Routes each address to its own fake server.
    static func factory(_ servers: [String: FakeMongoServer]) -> TransportFactory {
        { address, _ in
            guard let server = servers[address.description] else {
                throw MongoError(.network, "Connection refused by \(address)")
            }
            return server.makeTransport()
        }
    }

    static func member(primary: Bool, set: String = "rs0") -> FakeMongoServer {
        var config = FakeMongoServer.Configuration(maxWireVersion: 25, setName: set, isWritablePrimary: primary, isSecondary: !primary)
        config.hosts = ["a:27017", "b:27017"]
        config.primary = "b:27017"
        return FakeMongoServer(config) { _ in .document(["ok": 1, "version": "8.0.0"]) }
    }

    @Test func seedSecondaryLeadsToReportedPrimary() async throws {
        let servers = ["a:27017": Self.member(primary: false), "b:27017": Self.member(primary: true)]
        let client = MongoClient(try ConnectionString("mongodb://a:27017/?replicaSet=rs0"),
                                 options: MongoClientOptions(transportFactory: Self.factory(servers)))
        let info = try await client.connect()
        #expect(info.address == ServerAddress(host: "b", port: 27017))
        #expect(info.serverType == .rsPrimary)
        await client.close()
    }

    @Test func directConnectionToSecondaryEnablesSecondaryReads() async throws {
        let servers = ["a:27017": Self.member(primary: false)]
        let client = MongoClient(try ConnectionString("mongodb://a:27017/"),
                                 options: MongoClientOptions(transportFactory: Self.factory(servers)))
        let info = try await client.connect()
        #expect(info.address == ServerAddress(host: "a", port: 27017))
        #expect(info.serverType == .rsSecondary)
        await client.close()
    }

    @Test func wrongReplicaSetNameIsRejected() async throws {
        let servers = ["a:27017": Self.member(primary: true, set: "other")]
        let client = MongoClient(try ConnectionString("mongodb://a:27017/?replicaSet=rs0"),
                                 options: MongoClientOptions(transportFactory: Self.factory(servers)))
        await #expect(throws: MongoError.self) { try await client.connect() }
        await client.close()
    }

    @Test func secondaryPreferredPicksSecondary() async throws {
        let servers = ["a:27017": Self.member(primary: false), "b:27017": Self.member(primary: true)]
        let client = MongoClient(try ConnectionString("mongodb://a:27017,b:27017/?replicaSet=rs0&readPreference=secondaryPreferred"),
                                 options: MongoClientOptions(transportFactory: Self.factory(servers)))
        let info = try await client.connect()
        #expect(info.serverType == .rsSecondary)
        await client.close()
    }

    @Test func unreachableSeedsProduceAnExplanation() async throws {
        let client = MongoClient(try ConnectionString("mongodb://x:1,y:2/?replicaSet=rs0"),
                                 options: MongoClientOptions(transportFactory: Self.factory([:])))
        await #expect {
            try await client.connect()
        } throws: { error in
            let message = (error as? MongoError)?.message ?? ""
            return message.contains("x:1") && message.contains("y:2")
        }
        await client.close()
    }

    @Test(arguments: [
        ("cluster0.example.com", "shard-00.example.com", true),
        ("cluster0.example.com", "shard-00.cluster0.example.com", true),
        ("cluster0.example.com", "evil.other.com", false),
        ("cluster0.example.com", "example.com", false),
        ("example.com", "a.example.com", true),
        ("example.com", "example.com", false),
        ("localhost", "a.localhost", true),
    ])
    func srvTargetValidation(host: String, target: String, valid: Bool) {
        #expect(SRVResolution.isValidTarget(target, forSRVHost: host) == valid)
    }

    struct StubResolver: DNSResolving {
        var srv: [SRVRecord]
        var txt: [String]
        func srvRecords(for name: String) async throws -> [SRVRecord] { srv }
        func txtRecords(for name: String) async throws -> [String] { txt }
    }

    @Test func srvResolutionMergesTXTOptions() async throws {
        let resolver = StubResolver(srv: [SRVRecord(port: 27017, target: "a.example.com."), SRVRecord(port: 27018, target: "b.example.com")],
                                    txt: ["replicaSet=rs0&authSource=admin"])
        let result = try await SRVResolution.resolve(host: "cluster.example.com", resolver: resolver)
        #expect(result.hosts == [ServerAddress(host: "a.example.com", port: 27017), ServerAddress(host: "b.example.com", port: 27018)])
        #expect(result.options == ["replicaSet": "rs0", "authSource": "admin"])
    }

    @Test func srvRejectsForeignTargetsAndOptions() async {
        let hijacked = StubResolver(srv: [SRVRecord(port: 27017, target: "evil.other.com")], txt: [])
        await #expect(throws: MongoError.self) { _ = try await SRVResolution.resolve(host: "cluster.example.com", resolver: hijacked) }
        let badTXT = StubResolver(srv: [SRVRecord(port: 27017, target: "a.example.com")], txt: ["tls=false"])
        await #expect(throws: MongoError.self) { _ = try await SRVResolution.resolve(host: "cluster.example.com", resolver: badTXT) }
    }

    @Test func srvRecordParsing() {
        let rdata: [UInt8] = [0, 1, 0, 2, 0x69, 0x89, 1, 0x61, 7] + Array("example".utf8) + [3] + Array("com".utf8) + [0]
        #expect(SystemDNSResolver.parseSRV(rdata) == SRVRecord(priority: 1, weight: 2, port: 27017, target: "a.example.com"))
        #expect(SystemDNSResolver.parseSRV([0, 1, 2]) == nil)
        #expect(SystemDNSResolver.parseSRV([0, 0, 0, 0, 0, 1, 60, 0x61]) == nil)
        #expect(SystemDNSResolver.parseTXT([5] + Array("a=b&c".utf8) + [3] + Array("=d1".utf8)) == "a=b&c=d1")
    }
}
