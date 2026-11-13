import BSON
import Charts
import GroveKit
import MongoKit
import SwiftUI

// MARK: - Database overview

struct DatabaseOverviewView: View {
    @Bindable var model: DatabaseOverviewModel
    @State private var sheet: SidebarView.AdminSheet?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading) {
                    Text(model.database).font(.title3.weight(.semibold))
                    Text("\(model.rows.count) collections").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let stats = model.databaseStats {
                    StatPill(title: "Data size", value: Format.bytes(stats["dataSize"]?.doubleValue))
                    StatPill(title: "Storage", value: Format.bytes(stats["storageSize"]?.doubleValue))
                    StatPill(title: "Indexes", value: Format.count(stats["indexes"]?.int64Value))
                }
                Button { sheet = .createCollection(model.database) } label: { Label("Create Collection", systemImage: "plus") }
                Button(role: .destructive) { sheet = .dropDatabase(model.database) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    .help("Drop database")
            }
            .padding(16)
            Divider()
            if let error = model.error { ErrorBanner(message: error).padding(14) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(model.rows) { row in
                        CollectionCard(row: row) {
                            model.workspace.openCollection(MongoNamespace(database: model.database, collection: row.info.name), info: row.info)
                        }
                    }
                }
                .padding(16)
            }
            .overlay {
                if model.rows.isEmpty, !model.isLoading, model.error == nil {
                    ContentUnavailableView("No collections", systemImage: "tablecells")
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $sheet) { sheet in AdminSheetView(sheet: sheet, workspace: model.workspace) }
    }
}

