// Draws the app icon: a macOS-style rounded square with four usage bars in the
// account colors. Run by build.sh when app/AppIcon.icns is missing:
//   swift app/make-icon.swift <output.png>
// build.sh turns the 1024 px PNG into an .icns with sips and iconutil.

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Draw into an explicit 1024 px bitmap; NSImage.lockFocus would render at the screen's scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid: a 824 px rounded square centred in 1024, corner radius ~185.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
color(0x1C2230).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: color(0x2E3748), ending: color(0x141922))!.draw(in: shape, angle: -90)
// A faint top sheen, as on Apple's own icons.
NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183), angle: -90)

// Four meters, one per account color, each at a different fill.
let bars: [(UInt32, CGFloat)] = [(0x3567CF, 0.78), (0xB96E22, 0.46), (0xB3405F, 0.92), (0x2C8A5E, 0.30)]
let barHeight: CGFloat = 64, gap: CGFloat = 52
let barWidth: CGFloat = 560
let stackHeight = CGFloat(bars.count) * barHeight + CGFloat(bars.count - 1) * gap
var y = tile.midY + stackHeight / 2 - barHeight
let x = tile.midX - barWidth / 2
for (hex, fill) in bars {
    let track = NSRect(x: x, y: y, width: barWidth, height: barHeight)
    NSColor.white.withAlphaComponent(0.10).setFill()
    NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    let filled = NSRect(x: x, y: y, width: max(barHeight, barWidth * fill), height: barHeight)
    NSGradient(starting: color(hex).blended(withFraction: 0.18, of: .white)!, ending: color(hex))!
        .draw(in: NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2), angle: -90)
    y -= barHeight + gap
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not render icon\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
