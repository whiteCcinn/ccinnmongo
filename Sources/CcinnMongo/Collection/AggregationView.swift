import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI

struct AggregationView: View {
    @Bindable var model: AggregationModel
    let tab: CollectionTabModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.showResults {
                resultsView
            } else if model.isTextMode {
                textEditor
            } else {
                stageList
            }
        }
        .onAppear { model.schedulePreviews(from: nil) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.showResults {
                Button {
                    withAnimation(.snappy) { model.showResults = false }
                } label: {
                    Label("Edit Pipeline", systemImage: "chevron.left")
                }
            } else {
                Picker("", selection: Binding(get: { model.isTextMode }, set: { model.setTextMode($0) })) {
                    Label("Stages", systemImage: "square.stack").tag(false)
                    Label("Text", systemImage: "text.alignleft").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Auto preview", isOn: $model.autoPreview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: model.autoPreview) { _, enabled in if enabled { model.schedulePreviews(from: nil) } }
            }
            Spacer()
            Text("\(model.pipeline.stages.filter(\.isEnabled).count) of \(model.pipeline.stages.count) stages enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Pasteboard.copy(model.isTextMode ? model.pipelineText : model.pipeline.text)
                model.workspace.show("Pipeline copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                Task {
                    switch await model.explain() {
                    case let .success(raw):
                        tab.section = .explain
                        tab.explain.show(raw)
                    case let .failure(error):
                        model.runError = describe(error)
                        model.showResults = true
                    }
                }
            } label: {
                Label("Explain", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button {
                model.run()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeEditor(text: $model.pipelineText, completions: tab.knownFieldPaths, error: textSyntaxError, onSubmit: model.run)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            if let error = model.textError ?? textSyntaxError?.description {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
    }

    private var textSyntaxError: SyntaxError? {
        do {
            _ = try ShellSyntax.parseArray(model.pipelineText, allowEmpty: true)
            return nil
        } catch let error as SyntaxError {
            return error
        } catch {
            return nil
        }
    }

    private var stageList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(model.pipeline.stages.enumerated()), id: \.element.id) { index, stage in
                    StageCard(model: model, index: index, stage: Binding(get: {
                        model.pipeline.stages.first { $0.id == stage.id } ?? stage
                    }, set: { newValue in
                        if let position = model.pipeline.stages.firstIndex(where: { $0.id == stage.id }) {
                            model.pipeline.stages[position] = newValue
                        }
                    }), completions: tab.knownFieldPaths)
                    addStageButton(after: index)
                }
                if model.pipeline.stages.isEmpty {
                    addStageButton(after: nil)
                }
            }
            .padding(14)
        }
    }

    private func addStageButton(after index: Int?) -> some View {
        Menu {
            ForEach(StageCatalog.stages) { template in
                Button("\(template.name) — \(template.summary)") {
                    withAnimation(.snappy) { model.addStage(after: index, template: template) }
                }
            }
        } label: {
            Label("Add stage", systemImage: "plus.circle")
                .font(.callout)
        } primaryAction: {
            withAnimation(.snappy) { model.addStage(after: index) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.accent)
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            if model.isRunning {
                LoadingPlaceholder()
            } else if let error = model.runError {
                ErrorBanner(message: error).padding(14)
                Spacer()
            } else if model.results.isEmpty {
                ContentUnavailableView("No results", systemImage: "tray", description: Text("The pipeline returned no documents."))
            } else {
                HStack {
                    Text("\(Format.count(model.results.count))\(model.results.count >= 1000 ? "+" : "") results")
                        .font(.callout.weight(.medium))
                    if let duration = model.lastDuration {
                        Text("· \(Format.duration(duration))").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                DocumentJSONView(items: model.results, actions: DocumentActions(edit: { _ in }, clone: { _ in }, delete: { _ in },
                                                                                addToFilter: { _, _ in }, isReadOnly: true))
            }
        }
    }
}

private struct StageCard: View {
    let model: AggregationModel
    let index: Int
    @Binding var stage: PipelineStage
    let completions: [String]
    @State private var isCollapsed = false

    var body: some View {
        let preview = model.previews[stage.id]
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !isCollapsed {
                    AutoSizingCodeEditor(text: $stage.body, completions: completions, error: stage.syntaxError,
                                         minHeight: 60, maxHeight: 360, isSingleLine: false)
                        .modifier(FieldChrome(hasError: stage.syntaxError != nil))
                        .onChange(of: stage.body) { _, _ in model.stageEdited(stage) }
                    if let error = stage.syntaxError {
                        Text(error.description).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .frame(width: 420, alignment: .topLeading)
            Divider()
            previewPane(preview)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: isCollapsed ? 0 : 150)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .opacity(stage.isEnabled ? 1 : 0.55)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.15), in: Circle())
                .foregroundStyle(Theme.accent)
            Menu {
                ForEach(StageCatalog.stages) { template in
                    Button("\(template.name) — \(template.summary) (MongoDB \(template.since)+)") {
                        model.changeOperator(stage, to: template)
                    }
                }
            } label: {
                Text(stage.operatorName).font(Theme.monospaced.weight(.semibold))
            }
            .fixedSize()
            Spacer()
            Toggle("", isOn: $stage.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(stage.isEnabled ? "Disable stage" : "Enable stage")
                .onChange(of: stage.isEnabled) { _, _ in model.stageEdited(stage) }
            Button { withAnimation(.snappy) { model.move(stage, by: -1) } } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
            Button { withAnimation(.snappy) { model.move(stage, by: 1) } } label: { Image(systemName: "arrow.down") }
                .disabled(index == model.pipeline.stages.count - 1)
            Button { withAnimation(.snappy) { isCollapsed.toggle() } } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            }
            Button(role: .destructive) { withAnimation(.snappy) { model.remove(stage) } } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func previewPane(_ preview: AggregationModel.StagePreview?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output after \(stage.operatorName)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if preview?.isLoading == true { ProgressView().controlSize(.mini) }
                Spacer()
                if let preview, !preview.isLoading, preview.error == nil {
                    Text("Sample of \(preview.documents.count)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !stage.isEnabled {
                Text("Stage disabled").font(.callout).foregroundStyle(.secondary)
            } else if let error = preview?.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let documents = preview?.documents, !documents.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(documents.prefix(model.previewLimit).enumerated()), id: \.offset) { _, document in
                            MiniDocumentView(document: document)
                        }
                    }
                }
            } else if preview?.isLoading != true {
                Text(model.autoPreview ? "No documents" : "Auto preview is off").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact, single-line-per-field rendering used for stage previews.
struct MiniDocumentView: View {
    let document: BSONDocument
    static let maxFields = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(document.elements.prefix(Self.maxFields).enumerated()), id: \.offset) { _, element in
                HStack(spacing: 4) {
                    Text(element.key + ":")
                        .font(Theme.monospacedSmall.weight(.medium))
                        .foregroundStyle(Color(nsColor: .syntaxKey))
                        .lineLimit(1)
                        .fixedSize()
                    Text(BSONValueLabel.text(for: element.value, maxLength: 80) == "Object" || BSONValueLabel.text(for: element.value, maxLength: 80).hasPrefix("Array")
                         ? BSONFormatter.summary(of: element.value, maxLength: 80)
                         : BSONValueLabel.text(for: element.value, maxLength: 80))
                        .font(Theme.monospacedSmall)
                        .foregroundStyle(Theme.color(for: element.value.type))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if document.count > Self.maxFields {
                Text("… \(document.count - Self.maxFields) more fields").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 260, alignment: .topLeading)
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}
