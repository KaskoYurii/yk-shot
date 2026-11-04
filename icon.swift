// Draws the YKShot app icon. Regenerate AppIcon.icns with: ./build.sh icon
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centred on a 1024 canvas, soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 24
shadow.set()
NSColor(srgbRed: 0.20, green: 0.20, blue: 1.0, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.36, blue: 1.0, alpha: 1),
           ending: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.80, alpha: 1))!.draw(in: shape, angle: -90)

// Viewfinder corners.
NSColor.white.setStroke()
let inset = 250.0, arm = 140.0, lo = inset, hi = size - inset
let corners = NSBezierPath()
corners.lineWidth = 52; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
for (x, y, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1, -1), (lo, lo, 1, 1), (hi, lo, -1, 1)] {
    corners.move(to: NSPoint(x: x, y: y + dy * arm)); corners.line(to: NSPoint(x: x, y: y)); corners.line(to: NSPoint(x: x + dx * arm, y: y))
}
corners.stroke()

// "YK" monogram.
let text = NSAttributedString(string: "YK", attributes: [
    .font: NSFont.systemFont(ofSize: 250, weight: .black), .foregroundColor: NSColor.white, .kern: -6,
])
let t = text.size()
text.draw(at: NSPoint(x: (size - t.width) / 2, y: (size - t.height) / 2 - 4))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
