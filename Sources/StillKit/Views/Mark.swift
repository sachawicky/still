import AppKit
import SwiftUI

/// The product mark: a ring cut by a thin seam (the closed lid), with a dot that
/// bridges the seam (activity continuing through closure). One geometry feeds the
/// app icon, the menu-bar template image and the in-app glyph.
public enum MarkGeometry {
    static let ringRadius: CGFloat = 0.335
    static let ringWidth: CGFloat = 0.085
    static let seamHeight: CGFloat = 0.07
    static let dotRadius: CGFloat = 0.088

    public static func ringPath(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = ringRadius * side
        let circle = CGPath(
            ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r),
            transform: nil
        )
        let stroked = circle.copy(strokingWithWidth: ringWidth * side, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        let seam = CGRect(x: rect.minX, y: center.y - seamHeight * side / 2, width: rect.width, height: seamHeight * side)
        return stroked.subtracting(CGPath(rect: seam, transform: nil))
    }

    public static func dotPath(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let r = dotRadius * side
        return CGPath(
            ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r),
            transform: nil
        )
    }
}

public struct MarkRing: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(MarkGeometry.ringPath(in: rect)) }
}

public struct MarkDot: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(MarkGeometry.dotPath(in: rect)) }
}

public struct MarkView: View {
    public enum Style { case idle, active, paused }
    var style: Style

    public init(style: Style) { self.style = style }

    public var body: some View {
        ZStack {
            MarkRing().fill(style == .idle ? Color.secondary : Color.primary)
            switch style {
            case .active:
                MarkDot().fill(Color.primary).transition(.scale(scale: 0.4).combined(with: .opacity))
            case .paused:
                MarkDot().stroke(Color.secondary, lineWidth: 1.5).transition(.opacity)
            case .idle:
                EmptyView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The typographic wordmark: lowercase "still" in the system typeface,
/// slightly tightened. Used beside the mark in the popover header.
public struct Wordmark: View {
    var size: CGFloat
    public init(size: CGFloat = 15) { self.size = size }

    public var body: some View {
        Text(Brand.wordmark)
            .font(.system(size: size, weight: .semibold))
            .tracking(-size * 0.015)
            .accessibilityHidden(true)
    }
}

public enum MarkRenderer {
    /// Template image for the menu bar (monochrome; the system tints it).
    public static func menuBarImage(style: MarkView.Style) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(MarkGeometry.ringPath(in: rect))
            ctx.fillPath()
            switch style {
            case .active:
                ctx.addPath(MarkGeometry.dotPath(in: rect))
                ctx.fillPath()
            case .paused:
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.4)
                ctx.addPath(MarkGeometry.dotPath(in: rect.insetBy(dx: 0.7, dy: 0.7)))
                ctx.strokePath()
            case .idle:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Writes an .iconset folder (all required sizes) for `iconutil`.
    public static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (name, pixels) in entries {
            guard let png = appIconPNG(pixels: pixels) else { continue }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    static func appIconPNG(pixels: Int) -> Data? {
        let s = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = gctx.cgContext
        let space = CGColorSpaceCreateDeviceRGB()

        // macOS icon grid: 824/1024 body, centered.
        let body = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
        let radius = body.width * 0.2237
        let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.20, green: 0.21, blue: 0.23, alpha: 1),
                     CGColor(red: 0.07, green: 0.075, blue: 0.09, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.minY), options: [])

        // Mark, sized to the body.
        let markRect = body.insetBy(dx: body.width * 0.1, dy: body.height * 0.1)
        ctx.addPath(MarkGeometry.ringPath(in: markRect))
        ctx.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 0.92))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: s * 0.035, color: CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.55))
        ctx.addPath(MarkGeometry.dotPath(in: markRect))
        ctx.setFillColor(CGColor(red: 1, green: 0.98, blue: 0.94, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Hairline top highlight for depth.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.setLineWidth(max(1, s * 0.002))
        ctx.strokePath()
        ctx.restoreGState()

        return rep.representation(using: .png, properties: [:])
    }
}