private struct CollectionCard: View {
    let row: DatabaseOverviewModel.Row
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: row.info.kind == .view ? "eye" : "tablecells")
                        .foregroundStyle(row.info.kind == .view ? Color.purple : Theme.accent)
                    Text(row.info.name).font(.headline).lineLimit(1)
                    Spacer()
                    if row.info.kind == .view { Badge(text: "VIEW", color: .purple) }
                    if row.info.isCapped { Badge(text: "CAPPED", color: .orange) }
                }
                if let stats = row.stats {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            metric("Documents", Format.count(stats.documentCount))
                            metric("Avg. size", Format.bytes(stats.averageObjectSize))
                        }
                        GridRow {
                            metric("Storage", Format.bytes(stats.storageSize))
                            metric("Indexes", "\(stats.indexCount ?? 0) · \(Format.bytes(stats.totalIndexSize))")
                        }
                    }
                } else if row.info.kind == .view {
                    Text("View on \(row.info.viewOn ?? "?")").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                .strokeBorder(isHovered ? Theme.accent.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: isHovered ? 1 : 0.5))
            .shadow(color: .black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 6 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

// MARK: - Server overview

struct ServerOverviewView: View {
    let workspace: WorkspaceModel
    @State private var status: BSONDocument?
    @State private var statusError: String?

    var body: some View {
        let info = workspace.serverInfo
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    GroveLogo(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MongoDB \(info.version)").font(.largeTitle.weight(.semibold))
                        Text("\(info.serverType.displayName) at \(info.address.description)").foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    InfoTile(title: "Wire protocol", value: info.protocolName, detail: "wire versions \(info.hello.minWireVersion)–\(info.hello.maxWireVersion)",
                             icon: info.capabilities.usesOpMsg ? "bolt.horizontal" : "clock.arrow.circlepath")
                    InfoTile(title: "Topology", value: info.serverType.displayName, detail: info.setName.map { "Replica set \($0)" } ?? "—", icon: "point.3.connected.trianglepath.dotted")
                    InfoTile(title: "Storage engine", value: status?["storageEngine"]?.documentValue?["name"]?.stringValue ?? "—", detail: "", icon: "internaldrive")
                    InfoTile(title: "Uptime", value: uptime, detail: status?["host"]?.stringValue ?? "", icon: "clock")
                    InfoTile(title: "Connections", value: Format.count(status?["connections"]?.documentValue?["current"]?.int64Value),
                             detail: "available \(Format.count(status?["connections"]?.documentValue?["available"]?.int64Value))", icon: "person.2")
                    InfoTile(title: "Edition", value: info.isEnterprise ? "Enterprise" : "Community", detail: info.gitVersion.map { "git \($0.prefix(10))" } ?? "", icon: "seal")
                }
                if !info.members.isEmpty {
                    Text("Replica set members").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(info.members, id: \.self) { member in
                            HStack {
                                Image(systemName: member == info.hello.primary ? "crown.fill" : "circle.fill")
                                    .foregroundStyle(member == info.hello.primary ? .yellow : .secondary)
                                    .imageScale(.small)
                                Text(member).font(Theme.monospaced)
                                if member == info.hello.primary { Badge(text: "PRIMARY", color: .green) }
                                if member == info.hello.me { Badge(text: "CONNECTED", color: Theme.accent) }
                            }
                        }
                    }
                }
                if let statusError {
                    Label("serverStatus is not available for this user: \(statusError)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let buildInfo = info.buildInfo {
                    DisclosureGroup("Build information") {
                        Text(HighlightedText.make(BSONFormatter(style: .shell, indent: 2).format(buildInfo)))
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
        .task {
            do {
                status = try await workspace.client.serverStatus()
            } catch {
                statusError = describe(error)
            }
        }
    }

    private var uptime: String {
        guard let seconds = status?["uptime"]?.doubleValue else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }
}

private struct InfoTile: View {
    let title: String
    let value: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Performance

struct PerformanceView: View {
    let model: PerformanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Live performance").font(.title2.weight(.semibold))
                    if model.isRunning {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("updating every second").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.host).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { ErrorBanner(message: error) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14)], spacing: 14) {
                    chartCard("Operations / second") {
                        Chart {
                            ForEach(model.samples) { sample in
                                ForEach(PerformanceModel.operationKinds, id: \.self) { kind in
                                    LineMark(x: .value("Time", sample.time), y: .value("ops/s", sample.opsPerSecond[kind] ?? 0))
                                        .foregroundStyle(by: .value("Operation", kind))
                                        .interpolationMethod(.monotone)
                                }
                            }
                        }
                    }
                    chartCard("Network") {
                        Chart {
                            ForEach(model.samples) { sample in
                                LineMark(x: .value("Time", sample.time), y: .value("KB/s", sample.networkInPerSecond / 1024))
                                    .foregroundStyle(by: .value("Direction", "in"))
                                LineMark(x: .value("Time", sample.time), y: .value("KB/s", sample.networkOutPerSecond / 1024))
                                    .foregroundStyle(by: .value("Direction", "out"))
                            }
                        }
                        .chartYAxisLabel("KB/s")
                    }
                    chartCard("Connections") {
                        Chart(model.samples) { sample in
                            AreaMark(x: .value("Time", sample.time), y: .value("Connections", sample.connections))
                                .foregroundStyle(Theme.accent.opacity(0.25).gradient)
                            LineMark(x: .value("Time", sample.time), y: .value("Connections", sample.connections))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    chartCard("Memory (MB)") {
                        Chart {
                            ForEach(model.samples) { sample in
                                LineMark(x: .value("Time", sample.time), y: .value("MB", sample.residentMB))
                                    .foregroundStyle(by: .value("Kind", "resident"))
                                LineMark(x: .value("Time", sample.time), y: .value("MB", sample.virtualMB))
                                    .foregroundStyle(by: .value("Kind", "virtual"))
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func chartCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
                .frame(height: 200)
                .overlay {
                    if model.samples.isEmpty {
                        ProgressView()
                    }
                }
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Console

struct ConsoleView: View {
    @Bindable var model: ConsoleModel
    let databases: [String]

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Run command on").font(.callout)
                    Picker("", selection: $model.database) {
                        ForEach(Array(Set(databases + ["admin", model.database])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Menu("Examples") {
                        ForEach(Self.examples, id: \.0) { example in
                            Button(example.0) { model.input = example.1 }
                        }
                    }
                    .fixedSize()
                    Button {
                        model.run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.inputError != nil || model.isRunning)
                }
                CodeEditor(text: $model.input, error: model.inputError, focusOnAppear: true, onSubmit: model.run)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                    .frame(minHeight: 140, maxHeight: 260)
                Text("Commands are documents in shell syntax, e.g. { serverStatus: 1 }. Press ⌘↩ to run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isRunning { ProgressView().controlSize(.small) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(entry.succeeded ? .green : .red)
                                    Text(entry.command.replacingOccurrences(of: "\n", with: " ")).font(Theme.monospaced.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text("\(entry.database) · \(Format.duration(entry.duration))").font(.caption).foregroundStyle(.secondary)
                                    Button { model.input = entry.command } label: { Image(systemName: "arrow.uturn.up") }
                                        .buttonStyle(.borderless)
                                        .help("Edit again")
                                    Button { Pasteboard.copy(entry.output) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless)
                                        .help("Copy output")
                                }
                                Text(HighlightedText.make(entry.output))
                                    .font(Theme.monospacedSmall)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 460)
        }
    }

    static let examples: [(String, String)] = [
        ("Build info", "{ buildInfo: 1 }"),
        ("Server status", "{ serverStatus: 1 }"),
        ("Current operations", "{ currentOp: 1, active: true }"),
        ("Replica set status", "{ replSetGetStatus: 1 }"),
        ("Database stats", "{ dbStats: 1 }"),
        ("Users", "{ usersInfo: 1 }"),
        ("Connection status", "{ connectionStatus: 1, showPrivileges: true }"),
        ("Host info", "{ hostInfo: 1 }"),
        ("List commands", "{ listCommands: 1 }"),
    ]
}
