import BSON
import Foundation
import GroveKit
import MongoKit
import Observation

func describe(_ error: any Error) -> String {
    if let mongo = error as? MongoError { return mongo.message }
    if let syntax = error as? SyntaxError { return syntax.description }
    if let localized = error as? any LocalizedError, let description = localized.errorDescription { return description }
    return error.localizedDescription
}

@MainActor
@Observable
final class DatabaseNode: Identifiable {
    let name: String
    var info: DatabaseInfo
    var collections: [CollectionInfo]?
    var isLoading = false
    var error: String?
    var isExpanded = false

    nonisolated var id: String { name }

    init(info: DatabaseInfo) {
        name = info.name
        self.info = info
    }
}

@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    enum Kind {
        case collection(CollectionTabModel)
        case database(DatabaseOverviewModel)
        case server
        case performance(PerformanceModel)
        case console(ConsoleModel)
    }

    let id = UUID()
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case let .collection(model): model.namespace.collection
        case let .database(model): model.database
        case .server: "Server"
        case .performance: "Performance"
        case .console: "Console"
        }
    }

    var subtitle: String? {
        switch kind {
        case let .collection(model): model.namespace.database
        default: nil
        }
    }

    var icon: String {
        switch kind {
        case let .collection(model): model.info?.kind == .view ? "eye" : (model.info?.kind == .timeseries ? "clock" : "tablecells")
        case .database: "cylinder.split.1x2"
        case .server: "server.rack"
        case .performance: "chart.xyaxis.line"
        case .console: "terminal"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
}

/// One connected window: the database tree, open tabs and administrative actions.
@MainActor
@Observable
final class WorkspaceModel {
    let profile: ConnectionProfile
    let client: MongoClient
    let serverInfo: ServerInfo
    let tunnel: SSHTunnel?

    var databases: [DatabaseNode] = []
    var isLoadingDatabases = false
    var databasesError: String?
    var sidebarFilter = ""
    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?
    var isShutDown = false

    init(profile: ConnectionProfile, client: MongoClient, serverInfo: ServerInfo, tunnel: SSHTunnel?) {
        self.profile = profile
        self.client = client
        self.serverInfo = serverInfo
        self.tunnel = tunnel
        Task { await refreshDatabases() }
    }

    var capabilities: ServerCapabilities { serverInfo.capabilities }

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: Databases

    func refreshDatabases() async {
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        do {
            let infos = try await client.listDatabases()
            let expanded = Set(databases.filter(\.isExpanded).map(\.name))
            let previous = Dictionary(uniqueKeysWithValues: databases.map { ($0.name, $0) })
            databases = infos.map { info in
                let node = previous[info.name] ?? DatabaseNode(info: info)
                node.info = info
                node.isExpanded = expanded.contains(info.name)
                return node
            }
            databasesError = nil
            for node in databases where node.isExpanded {
                await loadCollections(node)
            }
        } catch {
            databasesError = describe(error)
        }
    }

    func toggle(_ node: DatabaseNode) {
        node.isExpanded.toggle()
        if node.isExpanded, node.collections == nil {
            Task { await loadCollections(node) }
        }
    }

    func loadCollections(_ node: DatabaseNode) async {
        node.isLoading = true
        defer { node.isLoading = false }
        do {
            node.collections = try await client.listCollections(database: node.name)
            node.error = nil
        } catch {
            node.error = describe(error)
        }
    }

    /// Databases/collections matching the sidebar filter.
    func filteredDatabases() -> [(DatabaseNode, [CollectionInfo])] {
        let query = sidebarFilter.trimmingCharacters(in: .whitespaces)
        return databases.compactMap { node in
            let collections = node.collections ?? []
            guard !query.isEmpty else { return (node, collections) }
            let matching = collections.filter { $0.name.localizedCaseInsensitiveContains(query) }
            if node.name.localizedCaseInsensitiveContains(query) { return (node, collections) }
            return matching.isEmpty ? nil : (node, matching)
        }
    }

    // MARK: Tabs

    func openCollection(_ namespace: MongoNamespace, info: CollectionInfo?, section: CollectionTabModel.Section? = nil, forceNewTab: Bool = false) {
        if !forceNewTab, let existing = tabs.first(where: {
            if case let .collection(model) = $0.kind { return model.namespace == namespace }
            return false
        }) {
            selectedTabID = existing.id
            if let section, case let .collection(model) = existing.kind { model.section = section }
            return
        }
        let model = CollectionTabModel(namespace: namespace, info: info, workspace: self)
        if let section { model.section = section }
        append(WorkspaceTab(kind: .collection(model)))
    }

    func openDatabase(_ name: String) {
        if let existing = tabs.first(where: {
            if case let .database(model) = $0.kind { return model.database == name }
            return false
        }) {
            selectedTabID = existing.id
            return
        }
        append(WorkspaceTab(kind: .database(DatabaseOverviewModel(database: name, workspace: self))))
    }

    func openServer() {
        if let existing = tabs.first(where: { if case .server = $0.kind { return true }; return false }) {
            selectedTabID = existing.id
            return
        }
        append(WorkspaceTab(kind: .server))
    }

    func openPerformance() {
        if let existing = tabs.first(where: { if case .performance = $0.kind { return true }; return false }) {
            selectedTabID = existing.id
            return
        }
        append(WorkspaceTab(kind: .performance(PerformanceModel(client: client))))
    }

    func openConsole(database: String? = nil) {
        let model = ConsoleModel(client: client, database: database ?? profile.defaultDatabaseName)
        append(WorkspaceTab(kind: .console(model)))
    }

    private func append(_ tab: WorkspaceTab) {
        if let current = selectedTabID, let index = tabs.firstIndex(where: { $0.id == current }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.willClose()
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty, let current = selectedTabID, let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to destination: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == destination }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    // MARK: Administration

    func createCollection(database: String, name: String, options: BSONDocument) async throws {
        try await client.createCollection(MongoNamespace(database: database, collection: name), options: options)
        await refreshDatabases()
        if let node = databases.first(where: { $0.name == database }) {
            node.isExpanded = true
            await loadCollections(node)
        }
        show("Created \(database).\(name)")
    }

    func dropCollection(_ namespace: MongoNamespace) async throws {
        try await client.dropCollection(namespace)
        for tab in tabs {
            if case let .collection(model) = tab.kind, model.namespace == namespace { close(tab) }
        }
        if let node = databases.first(where: { $0.name == namespace.database }) { await loadCollections(node) }
        await refreshDatabases()
        show("Dropped \(namespace.fullName)")
    }

    func dropDatabase(_ name: String) async throws {
        try await client.dropDatabase(name)
        for tab in tabs {
            switch tab.kind {
            case let .collection(model) where model.namespace.database == name: close(tab)
            case let .database(model) where model.database == name: close(tab)
            default: break
            }
        }
        await refreshDatabases()
        show("Dropped database \(name)")
    }

    func renameCollection(_ namespace: MongoNamespace, to newName: String) async throws {
        try await client.renameCollection(namespace, to: newName)
        for tab in tabs {
            if case let .collection(model) = tab.kind, model.namespace == namespace { close(tab) }
        }
        if let node = databases.first(where: { $0.name == namespace.database }) { await loadCollections(node) }
        show("Renamed to \(namespace.database).\(newName)")
    }

    func show(_ message: String, isError: Bool = false) {
        let toast = Toast(message: message, isError: isError)
        self.toast = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for tab in tabs { tab.willClose() }
        let client = self.client
        let tunnel = self.tunnel
        Task.detached {
            await client.close()
            tunnel?.close()
        }
    }
}

extension WorkspaceTab {
    func willClose() {
        switch kind {
        case let .collection(model): model.cancelAll()
        case let .performance(model): model.stop()
        default: break
        }
    }
}

extension ConnectionProfile {
    var defaultDatabaseName: String {
        (try? ConnectionString(uri))?.database ?? "admin"
    }
}
