import CcinnMongoKit
import MongoKit
import SwiftUI

struct CollectionView: View {
    @Bindable var model: CollectionTabModel

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionBar
            Divider()
            Group {
                switch model.section {
                case .documents: DocumentsView(model: model.documents, tab: model)
                case .aggregations: AggregationView(model: model.aggregation, tab: model)
                case .schema: SchemaView(model: model.schema, tab: model)
                case .indexes: IndexesView(model: model.indexes, tab: model)
                case .explain: ExplainView(model: model.explain, tab: model)
                case .assistant: AssistantView(model: model.assistant)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.info?.kind == .view ? "eye" : "tablecells")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.namespace.collection)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if model.info?.kind == .view {
                        Badge(text: "VIEW", color: .purple)
                    }
                    if model.info?.kind == .timeseries {
                        Badge(text: "TIME SERIES", color: .blue)
                    }
                    if model.stats?.isCapped == true || model.info?.isCapped == true {
                        Badge(text: "CAPPED", color: .orange)
                    }
                }
                Text(model.info?.viewOn.map { "\(model.namespace.database) · view on \($0)" } ?? model.namespace.database)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let stats = model.stats {
                StatPill(title: "Documents", value: Format.count(stats.documentCount))
                StatPill(title: "Storage", value: Format.bytes(stats.storageSize))
                StatPill(title: "Avg. size", value: Format.bytes(stats.averageObjectSize))
                StatPill(title: "Indexes", value: stats.indexCount.map(String.init) ?? "—")
                StatPill(title: "Index size", value: Format.bytes(stats.totalIndexSize))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sectionBar: some View {
        HStack(spacing: 2) {
            ForEach(CollectionTabModel.Section.allCases) { section in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.section = section }
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.callout.weight(model.section == section ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(model.section == section ? Theme.accent : .secondary)
                        .overlay(alignment: .bottom) {
                            if model.section == section {
                                Capsule().fill(Theme.accent).frame(height: 2.5).offset(y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }
}

struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}
