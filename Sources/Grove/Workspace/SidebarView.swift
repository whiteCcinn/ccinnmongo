import BSON
import GroveKit
import MongoKit
import SwiftUI

/// Databases → collections tree with filtering and administrative context menus.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var sheet: AdminSheet?

    enum AdminSheet: Identifiable {
        case createDatabase
        case createCollection(String)
        case dropDatabase(String)
        case dropCollection(MongoNamespace)
        case renameCollection(MongoNamespace)

        var id: String {
            switch self {
            case .createDatabase: "createDatabase"
            case let .createCollection(db): "createCollection.\(db)"
            case let .dropDatabase(db): "dropDatabase.\(db)"
            case let .dropCollection(ns): "dropCollection.\(ns)"
            case let .renameCollection(ns): "rename.\(ns)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
            List {
                Section("Databases") {
                    ForEach(workspace.filteredDatabases(), id: \.0.id) { node, collections in
                        DatabaseRow(node: node, collections: collections, workspace: workspace, sheet: $sheet,
                                    forceExpanded: !workspace.sidebarFilter.isEmpty)
                    }
                }
            }
            .listStyle(.sidebar)
            bottomBar
        }
        .overlay {
            if let error = workspace.databasesError, workspace.databases.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error).multilineTextAlignment(.center).font(.callout)
                    Button("Retry") { Task { await workspace.refreshDatabases() } }
                }
                .foregroundStyle(.secondary)
                .padding()
            } else if workspace.databases.isEmpty, !workspace.isLoadingDatabases {
                ContentUnavailableView("No Databases", systemImage: "cylinder", description: Text("Create a database to get started."))
            }
        }
        .sheet(item: $sheet) { sheet in
            AdminSheetView(sheet: sheet, workspace: workspace)
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter databases & collections", text: $workspace.sidebarFilter)
                .textFieldStyle(.plain)
            if !workspace.sidebarFilter.isEmpty {
                Button { workspace.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                sheet = .createDatabase
            } label: {
                Label("Create Database", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Spacer()
            if workspace.isLoadingDatabases {
                ProgressView().controlSize(.mini)
            }
            Button {
                Task { await workspace.refreshDatabases() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh databases (⇧⌘R)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct DatabaseRow: View {
    let node: DatabaseNode
    let collections: [CollectionInfo]
    let workspace: WorkspaceModel
    @Binding var sheet: SidebarView.AdminSheet?
    let forceExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { node.isExpanded || forceExpanded }, set: { newValue in
            if newValue != node.isExpanded { workspace.toggle(node) }
        })) {
            if node.isLoading, node.collections == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else if let error = node.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else if collections.isEmpty {
                Text("No collections").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(collections) { collection in
                CollectionRow(collection: collection)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        workspace.openCollection(MongoNamespace(database: node.name, collection: collection.name), info: collection,
                                                 forceNewTab: NSEvent.modifierFlags.contains(.command))
                    }
                    .contextMenu {
                        let namespace = MongoNamespace(database: node.name, collection: collection.name)
                        Button("Open") { workspace.openCollection(namespace, info: collection) }
                        Button("Open in New Tab") { workspace.openCollection(namespace, info: collection, forceNewTab: true) }
                        Divider()
                        Button("Aggregations") { workspace.openCollection(namespace, info: collection, section: .aggregations) }
                        Button("Indexes") { workspace.openCollection(namespace, info: collection, section: .indexes) }
                        Button("Schema") { workspace.openCollection(namespace, info: collection, section: .schema) }
                        Divider()
                        Button("Copy Name") { Pasteboard.copy(collection.name) }
                        Button("Copy Namespace") { Pasteboard.copy(namespace.fullName) }
                        Divider()
                        if collection.kind == .collection {
                            Button("Rename…") { sheet = .renameCollection(namespace) }
                        }
                        Button(collection.kind == .view ? "Drop View…" : "Drop Collection…", role: .destructive) {
                            sheet = .dropCollection(namespace)
                        }
                    }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.info.isSystem ? "gearshape.2" : "cylinder.split.1x2")
                    .foregroundStyle(node.info.isSystem ? Color.secondary : Theme.accent)
                Text(node.name).lineLimit(1)
                Spacer(minLength: 4)
                if node.info.isEmpty == true {
                    Text("empty").font(.caption2).foregroundStyle(.tertiary)
                } else if let size = node.info.sizeOnDisk, size > 0 {
                    Text(Format.bytes(size)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.openDatabase(node.name) }
            .contextMenu {
                Button("Open Database Overview") { workspace.openDatabase(node.name) }
                Button("Create Collection…") { sheet = .createCollection(node.name) }
                Button("Refresh") { Task { await workspace.loadCollections(node) } }
                Button("Open Console Here") { workspace.openConsole(database: node.name) }
                Divider()
                Button("Copy Name") { Pasteboard.copy(node.name) }
                Divider()
                Button("Drop Database…", role: .destructive) { sheet = .dropDatabase(node.name) }
            }
        }
    }
}

private struct CollectionRow: View {
    let collection: CollectionInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(collection.kind == .view ? Color.purple : Color.secondary)
                .frame(width: 16)
            Text(collection.name)
                .lineLimit(1)
                .foregroundStyle(collection.isSystem ? .secondary : .primary)
            Spacer(minLength: 0)
            if collection.isCapped {
                Text("capped").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch collection.kind {
        case .view: "eye"
        case .timeseries: "clock"
        case .collection: "tablecells"
        }
    }
}

/// Create/drop/rename sheets for the sidebar.
struct AdminSheetView: View {
    let sheet: SidebarView.AdminSheet
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var database = ""
    @State private var collection = ""
    @State private var capped = false
    @State private var cappedSize = 1_048_576
    @State private var confirmation = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, role: isDestructive ? .destructive : nil) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isDestructive ? .red : Theme.accent)
                    .disabled(!canPerform || isWorking)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .createDatabase:
            Text("Create Database").font(.title2.weight(.semibold))
            Text("MongoDB creates a database when its first collection is created.").foregroundStyle(.secondary)
            Form {
                TextField("Database name", text: $database)
                TextField("First collection", text: $collection)
                cappedOptions
            }
            .formStyle(.grouped)
        case let .createCollection(db):
            Text("Create Collection").font(.title2.weight(.semibold))
            Text("in \(db)").foregroundStyle(.secondary)
            Form {
                TextField("Collection name", text: $collection)
                cappedOptions
            }
            .formStyle(.grouped)
        case let .dropDatabase(db):
            DestructiveConfirmation(title: "Drop database “\(db)”?", message: "All collections, documents and indexes in \(db) will be permanently deleted.", expected: db, confirmation: $confirmation)
        case let .dropCollection(ns):
            DestructiveConfirmation(title: "Drop “\(ns.collection)”?", message: "\(ns.fullName) and its indexes will be permanently deleted.", expected: ns.collection, confirmation: $confirmation)
        case let .renameCollection(ns):
            Text("Rename Collection").font(.title2.weight(.semibold))
            Form {
                LabeledContent("Current name", value: ns.collection)
                TextField("New name", text: $collection)
            }
            .formStyle(.grouped)
        }
    }

    private var cappedOptions: some View {
        Group {
            Toggle("Capped collection", isOn: $capped)
            if capped {
                TextField("Maximum size (bytes)", value: $cappedSize, format: .number)
            }
        }
    }

    private var isDestructive: Bool {
        switch sheet {
        case .dropDatabase, .dropCollection: true
        default: false
        }
    }

    private var actionTitle: String {
        switch sheet {
        case .createDatabase: "Create Database"
        case .createCollection: "Create Collection"
        case .dropDatabase: "Drop Database"
        case .dropCollection: "Drop"
        case .renameCollection: "Rename"
        }
    }

    private var canPerform: Bool {
        switch sheet {
        case .createDatabase: Self.isValidName(database) && Self.isValidName(collection)
        case .createCollection, .renameCollection: Self.isValidName(collection)
        case let .dropDatabase(db): confirmation == db
        case let .dropCollection(ns): confirmation == ns.collection
        }
    }

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("$") && !trimmed.contains("\0") && !trimmed.hasPrefix("system.")
    }

    private func perform() {
        isWorking = true
        error = nil
        let options: BSONDocument = capped ? ["capped": true, "size": .int(cappedSize)] : [:]
        Task {
            do {
                switch sheet {
                case .createDatabase:
                    try await workspace.createCollection(database: database.trimmingCharacters(in: .whitespaces), name: collection.trimmingCharacters(in: .whitespaces), options: options)
                case let .createCollection(db):
                    try await workspace.createCollection(database: db, name: collection.trimmingCharacters(in: .whitespaces), options: options)
                case let .dropDatabase(db):
                    try await workspace.dropDatabase(db)
                case let .dropCollection(ns):
                    try await workspace.dropCollection(ns)
                case let .renameCollection(ns):
                    try await workspace.renameCollection(ns, to: collection.trimmingCharacters(in: .whitespaces))
                }
                dismiss()
            } catch {
                self.error = describe(error)
                isWorking = false
            }
        }
    }
}

/// Type-the-name confirmation used for irreversible operations.
struct DestructiveConfirmation: View {
    let title: String
    let message: String
    let expected: String
    @Binding var confirmation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
            Text("Type **\(expected)** to confirm.")
                .foregroundStyle(.secondary)
            TextField(expected, text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monospaced)
        }
    }
}
