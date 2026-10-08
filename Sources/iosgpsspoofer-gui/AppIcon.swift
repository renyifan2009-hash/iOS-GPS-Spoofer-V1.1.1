import AppKit

/// Draws the app icon: a gradient tile with a faint globe grid, a dotted route
/// and a glowing location pin. One source of truth for the Dock icon at
/// runtime and for the `.icns` that `package-dmg.sh` builds
/// (`iosgpsspoofer-gui --render-icon <dir>`).
enum AppIconRenderer {
    /// The icon as an image, rendered at `size`×`size` pixels.
    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep = bitmap(pixels: Int(size)) { image.addRepresentation(rep) }
        return image
    }

    /// Write `icon_16x16.png` … `icon_512x512@2x.png` into `directory`
    /// (which should end in `.iconset`, for `iconutil`).
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let rep = bitmap(pixels: pixels),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }

    static func bitmap(pixels: Int) -> NSBitmapImageRep? {
        guard pixels > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(size: CGFloat(pixels))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Drawing

    private static func draw(size s: CGFloat) {
        // macOS icon grid: an 824/1024 body, centred, with a soft drop shadow.
        let inset = s * 100 / 1024
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = body.width * 0.225
        let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        let line = max(1, s * 0.006)

        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
        drop.shadowBlurRadius = s * 0.028
        drop.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        drop.set()
        NSColor.black.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()

        // Night-to-sky gradient with a highlight in the top-left corner.
        let deep = NSColor(srgbRed: 0.13, green: 0.10, blue: 0.45, alpha: 1)
        NSGradient(colors: [deep, Brand.nsIndigo, Brand.nsSky])?.draw(in: body, angle: -60)
        let highlightCenter = NSPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.18)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)])?
            .draw(fromCenter: highlightCenter, radius: 0, toCenter: highlightCenter, radius: body.width * 0.8, options: [])

        // Globe grid.
        let globeCenter = NSPoint(x: body.midX, y: body.midY + body.height * 0.02)
        let globeRadius = body.width * 0.37
        NSColor.white.withAlphaComponent(0.17).setStroke()
        let outline = NSBezierPath(ovalIn: NSRect(x: globeCenter.x - globeRadius, y: globeCenter.y - globeRadius,
                                                  width: globeRadius * 2, height: globeRadius * 2))
        outline.lineWidth = line
        outline.stroke()
        for f: CGFloat in [0.38, 0.75] {
            let meridian = NSBezierPath(ovalIn: NSRect(x: globeCenter.x - globeRadius * f, y: globeCenter.y - globeRadius,
                                                       width: globeRadius * 2 * f, height: globeRadius * 2))
            meridian.lineWidth = line
            meridian.stroke()
        }
        for k: CGFloat in [-0.55, 0.0, 0.55] {
            let y = globeCenter.y + globeRadius * k
            let half = globeRadius * (1 - k * k).squareRoot()
            let parallel = NSBezierPath()
            parallel.move(to: NSPoint(x: globeCenter.x - half, y: y))
            parallel.line(to: NSPoint(x: globeCenter.x + half, y: y))
            parallel.lineWidth = line
            parallel.stroke()
        }

        // The pin stands slightly right of centre; a dotted route leads to it.
        let pinBase = NSPoint(x: body.midX + body.width * 0.05, y: body.midY - body.height * 0.2)
        let route = NSBezierPath()
        route.move(to: NSPoint(x: body.minX + body.width * 0.16, y: body.minY + body.height * 0.24))
        route.curve(to: NSPoint(x: pinBase.x - body.width * 0.05, y: pinBase.y + body.height * 0.005),
                    controlPoint1: NSPoint(x: body.minX + body.width * 0.30, y: body.minY + body.height * 0.48),
                    controlPoint2: NSPoint(x: body.midX - body.width * 0.24, y: pinBase.y - body.height * 0.06))
        route.lineWidth = s * 0.018
        route.lineCapStyle = .round
        let dash: [CGFloat] = [s * 0.0005, s * 0.036]
        route.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        route.stroke()

        // Ground ping under the pin.
        let rings: [(scale: CGFloat, alpha: CGFloat)] = [(1.0, 0.42), (1.75, 0.2)]
        for (scale, alpha) in rings {
            let w = body.width * 0.13 * scale
            let ring = NSBezierPath(ovalIn: NSRect(x: pinBase.x - w / 2, y: pinBase.y - w * 0.18, width: w, height: w * 0.36))
            ring.lineWidth = s * 0.008
            NSColor.white.withAlphaComponent(alpha).setStroke()
            ring.stroke()
        }

        // The pin: a teardrop whose sides are tangent to the head.
        let r = body.width * 0.16
        let head = NSPoint(x: pinBase.x, y: pinBase.y + r * 1.95)
        let beta = acos(r / (head.y - pinBase.y)) * 180 / .pi
        let pin = NSBezierPath()
        pin.move(to: pinBase)
        pin.appendArc(withCenter: head, radius: r, startAngle: -90 + beta, endAngle: 270 - beta, clockwise: false)
        pin.close()

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(srgbRed: 0.02, green: 0.05, blue: 0.25, alpha: 0.45)
        glow.shadowBlurRadius = s * 0.035
        glow.shadowOffset = NSSize(width: 0, height: -s * 0.014)
        glow.set()
        NSColor.white.setFill()
        pin.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Subtle shading on the pin's right side.
        NSGraphicsContext.saveGraphicsState()
        pin.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor(srgbRed: 0.75, green: 0.8, blue: 0.95, alpha: 0.55)])?
            .draw(in: pin.bounds, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // Gradient "lens" in the head.
        let lensRadius = r * 0.46
        let lens = NSBezierPath(ovalIn: NSRect(x: head.x - lensRadius, y: head.y - lensRadius,
                                               width: lensRadius * 2, height: lensRadius * 2))
        NSGradient(colors: [Brand.nsViolet, Brand.nsIndigo, Brand.nsSky])?.draw(in: lens, angle: -50)

        NSGraphicsContext.restoreGraphicsState()   // un-clip the tile

        // Hairline highlight around the tile.
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: line / 2, dy: line / 2), xRadius: radius, yRadius: radius)
        rim.lineWidth = line
        NSColor.white.withAlphaComponent(0.22).setStroke()
        rim.stroke()
    }
}
