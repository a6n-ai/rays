// Draws the DMG window background (660x400 pt) at 1x and 2x: swift scripts/dmg/draw-background.swift <out-dir>
import AppKit

func draw(scale: CGFloat, to url: URL) {
    let size = CGSize(width: 660, height: 400)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Same sunlit blend as the app icon, washed out so the icons and label stay readable.
    let colors = [NSColor(red: 1.00, green: 0.93, blue: 0.80, alpha: 1), NSColor(red: 1.00, green: 0.86, blue: 0.84, alpha: 1),
                  NSColor(red: 0.93, green: 0.88, blue: 0.98, alpha: 1), NSColor(red: 0.84, green: 0.92, blue: 1.00, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: size), angle: -25)

    // Arrow between the two icon slots (icons are centred at x 170 and 490, y 190 from the top).
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y)); arrow.line(to: NSPoint(x: 392, y: y))
    arrow.move(to: NSPoint(x: 376, y: y + 14)); arrow.line(to: NSPoint(x: 394, y: y)); arrow.line(to: NSPoint(x: 376, y: y - 14))
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(white: 0.15, alpha: 0.35).setStroke(); arrow.stroke()

    let label = "Drag Rays to Applications" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                .foregroundColor: NSColor(white: 0.12, alpha: 0.75)]
    let w = label.size(withAttributes: attrs).width
    label.draw(at: NSPoint(x: (size.width - w) / 2, y: 318), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(filePath: CommandLine.arguments.dropFirst().first ?? ".")
draw(scale: 1, to: out.appending(path: "background.png"))
draw(scale: 2, to: out.appending(path: "background@2x.png"))
