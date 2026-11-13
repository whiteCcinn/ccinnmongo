import AppKit
import BSON
import CcinnMongoKit
import SwiftUI

/// Visual language: one accent ("leaf green"), adaptive syntax/type palette, consistent metrics.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 12
        static let rowHeight: CGFloat = 22
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    static func color(for type: BSONType) -> Color { Color(nsColor: NSColor.bsonColor(for: type)) }

    static func color(for profileColor: ProfileColor) -> Color {
        switch profileColor {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    static func icon(for type: BSONType) -> String {
        switch type {
        case .document: "curlybraces"
        case .array: "square.stack.3d.up"
        case .string, .symbol: "textformat"
        case .int32, .int64, .double, .decimal128: "number"
        case .bool: "checkmark.circle"
        case .datetime, .timestamp: "calendar"
        case .objectId: "key"
        case .binary: "doc.zipper"
        case .null, .undefined: "circle.slash"
        case .regex: "asterisk"
        case .javascript, .javascriptWithScope: "chevron.left.forwardslash.chevron.right"
        case .minKey, .maxKey: "arrow.up.and.down"
        case .dbPointer: "link"
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let appAccent = adaptive(light: .hex(0x14864A), dark: .hex(0x3DD68C))

    static let syntaxKey = adaptive(light: .hex(0x7A3E9D), dark: .hex(0xC792EA))
    static let syntaxOperator = adaptive(light: .hex(0xB4235A), dark: .hex(0xFF7AB2))
    static let syntaxString = adaptive(light: .hex(0x1A7F37), dark: .hex(0x7EE2A8))
    static let syntaxNumber = adaptive(light: .hex(0x1F5FD1), dark: .hex(0x82AAFF))
    static let syntaxKeyword = adaptive(light: .hex(0xB35900), dark: .hex(0xFFB86C))
    static let syntaxConstructor = adaptive(light: .hex(0x0E7490), dark: .hex(0x5FD7E8))
    static let syntaxRegex = adaptive(light: .hex(0xC2410C), dark: .hex(0xFF9166))
    static let syntaxComment = adaptive(light: .hex(0x8A8F98), dark: .hex(0x6B7280))
    static let syntaxFieldReference = adaptive(light: .hex(0x4338CA), dark: .hex(0xA5B4FC))

    static func bsonColor(for type: BSONType) -> NSColor {
        switch type {
        case .string, .symbol: .syntaxString
        case .int32, .int64, .double, .decimal128: .syntaxNumber
        case .bool: .syntaxKeyword
        case .objectId: adaptive(light: .hex(0xA16207), dark: .hex(0xF5C451))
        case .datetime, .timestamp: .syntaxConstructor
        case .null, .undefined, .minKey, .maxKey: .syntaxComment
        case .regex: .syntaxRegex
        case .binary, .dbPointer: adaptive(light: .hex(0x6B7280), dark: .hex(0x9CA3AF))
        case .javascript, .javascriptWithScope: .syntaxFieldReference
        case .document, .array: .secondaryLabelColor
        }
    }

    static func syntaxColor(for role: SyntaxRole) -> NSColor {
        switch role {
        case .key: .syntaxKey
        case .operatorKey: .syntaxOperator
        case .string: .syntaxString
        case .fieldReference: .syntaxFieldReference
        case .number: .syntaxNumber
        case .keyword: .syntaxKeyword
        case .constructor: .syntaxConstructor
        case .regex: .syntaxRegex
        case .comment: .syntaxComment
        case .punctuation: .secondaryLabelColor
        case .identifier: .labelColor
        case .invalid: .systemRed
        }
    }
}

enum Format {
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func duration(_ duration: Duration) -> String {
        let millis = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        if millis < 1 { return "<1 ms" }
        if millis < 1000 { return "\(Int(millis.rounded())) ms" }
        return String(format: "%.2f s", millis / 1000)
    }
}

/// Small rounded label used for versions, protocols and properties.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }
}

/// Inline error presentation with a copy affordance.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy error")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// Card container used across the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Metrics.cardPadding)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

extension View {
    /// Copies text to the general pasteboard.
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
