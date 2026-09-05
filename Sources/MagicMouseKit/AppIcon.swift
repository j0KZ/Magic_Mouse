import AppKit

/// The app icon, drawn in code.
///
/// An accessory app has no Dock icon, so this shows up in exactly two places —
/// the Finder and, more to the point, the Privacy & Security lists where people
/// go to grant the two permissions this app cannot work without. Being
/// recognisable there is worth more than it sounds.
///
/// Follows the macOS shape: a squircle inset inside the canvas, so it lines up
/// with every other icon in the grid instead of looking a size too big.
public enum AppIcon {

    public static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            draw(in: context, size: size)
            return true
        }
    }

    private static func draw(in context: CGContext, size: CGFloat) {
        // Apple's grid: the rounded square covers ~82% of the canvas, and the
        // corner radius is ~22.4% of that square.
        let plate = size * 0.824
        let origin = (size - plate) / 2
        let rect = CGRect(x: origin, y: origin, width: plate, height: plate)
        let radius = plate * 0.2237

        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)

        // Background: a quiet vertical gradient. Loud icons age badly.
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let colors = [
            NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.42, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY),
                                       options: [])
        }
        // A hairline of light along the top edge, the way a physical object
        // catches the light. It is what keeps a flat gradient from looking dead.
        context.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
        context.setLineWidth(size * 0.006)
        context.addPath(shape)
        context.strokePath()
        context.restoreGState()

        // The mouse, same two shapes as the menu bar icon so they read as one
        // family: a 1:2 capsule with three contacts on the touch half.
        let bodyHeight = plate * 0.50
        let bodyWidth = bodyHeight / 1.95
        let line = bodyWidth * 0.11
        let body = CGRect(x: (size - bodyWidth) / 2,
                          y: (size - bodyHeight) / 2 - plate * 0.055,
                          width: bodyWidth, height: bodyHeight)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineWidth(line)
        context.addPath(CGPath(roundedRect: body,
                               cornerWidth: bodyWidth / 2, cornerHeight: bodyWidth / 2,
                               transform: nil))
        context.strokePath()

        let dot = bodyWidth * 0.155
        let spread = bodyWidth * 0.28
        let dotsY = body.maxY - body.height * 0.235
        for offset in [-spread, 0, spread] {
            context.fillEllipse(in: CGRect(x: body.midX + offset - dot / 2,
                                           y: dotsY - dot / 2,
                                           width: dot, height: dot))
        }

        // Two chevrons lifting off the top, fading out: the flick. There is room
        // for this at 1024 points and none at 18, which is why the menu bar icon
        // stops at the capsule and the dots.
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let half = bodyWidth * 0.34
        for (index, alpha) in [(0, 0.70), (1, 0.26)] {
            let base = body.maxY + plate * 0.055 + CGFloat(index) * plate * 0.078
            let rise = plate * 0.040
            context.setStrokeColor(NSColor(white: 1, alpha: alpha).cgColor)
            context.setLineWidth(line * 0.85)
            context.move(to: CGPoint(x: body.midX - half, y: base))
            context.addLine(to: CGPoint(x: body.midX, y: base + rise))
            context.addLine(to: CGPoint(x: body.midX + half, y: base))
            context.strokePath()
        }
    }
}
