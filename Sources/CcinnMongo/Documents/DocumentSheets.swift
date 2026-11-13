import AppKit
import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI
import UniformTypeIdentifiers

/// Insert / edit / clone a document in a type-preserving shell-syntax editor.
struct DocumentEditorSheet: View {
    enum Mode {
        case insert
        case edit(DocumentItem)
        case clone(DocumentItem)
    }

    let mode: Mode
    let model: DocumentsModel
    let completions: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(model.namespace.fullName).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Shell syntax · ObjectId(), ISODate(), NumberLong(), NumberDecimal() …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CodeEditor(text: $text, completions: completions, error: syntaxError, focusOnAppear: true, onSubmit: save)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(syntaxError == nil ? Color.secondary.opacity(0.25) : .red.opacity(0.7)))
                .frame(minHeight: 380)
            if let syntaxError {
                Label(syntaxError.description, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            } else if case .insert = mode {
                Text("Insert one document, an array of documents, or one document per line. A missing _id is generated as an ObjectId.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Button("Format") { format() }
                    .disabled(syntaxError != nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(syntaxError != nil || isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 540)
        .onAppear(perform: prepare)
    }

    private var title: String {
        switch mode {
        case .insert: "Insert Documents"
        case .edit: "Edit Document"
        case .clone: "Clone Document"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .insert, .clone: "Insert"
        case .edit: "Replace"
        }
    }

    private var syntaxError: SyntaxError? {
        do {
            if case .insert = mode {
                _ = try ShellSyntax.parseDocumentSequence(text)
            } else {
                _ = try ShellSyntax.parseDocument(text)
            }
            return nil
        } catch let error as SyntaxError {
            return error
        } catch {
            return nil
        }
    }

    private func prepare() {
        let formatter = BSONFormatter(style: .shell, indent: 2)
        switch mode {
        case .insert:
            text = "{\n  \n}"
        case let .edit(item):
            text = formatter.format(item.document)
        case let .clone(item):
            var copy = item.document
            copy.removeValue(forKey: "_id")
            text = formatter.format(copy)
        }
    }

    private func format() {
        let formatter = BSONFormatter(style: .shell, indent: 2)
        if case .insert = mode, let documents = try? ShellSyntax.parseDocumentSequence(text) {
            text = documents.count == 1 ? formatter.format(documents[0]) : formatter.format(array: documents.map(BSONValue.document))
        } else if let document = try? ShellSyntax.parseDocument(text) {
            text = formatter.format(document)
        }
    }

    private func save() {
        guard syntaxError == nil, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            do {
                switch mode {
                case .insert:
                    let documents = try ShellSyntax.parseDocumentSequence(text)
                    let count = try await model.insert(documents)
                    model.workspace.show(count == 1 ? "Inserted 1 document" : "Inserted \(count) documents")
                case let .edit(item):
                    try await model.replace(item, with: try ShellSyntax.parseDocument(text))
                    model.workspace.show("Document updated")
                case .clone:
                    _ = try await model.insert([try ShellSyntax.parseDocument(text)])
                    model.workspace.show("Document cloned")
                }
                dismiss()
            } catch {
                self.error = describe(error)
                isSaving = false
            }
        }
    }
}

// MARK: - Bulk operations

struct BulkUpdateSheet: View {
    let model: DocumentsModel
    @Environment(\.dismiss) private var dismiss
    @State private var update = "{\n  $set: {\n    \n  }\n}"
    @State private var error: String?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Matching Documents").font(.title2.weight(.semibold))
            filterSummary(model)
            Text("Update").font(.headline)
            CodeEditor(text: $update, completions: CompletionCatalog.updateOperators, error: parseError, focusOnAppear: true)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .frame(minHeight: 200)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update Documents") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parseError != nil || isRunning)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }

    private var parseError: SyntaxError? {
        do {
            _ = try ShellSyntax.parseDocument(update)
            return nil
        } catch let error as SyntaxError {
            return error
        } catch {
            return nil
        }
    }

    private func run() {
        isRunning = true
        Task {
            do {
                let result = try await model.updateAllMatching(try ShellSyntax.parseDocument(update))
                model.workspace.show("Matched \(result.matchedCount), modified \(result.modifiedCount)")
                dismiss()
            } catch {
                self.error = describe(error)
                isRunning = false
            }
        }
    }
}

struct BulkDeleteSheet: View {
    let model: DocumentsModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var isRunning = false
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Matching Documents", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            filterSummary(model)
            if case let .known(count) = model.count {
                Text("\(Format.count(count)) documents will be permanently deleted.")
            }
            Text("Type **delete** to confirm.").foregroundStyle(.secondary)
            TextField("delete", text: $confirmation).textFieldStyle(.roundedBorder)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete Documents", role: .destructive) { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(confirmation != "delete" || isRunning)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func run() {
        isRunning = true
        Task {
            do {
                let deleted = try await model.deleteAllMatching()
                model.workspace.show("Deleted \(deleted) documents")
                dismiss()
            } catch {
                self.error = describe(error)
                isRunning = false
            }
        }
    }
}

