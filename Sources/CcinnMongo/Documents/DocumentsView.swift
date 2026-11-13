import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI

struct DocumentsView: View {
    @Bindable var model: DocumentsModel
    let tab: CollectionTabModel
    @State private var sheet: DocumentSheet?
    @State private var pendingDelete: DocumentItem?
    @State private var actionError: String?

    enum DocumentSheet: Identifiable {
        case insert
        case edit(DocumentItem)
        case clone(DocumentItem)
        case importFile
        case export
        case updateMany
        case deleteMany

        var id: String {
            switch self {
            case .insert: "insert"
            case let .edit(item): "edit.\(item.id)"
            case let .clone(item): "clone.\(item.id)"
            case .importFile: "import"
            case .export: "export"
            case .updateMany: "updateMany"
            case .deleteMany: "deleteMany"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            QueryBar(model: model, completions: tab.knownFieldPaths, onExplain: tab.explainCurrentQuery, tab: tab)
            Divider()
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            statusBar
        }
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "defaultViewMode"), !model.hasLoaded,
               let mode = DocumentViewMode(rawValue: raw) {
                model.viewMode = mode
            }
            model.loadIfNeeded()
        }
        .sheet(item: $sheet) { sheet in
            sheetView(sheet)
        }
        .confirmationDialog("Delete this document?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    do {
                        try await model.delete(item)
                        model.workspace.show("Document deleted")
                    } catch {
                        actionError = describe(error)
                    }
                }
            }
        } message: {
            Text("The document with _id \(pendingDelete?.idSummary ?? "") will be permanently deleted.")
        }
    }

    private var actions: DocumentActions {
        DocumentActions(edit: { sheet = .edit($0) },
                        clone: { sheet = .clone($0) },
                        delete: { pendingDelete = $0 },
                        addToFilter: addToFilter,
                        isReadOnly: tab.isReadOnly)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !tab.isReadOnly {
                Menu {
                    Button("Insert Document…") { sheet = .insert }
                    Button("Import JSON File…") { sheet = .importFile }
                } label: {
                    Label("Add Data", systemImage: "plus")
                } primaryAction: {
                    sheet = .insert
                }
                .fixedSize()
            }
            Button {
                sheet = .export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            if !tab.isReadOnly {
                Menu {
                    Button("Update Matching Documents…") { sheet = .updateMany }
                    Button("Delete Matching Documents…", role: .destructive) { sheet = .deleteMany }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Bulk operations on the current filter")
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.borderless)
            }
            Text(model.rangeDescription)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                ForEach([10, 20, 50, 100, 200, 500], id: \.self) { size in
                    Button {
                        model.setPageSize(size)
                    } label: {
                        if size == model.pageSize { Label("\(size) per page", systemImage: "checkmark") } else { Text("\(size) per page") }
                    }
                }
            } label: {
                Text("\(model.pageSize)").monospacedDigit()
            }
            .fixedSize()
            .help("Documents per page")
            ControlGroup {
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .fixedSize()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            Picker("View", selection: $model.viewMode) {
                ForEach(DocumentViewMode.allCases) { mode in
                    Image(systemName: mode.icon).help(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(message: error) { model.error = nil }.padding(12)
            }
            if let actionError {
                ErrorBanner(message: actionError) { self.actionError = nil }.padding(12)
            }
            ZStack {
                if model.items.isEmpty {
                    if model.isLoading || !model.hasLoaded {
                        LoadingPlaceholder()
                    } else if model.error == nil {
                        ContentUnavailableView {
                            Label(model.appliedQuery.isDefault ? "This collection is empty" : "No documents match", systemImage: "doc.text.magnifyingglass")
                        } description: {
                            Text(model.appliedQuery.isDefault ? "Insert a document or import a file to get started." : "Try changing the filter.")
                        } actions: {
                            if !tab.isReadOnly, model.appliedQuery.isDefault {
                                Button("Insert Document") { sheet = .insert }
                            }
                        }
                    }
                } else {
                    switch model.viewMode {
                    case .list: DocumentListView(model: model, actions: actions)
                    case .json: DocumentJSONView(items: model.items, actions: actions)
                    case .table: DocumentTableView(items: model.items, actions: actions)
                    }
                }
            }
            .opacity(model.isLoading && !model.items.isEmpty ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.15), value: model.isLoading)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let duration = model.lastDuration {
                Label("Query took \(Format.duration(duration))", systemImage: "timer")
            }
            if case .unavailable = model.count {
                Label("Count unavailable (took longer than 5 s)", systemImage: "exclamationmark.circle")
            }
            Spacer()
            Text(model.namespace.fullName)
            Text("·")
            Text(model.workspace.capabilities.protocolName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func addToFilter(_ path: String, _ value: BSONValue) {
        var filter = (try? ShellSyntax.parseDocument(model.query.filter, allowEmpty: true)) ?? [:]
        filter[path] = value
        model.query.filter = BSONFormatter(style: .shell).format(filter)
        model.run()
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: DocumentSheet) -> some View {
        switch sheet {
        case .insert:
            DocumentEditorSheet(mode: .insert, model: model, completions: tab.knownFieldPaths)
        case let .edit(item):
            DocumentEditorSheet(mode: .edit(item), model: model, completions: tab.knownFieldPaths)
        case let .clone(item):
            DocumentEditorSheet(mode: .clone(item), model: model, completions: tab.knownFieldPaths)
        case .importFile:
            ImportSheet(model: model)
        case .export:
            ExportSheet(model: model)
        case .updateMany:
            BulkUpdateSheet(model: model)
        case .deleteMany:
            BulkDeleteSheet(model: model)
        }
    }
}

/// Shimmering placeholder cards while the first page loads.
struct LoadingPlaceholder: View {
    @State private var phase = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<4, id: \.self) { line in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: CGFloat([220, 320, 180, 260][line]), height: 10)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            }
            Spacer()
        }
        .padding(14)
        .opacity(phase ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}
