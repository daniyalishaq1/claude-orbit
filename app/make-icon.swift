// Builds Resources/AppIcon.icns from Resources/MenuBarIcon.svg, so the app icon and the menu-bar mark stay one drawing.
// Run from app/:  swift make-icon.swift
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = here.appendingPathComponent("Resources")
guard let mark = NSImage(contentsOf: resources.appendingPathComponent("MenuBarIcon.svg")) else { fatalError("MenuBarIcon.svg not found") }

func bitmap(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func shadow(_ color: NSColor, dy: CGFloat, blur: CGFloat) -> NSShadow {
    let s = NSShadow(); s.shadowColor = color; s.shadowOffset = NSSize(width: 0, height: dy); s.shadowBlurRadius = blur; return s
}

/// The mark in white, with a soft shadow, on the standard macOS rounded square (824 on a 1024 canvas) in a warm terracotta.
let master = bitmap(1024) { s in
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    shadow(NSColor(white: 0, alpha: 0.28), dy: -10, blur: 28).set()
    NSColor(srgbRed: 0.78, green: 0.37, blue: 0.23, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.914, green: 0.584, blue: 0.420, alpha: 1),      // #E9956B
               ending: NSColor(srgbRed: 0.780, green: 0.373, blue: 0.227, alpha: 1))!        // #C75F3A
        .draw(in: plate, angle: -90)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.28), NSColor(white: 1, alpha: 0)], atLocations: [0, 0.5], colorSpace: .sRGB)!
        .draw(in: plate, angle: -90)

    let side: CGFloat = 576
    let white = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        mark.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    shadow(NSColor(srgbRed: 0.42, green: 0.16, blue: 0.07, alpha: 0.35), dy: -6, blur: 16).set()
    white.draw(in: NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let masterImage = NSImage(size: NSSize(width: 1024, height: 1024)); masterImage.addRepresentation(master)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = px == 1024 ? master : bitmap(px) { s in masterImage.draw(in: NSRect(x: 0, y: 0, width: s, height: s)) }
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = resources.appendingPathComponent("AppIcon.icns")
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! tool.run(); tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
