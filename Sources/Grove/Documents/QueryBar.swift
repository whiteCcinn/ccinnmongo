import BSON
import GroveKit
import SwiftUI

/// Filter / project / sort / collation / skip / limit inputs with history and validation.
struct QueryBar: View {
    @Bindable var model: DocumentsModel
    let completions: [String]
    var onExplain: (() -> Void)?
    @State private var showOptions = false
    @State private var history: [QueryHistoryEntry] = []

    var body: some View {
        let errors = model.validationErrors
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                fieldLabel("Filter")
                AutoSizingCodeEditor(text: $model.query.filter, placeholder: "{ field: \"value\" }   Type a query or leave empty for all documents",
                                     completions: completions, error: errors[.filter], onSubmit: model.run)
                    .modifier(FieldChrome(hasError: errors[.filter] != nil))
                Button {
                    withAnimation(.snappy) { showOptions.toggle() }
                } label: {
                    Label("Options", systemImage: showOptions ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Project, sort, collation, skip, limit")
                historyMenu
                Button("Reset", action: model.reset)
                    .disabled(model.query.isDefault && model.appliedQuery.isDefault)
                if let onExplain {
                    Button(action: onExplain) { Label("Explain", systemImage: "point.3.connected.trianglepath.dotted") }
                        .help("Explain this query")
                }
                Button(action: model.run) {
                    Text("Find").frame(minWidth: 44)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRun)
            }
            if let error = errors[.filter] {
                Text(error.description).font(.caption).foregroundStyle(.red).padding(.leading, 64)
            }
            if showOptions {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        fieldLabel("Project")
                        AutoSizingCodeEditor(text: $model.query.projection, placeholder: "{ field: 0 }", completions: completions,
                                             error: errors[.projection], onSubmit: model.run)
                            .modifier(FieldChrome(hasError: errors[.projection] != nil))
                        fieldLabel("Sort")
                        AutoSizingCodeEditor(text: $model.query.sort, placeholder: "{ field: -1 }", completions: completions,
                                             error: errors[.sort], onSubmit: model.run)
                            .modifier(FieldChrome(hasError: errors[.sort] != nil))
                    }
                    GridRow {
                        fieldLabel("Collation")
                        AutoSizingCodeEditor(text: $model.query.collation, placeholder: "{ locale: \"en\", strength: 2 }",
                                             error: errors[.collation], onSubmit: model.run)
                            .modifier(FieldChrome(hasError: errors[.collation] != nil))
                        fieldLabel("Hint")
                        AutoSizingCodeEditor(text: $model.query.hint, placeholder: "{ field: 1 } or index name",
                                             error: errors[.hint], onSubmit: model.run)
                            .modifier(FieldChrome(hasError: errors[.hint] != nil))
                    }
                    GridRow {
                        fieldLabel("Skip")
                        HStack {
                            TextField("0", value: $model.query.skip, format: .number.grouping(.never))
                                .frame(width: 90)
                            fieldLabel("Limit")
                            TextField("0 = none", value: $model.query.limit, format: .number.grouping(.never))
                                .frame(width: 90)
                            fieldLabel("Max time")
                            TextField("ms", value: $model.query.maxTimeMS, format: .number.grouping(.never))
                                .frame(width: 90)
                            Text("ms").foregroundStyle(.secondary)
                        }
                        .textFieldStyle(.roundedBorder)
                        .gridCellColumns(3)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(.background)
    }

    private var historyMenu: some View {
        Menu {
            if history.isEmpty {
                Text("No recent queries")
            }
            ForEach(history) { entry in
                Button {
                    model.query = entry.query
                    model.run()
                } label: {
                    Text((entry.isFavorite ? "★ " : "") + summary(entry.query))
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Query history")
        .onAppear { history = AppServices.shared.history.entries(for: model.namespace.fullName) }
        .onChange(of: model.appliedQuery) { _, _ in
            history = AppServices.shared.history.entries(for: model.namespace.fullName)
        }
    }

    private func summary(_ query: QueryInput) -> String {
        var parts: [String] = []
        if !query.filter.isEmpty { parts.append(query.filter) }
        if !query.sort.isEmpty { parts.append("sort " + query.sort) }
        if !query.projection.isEmpty { parts.append("project " + query.projection) }
        if query.limit > 0 { parts.append("limit \(query.limit)") }
        let text = parts.joined(separator: " · ").replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? "{}" : String(text.prefix(90))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 52, alignment: .trailing)
            .padding(.top, 6)
    }
}

/// Rounded field chrome around a code editor, red when invalid.
struct FieldChrome: ViewModifier {
    var hasError = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hasError ? Color.red.opacity(0.8) : Color.secondary.opacity(0.25)))
    }
}
