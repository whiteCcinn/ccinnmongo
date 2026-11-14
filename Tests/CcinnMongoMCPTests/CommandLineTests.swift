import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("mcp command line")
struct CommandLineTests {
    @Test func defaults() throws {
        #expect(try MCPCommandOptions.parse([]) == MCPCommandOptions(profile: nil, readOnly: false, showHelp: false))
    }

    @Test func profileAndReadOnly() throws {
        #expect(try MCPCommandOptions.parse(["--profile", "Prod DB", "--read-only"])
            == MCPCommandOptions(profile: "Prod DB", readOnly: true, showHelp: false))
        #expect(try MCPCommandOptions.parse(["--read-only", "--profile=7D1C2D9B-2B9E-4C59-9A55-0E0B1B6A2F10"])
            == MCPCommandOptions(profile: "7D1C2D9B-2B9E-4C59-9A55-0E0B1B6A2F10", readOnly: true, showHelp: false))
    }

    @Test func help() throws {
        #expect(try MCPCommandOptions.parse(["--help"]).showHelp)
        #expect(try MCPCommandOptions.parse(["-h"]).showHelp)
    }

    @Test func usageErrors() {
        for arguments in [["--bogus"], ["--profile"], ["--profile", ""], ["--profile=  "], ["--profile", "a", "--profile", "b"],
                          ["extra"], ["--profile", "--read-only"]] {
            #expect(throws: MCPUsageError.self, "\(arguments)") { try MCPCommandOptions.parse(arguments) }
        }
    }

    @Test func usageTextMentionsEveryOption() {
        #expect(MCPCommandOptions.usage.contains("--profile"))
        #expect(MCPCommandOptions.usage.contains("--read-only"))
        #expect(MCPCommandOptions.usage.contains("CcinnMongo mcp"))
    }
}

@Suite("Standard streams")
struct StandardStreamsTests {
    @Test func readsChunksUntilEndOfInput() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let payload = Array(repeating: UInt8(ascii: "x"), count: 200_000) + [0x0A]
        let writeEnd = descriptors[1]
        let readEnd = descriptors[0]
        let writer = Thread {
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard let base = raw.baseAddress else { break }
                    let written = write(writeEnd, base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(writeEnd)
        }
        writer.start()
        var received: [UInt8] = []
        for await chunk in StandardInput.chunks(fileDescriptor: readEnd, chunkSize: 4096) {
            #expect(chunk.count <= 4096)
            received.append(contentsOf: chunk)
        }
        close(readEnd)
        #expect(received == payload)
    }

    @Test func nonBlockingInputWaitsInsteadOfEnding() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
        let writer = Thread {
            usleep(200_000)
            _ = "late\n".withCString { write(writeEnd, $0, 5) }
            close(writeEnd)
        }
        writer.start()
        var received: [UInt8] = []
        for await chunk in StandardInput.chunks(fileDescriptor: readEnd) { received.append(contentsOf: chunk) }
        close(readEnd)
        #expect(String(decoding: received, as: UTF8.self) == "late\n")
    }

    @Test func writerAppendsNewlinesAndReportsBrokenPipes() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let output = StandardOutputWriter(fileDescriptor: descriptors[1])
        try await output.send(Array("{\"a\":1}".utf8))
        try await output.send(Array("{\"b\":2}".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(descriptors[0], &buffer, 64)
        #expect(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self) == "{\"a\":1}\n{\"b\":2}\n")
        close(descriptors[0])
        signal(SIGPIPE, SIG_IGN)
        await #expect(throws: MCPOutputError.self) { try await output.send(Array("{}".utf8)) }
        close(descriptors[1])
    }
}
