import SwiftUI
import UniformTypeIdentifiers

/// Compass-style tab strip with close buttons, middle-click close and drag reordering.
struct TabBarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var hovered: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    TabButton(tab: tab, isSelected: workspace.selectedTabID == tab.id, isHovered: hovered == tab.id,
                              onSelect: { workspace.selectedTabID = tab.id },
                              onClose: { withAnimation(.snappy) { workspace.close(tab) } })
                        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            withAnimation(.snappy) { workspace.moveTab(id, to: tab.id) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = tab.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onClose))
        .help(tab.subtitle.map { "\($0).\(tab.title)" } ?? tab.title)
    }
}
