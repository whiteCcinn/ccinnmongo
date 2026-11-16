import CcinnMongoKit
import MongoKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let session: WindowSession
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    TabBarView(workspace: workspace)
                    Divider()
                }
                ZStack {
                    if let tab = workspace.selectedTab {
                        TabContentView(tab: tab, workspace: workspace)
                            .id(tab.id)
                    } else {
                        WorkspaceHome(workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) { ToastView(toast: workspace.toast) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionBadge(workspace: workspace)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("New Window with This Connection", action: openDuplicateWindow)
                    Button("New Window") { openWindow(id: RootView.windowGroupID) }
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                } primaryAction: {
                    openDuplicateWindow()
                }
                .help("Open this connection in another window (⇧⌘N); each window has its own connection")
                Button {
                    workspace.openServer()
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
                .help("Server overview")
                Button {
                    workspace.openPerformance()
                } label: {
                    Label("Performance", systemImage: "chart.xyaxis.line")
                }
                .help("Live performance")
                Button {
                    workspace.openConsole()
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .help("Command console (⇧⌘K)")
                Button {
                    session.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .help("Disconnect (⇧⌘D)")
            }
        }
    }

    private func openDuplicateWindow() {
        if let request = session.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
    }
}

/// Connection identity in the toolbar: colour, name, version and protocol.
private struct ConnectionBadge: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(for: workspace.profile.color).gradient)
                .frame(width: 10, height: 10)
            Text(workspace.profile.displayName)
                .font(.headline)
                .lineLimit(1)
            Badge(text: "MongoDB \(workspace.serverInfo.version)", color: Theme.accent)
            if !workspace.capabilities.usesOpMsg {
                Badge(text: "OP_QUERY", color: .orange, systemImage: "clock.arrow.circlepath")
                    .help("This server predates MongoDB 3.6; CcinnMongo talks to it with the legacy OP_QUERY wire protocol.")
            }
            if workspace.tunnel != nil {
                Badge(text: "SSH", color: .purple, systemImage: "lock.shield")
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct ToastView: View {
    let toast: Toast?

    var body: some View {
        Group {
            if let toast {
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .foregroundStyle(toast.isError ? Color.red : Color.primary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.35), value: toast)
    }
}

/// Content of the selected tab.
struct TabContentView: View {
    let tab: WorkspaceTab
    let workspace: WorkspaceModel

    var body: some View {
        switch tab.kind {
        case let .collection(model):
            CollectionView(model: model)
        case let .database(model):
            DatabaseOverviewView(model: model)
        case .server:
            ServerOverviewView(workspace: workspace)
        case let .performance(model):
            PerformanceView(model: model)
        case let .console(model):
            ConsoleView(model: model, databases: workspace.databases.map(\.name))
        }
    }
}

/// Shown when no tab is open: a quick summary and shortcuts.
private struct WorkspaceHome: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 20) {
            AppLogo(size: 72)
            VStack(spacing: 6) {
                Text(workspace.profile.displayName).font(.title.weight(.semibold))
                Text("MongoDB \(workspace.serverInfo.version) · \(workspace.serverInfo.serverType.displayName) · \(workspace.capabilities.protocolName)")
                    .foregroundStyle(.secondary)
            }
            Text("Choose a collection in the sidebar to browse its documents.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { workspace.openServer() } label: { Label("Server Overview", systemImage: "server.rack") }
                Button { workspace.openPerformance() } label: { Label("Performance", systemImage: "chart.xyaxis.line") }
                Button { workspace.openConsole() } label: { Label("Console", systemImage: "terminal") }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
