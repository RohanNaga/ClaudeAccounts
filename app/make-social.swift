// Draws docs/social.png, the 1280×640 card GitHub and X show when the repo link is shared.
// Run: swift app/make-social.swift <icon.png> <menu screenshot cropped to the menu> <out.png>

import AppKit

let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!
let shot = NSImage(contentsOfFile: args[2])!
let size = NSSize(width: 1280, height: 640)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The icon's own dark gradient, so the card and the app read as one thing.
NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.28, blue: 0.35, alpha: 1),
           ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1))!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

icon.draw(in: NSRect(x: 64, y: 410, width: 140, height: 140))

/// Draw a block of text whose first line starts at `top`; AppKit's y axis points up.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, width: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.18
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: style]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 72, y: top - 200, width: width, height: 200))
}

text("ClaudeAccounts", size: 64, weight: .bold, color: .white, top: 385, width: 640)
text("Switch Claude accounts without losing your chats.", size: 34, weight: .medium,
     color: NSColor(white: 0.86, alpha: 1), top: 290, width: 600)
text("Every account's usage in your menu bar. Free and open source for macOS.", size: 22, weight: .regular,
     color: NSColor(white: 0.62, alpha: 1), top: 175, width: 600)

// The menu itself, on the right, at its natural size so it stays sharp.
let shotHeight: CGFloat = 558
let shotWidth = shotHeight * shot.size.width / shot.size.height
let frame = NSRect(x: size.width - shotWidth - 96, y: (size.height - shotHeight) / 2, width: shotWidth, height: shotHeight)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
