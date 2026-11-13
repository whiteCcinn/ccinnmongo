import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI

struct IndexesView: View {
    @Bindable var model: IndexesModel
    let tab: CollectionTabModel
    @State private var showCreate = false
    @State private var pendingDrop: IndexInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !tab.isReadOnly {
                    Button {
                        showCreate = true
                    } label: {
                        Label("Create Index", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                if !model.supportsUsage {
                    Label("Usage statistics need MongoDB 3.2+", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if let error = model.error {
                ErrorBanner(message: error).padding(14)
            }
            Table(model.indexes) {
                TableColumn("Name & Definition") { index in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index.name).font(.callout.weight(.semibold))
                        HStack(spacing: 4) {
                            ForEach(index.keys.elements, id: \.key) { element in
                                Text("\(element.key)  \(BSONFormatter.summary(of: element.value, maxLength: 20))")
                                    .font(Theme.monospacedSmall)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Type") { index in Text(index.kind) }
                    .width(min: 70, ideal: 100)
                TableColumn("Size") { index in Text(Format.bytes(model.sizes[index.name])).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Usage") { index in usageView(index) }
                    .width(min: 120, ideal: 170)
                TableColumn("Properties") { index in properties(index) }
                    .width(min: 120, ideal: 220)
                TableColumn("") { index in
                    if !index.isIdIndex, !tab.isReadOnly {
                        Button(role: .destructive) { pendingDrop = index } label: { Image(systemName: "trash").foregroundStyle(.red) }
                            .buttonStyle(.borderless)
                            .help("Drop index")
                    }
                }
                .width(30)
            }
            .overlay {
                if model.indexes.isEmpty, model.hasLoaded, model.error == nil {
                    ContentUnavailableView("No indexes", systemImage: "list.bullet.indent")
                }
            }
        }
        .task { if !model.hasLoaded { await model.load() } }
        .sheet(isPresented: $showCreate) {
            CreateIndexSheet(model: model, fieldPaths: tab.knownFieldPaths)
        }
        .sheet(item: $pendingDrop) { index in
            DropIndexSheet(model: model, index: index)
        }
    }

    @ViewBuilder
    private func usageView(_ index: IndexInfo) -> some View {
        if let usage = model.usage?[index.name] {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Format.count(usage.operations)) ops").monospacedDigit()
                if let since = usage.since {
                    Text("since \(since.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func properties(_ index: IndexInfo) -> some View {
        HStack(spacing: 4) {
            if index.isUnique { Badge(text: "UNIQUE", color: .blue) }
            if index.isSparse { Badge(text: "SPARSE", color: .teal) }
            if let ttl = index.expireAfterSeconds { Badge(text: "TTL \(ttl)s", color: .orange) }
            if index.partialFilterExpression != nil { Badge(text: "PARTIAL", color: .purple) }
            if index.isHidden { Badge(text: "HIDDEN", color: .gray) }
            if index.collation != nil { Badge(text: "COLLATION", color: .pink) }
        }
    }
}

struct CreateIndexSheet: View {
    struct FieldEntry: Identifiable {
        let id = UUID()
        var path = ""
        var type = "1"
    }

    let model: IndexesModel
    let fieldPaths: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var fields = [FieldEntry()]
    @State private var name = ""
    @State private var unique = false
    @State private var sparse = false
    @State private var ttlEnabled = false
    @State private var ttl = 3600
    @State private var partial = ""
    @State private var collation = ""
    @State private var background = false
    @State private var hidden = false
    @State private var error: String?
    @State private var isCreating = false

    static let types: [(String, String)] = [("1", "Ascending (1)"), ("-1", "Descending (-1)"), ("text", "Text"),
                                            ("2dsphere", "2dsphere"), ("2d", "2d"), ("hashed", "Hashed")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Index").font(.title2.weight(.semibold))
            Text(model.namespace.fullName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fields").font(.headline)
                ForEach($fields) { $field in
                    HStack {
                        TextField("field.path", text: $field.path)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.monospaced)
                        Menu {
                            ForEach(fieldPaths, id: \.self) { path in Button(path) { field.path = path } }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(fieldPaths.isEmpty)
                        Picker("", selection: $field.type) {
                            ForEach(Self.types, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button {
                            fields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(fields.count == 1)
                    }
                }
                Button { fields.append(FieldEntry()) } label: { Label("Add field", systemImage: "plus") }
                    .buttonStyle(.link)
            }
            Form {
                TextField("Name", text: $name, prompt: Text(defaultName))
                Toggle("Unique", isOn: $unique)
                Toggle("Sparse", isOn: $sparse)
                Toggle("Expire documents (TTL)", isOn: $ttlEnabled)
                if ttlEnabled {
                    TextField("Seconds", value: $ttl, format: .number)
                }
                LabeledContent("Partial filter") {
                    TextField("{ field: { $exists: true } }", text: $partial).font(Theme.monospaced)
                }
                LabeledContent("Collation") {
                    TextField("{ locale: \"en\" }", text: $collation).font(Theme.monospaced)
                }
                if !model.workspace.capabilities.hasHiddenIndexes {
                    Toggle("Build in background (MongoDB < 4.2)", isOn: $background)
                } else {
                    Toggle("Hidden from the query planner", isOn: $hidden)
                }
            }
            .formStyle(.grouped)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Index", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || fields.allSatisfy { $0.path.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var keys: BSONDocument {
        var document = BSONDocument()
        for field in fields {
            let path = field.path.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            document.append(path, Int32(field.type).map(BSONValue.int32) ?? .string(field.type))
        }
        return document
    }

    private var defaultName: String { MongoClient.defaultIndexName(keys) }

    private func create() {
        isCreating = true
        error = nil
        do {
            let partialDocument = partial.isEmpty ? nil : try ShellSyntax.parseDocument(partial)
            let collationDocument = collation.isEmpty ? nil : try ShellSyntax.parseDocument(collation)
            let options = IndexOptions(name: name.isEmpty ? nil : name, unique: unique, sparse: sparse,
                                       expireAfterSeconds: ttlEnabled ? ttl : nil, partialFilterExpression: partialDocument,
                                       background: background, collation: collationDocument, hidden: hidden)
            let keys = self.keys
            Task {
                do {
                    try await model.create(keys: keys, options: options)
                    dismiss()
                } catch {
                    self.error = describe(error)
                    isCreating = false
                }
            }
        } catch {
            self.error = describe(error)
            isCreating = false
        }
    }
}

private struct DropIndexSheet: View {
    let model: IndexesModel
    let index: IndexInfo
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DestructiveConfirmation(title: "Drop index “\(index.name)”?",
                                    message: "Queries that rely on this index may become slow. The index can be recreated later.",
                                    expected: index.name, confirmation: $confirmation)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Drop Index", role: .destructive) {
                    Task {
                        do {
                            try await model.drop(index)
                            dismiss()
                        } catch {
                            self.error = describe(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(confirmation != index.name)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
