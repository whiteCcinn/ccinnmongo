import BSON
import Foundation
import Testing
@testable import GroveKit

@Suite("Explain plan parsing (real server outputs)")
struct ExplainPlanTests {
    static func fixture(_ name: String) throws -> BSONDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try ShellSyntax.parseDocument(String(contentsOf: url, encoding: .utf8))
    }

    @Test(arguments: ["26", "34", "40", "80"])
    func collectionScanIsDetected(version: String) throws {
        let plan = ExplainPlan(try Self.fixture("explain-\(version)-collscan"))
        #expect(plan.usesCollectionScan, "\(version)")
        #expect(plan.indexesUsed.isEmpty, "\(version)")
        #expect(plan.documentsReturned == 167, "\(version)")
        #expect(plan.documentsExamined == 500, "\(version)")
        #expect(plan.root != nil, "\(version)")
    }

    @Test(arguments: ["26", "34", "40", "80"])
    func indexScanWithSortIsDetected(version: String) throws {
        let plan = ExplainPlan(try Self.fixture("explain-\(version)-ixscan-sort"))
        #expect(!plan.usesCollectionScan, "\(version)")
        #expect(plan.indexesUsed == ["n_1"], "\(version)")
        #expect(plan.hasInMemorySort, "\(version)")
        #expect(plan.documentsReturned == 10, "\(version)")
        #expect((plan.keysExamined ?? 0) >= 399, "\(version)")
    }

    @Test(arguments: ["26", "34", "40", "80"])
    func aggregateExplainExposesPipelineAndIndex(version: String) throws {
        let plan = ExplainPlan(try Self.fixture("explain-\(version)-aggregate"))
        #expect(plan.indexesUsed == ["n_1"], "\(version)")
        #expect(!plan.usesCollectionScan, "\(version)")
        let stages = plan.root?.flattened.map(\.stage) ?? []
        #expect(stages.contains { $0.localizedCaseInsensitiveContains("group") }, "\(version): \(stages)")
    }

    @Test func treeFlattensDepthFirst() throws {
        let plan = ExplainPlan(try Self.fixture("explain-34-ixscan-sort"))
        let stages = plan.root?.flattened.map(\.stage) ?? []
        #expect(stages.first == "SORT" || stages.first == "LIMIT" || stages.first == "SORT_KEY_GENERATOR" || stages.contains("SORT"))
        #expect(stages.last == "IXSCAN")
    }

    @Test func unknownShapesDoNotCrash() {
        let plan = ExplainPlan(["ok": 1, "weird": ["stuff": .array([1, 2])]])
        #expect(plan.root == nil)
        #expect(!plan.usesCollectionScan)
    }
}
