import Foundation
import Testing
@testable import CcinnMongoMCP

@Suite("Client setup snippets")
struct ClientSnippetsTests {
    let app = "/Applications/CcinnMongo.app/Contents/MacOS/CcinnMongo"

    @Test func claudeCodeCommand() {
        let snippets = MCPClientSnippets(executablePath: app)
        #expect(snippets.claudeCode == #"claude mcp add ccinnmongo -- "/Applications/CcinnMongo.app/Contents/MacOS/CcinnMongo" mcp"#)
        #expect(MCPClientSnippets(executablePath: app, readOnly: true).claudeCode.hasSuffix(#"CcinnMongo" mcp --read-only"#))
        #expect(snippets.commandLine == #""/Applications/CcinnMongo.app/Contents/MacOS/CcinnMongo" mcp"#)
    }

    @Test func codexConfiguration() {
        #expect(MCPClientSnippets(executablePath: app).codexTOML == """
        [mcp_servers.ccinnmongo]
        command = "/Applications/CcinnMongo.app/Contents/MacOS/CcinnMongo"
        args = ["mcp"]
        """)
        #expect(MCPClientSnippets(executablePath: app, readOnly: true).codexTOML.hasSuffix(#"args = ["mcp", "--read-only"]"#))
    }

    @Test func claudeDesktopConfiguration() throws {
        let json = MCPClientSnippets(executablePath: app).claudeDesktopJSON
        #expect(json == """
        {
          "mcpServers": {
            "ccinnmongo": {
              "command": "/Applications/CcinnMongo.app/Contents/MacOS/CcinnMongo",
              "args": ["mcp"]
            }
          }
        }
        """)
        let parsed = try JSONParser.parse(json)
        #expect(parsed.objectValue?["mcpServers"]?.objectValue?["ccinnmongo"]?.objectValue?["command"] == .string(app))
    }

    @Test func awkwardPathsAreQuotedForEveryFormat() throws {
        let path = #"/Users/me/My "Apps"/$HOME `x` \bin/CcinnMongo.app/Contents/MacOS/CcinnMongo"#
        let snippets = MCPClientSnippets(executablePath: path, readOnly: true)
        #expect(snippets.claudeCode == #"claude mcp add ccinnmongo -- "/Users/me/My \"Apps\"/\$HOME \`x\` \\bin/CcinnMongo.app/Contents/MacOS/CcinnMongo" mcp --read-only"#)
        #expect(snippets.codexTOML.contains(#"command = "/Users/me/My \"Apps\"/$HOME `x` \\bin/CcinnMongo.app/Contents/MacOS/CcinnMongo""#))
        let parsed = try JSONParser.parse(snippets.claudeDesktopJSON)
        #expect(parsed.objectValue?["mcpServers"]?.objectValue?["ccinnmongo"]?.objectValue?["command"] == .string(path))
        #expect(parsed.objectValue?["mcpServers"]?.objectValue?["ccinnmongo"]?.objectValue?["args"] == ["mcp", "--read-only"])
    }

    @Test func tomlEscapesControlCharacters() {
        let snippets = MCPClientSnippets(executablePath: "/tmp/a\tb\u{1}c")
        #expect(snippets.codexTOML.contains(#"command = "/tmp/a\tb\u0001c""#))
    }
}
