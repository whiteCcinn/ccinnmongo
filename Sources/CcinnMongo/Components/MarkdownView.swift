import CcinnMongoKit
import SwiftUI

/// Renders block-level Markdown (headings, lists, tables, code, quotes) with inline styling.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        blocks = MarkdownBlockParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 2)
        case let .paragraph(text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                        Text(Self.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).").monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .code(_, text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(HighlightedText.make(text))
                    .font(Theme.monospacedSmall)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        case let .table(header, alignments, rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows)
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownBlock.Alignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column)
                            .font(.callout.weight(.semibold))
                    }
                }
                .background(Color.secondary.opacity(0.12))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column)
                                .font(.callout)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cellView(_ text: String, column: Int) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(MarkdownView.inline(text))
            .monospacedDigit()
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}