@MainActor
private func filterSummary(_ model: DocumentsModel) -> some View {
    let filter = model.appliedQuery.filter.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(alignment: .leading, spacing: 4) {
        Text("Filter").font(.headline)
        Text(filter.isEmpty ? "{}  (all documents)" : filter)
            .font(Theme.monospaced)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Import

struct ImportSheet: View {
    let model: DocumentsModel
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var documents: [BSONDocument] = []
    @State private var isParsing = false
    @State private var progress: Double = 0
    @State private var isImporting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Documents").font(.title2.weight(.semibold))
            Text("Into \(model.namespace.fullName). Supports a JSON array or newline-delimited JSON, in Extended JSON or shell syntax.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose File…", action: choose)
                if let fileURL { Text(fileURL.lastPathComponent).font(.callout.weight(.medium)) }
                if isParsing { ProgressView().controlSize(.small) }
            }
            if !documents.isEmpty {
                Text("\(Format.count(documents.count)) documents ready to import.")
                ScrollView {
                    Text(BSONFormatter(style: .shell, indent: 2).format(documents[0]))
                        .font(Theme.monospacedSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if isImporting { ProgressView(value: progress) }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(documents.isEmpty || isImporting)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        isParsing = true
        error = nil
        documents = []
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[BSONDocument], any Error> in
                Result {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return try DocumentImporter.parse(text)
                }
            }.value
            isParsing = false
            switch result {
            case let .success(parsed): documents = parsed
            case let .failure(failure): error = describe(failure)
            }
        }
    }

    private func runImport() {
        isImporting = true
        error = nil
        let batches = stride(from: 0, to: documents.count, by: 1000).map { Array(documents[$0..<min($0 + 1000, documents.count)]) }
        let total = documents.count
        Task {
            var inserted = 0
            do {
                for batch in batches {
                    let result = try await model.client.insert(batch, into: model.namespace)
                    inserted += result.insertedCount
                    progress = Double(inserted) / Double(max(1, total))
                }
                model.refresh()
                model.workspace.show("Imported \(Format.count(inserted)) documents")
                dismiss()
            } catch {
                self.error = describe(error) + " (\(inserted) of \(total) imported)"
                isImporting = false
                model.refresh()
            }
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    let model: DocumentsModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .jsonArray
    @State private var scope: Scope = .query
    @State private var exported = 0
    @State private var isExporting = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    enum Scope: String, CaseIterable, Identifiable {
        case query = "All documents matching the query"
        case page = "Current page only"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Documents").font(.title2.weight(.semibold))
            Form {
                Picker("Documents", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)
            if isExporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Exported \(Format.count(exported)) documents…").monospacedDigit()
                }
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button(isExporting ? "Stop" : "Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…", action: export)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.namespace.collection).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        error = nil
        exported = 0
        let format = self.format
        let client = model.client
        let namespace = model.namespace
        let pageDocuments = scope == .page ? model.items.map(\.document) : nil
        let options: FindOptions
        do {
            options = try model.appliedQuery.allResultsOptions()
        } catch {
            self.error = describe(error)
            isExporting = false
            return
        }
        task = Task {
            do {
                let sink = try ExportSink(url: url, format: format)
                let progress: @Sendable (Int) -> Void = { count in Task { @MainActor in exported = count } }
                if format == .csv {
                    var paths: [String] = []
                    if let pageDocuments {
                        paths = CSVExporter.fieldPaths(of: pageDocuments)
                    } else {
                        let collector = PathCollector()
                        try await client.forEachBatch(namespace, options: options) { batch in await collector.add(batch) }
                        paths = await collector.paths
                    }
                    try await sink.setCSVPaths(paths)
                }
                if let pageDocuments {
                    try await sink.write(pageDocuments)
                } else {
                    try await client.forEachBatch(namespace, options: options) { batch in
                        try await sink.write(batch)
                        progress(await sink.count)
                    }
                }
                let total = try await sink.finish()
                model.workspace.show("Exported \(Format.count(total)) documents to \(url.lastPathComponent)")
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = describe(error)
                isExporting = false
            }
        }
    }
}

/// Collects CSV column paths during the first export pass.
actor PathCollector {
    private var seen = Set<String>()
    private(set) var paths: [String] = []

    func add(_ documents: [BSONDocument]) {
        for path in CSVExporter.fieldPaths(of: documents) where seen.insert(path).inserted {
            paths.append(path)
        }
    }
}

/// Serialises export output to a file from concurrent batch callbacks.
actor ExportSink {
    private let handle: FileHandle
    private let format: ExportFormat
    private var writer: DocumentExportWriter?
    private var csvPaths: [String] = []
    private var wroteHeader = false
    private(set) var count = 0

    init(url: URL, format: ExportFormat) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.format = format
        switch format {
        case .jsonArray:
            var writer = DocumentExportWriter(format: .jsonArray)
            try handle.write(contentsOf: Data(writer.begin().utf8))
            self.writer = writer
        case .ndjson:
            writer = DocumentExportWriter(format: .ndjson)
        case .csv:
            writer = nil
        }
    }

    func setCSVPaths(_ paths: [String]) throws {
        csvPaths = paths
        try handle.write(contentsOf: Data(CSVExporter.header(paths).utf8))
        wroteHeader = true
    }

    func write(_ documents: [BSONDocument]) throws {
        var output = ""
        if format == .csv {
            for document in documents { output += CSVExporter.row(document, paths: csvPaths) }
        } else if var writer {
            output = writer.write(documents)
            self.writer = writer
        }
        try handle.write(contentsOf: Data(output.utf8))
        count += documents.count
    }

    func finish() throws -> Int {
        if var writer {
            try handle.write(contentsOf: Data(writer.finish().utf8))
            self.writer = writer
        }
        try handle.close()
        return count
    }
}
