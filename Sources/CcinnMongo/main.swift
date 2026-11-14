// CcinnMongo — a native MongoDB client for every server from 2.6 to 8.x.
import CcinnMongoMCP

// `CcinnMongo mcp …` runs the headless Model Context Protocol server instead of the app. This check
// happens before anything touches AppKit, so no window, menu bar or Dock icon is created.
if CommandLine.arguments.dropFirst().first == "mcp" {
    MCPCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}
CcinnMongoApp.main()
