import CcinnMongoKit
import Darwin
import Dispatch
import Foundation
import MongoKit

/// `CcinnMongo mcp`: runs the MCP server headless on stdin/stdout and exits when stdin closes.
public enum MCPCommand {
    /// Used when the executable does not run from an app bundle (e.g. `swift run`).
    public static let fallbackVersion = "1.1.0"

    public static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackVersion
    }

    /// Never returns. Nothing but protocol messages is written to stdout; diagnostics go to stderr.
    public static func run(arguments: [String]) -> Never {
        // A client that disappears must end the session, not kill the process mid-cleanup.
        signal(SIGPIPE, SIG_IGN)

        let options: MCPCommandOptions
        do {
            options = try MCPCommandOptions.parse(arguments)
        } catch {
            writeError("ccinnmongo mcp: \(error)\n\n\(MCPCommandOptions.usage)\n")
            exit(64)
        }
        if options.showHelp {
            writeError(MCPCommandOptions.usage + "\n")
            exit(0)
        }

        let repository = ProfileRepository()
        let profiles = ProfileFileSource(repository: repository)
        let connections = MCPConnectionManager(opener: ProfileSessionOpener(repository: repository))
        let provider = MongoToolProvider(configuration: MongoToolProvider.Configuration(defaultProfile: options.profile, readOnly: options.readOnly),
                                         profiles: profiles, sessions: connections, audit: MCPAuditLog(directory: repository.directory))
        let configuration = MCPServer.Configuration(name: "ccinnmongo", title: "CcinnMongo", version: appVersion,
                                                    instructions: MongoToolProvider.instructions(writeToolsAvailable: provider.writeToolsAvailable()))
        let server = MCPServer(configuration: configuration, tools: provider, output: StandardOutputWriter())

        let enabled = (try? profiles.loadProfiles()).map { MCPProfileSelector.enabledProfiles($0, cap: options.readOnly ? .readOnly : .readWrite).count } ?? 0
        writeError("ccinnmongo mcp \(appVersion): ready, \(enabled) connection(s) enabled for AI access\(options.readOnly ? " (read-only)" : "")\n")

        installTerminationHandlers()
        Task.detached {
            await server.run(input: StandardInput.chunks())
            await connections.closeAll()
            SSHTunnel.terminateAll()
            exit(0)
        }
        dispatchMain()
    }

    static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// SIGTERM/SIGINT/SIGHUP: stop SSH port forwards synchronously, then exit.
    private static func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                SSHTunnel.terminateAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
