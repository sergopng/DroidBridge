import AppKit
import SwiftUI

// Design review based on unslop by Damir Sokolovsky (@heydamir), CC BY 4.0.
enum BridgeAppearance {
    static let chrome = adaptive(light: 0xf3f4f4, dark: 0x202223)
    static let surface = adaptive(light: 0xfbfbfb, dark: 0x1a1c1d)
    static let field = adaptive(light: 0xe9ebeb, dark: 0x2b2e2f)
    static let hover = adaptive(light: 0xe3e7e7, dark: 0x343839)
    static let accent = adaptive(light: 0x08675d, dark: 0x72d4c1)
    static let accentInk = adaptive(light: 0xffffff, dark: 0x102622)
    static let alert = adaptive(light: 0x974517, dark: 0xf1ae7f)
    static let rule = Color.primary.opacity(0.10)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = useDark ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct BridgeAction: ButtonStyle {
    enum Kind { case quiet, selected, transfer }
    var kind = Kind.quiet
    var monospaced = false

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(label: configuration.label, kind: kind, pressed: configuration.isPressed, monospaced: monospaced)
    }

    private struct ActionBody<Content: View>: View {
        let label: Content
        let kind: Kind
        let pressed: Bool
        let monospaced: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let primary = enabled && kind == .transfer
            let fill = primary ? BridgeAppearance.accent :
                (enabled && (hover || pressed) ? BridgeAppearance.hover :
                    (kind == .selected || kind == .transfer ? BridgeAppearance.field : .clear))
            label
                .font(monospaced ? .system(size: 12, design: .monospaced) :
                        .system(size: 13, weight: kind == .quiet ? .regular : .medium))
                .foregroundStyle(primary ? BridgeAppearance.accentInk : Color.primary.opacity(enabled ? 1 : 0.44))
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .opacity(primary && pressed ? 0.82 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hover = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover)
        }
    }
}

struct BridgeSymbol: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

struct ShortcutHint: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .frame(minWidth: 24, minHeight: 20)
                .background(BridgeAppearance.field, in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(BridgeAppearance.rule) }
            Text(action).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
