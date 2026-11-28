// Draws the AI Stickies app icon and writes DesktopNote.app/Contents/Resources/AppIcon.icns
// Run:  swift DesktopNote/make-icon.swift   (from the repo root)

import AppKit

let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(in ctx: CGContext) {
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    // macOS icon grid: 824×824 rounded square centred on a 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow under the whole icon.
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
    drop.shadowBlurRadius = 28
    drop.shadowOffset = NSSize(width: 0, height: -12)
    drop.set()
    rgb(0x3B4BC8).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // "Wallpaper": a soft blue → violet → pink gradient.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [rgb(0x4F8BFF), rgb(0x7B5CF0), rgb(0xE77BB8)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -50)
    // A gentle glow in the top-left, like light on a wallpaper.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 280, y: 820), radius: 0, toCenter: NSPoint(x: 280, y: 820), radius: 560,
              options: [])

    // A sticky note: frosted rounded rectangle, rotated around its centre.
    func note(center: NSPoint, size: CGFloat, angle: CGFloat, alpha: CGFloat, shadow: Bool, draw: (NSRect) -> Void = { _ in }) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: center.x, yBy: center.y)
        t.rotate(byDegrees: angle)
        t.concat()
        let r = NSRect(x: -size / 2, y: -size / 2, width: size, height: size)
        let p = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor(srgbRed: 0.1, green: 0.05, blue: 0.3, alpha: 0.45)
            sh.shadowBlurRadius = 40
            sh.shadowOffset = NSSize(width: 0, height: -18)
            sh.set()
            NSColor.white.withAlphaComponent(alpha).setFill()
            p.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.white.withAlphaComponent(alpha).setFill()
            p.fill()
        }
        NSColor.white.withAlphaComponent(0.6).setStroke()
        p.lineWidth = 3
        p.stroke()
        draw(r)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Back note (more see-through), tilted left.
    note(center: NSPoint(x: 455, y: 545), size: 470, angle: 9, alpha: 0.28, shadow: false)

    // Front note with "handwriting" lines, tilted slightly right.
    note(center: NSPoint(x: 540, y: 470), size: 500, angle: -5, alpha: 0.9, shadow: true) { r in
        // Small drag pill at the top, like the real stickers.
        rgb(0x1C1C1E, 0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: -38, y: r.maxY - 46, width: 76, height: 12), xRadius: 6, yRadius: 6).fill()

        // Wavy hand-drawn lines.
        let ink = rgb(0x2A2A35, 0.78)
        ink.setStroke()
        let lines: [(CGFloat, CGFloat)] = [(120, 320), (40, 280), (-40, 320), (-120, 200)]
        for (i, (y, len)) in lines.enumerated() {
            let path = NSBezierPath()
            let x0 = r.minX + 70
            path.move(to: NSPoint(x: x0, y: y))
            var x = x0
            var up = i % 2 == 0
            while x < x0 + len {
                let nx = min(x + 40, x0 + len)
                path.curve(to: NSPoint(x: nx, y: y),
                           controlPoint1: NSPoint(x: x + 13, y: y + (up ? 9 : -9)),
                           controlPoint2: NSPoint(x: nx - 13, y: y + (up ? 9 : -9)))
                up.toggle()
                x = nx
            }
            path.lineWidth = 17
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    // Orange reminder badge with a bell, top-right of the front note.
    let badgeC = NSPoint(x: 735, y: 680)
    let badgeR: CGFloat = 92
    NSGraphicsContext.saveGraphicsState()
    let bs = NSShadow()
    bs.shadowColor = NSColor(srgbRed: 0.5, green: 0.15, blue: 0, alpha: 0.45)
    bs.shadowBlurRadius = 22
    bs.shadowOffset = NSSize(width: 0, height: -8)
    bs.set()
    let badge = NSBezierPath(ovalIn: NSRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2))
    NSGradient(colors: [rgb(0xFFB547), rgb(0xFF7A1A)])!.draw(in: badge, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.85).setStroke()
    badge.lineWidth = 6
    badge.stroke()

    if let sym = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 96, weight: .bold)) {
        let tinted = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let sz = tinted.size
        tinted.draw(in: NSRect(x: badgeC.x - sz.width / 2, y: badgeC.y - sz.height / 2 - 2,
                               width: sz.width, height: sz.height))
    }

    // Subtle glass highlight along the top edge of the icon.
    NSColor.white.withAlphaComponent(0.25).setStroke()
    shape.lineWidth = 4
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func png(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: here.appendingPathComponent("icon-preview.png"))

let resources = here.appendingPathComponent("DesktopNote.app/Contents/Resources")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let out = resources.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
