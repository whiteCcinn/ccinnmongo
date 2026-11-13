import Foundation
import Testing
@testable import BSON

@Suite("ObjectId")
struct ObjectIdTests {
    @Test func parsesAndFormatsHex() throws {
        let oid = try #require(ObjectId(hex: "507f1f77bcf86cd799439011"))
        #expect(oid.hex == "507f1f77bcf86cd799439011")
        #expect(oid.bytes.count == 12)
        #expect(oid.timestampSeconds == 0x507F_1F77)
        #expect(ObjectId(hex: "507F1F77BCF86CD799439011") == oid)
    }

    @Test func rejectsInvalidHex() {
        #expect(ObjectId(hex: "") == nil)
        #expect(ObjectId(hex: "507f1f77bcf86cd79943901") == nil)
        #expect(ObjectId(hex: "507f1f77bcf86cd7994390111") == nil)
        #expect(ObjectId(hex: "zz7f1f77bcf86cd799439011") == nil)
    }

    @Test func generatedIdsEncodeCurrentTime() {
        let before = UInt32(Date().timeIntervalSince1970)
        let oid = ObjectId()
        let after = UInt32(Date().timeIntervalSince1970)
        #expect(oid.timestampSeconds >= before && oid.timestampSeconds <= after)
    }

    @Test func comparableFollowsByteOrder() {
        let a = ObjectId(hex: "000000000000000000000001")!
        let b = ObjectId(hex: "000000000000000000000100")!
        let c = ObjectId(hex: "010000000000000000000000")!
        #expect(a < b)
        #expect(b < c)
    }

    @Test func concurrentGenerationIsUnique() async {
        let ids = await withTaskGroup(of: [ObjectId].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<12_500).map { _ in ObjectId() } }
            }
            var all: [ObjectId] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        #expect(ids.count == 100_000)
        #expect(Set(ids).count == 100_000)
    }
}
