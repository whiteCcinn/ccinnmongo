import AppKit
import BSON
import CcinnMongoKit
import SwiftUI

/// Grid of documents with one column per top-level field, backed by NSTableView for speed and
/// runtime-defined columns.
struct DocumentTableView: NSViewRepresentable {
    let items: [DocumentItem]
    let actions: DocumentActions

    static let maxColumns = 80

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.menu = context.coordinator.makeMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        context.coordinator.update(items: items)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(items: items)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DocumentTableView
        weak var tableView: NSTableView?
        private var items: [DocumentItem] = []
        private var columns: [String] = []
        private var itemIDs: [Int] = []

        init(_ parent: DocumentTableView) {
            self.parent = parent
        }

        func update(items: [DocumentItem]) {
            guard let tableView else { return }
            let ids = items.map(\.id)
            let newColumns = Self.columns(for: items)
            if newColumns != columns {
                columns = newColumns
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for key in columns {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
                    column.title = key
                    column.minWidth = 60
                    column.width = key == "_id" ? 230 : 160
                    column.maxWidth = 1200
                    column.headerToolTip = key
                    tableView.addTableColumn(column)
                }
            }
            if ids != itemIDs || items.map(\.shellText) != self.items.map(\.shellText) {
                self.items = items
                itemIDs = ids
                tableView.reloadData()
            }
        }

        static func columns(for items: [DocumentItem]) -> [String] {
            var seen = Set<String>()
            var order: [String] = []
            for item in items {
                for key in item.document.keys where seen.insert(key).inserted {
                    order.append(key)
                    if order.count >= DocumentTableView.maxColumns { return order }
                }
            }
            if let index = order.firstIndex(of: "_id"), index != 0 {
                order.remove(at: index)
                order.insert("_id", at: 0)
            }
            return order
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, items.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let key = tableColumn.identifier.rawValue
            if let value = items[row].document[key] {
                let text: String
                switch value {
                case .document, .array: text = BSONFormatter.summary(of: value, maxLength: 200)
                default: text = BSONValueLabel.text(for: value, maxLength: 200)
                }
                cell.textField?.stringValue = text
                cell.textField?.textColor = NSColor.bsonColor(for: value.type)
                cell.toolTip = "\(key): \(value.type.displayName)"
            } else {
                cell.textField?.stringValue = "—"
                cell.textField?.textColor = .tertiaryLabelColor
                cell.toolTip = "No \(key) field"
            }
            return cell
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard items.indices.contains(row), !parent.actions.isReadOnly else { return }
            parent.actions.edit(items[row])
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Value", action: #selector(copyValue), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Document", action: #selector(copyDocument), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Edit…", action: #selector(editDocument), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Clone…", action: #selector(cloneDocument), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete…", action: #selector(deleteDocument), keyEquivalent: "").target = self
            return menu
        }

        private var clickedItem: DocumentItem? {
            guard let row = tableView?.clickedRow, items.indices.contains(row) else { return nil }
            return items[row]
        }

        @objc private func copyValue() {
            guard let tableView, let item = clickedItem, tableView.clickedColumn >= 0 else { return }
            let key = tableView.tableColumns[tableView.clickedColumn].identifier.rawValue
            if let value = item.document[key] {
                if case let .string(text) = value { Pasteboard.copy(text) } else { Pasteboard.copy(BSONFormatter(style: .shell).format(value)) }
            }
        }

        @objc private func copyDocument() {
            if let item = clickedItem { Pasteboard.copy(item.shellText) }
        }

        @objc private func editDocument() {
            if let item = clickedItem, !parent.actions.isReadOnly { parent.actions.edit(item) }
        }

        @objc private func cloneDocument() {
            if let item = clickedItem, !parent.actions.isReadOnly { parent.actions.clone(item) }
        }

        @objc private func deleteDocument() {
            if let item = clickedItem, !parent.actions.isReadOnly { parent.actions.delete(item) }
        }
    }
}
