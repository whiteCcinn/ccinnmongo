import BSON
import CcinnMongoKit
import SwiftUI

/// Actions available on a document card.
struct DocumentActions {
    var edit: (DocumentItem) -> Void
    var clone: (DocumentItem) -> Void
    var delete: (DocumentItem) -> Void
    var addToFilter: (String, BSONValue) -> Void
    var isReadOnly: Bool
}

/// Expandable, type-coloured tree cards (Compass "List" view).
struct DocumentListView: View {
    @Bindable var model: DocumentsModel
    let actions: DocumentActions

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.items) { item in
                    DocumentCard(item: item,
                                 expanded: Binding(get: { model.expanded[item.id] ?? [] }, set: { model.expanded[item.id] = $0 }),
                                 actions: actions)
                }
            }
            .padding(14)
        }
    }
}

private struct DocumentCard: View {
    let item: DocumentItem
    @Binding var expanded: Set<String>
    let actions: DocumentActions
    @State private var isHovered = false
    @State private var showAllFields = false

    private static let initialFields = 25

    var body: some View {
        let tree = TreeRow.rows(for: item.document, expanded: expanded, topLevelLimit: showAllFields ? nil : Self.initialFields)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tree.rows) { row in
                TreeRowView(row: row, toggle: { toggle(row) }, addToFilter: actions.addToFilter)
            }
            if tree.hiddenTopLevel > 0 {
                Button("Show \(tree.hiddenTopLevel) more fields") { withAnimation(.snappy) { showAllFields = true } }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 4)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
            .strokeBorder(isHovered ? Theme.accent.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: isHovered ? 1 : 0.5))
        .shadow(color: .black.opacity(isHovered ? 0.07 : 0.03), radius: isHovered ? 5 : 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if isHovered { toolbar.padding(6).transition(.opacity) }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .contextMenu { menu }
        .onTapGesture(count: 2) { if !actions.isReadOnly { actions.edit(item) } }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            if !actions.isReadOnly {
                iconButton("pencil", help: "Edit document") { actions.edit(item) }
            }
            iconButton("doc.on.doc", help: "Copy document") { Pasteboard.copy(item.shellText) }
            if !actions.isReadOnly {
                iconButton("plus.square.on.square", help: "Clone document") { actions.clone(item) }
                iconButton("trash", help: "Delete document", role: .destructive) { actions.delete(item) }
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.5)))
    }

    private func iconButton(_ icon: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy Document") { Pasteboard.copy(item.shellText) }
        Button("Copy as Extended JSON") { Pasteboard.copy(BSONFormatter(style: .relaxedExtendedJSON, indent: 2).format(item.document)) }
        Button("Copy _id") { Pasteboard.copy(item.idSummary) }
        Divider()
        Button("Expand All") { expanded = Self.allPaths(item.document) }
        Button("Collapse All") { expanded = [] }
        if !actions.isReadOnly {
            Divider()
            Button("Edit…") { actions.edit(item) }
            Button("Clone…") { actions.clone(item) }
            Button("Delete…", role: .destructive) { actions.delete(item) }
        }
    }

    private func toggle(_ row: TreeRow) {
        withAnimation(.snappy(duration: 0.18)) {
            if expanded.contains(row.id) {
                expanded = expanded.filter { $0 != row.id && !$0.hasPrefix(row.id + ".") }
            } else {
                expanded.insert(row.id)
            }
        }
    }

    static func allPaths(_ document: BSONDocument) -> Set<String> {
        var paths = Set<String>()
        func walk(_ value: BSONValue, path: String, depth: Int) {
            guard depth < 8, paths.count < 2_000 else { return }
            switch value {
            case let .document(doc):
                if !path.isEmpty { paths.insert(path) }
                for element in doc.elements { walk(element.value, path: path.isEmpty ? element.key : "\(path).\(element.key)", depth: depth + 1) }
            case let .array(array):
                paths.insert(path)
                for (index, element) in array.prefix(TreeRow.maxChildren).enumerated() { walk(element, path: "\(path).\(index)", depth: depth + 1) }
            default:
                break
            }
        }
        walk(.document(document), path: "", depth: 0)
        return paths
    }
}

