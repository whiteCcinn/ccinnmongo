import BSON
import Foundation

/// A validated `database.collection` pair.
public struct MongoNamespaceName: Sendable, Equatable {
    public let database: String
    public let collection: String
}

/// Typed access to a tool's JSON arguments.
///
/// Type and range violations are schema errors (`MCPToolError.invalidArguments`, JSON-RPC `-32602`);
/// a well-typed value with invalid MongoDB syntax is a tool failure (`MCPToolFailure`, `isError`).
public struct ToolArguments: Sendable {
    public let tool: String
    public let values: JSONObject

    public init(tool: String, values: JSONObject) {
        self.tool = tool
        self.values = values
    }

    public func requireOnly(_ allowed: [String]) throws {
        if let unexpected = values.keys.first(where: { !allowed.contains($0) }) {
            throw MCPToolError.invalidArguments("Unexpected argument \"\(unexpected.clipped(100))\" for \(tool). Allowed: \(allowed.joined(separator: ", "))")
        }
    }

    private func invalid(_ message: String) -> MCPToolError { .invalidArguments("\(tool): \(message)") }

    public func optionalString(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case let .string(text)?: return text
        default: throw invalid("\"\(key)\" must be a string")
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw invalid("\"\(key)\" is required") }
        guard !value.isEmpty else { throw invalid("\"\(key)\" must not be empty") }
        return value
    }

    public func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        switch values[key] {
        case nil, .null?: return defaultValue
        case let .bool(flag)?: return flag
        default: throw invalid("\"\(key)\" must be true or false")
        }
    }

    public func integer(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        switch values[key] {
        case nil, .null?:
            return defaultValue
        case let value?:
            guard let integer = value.int64Value, let number = Int(exactly: integer) else {
                throw invalid("\"\(key)\" must be an integer")
            }
            guard range.contains(number) else {
                throw invalid("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound)")
            }
            return number
        }
    }

    // MARK: Names

    /// MongoDB database names may not contain `/\. "$` or NUL; rejecting `.` also prevents namespace
    /// confusion (`admin.system` + `users` would otherwise address `admin.system.users` on legacy servers).
    public func database(_ key: String = "database") throws -> String {
        let name = try requiredString(key)
        guard name.utf8.count <= 64, !name.contains(where: { "/\\. \"$\u{0}".contains($0) }) else {
            throw invalid("\"\(key)\" is not a valid database name")
        }
        return name
    }

    public func namespace() throws -> MongoNamespaceName {
        let database = try database()
        let collection = try requiredString("collection")
        // `$` only appears in the legacy `oplog.$main` name (index namespaces are not collections).
        guard collection.utf8.count <= 255, !collection.contains("\u{0}"),
              !collection.contains("$") || collection == "oplog.$main" else {
            throw invalid("\"collection\" is not a valid collection name")
        }
        return MongoNamespaceName(database: database, collection: collection)
    }

    // MARK: Documents

    /// A document given as a JSON object (Extended JSON) or as a mongo-shell syntax string; nil when absent or blank.
    public func document(_ key: String) throws -> BSONDocument? {
        switch values[key] {
        case nil, .null?:
            return nil
        case let .object(object)?:
            return try parseDocument(JSONWriter.string(.object(object)), key: key)
        case let .string(text)?:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try parseDocument(trimmed, key: key)
        default:
            throw invalid("\"\(key)\" must be an object or a string in mongo-shell syntax")
        }
    }

    public func requiredDocument(_ key: String) throws -> BSONDocument {
        guard let document = try document(key) else { throw invalid("\"\(key)\" is required") }
        return document
    }

    private func parseDocument(_ text: String, key: String) throws -> BSONDocument {
        do {
            return try ShellSyntax.parseDocument(text)
        } catch let error as SyntaxError {
            throw MCPToolFailure("\"\(key)\" is not valid MongoDB syntax: \(error.description)")
        } catch {
            throw MCPToolFailure("\"\(key)\" is not valid MongoDB syntax")
        }
    }

    /// An aggregation pipeline given as a JSON array of stages or as a mongo-shell syntax string.
    public func pipeline(_ key: String) throws -> [BSONDocument] {
        let values: [BSONValue]
        do {
            switch self.values[key] {
            case let .array(array)?:
                values = try ShellSyntax.parseArray(JSONWriter.string(.array(array)), allowEmpty: true)
            case let .string(text)?:
                values = try ShellSyntax.parseArray(text, allowEmpty: true)
            case nil, .null?:
                throw invalid("\"\(key)\" is required")
            default:
                throw invalid("\"\(key)\" must be an array of stages or a string in mongo-shell syntax")
            }
        } catch let error as SyntaxError {
            throw MCPToolFailure("\"\(key)\" is not valid MongoDB syntax: \(error.description)")
        }
        guard !values.isEmpty else { throw MCPToolFailure("\"\(key)\" must contain at least one stage") }
        return try values.enumerated().map { index, value in
            guard case let .document(stage) = value, stage.count == 1, let name = stage.keys.first, name.hasPrefix("$") else {
                throw MCPToolFailure("Stage \(index + 1) must be a document with exactly one $operator, e.g. {\"$match\": {...}}")
            }
            return stage
        }
    }
}
