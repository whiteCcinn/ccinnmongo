import AppKit
import CcinnMongoKit
import MongoKit
import SwiftUI

struct CcinnMongoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup("CcinnMongo", id: "main") {
            RootView()
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
        }

        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                AISettingsView()
                    .tabItem { Label("AI", systemImage: "sparkles") }
            }
            .frame(width: 520)
            .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also behave like a regular app when launched from `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        SnapshotTool.scheduleIfRequested()
        Task { @MainActor in AgentService.shared.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .onDisappear { session.disconnect() }
        .task { LaunchArguments.consume(into: session) }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnMongo — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Developer conveniences / deep links:
/// `CcinnMongo --connect <uri> [--namespace db.collection] [--section documents|aggregations|schema|indexes|explain] [--view list|json|table]`
@MainActor
enum LaunchArguments {
    private static var consumed = false

    static func consume(into session: WindowSession) {
        guard !consumed else { return }
        consumed = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let raw = value("--connect"), let uri = try? ConnectionString(raw) else { return }
        let namespace = value("--namespace").flatMap(MongoNamespace.init(fullName:))
        let section = value("--section").flatMap { name in CollectionTabModel.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(name.lowercased()) } }
        let view = value("--view").flatMap { DocumentViewMode(rawValue: $0.capitalized) ?? ($0.lowercased() == "json" ? .json : nil) }
        session.connect(uri: uri) { workspace in
            if let namespace {
                workspace.openCollection(namespace, info: nil, section: section)
                guard case let .collection(model)? = workspace.selectedTab?.kind else { return }
                if let view { model.documents.viewMode = view }
                if let filter = value("--filter") {
                    model.documents.query.filter = filter
                    model.documents.run()
                }
                if let pipeline = value("--pipeline"), let parsed = try? PipelineModel(text: pipeline) {
                    model.aggregation.pipeline = parsed
                }
                if arguments.contains("--auto-run") {
                    switch model.section {
                    case .schema: model.schema.analyze()
                    case .explain:
                        model.explain.query = model.documents.query
                        model.explain.run()
                    case .aggregations: model.aggregation.schedulePreviews(from: nil)
                    case .assistant:
                        if let question = value("--ask") {
                            Task { @MainActor in
                                // Wait for CLI discovery before sending.
                                for _ in 0..<50 where !AgentService.shared.hasScanned { try? await Task.sleep(for: .milliseconds(100)) }
                                model.assistant.provider = AgentService.shared.activeProvider
                                model.assistant.input = question
                                model.assistant.send()
                            }
                        }
                    default: break
                    }
                }
            } else if value("--server") != nil {
                workspace.openServer()
            }
        }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the key window
/// into a PNG (used for automated visual checks; needs no screen-recording permission).
@MainActor
enum SnapshotTool {
    static func scheduleIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return }
        let path = arguments[index + 1]
        var delay = 5.0
        if let delayIndex = arguments.firstIndex(of: "--snapshot-delay"), arguments.indices.contains(delayIndex + 1),
           let parsed = Double(arguments[delayIndex + 1]) {
            delay = parsed
        }
        let quit = arguments.contains("--quit-after-snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("defaultPageSize") private var pageSize = 20
    @AppStorage("defaultViewMode") private var viewMode = DocumentViewMode.list.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Documents per page", selection: $pageSize) {
                ForEach([10, 20, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Default view", selection: $viewMode) {
                ForEach(DocumentViewMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.applicationSupport])
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandMenu("Database") {
            Button("Refresh") {
                guard let workspace = session?.workspace else { return }
                Task { await workspace.refreshDatabases() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session?.workspace == nil)
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Divider()
            Button("Server Overview") { session?.workspace?.openServer() }
                .disabled(session?.workspace == nil)
            Button("Performance") { session?.workspace?.openPerformance() }
                .disabled(session?.workspace == nil)
            Button("Command Console") { session?.workspace?.openConsole() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }
}

enum AppPaths {
    static var applicationSupport: URL { ProfileRepository.defaultDirectory }
}
