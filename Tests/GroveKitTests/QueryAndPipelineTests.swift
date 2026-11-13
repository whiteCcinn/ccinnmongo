import BSON
import MongoKit
import Testing
@testable import GroveKit

@Suite("Query input and pipelines")
struct QueryAndPipelineTests {
    @Test func buildsFindOptionsForAPage() throws {
        var query = QueryInput()
        query.filter = "{status: 'A'}"
        query.sort = "{n: -1}"
        query.projection = "{_id: 0}"
        query.skip = 10
        let options = try #require(try query.findOptions(page: 2, pageSize: 20))
        #expect(options.filter == ["status": "A"])
        #expect(options.sort == ["n": -1])
        #expect(options.projection == ["_id": 0])
        #expect(options.skip == 50)
        #expect(options.limit == 20)
    }

    @Test func userLimitCapsTheLastPage() throws {
        var query = QueryInput()
        query.limit = 45
        #expect(try query.findOptions(page: 2, pageSize: 20)?.limit == 5)
        // Past the user's limit there is nothing to fetch: must be nil, never `limit: 0` (= unlimited).
        #expect(try query.findOptions(page: 3, pageSize: 20) == nil)
        #expect(query.pageCount(total: 1000, pageSize: 20) == 3)
    }

    @Test func emptyFieldsAreAllowedAndInvalidOnesReported() {
        var query = QueryInput()
        #expect(query.validationErrors.isEmpty)
        query.filter = "{a: }"
        query.sort = "{b: 1"
        let errors = query.validationErrors
        #expect(errors[.filter] != nil)
        #expect(errors[.sort] != nil)
        #expect(errors[.projection] == nil)
    }

    @Test func pipelineTextAndStagesConvertLosslessly() throws {
        let pipeline = try PipelineModel(text: #"[{$match: {a: 1}}, {$count: "n"}]"#)
        #expect(pipeline.stages.map(\.operatorName) == ["$match", "$count"])
        let reparsed = try PipelineModel(text: pipeline.text)
        #expect(try reparsed.documents() == pipeline.documents())
    }

    @Test func disabledStagesAreSkipped() throws {
        var pipeline = try PipelineModel(text: "[{$match: {a: 1}}, {$limit: 5}, {$skip: 1}]")
        pipeline.stages[1].isEnabled = false
        #expect(try pipeline.documents().map { $0.keys.first } == ["$match", "$skip"])
        #expect(try pipeline.documents(through: 1).map { $0.keys.first } == ["$match"])
    }

    @Test func invalidStageReportsItsIndex() throws {
        var pipeline = PipelineModel()
        pipeline.stages = [PipelineStage(operatorName: "$match", body: "{a: 1}"), PipelineStage(operatorName: "$project", body: "{a: }")]
        #expect {
            _ = try pipeline.documents()
        } throws: { error in
            (error as? PipelineModel.StageError)?.index == 1
        }
    }

    @Test func stageTemplatesParse() throws {
        for template in StageCatalog.stages {
            #expect(throws: Never.self, "\(template.name)") { _ = try ShellSyntax.parseValue(template.template) }
        }
    }
}
