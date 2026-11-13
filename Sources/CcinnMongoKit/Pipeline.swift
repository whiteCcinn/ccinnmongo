import BSON
import Foundation

public struct PipelineStage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var operatorName: String
    public var body: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), operatorName: String, body: String, isEnabled: Bool = true) {
        self.id = id
        self.operatorName = operatorName
        self.body = body
        self.isEnabled = isEnabled
    }

    public func document() throws -> BSONDocument {
        let value = try ShellSyntax.parseValue(body)
        return [operatorName: value]
    }

    public var syntaxError: SyntaxError? {
        do {
            _ = try ShellSyntax.parseValue(body)
            return nil
        } catch let error as SyntaxError {
            return error
        } catch {
            return nil
        }
    }
}

/// An aggregation pipeline edited stage by stage, convertible to and from text.
public struct PipelineModel: Hashable, Sendable {
    public struct StageError: Error, LocalizedError, Sendable {
        public let index: Int
        public let message: String
        public var errorDescription: String? { "Stage \(index + 1): \(message)" }
    }

    public var stages: [PipelineStage] = []

    public init() {}

    public init(text: String) throws {
        let values = try ShellSyntax.parseArray(text, allowEmpty: true)
        let formatter = BSONFormatter(style: .shell, indent: 2)
        stages = try values.enumerated().map { index, value in
            guard case let .document(document) = value, document.count == 1, let element = document.elements.first,
                  element.key.hasPrefix("$") else {
                throw StageError(index: index, message: "Each stage must be a document with exactly one $operator")
            }
            return PipelineStage(operatorName: element.key, body: formatter.format(element.value))
        }
    }

    /// Whole pipeline as shell-syntax text (all stages).
    public var text: String {
        guard !stages.isEmpty else { return "[]" }
        let formatter = BSONFormatter(style: .shell, indent: 2)
        let rendered = stages.map { stage -> String in
            let body: String
            if let document = try? stage.document() {
                body = formatter.format(document)
            } else {
                body = "{ \(stage.operatorName): \(stage.body) }"
            }
            return body.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
        }
        return "[\n" + rendered.joined(separator: ",\n") + "\n]"
    }

    /// Enabled stages up to and including `through` (all when nil).
    public func documents(through index: Int? = nil) throws -> [BSONDocument] {
        var result: [BSONDocument] = []
        for (position, stage) in stages.enumerated() {
            if let index, position > index { break }
            guard stage.isEnabled else { continue }
            do {
                result.append(try stage.document())
            } catch let error as SyntaxError {
                throw StageError(index: position, message: error.description)
            }
        }
        return result
    }
}

public struct StageTemplate: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let template: String
    /// Oldest MongoDB version supporting the stage, for display.
    public let since: String
}

public enum StageCatalog {
    public static let stages: [StageTemplate] = [
        StageTemplate(name: "$match", summary: "Filter documents", template: "{\n  field: \"value\"\n}", since: "2.2"),
        StageTemplate(name: "$project", summary: "Reshape documents", template: "{\n  _id: 0,\n  field: 1\n}", since: "2.2"),
        StageTemplate(name: "$group", summary: "Group by a key and accumulate", template: "{\n  _id: \"$field\",\n  count: { $sum: 1 }\n}", since: "2.2"),
        StageTemplate(name: "$sort", summary: "Order documents", template: "{\n  field: -1\n}", since: "2.2"),
        StageTemplate(name: "$limit", summary: "Keep the first N documents", template: "10", since: "2.2"),
        StageTemplate(name: "$skip", summary: "Skip N documents", template: "10", since: "2.2"),
        StageTemplate(name: "$unwind", summary: "Deconstruct an array field", template: "{\n  path: \"$items\",\n  preserveNullAndEmptyArrays: false\n}", since: "3.2"),
        StageTemplate(name: "$lookup", summary: "Join another collection", template: "{\n  from: \"collection\",\n  localField: \"field\",\n  foreignField: \"_id\",\n  as: \"joined\"\n}", since: "3.2"),
        StageTemplate(name: "$addFields", summary: "Add computed fields", template: "{\n  total: { $add: [\"$a\", \"$b\"] }\n}", since: "3.4"),
        StageTemplate(name: "$set", summary: "Alias of $addFields", template: "{\n  field: \"value\"\n}", since: "4.2"),
        StageTemplate(name: "$unset", summary: "Remove fields", template: "[\"field\"]", since: "4.2"),
        StageTemplate(name: "$count", summary: "Count documents", template: "\"count\"", since: "3.4"),
        StageTemplate(name: "$facet", summary: "Multiple sub-pipelines", template: "{\n  byStatus: [{ $sortByCount: \"$status\" }]\n}", since: "3.4"),
        StageTemplate(name: "$sortByCount", summary: "Group and count, sorted", template: "\"$field\"", since: "3.4"),
        StageTemplate(name: "$bucket", summary: "Group into ranges", template: "{\n  groupBy: \"$price\",\n  boundaries: [0, 100, 200],\n  default: \"other\"\n}", since: "3.4"),
        StageTemplate(name: "$replaceRoot", summary: "Promote an embedded document", template: "{\n  newRoot: \"$embedded\"\n}", since: "3.4"),
        StageTemplate(name: "$sample", summary: "Random sample", template: "{\n  size: 20\n}", since: "3.2"),
        StageTemplate(name: "$geoNear", summary: "Sort by distance", template: "{\n  near: { type: \"Point\", coordinates: [0, 0] },\n  distanceField: \"distance\",\n  spherical: true\n}", since: "2.4"),
        StageTemplate(name: "$out", summary: "Write results to a collection", template: "\"output_collection\"", since: "2.6"),
        StageTemplate(name: "$merge", summary: "Merge results into a collection", template: "{\n  into: \"collection\"\n}", since: "4.2"),
        StageTemplate(name: "$redact", summary: "Restrict content by condition", template: "{\n  $cond: { if: true, then: \"$$DESCEND\", else: \"$$PRUNE\" }\n}", since: "2.6"),
        StageTemplate(name: "$indexStats", summary: "Index usage statistics", template: "{}", since: "3.2"),
        StageTemplate(name: "$densify", summary: "Fill gaps in a sequence", template: "{\n  field: \"timestamp\",\n  range: { step: 1, unit: \"hour\", bounds: \"full\" }\n}", since: "5.1"),
        StageTemplate(name: "$setWindowFields", summary: "Window functions", template: "{\n  sortBy: { date: 1 },\n  output: { running: { $sum: \"$value\", window: { documents: [\"unbounded\", \"current\"] } } }\n}", since: "5.0"),
    ]
}
