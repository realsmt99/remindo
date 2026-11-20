import AppKit

/// Draws the app icon (for the .icns built by scripts/build.sh).
enum IconRenderer {
    static func renderIconSet(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in specs {
            guard let data = png(pixels: pixels) else { return false }
            do { try data.write(to: dir.appendingPathComponent(name + ".png")) } catch { return false }
        }
        return true
    }

    static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: context.cgContext, size: CGFloat(pixels))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// y-up CoreGraphics coordinates.
    static func draw(in ctx: CGContext, size s: CGFloat) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let inset = s * 0.098
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.225
        let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(squircle)
        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.075, blue: 0.07, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        let background = CGGradient(colorsSpace: srgb, colors: [
            CGColor(srgbRed: 0.22, green: 0.16, blue: 0.13, alpha: 1),
            CGColor(srgbRed: 0.05, green: 0.045, blue: 0.045, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(background, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])

        // A little notch at the top, glowing coral.
        let nw = rect.width * 0.40, nh = rect.height * 0.11
        let notch = CGRect(x: rect.midX - nw / 2, y: rect.maxY - nh, width: nw, height: nh * 2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.05, color: CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: notch, cornerWidth: nh * 0.5, cornerHeight: nh * 0.5, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // The spark.
        let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.05)
        let r = rect.width * 0.29
        let glow = CGGradient(colorsSpace: srgb, colors: [
            CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.42),
            CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: r * 1.7, options: [])
        ctx.setFillColor(Palette.nsClaude.cgColor)
        for path in SparkGeometry.paths(center: center, radius: r, rotation: 0.08, scale: 1, length: { _ in 1 }) {
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

/// The spark in the menu bar: a template image when idle, coral with a status dot otherwise.
@MainActor
enum MenuBarIcon {
    static func image(state: AgentState?) -> NSImage {
        let colored = state != nil && state != .idle
        let dotColor = state.flatMap { $0 == .working || $0 == .idle ? nil : NSColor($0.accent) }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.setFillColor(colored ? Palette.nsClaude.cgColor : NSColor.black.cgColor)
            for path in SparkGeometry.paths(center: center, radius: 7.6, rotation: 0.08, scale: 1, length: { _ in 1 }) {
                ctx.addPath(path)
                ctx.fillPath()
            }
            if let dotColor {
                let dot = CGRect(x: rect.maxX - 7, y: rect.minY + 0.5, width: 6.5, height: 6.5)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
                ctx.setFillColor(dotColor.cgColor)
                ctx.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = "Remindo"
        return image
    }

    /// Small colored dot for menu items.
    static func dot(_ state: AgentState) -> NSImage {
        let color = NSColor(state.accent)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}
