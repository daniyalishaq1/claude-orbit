import AppKit
import SwiftUI

@main
struct ClaudeOrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = AccountStore.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            Image(nsImage: MenuBarImage.make(label: store.activeAccount?.label))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?
    private var backdropWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview-window") else { return }
        // Testing aid: render the panel in a normal window so it can be screenshotted.
        let rest = args.dropFirst(i + 1)
        MainActor.assumeIsolated {
            let store = AccountStore.shared
            store.forceSetup = rest.contains("setup")
            PanelCloser.shared.enabled = false
            // Both test windows sit in the top-right corner, out of the way of whatever is being worked on.
            let corner = NSScreen.main!.visibleFrame
            if let bg = rest.first(where: { $0.hasPrefix("bg-") }) {
                // Testing aid: a plain window behind the panel, standing in for a light or dark app.
                let b = NSWindow(contentRect: NSRect(x: corner.maxX - 450, y: max(corner.minY, corner.maxY - 820), width: 450, height: min(820, corner.height)),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                b.backgroundColor = bg == "bg-dark" ? NSColor(white: 0.12, alpha: 1) : .white
                b.level = .floating   // directly behind the panel, even when another app is frontmost
                b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                b.orderFront(nil)
                backdropWindow = b
            }
            let w = KeyableWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 400),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .floating   // test window stays above other apps
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            // Same surface as the real panel. On macOS 26 and later that is Liquid Glass, where macOS swaps
            // system colours (Color.green…) for brighter "vibrant" variants, so colour changes must be judged
            // on glass. Earlier systems use the vibrant menu material.
            let host: NSHostingView<AnyView>
            let content: NSView
            if #available(macOS 26.0, *), !rest.contains("no-glass") {
                host = NSHostingView(rootView: AnyView(PanelView(store: store).glassEffect(.regular, in: .rect(cornerRadius: 12))))
                host.sizingOptions = .intrinsicContentSize   // window follows the panel's size, as in the menu bar
                content = host
            } else {
                host = NSHostingView(rootView: AnyView(PanelView(store: store)))
                let material = NSVisualEffectView()
                material.material = .menu
                material.blendingMode = .behindWindow
                material.state = .active
                material.wantsLayer = true
                material.layer?.cornerRadius = 12
                material.layer?.masksToBounds = true
                host.sizingOptions = .intrinsicContentSize
                host.translatesAutoresizingMaskIntoConstraints = false
                material.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                    host.topAnchor.constraint(equalTo: material.topAnchor),
                    host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
                ])
                content = material
            }
            w.isMovableByWindowBackground = true
            w.contentView = content
            w.appearance = NSAppearance(named: rest.contains("dark") ? .darkAqua : .aqua)
            w.setContentSize(host.fittingSize)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            func place() { w.setFrameTopLeftPoint(NSPoint(x: corner.maxX - 390, y: corner.maxY - 60)) }   // grows downwards, like the menu
            // Keep the window the size of the panel as its content loads and changes.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let size = host.fittingSize
                if size != w.contentView?.frame.size { w.setContentSize(size); place() }
            }
            place()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = w
            if let id = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_RENAME"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.renamingId = id }
            }
            if let id = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_LOGIN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.login(id) }
            }
            if let demo = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_SWITCH"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { store.switchTo(demo) }
            }
            if let path = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_SHOT"] {
                // Testing aid: the app screenshots its own panel.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    // <path>.png: the panel alone. <path>-below.png: the panel over this app's backdrop window, which
                    // is how it really looks over a light or dark app. Only these two windows are composited, so
                    // nothing else on screen can end up in a screenshot.
                    // <path>-menubar.png: the menu-bar item (mark and initials) at 4x, black on white.
                    let item = MenuBarImage.make(label: store.activeAccount?.label)
                    let big = NSImage(size: NSSize(width: item.size.width * 4 + 32, height: item.size.height * 4 + 32), flipped: false) { r in
                        NSColor.white.setFill(); r.fill()
                        item.draw(in: r.insetBy(dx: 16, dy: 16))
                        return true
                    }
                    if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-menubar.png"))
                    }
                    let rect = w.frame.insetBy(dx: -20, dy: -20).flipped
                    var shots: [(String, [NSWindow])] = [("", [w])]
                    if let backdrop = self.backdropWindow { shots.append(("-below", [w, backdrop])) }
                    for (suffix, windows) in shots {
                        var ids = windows.map { UnsafeRawPointer(bitPattern: UInt(CGWindowID($0.windowNumber))) }
                        let array = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil)! }
                        guard let img = CGImage(windowListFromArrayScreenBounds: rect, windowArray: array, imageOption: [.bestResolution]) else { continue }
                        let rep = NSBitmapImageRep(cgImage: img)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + suffix + ".png"))
                    }
                }
            }
            print("WINDOW_ID=\(w.windowNumber)")
            fflush(stdout)
        }
    }
}

/// Borderless windows can't take keyboard focus by default; the preview window needs it for text fields.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


private extension NSRect {
    /// Cocoa (bottom-left origin) → CoreGraphics screen coordinates (top-left origin).
    var flipped: CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}
