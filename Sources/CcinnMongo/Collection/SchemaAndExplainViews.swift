import BSON
import CcinnMongoKit
import MongoKit
import SwiftUI

// MARK: - Schema

struct SchemaView: View {
    @Bindable var model: SchemaModel
    let tab: CollectionTabModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Sample", selection: $model.sampleSize) {
                    ForEach([100, 1000, 5000, 20000], id: \.self) { Text("\($0) documents").tag($0) }
                }
                .fixedSize()
                Button {
                    model.analyze()
                } label: {
                    Label(model.result == nil ? "Analyze Schema" : "Re-analyze", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }.buttonStyle(.borderless)
                }
                Spacer()
                if let result = model.result {
                    Text("\(result.fields.count) top-level fields · \(Format.count(result.sampleSize)) sampled\(model.lastDuration.map { " · \(Format.duration($0))" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(tab.workspace.capabilities.hasSampleStage ? "Random sample ($sample)" : "First documents (no $sample before 3.2)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if let error = model.error {
                ErrorBanner(message: error).padding(14)
            }
            if let result = model.result {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows(result.fields, depth: 0), id: \.field.path) { row in
                            SchemaFieldRow(field: row.field, depth: row.depth, isExpanded: expanded.contains(row.field.path)) {
                                withAnimation(.snappy) {
                                    if expanded.contains(row.field.path) { expanded.remove(row.field.path) } else { expanded.insert(row.field.path) }
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 14)
                }
            } else if !model.isLoading {
                ContentUnavailableView {
                    Label("Explore your schema", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text("CcinnMongo samples documents and summarises every field: how often it appears, its types and example values.")
                } actions: {
                    Button("Analyze Schema") { model.analyze() }.buttonStyle(.borderedProminent)
                }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func rows(_ fields: [SchemaField], depth: Int) -> [(field: SchemaField, depth: Int)] {
        fields.flatMap { field -> [(field: SchemaField, depth: Int)] in
            var result = [(field: field, depth: depth)]
            if expanded.contains(field.path) { result += rows(field.children, depth: depth + 1) }
            return result
        }
    }
}

private struct SchemaFieldRow: View {
    let field: SchemaField
    let depth: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
                if !field.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.name).font(Theme.monospaced.weight(.semibold))
                    Text(field.types.map(\.type.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 260, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !field.children.isEmpty { toggle() } }

            VStack(alignment: .leading, spacing: 6) {
                TypeDistributionBar(types: field.types, total: field.count)
                HStack(spacing: 12) {
                    ForEach(field.types.prefix(4), id: \.type) { type in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(for: type.type)).frame(width: 7, height: 7)
                            Text("\(type.type.displayName) \(Int((Double(type.count) / Double(max(1, field.count)) * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !field.arrayElementTypes.isEmpty {
                    Text("Array elements: " + field.arrayElementTypes.map { "\($0.type.displayName) (\($0.count))" }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !field.sampleValues.isEmpty {
                    FlowChips(values: field.sampleValues)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int((field.presence * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(field.presence < 1 ? .orange : Theme.accent)
                Text("present").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 70)
        }
        .padding(.vertical, 10)
    }
}

struct TypeDistributionBar: View {
    let types: [TypeCount]
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(types, id: \.type) { type in
                    Rectangle()
                        .fill(Theme.color(for: type.type).gradient)
                        .frame(width: max(3, proxy.size.width * Double(type.count) / Double(max(1, total)) - 1.5))
                        .help("\(type.type.displayName): \(type.count)")
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }
}

private struct FlowChips: View {
    let values: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(Theme.monospacedSmall)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - Explain

struct ExplainView: View {
    @Bindable var model: ExplainModel
    let tab: CollectionTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Filter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                AutoSizingCodeEditor(text: $model.query.filter, placeholder: "{ field: \"value\" }", completions: tab.knownFieldPaths,
                                     error: model.query.validationErrors[.filter], onSubmit: model.run)
                    .modifier(FieldChrome(hasError: model.query.validationErrors[.filter] != nil))
                Button("Use Documents Query") { model.query = tab.documents.query }
                Button {
                    model.run()
                } label: {
                    Label("Explain", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.query.validationErrors.isEmpty || model.isLoading)
            }
            .padding(12)
            Divider()
            if let error = model.error { ErrorBanner(message: error).padding(14) }
            if model.isLoading {
                LoadingPlaceholder()
            } else if let plan = model.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(plan)
                        HStack {
                            Text("Query plan").font(.headline)
                            Badge(text: plan.format.rawValue)
                            Spacer()
                            Toggle("Raw output", isOn: $model.showRaw).toggleStyle(.switch).controlSize(.small)
                        }
                        if model.showRaw {
                            Text(HighlightedText.make(BSONFormatter(style: .shell, indent: 2).format(plan.raw)))
                                .font(Theme.monospacedSmall)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        } else if let root = plan.root {
                            PlanTreeView(node: root)
                        } else {
                            Text("This explain output has an unrecognised shape. Switch to raw output to inspect it.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("Understand query performance", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("See how MongoDB executes a query: which index it uses, how many documents it examines, and where time is spent.")
                } actions: {
                    Button("Explain Documents Query") {
                        model.query = tab.documents.query
                        model.run()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func summary(_ plan: ExplainPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if plan.usesCollectionScan {
                    Label("Collection scan — no index used", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if !plan.indexesUsed.isEmpty {
                    Label("Index used: \(plan.indexesUsed.joined(separator: ", "))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                if plan.hasInMemorySort {
                    Label("In-memory sort", systemImage: "arrow.up.arrow.down.circle")
                        .foregroundStyle(.orange)
                        .help("The sort could not use an index; large results may hit the 32/100 MB sort limit.")
                }
            }
            .font(.callout.weight(.medium))
            HStack(spacing: 12) {
                MetricCard(title: "Documents returned", value: Format.count(plan.documentsReturned), icon: "doc.text")
                MetricCard(title: "Documents examined", value: Format.count(plan.documentsExamined), icon: "doc.text.magnifyingglass")
                MetricCard(title: "Index keys examined", value: Format.count(plan.keysExamined), icon: "key")
                MetricCard(title: "Execution time", value: plan.executionTimeMillis.map { "\($0) ms" } ?? "—", icon: "timer")
                if let selectivity = plan.selectivity {
                    MetricCard(title: "Returned / examined", value: selectivity.formatted(.percent.precision(.fractionLength(0...1))), icon: "target")
                }
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(minWidth: 130, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }
}

/// Stage tree drawn top-down with connectors.
struct PlanTreeView: View {
    let node: PlanNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StageBox(node: node)
            if !node.children.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1.5).padding(.leading, 20)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(node.children) { child in
                            HStack(alignment: .top, spacing: 0) {
                                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 18, height: 1.5).padding(.top, 22)
                                PlanTreeView(node: child)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
    }
}

private struct StageBox: View {
    let node: PlanNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(node.stage).font(Theme.monospaced.weight(.bold))
                if let index = node.indexName { Badge(text: index, color: .green) }
                Spacer(minLength: 12)
                if let millis = node.executionTimeMillis { Text("\(millis) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                if let returned = node.documentsReturned { stat("returned", returned) }
                if let docs = node.documentsExamined { stat("docs examined", docs) }
                if let keys = node.keysExamined { stat("keys examined", keys) }
            }
            ForEach(node.details, id: \.self) { detail in
                Text(detail).font(Theme.monospacedSmall).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(minWidth: 280, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }

    private func stat(_ label: String, _ value: Int64) -> some View {
        Text("\(Format.count(value)) \(label)").font(.caption.monospacedDigit())
    }

    private var tint: Color {
        if node.isCollectionScan { return .orange }
        if node.isBlockingSort { return .yellow }
        if node.indexName != nil { return .green }
        return .accentColor
    }

    private var icon: String {
        if node.isCollectionScan { return "exclamationmark.triangle" }
        if node.isBlockingSort { return "arrow.up.arrow.down" }
        if node.indexName != nil { return "key" }
        return "square.stack.3d.down.right"
    }
}