private struct TreeRowView: View {
    let row: TreeRow
    let toggle: () -> Void
    let addToFilter: (String, BSONValue) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            Group {
                if row.isExpandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            (Text(row.key).foregroundStyle(Color(nsColor: .syntaxKey)).font(Theme.monospaced.weight(.medium))
                + Text(":").foregroundStyle(.secondary).font(Theme.monospaced))
                .lineLimit(1)
                .layoutPriority(1)
            valueView
            Spacer(minLength: 8)
            if isHovered {
                Text(row.value.type.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if row.isExpandable { toggle() } }
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            Button("Copy Value") { Pasteboard.copy(copyText) }
            Button("Copy Field Path") { Pasteboard.copy(row.id) }
            if !row.value.type.isContainer || row.value == .document([:]) {
                Button("Add to Filter") { addToFilter(row.id, row.value) }
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        switch row.value {
        case let .document(document) where !document.isEmpty:
            HStack(spacing: 4) {
                Text("Object").font(Theme.monospaced).foregroundStyle(.secondary)
                if !row.isExpanded {
                    Text(BSONFormatter.summary(of: row.value, maxLength: 90))
                        .font(Theme.monospacedSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        case let .array(array) where !array.isEmpty:
            HStack(spacing: 4) {
                Text("Array [\(array.count)]").font(Theme.monospaced).foregroundStyle(.secondary)
                if !row.isExpanded {
                    Text(BSONFormatter.summary(of: row.value, maxLength: 90))
                        .font(Theme.monospacedSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        default:
            BSONValueLabel(value: row.value)
                .textSelection(.enabled)
        }
    }

    private var copyText: String {
        if case let .string(text) = row.value { return text }
        return BSONFormatter(style: .shell, indent: row.value.type.isContainer ? 2 : nil).format(row.value)
    }

    private var helpText: String {
        switch row.value {
        case let .datetime(date):
            return date.date.formatted(date: .complete, time: .complete)
        case let .objectId(oid):
            return "Created \(oid.date.formatted(date: .abbreviated, time: .standard))"
        case let .string(text) where text.count > 80:
            return String(text.prefix(2_000))
        default:
            return row.value.type.displayName
        }
    }
}

/// Syntax-highlighted text cards (JSON view).
struct DocumentJSONView: View {
    let items: [DocumentItem]
    let actions: DocumentActions

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    JSONCard(item: item, actions: actions)
                }
            }
            .padding(14)
        }
    }
}

private struct JSONCard: View {
    let item: DocumentItem
    let actions: DocumentActions
    @State private var isHovered = false
    @State private var text: AttributedString?

    var body: some View {
        Text(text ?? AttributedString(item.shellText))
            .font(Theme.monospaced)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                .strokeBorder(isHovered ? Theme.accent.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: isHovered ? 1 : 0.5))
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    HStack(spacing: 2) {
                        if !actions.isReadOnly {
                            Button { actions.edit(item) } label: { Image(systemName: "pencil") }.help("Edit")
                        }
                        Button { Pasteboard.copy(item.shellText) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                        if !actions.isReadOnly {
                            Button { actions.clone(item) } label: { Image(systemName: "plus.square.on.square") }.help("Clone")
                            Button(role: .destructive) { actions.delete(item) } label: { Image(systemName: "trash").foregroundStyle(.red) }.help("Delete")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .padding(6)
                }
            }
            .onHover { isHovered = $0 }
            .task(id: item.id) {
                let source = item.shellText
                text = await Task.detached(priority: .userInitiated) { HighlightedText.make(source) }.value
            }
    }
}
