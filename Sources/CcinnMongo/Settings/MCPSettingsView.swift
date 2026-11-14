import AppKit
import CcinnMongoKit
import CcinnMongoMCP
import SwiftUI

/// Tabs of the Settings window (also used by the `--settings <tab>` launch argument).
enum SettingsTab: String, CaseIterable {
    case general
    case ai
    case mcp
}

/// Selected Settings tab, shared so other views (and launch arguments) can open a specific pane.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab: SettingsTab = .general
}

/// Settings → MCP: per-connection AI access, the server command and ready-to-paste client configuration.
struct MCPSettingsView: View {
    private let store = AppServices.shared.profiles
    @AppStorage("mcpSnippetReadOnly") private var readOnlySnippets = false
    @State private var copied: String?

    private var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "CcinnMongo"
    }

    private var snippets: MCPClientSnippets { MCPClientSnippets(executablePath: executablePath, readOnly: readOnlySnippets) }

    private var sortedProfiles: [ConnectionProfile] {
        store.profiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Text("Let AI tools such as Claude Code, Claude Desktop and Codex query your MongoDB connections through the Model Context Protocol. CcinnMongo runs every query itself: access is off until you enable it per connection, and read-only access refuses writes, $out/$merge, server-side JavaScript and credential collections.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each call returns at most 1,000 documents (about 256 KB) and stops after 120 seconds. Passwords stay in your Keychain and are never sent to the AI client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("AI access per connection") {
                if sortedProfiles.isEmpty {
                    Text("No saved connections yet.").foregroundStyle(.secondary)
                }
                ForEach(sortedProfiles) { profile in
                    Picker(selection: Binding(get: { profile.mcpAccess }, set: { store.setMCPAccess($0, for: profile.id) })) {
                        ForEach(MCPAccessLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.color(for: profile.color).gradient).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName).lineLimit(1)
                                Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Connect your AI client") {
                Toggle("Cap every connection at read-only (--read-only)", isOn: $readOnlySnippets)
                if let warning = locationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SnippetRow(title: "Command", caption: "The server runs on demand; CcinnMongo does not need to be open.",
                           text: snippets.commandLine, copied: $copied)
                SnippetRow(title: "Claude Code", caption: "Run in Terminal. Add --scope user to use it in every project.",
                           text: snippets.claudeCode, copied: $copied)
                SnippetRow(title: "Codex", caption: "Add to ~/.codex/config.toml.", text: snippets.codexTOML, copied: $copied)
                SnippetRow(title: "Claude Desktop", caption: "Merge into claude_desktop_config.json (Settings → Developer → Edit Config).",
                           text: snippets.claudeDesktopJSON, copied: $copied)
            }

            Section("Activity") {
                LabeledContent {
                    Button("Show in Finder") { revealAuditLog() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audit log")
                        Text("Every tool call is recorded in mcp-audit.jsonl.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 640)
    }

    /// Paths inside an app translocation folder or a disk image change, which would break client configuration.
    private var locationWarning: String? {
        let path = executablePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "CcinnMongo is running from a temporary location. Move it to the Applications folder and reopen it before copying these settings."
        }
        return nil
    }

    private func revealAuditLog() {
        let directory = AppPaths.applicationSupport
        let file = directory.appendingPathComponent(MCPAuditLog.fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }
}

/// A titled, selectable code block with a copy button.
private struct SnippetRow: View {
    let title: String
    let caption: String
    let text: String
    @Binding var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Pasteboard.copy(text)
                    copied = title
                } label: {
                    Label(copied == title ? "Copied" : "Copy", systemImage: copied == title ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 64)
                }
                .controlSize(.small)
            }
            Text(text)
                .font(Theme.monospacedSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        }
        .padding(.vertical, 2)
    }
}
