// Native, vector-drawn disk-image backdrop. No network or generated image assets.
import AppKit

let output = CommandLine.arguments[1]
let preview = CommandLine.arguments.contains("--preview")
let width = 720, height = 440
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.95, alpha: 1)])!.draw(in: canvas, angle: -75)
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 36, y: y, width: 648, height: size * 1.6), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
}
let ink = NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.29, alpha: 1)
text("still", y: 340, size: 42, weight: .medium, color: ink)
text("A little more time.", y: 310, size: 16, color: ink.withAlphaComponent(0.65))
for x: CGFloat in [180, 540] {
    let rect = NSRect(x: x - 88, y: 126, width: 176, height: 178)
    NSColor.white.withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
    NSColor.white.withAlphaComponent(0.75).setStroke()
    let border = NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32); border.lineWidth = 1; border.stroke()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 323, y: 216)); arrow.line(to: NSPoint(x: 397, y: 216))
arrow.move(to: NSPoint(x: 384, y: 229)); arrow.line(to: NSPoint(x: 397, y: 216)); arrow.line(to: NSPoint(x: 384, y: 203))
arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
ink.withAlphaComponent(0.45).setStroke(); arrow.stroke()
text("Drag Still to Applications", y: 73, size: 18, weight: .medium, color: ink)
text(preview ? "LOCAL PREVIEW  ·  NOT SIGNED FOR DISTRIBUTION" : "macOS 26 or later  ·  Apple silicon", y: 38, size: 11, weight: .medium, color: ink.withAlphaComponent(0.6))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
