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

        var body = CGRect(x: size * 0.35, y: size * 0.3, width: size * 0.3, height: size * 0.4)
        let line = plate * 0.03

        // The same mouse as the menu bar icon, so the two read as one family.
        let glyphHeight = plate * 0.46
        // `paletteColors` en vez de fijar el color y dibujar: un símbolo no es una
        // plantilla por defecto, así que sale negro sobre el degradado oscuro y
        // desaparece — que es exactamente lo que pasó al primer intento.
        let configuration = NSImage.SymbolConfiguration(pointSize: glyphHeight, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let drawn = glyph.size
            let box = CGRect(x: (size - drawn.width) / 2,
                             y: (size - drawn.height) / 2 - plate * 0.06,
                             width: drawn.width, height: drawn.height)
            glyph.draw(in: box)
            body = box
        }

        // Two chevrons lifting off the top, fading out: the flick. There is room
        // for this at 1024 points and none at 18, which is why the menu bar icon
        // stops at the capsule and the dots.
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let half = body.width * 0.33
        for (index, alpha) in [(0, 0.70), (1, 0.26)] {
            let base = body.maxY + plate * 0.062 + CGFloat(index) * plate * 0.068
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
