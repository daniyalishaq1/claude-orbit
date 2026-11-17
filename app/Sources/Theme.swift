import AppKit
import SwiftUI

/// Fixed colours, deliberately not `Color.green` / `Color.red`. The menu panel is Liquid Glass, and on glass
/// macOS swaps system colours for much brighter "vibrant" variants (system green turns neon over a dark app
/// and pale mint over a light one), which made the initials and tick unreadable. A plain sRGB colour is
/// drawn exactly as written, whatever is behind the panel.
/// In use: a soft lime with near-black green on top (about 10:1). Danger: red, dark enough for white on top.
let inUseColor = Color(.sRGB, red: 0.749, green: 0.918, blue: 0.424)   // #BFEA6C
let inUseInk = Color(.sRGB, red: 0.137, green: 0.188, blue: 0.161)     // #233029
let dangerColor = Color(.sRGB, red: 0.84, green: 0.19, blue: 0.15)

/// "In use" badge: a filled lime disc with a dark check. The colour lives in a solid shape, never in
/// thin text or a bare stroke, so it stays readable whatever app the translucent panel is blurring.
struct InUseBadge: View {
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(inUseInk, inUseColor)
            .font(.system(size: size, weight: .medium))
    }
}

/// Inline error: the red filled icon carries the colour; the words stay in the normal label colour.
struct ErrorLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, dangerColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

enum Motion {
    /// Critically-damped-ish: a click carries no momentum, so no bounce.
    static let highlight = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let fade = Animation.easeOut(duration: 0.18)
    static let press = Animation.easeOut(duration: 0.1)
}

func initials(_ label: String) -> String {
    let words = label.split(separator: " ").filter { !$0.isEmpty }
    let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.joined().isEmpty ? "?" : letters.joined()
}

/// Initials avatar. Neutral for every account; filled lime when in use
/// (like the connected network in the Wi-Fi menu).
struct Avatar: View {
    let label: String
    var active = false
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(active ? AnyShapeStyle(inUseColor) : AnyShapeStyle(.primary.opacity(0.14)))
            Text(initials(label))
                .font(.system(size: size * 0.38, weight: .medium, design: .rounded))
                .foregroundStyle(active ? AnyShapeStyle(inUseInk) : AnyShapeStyle(.primary.opacity(0.85)))
        }
        .frame(width: size, height: size)
    }
}

/// A menu-style row: full-width, rounded hover highlight, instant press feedback.
struct MenuRowStyle: ButtonStyle {
    var highlighted = false
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, highlighted: highlighted)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let highlighted: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : (hover || highlighted) && enabled ? 0.08 : 0))
                )
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .onHover { hover = $0 }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// Text row used for actions ("Add Account…"), aligned with the panel's leading inset.
struct MenuRowLabel: View {
    let title: String
    var shortcut: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if let shortcut { Text(shortcut).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Monochrome menu-bar item: the app's mark followed by the active account's initials
/// (template image: macOS tints it like every other menu extra).
enum MenuBarImage {
    /// A spark with two accounts in orbit around it, from Resources/MenuBarIcon.svg (the app icon is built from the same file).
    private static let mark: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 17, height: 17)
            return image
        }
        // Run outside the app bundle (no resources): fall back to a system symbol.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        return NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }()

    static func make(label: String?) -> NSImage {
        // Initials only: a full account name takes too much of the menu bar.
        let text = (label ?? "").isEmpty ? "" : initials(label ?? "")
        let str = NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black])
        let gap: CGFloat = text.isEmpty ? 0 : 4
        let mark = self.mark
        let size = NSSize(width: ceil(mark.size.width + gap + str.size().width), height: max(18, mark.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: (size.height - mark.size.height) / 2, width: mark.size.width, height: mark.size.height))
            str.draw(at: NSPoint(x: mark.size.width + gap, y: (size.height - str.size().height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = (label ?? "").isEmpty ? "Claude Orbit" : "Claude Orbit, \(label ?? "")"
        return image
    }
}
