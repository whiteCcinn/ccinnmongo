import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("Line framing")
struct LineFramerTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func splitsCompleteLines() {
        var framer = LineFramer(maxLineBytes: 1024)
        let events = framer.append(bytes("{\"a\":1}\n{\"b\":2}\n"))
        #expect(events == [.line(bytes("{\"a\":1}")), .line(bytes("{\"b\":2}"))])
    }

    @Test func joinsPartialLinesAcrossChunks() {
        var framer = LineFramer(maxLineBytes: 1024)
        #expect(framer.append(bytes("{\"a\"")).isEmpty)
        #expect(framer.append(bytes(":1")).isEmpty)
        #expect(framer.append(bytes("}\n{\"b")) == [.line(bytes("{\"a\":1}"))])
        #expect(framer.append(bytes("\":2}\n")) == [.line(bytes("{\"b\":2}"))])
    }

    @Test func stripsCarriageReturnsAndSkipsBlankLines() {
        var framer = LineFramer(maxLineBytes: 1024)
        let events = framer.append(bytes("\n\r\n  \t\r\n{\"a\":1}\r\n\n"))
        #expect(events == [.line(bytes("{\"a\":1}"))])
    }

    @Test func multiByteCharactersSplitAcrossChunks() {
        var framer = LineFramer(maxLineBytes: 1024)
        let line = bytes("\"🌳\"")
        #expect(framer.append(Array(line[0..<3])).isEmpty)
        #expect(framer.append(Array(line[3...]) + [0x0A]) == [.line(line)])
    }

    @Test func oversizedLineIsReportedOnceAndFramingRecovers() {
        var framer = LineFramer(maxLineBytes: 10)
        var events = framer.append(bytes("0123456789ABCDEF"))
        #expect(events.isEmpty)
        events = framer.append(bytes("GHIJ"))
        #expect(events.isEmpty)
        events = framer.append(bytes("KL\n{\"ok\":1}\n"))
        #expect(events == [.oversized(22), .line(bytes("{\"ok\":1}"))])
    }

    @Test func oversizedLineInOneChunk() {
        var framer = LineFramer(maxLineBytes: 4)
        let events = framer.append(bytes("123456\nab\n"))
        #expect(events == [.oversized(6), .line(bytes("ab"))])
    }

    @Test func lineOfExactlyTheLimitIsAccepted() {
        var framer = LineFramer(maxLineBytes: 4)
        #expect(framer.append(bytes("1234\n")) == [.line(bytes("1234"))])
        // The trailing CR does not count towards the limit.
        #expect(framer.append(bytes("1234\r\n")) == [.line(bytes("1234"))])
    }

    @Test func finishFlushesAnUnterminatedLine() {
        var framer = LineFramer(maxLineBytes: 1024)
        #expect(framer.append(bytes("{\"a\":1}")).isEmpty)
        #expect(framer.finish() == [.line(bytes("{\"a\":1}"))])
        #expect(framer.finish().isEmpty)
    }

    @Test func finishReportsAnUnterminatedOversizedLine() {
        var framer = LineFramer(maxLineBytes: 2)
        _ = framer.append(bytes("12345"))
        #expect(framer.finish() == [.oversized(5)])
    }

    @Test func bufferNeverGrowsBeyondTheLimit() {
        var framer = LineFramer(maxLineBytes: 1000)
        for _ in 0..<1000 { _ = framer.append([UInt8](repeating: 0x41, count: 1000)) }
        #expect(framer.bufferedByteCount <= 1000)
    }
}

@Suite("JSON-RPC classification")
struct JSONRPCTests {
    private func classify(_ text: String) throws -> JSONRPCIncoming {
        JSONRPC.classify(try JSONParser.parse(text))
    }

    @Test func requestsWithIntegerAndStringIDs() throws {
        #expect(try classify(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) == .request(id: .int(1), method: "ping", params: nil))
        #expect(try classify(#"{"jsonrpc":"2.0","id":"a-1","method":"ping","params":{}}"#)
            == .request(id: .string("a-1"), method: "ping", params: [:]))
        #expect(try classify(#"{"jsonrpc":"2.0","id":2.0,"method":"ping"}"#) == .request(id: .int(2), method: "ping", params: nil))
    }

    @Test func notifications() throws {
        #expect(try classify(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            == .notification(method: "notifications/initialized", params: nil))
    }

    @Test func responsesFromTheClientAreRecognised() throws {
        #expect(try classify(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == .response)
        #expect(try classify(#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"x"}}"#) == .response)
    }

    @Test func invalidMessages() throws {
        #expect(try classify(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == .invalid(id: nil, message: "Batch requests are not supported"))
        #expect(try classify("42") == .invalid(id: nil, message: "A request must be a JSON object"))
        #expect(try classify(#"{"id":1,"method":"ping"}"#) == .invalid(id: .int(1), message: "\"jsonrpc\" must be \"2.0\""))
        #expect(try classify(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#) == .invalid(id: .int(1), message: "\"jsonrpc\" must be \"2.0\""))
        #expect(try classify(#"{"jsonrpc":"2.0","id":1,"method":5}"#) == .invalid(id: .int(1), message: "\"method\" must be a string"))
        #expect(try classify(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == .invalid(id: nil, message: "\"id\" must be a string or an integer"))
        #expect(try classify(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#) == .invalid(id: nil, message: "\"id\" must be a string or an integer"))
        #expect(try classify(#"{"jsonrpc":"2.0","id":{},"method":"ping"}"#) == .invalid(id: nil, message: "\"id\" must be a string or an integer"))
        #expect(try classify(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":3}"#) == .invalid(id: .int(1), message: "\"params\" must be an object or an array"))
        #expect(try classify(#"{"jsonrpc":"2.0","id":1}"#) == .invalid(id: .int(1), message: "Missing \"method\""))
    }

    @Test func errorAndResultEnvelopes() {
        #expect(JSONWriter.string(JSONRPC.response(id: .int(3), result: [:])) == #"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        #expect(JSONWriter.string(JSONRPC.errorResponse(id: .string("x"), code: .methodNotFound, message: "nope"))
            == #"{"jsonrpc":"2.0","id":"x","error":{"code":-32601,"message":"nope"}}"#)
        #expect(JSONWriter.string(JSONRPC.errorResponse(id: nil, code: .parseError, message: "bad"))
            == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}"#)
    }
}
