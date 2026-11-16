import CcinnMongoKit
import MongoKit
import SwiftUI

/// Connection manager: saved profiles on the left, editor (or welcome) on the right.
struct ConnectionsView: View {
    @Bindable var session: WindowSession
    let store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    @State private var selection: UUID?
    @State private var draft: ConnectionDraft?
    @State private var search = ""
    @State private var pendingDelete: ConnectionProfile?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: RootView.windowGroupID)
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                .help("Open another window with its own connection (⌘N)")
            }
        }
        .onChange(of: selection) { _, newValue in
            if let profile = store.profile(id: newValue) {
                draft = ConnectionDraft(profile: profile, store: store)
            }
        }
        .onAppear {
            if draft == nil {
                if let first = store.favorites.first ?? store.recents.first ?? store.others.first {
                    selection = first.id
                    draft = ConnectionDraft(profile: first, store: store)
                }
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete {
                    store.delete(profile)
                    if selection == profile.id {
                        selection = nil
                        draft = nil
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The saved connection and its stored password will be removed. This cannot be undone.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter connections", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List(selection: $selection) {
                if !store.favorites.isEmpty {
                    Section("Favorites") { rows(filtered(store.favorites)) }
                }
                if !store.recents.isEmpty {
                    Section("Recent") { rows(filtered(store.recents)) }
                }
                if !store.others.isEmpty {
                    Section("Saved") { rows(filtered(store.others)) }
                }
            }
            .listStyle(.sidebar)
            Button {
                newConnection()
            } label: {
                Label("New Connection", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .placedBelowWindowToolbar()
        .overlay {
            if store.profiles.isEmpty {
                ContentUnavailableView("No Saved Connections", systemImage: "leaf", description: Text("Create a connection to get started."))
            }
        }
    }

    private func filtered(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.hostSummary.localizedCaseInsensitiveContains(search) }
    }

    private func rows(_ profiles: [ConnectionProfile]) -> some View {
        ForEach(profiles) { profile in
            ProfileRow(profile: profile)
                .tag(profile.id)
                .contextMenu {
                    Button("Connect") { session.connect(profile: profile, store: store) }
                    Button("Open in New Window") { openWindow(id: RootView.windowGroupID, value: WindowSession.request(opening: profile)) }
                    Divider()
                    Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(profile) }
                    Button("Duplicate") {
                        if let copy = store.duplicate(profile) { selection = copy.id }
                    }
                    Button("Copy Connection String") {
                        Pasteboard.copy((try? ConnectionString(profile.uri))?.redacted ?? profile.uri)
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = profile }
                }
                .onTapGesture(count: 2) { session.connect(profile: profile, store: store) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let draft {
            ConnectionEditorView(draft: draft, store: store, session: session) { saved in
                selection = saved.id
            }
            .id(draft.profileID ?? UUID())
        } else {
            WelcomeView(onNew: newConnection, onQuickConnect: quickConnect)
        }
    }

    private func newConnection() {
        selection = nil
        draft = ConnectionDraft(profile: nil, store: store)
    }

    private func quickConnect(_ uri: String) {
        let draft = ConnectionDraft(profile: nil, store: store)
        draft.uriText = uri
        self.draft = draft
    }
}

private struct ProfileRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.color(for: profile.color).gradient)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text(profile.hostSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if profile.ssh != nil {
                Image(systemName: "lock.shield").foregroundStyle(.secondary).help("SSH tunnel")
            }
            if profile.mcpAccess != .disabled {
                Image(systemName: "sparkles")
                    .foregroundStyle(profile.mcpAccess == .readWrite ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .imageScale(.small)
                    .help("AI access via MCP: \(profile.mcpAccess.displayName)")
            }
            if profile.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Shown when no connection is selected.
private struct WelcomeView: View {
    let onNew: () -> Void
    let onQuickConnect: (String) -> Void
    @State private var uri = "mongodb://localhost:27017"

    var body: some View {
        VStack(spacing: 24) {
            AppLogo(size: 88)
            VStack(spacing: 6) {
                Text("Welcome to CcinnMongo")
                    .font(.largeTitle.weight(.semibold))
                Text("A native MongoDB client for every server from 2.6 to 8.x.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Connection string", text: $uri)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.monospaced)
                    .frame(width: 380)
                    .onSubmit { onQuickConnect(uri) }
                Button("Continue") { onQuickConnect(uri) }
                    .buttonStyle(.borderedProminent)
            }
            Button("New Connection…", action: onNew)
                .buttonStyle(.link)
            HStack(spacing: 18) {
                FeaturePill(icon: "clock.arrow.circlepath", text: "Legacy OP_QUERY protocol")
                FeaturePill(icon: "bolt.horizontal", text: "Modern OP_MSG")
                FeaturePill(icon: "key", text: "SCRAM · MONGODB-CR · LDAP")
                FeaturePill(icon: "lock.shield", text: "TLS & SSH tunnels")
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// The app mark, drawn in SwiftUI so it matches the generated app icon.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.62, blue: 0.38), Color(red: 0.03, green: 0.36, blue: 0.27)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "leaf.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white.gradient)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64)
                .symbolEffect(.pulse)
            Text("Connecting to \(name)")
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
