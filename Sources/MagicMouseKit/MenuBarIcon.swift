import AppKit

/// The menu bar icon, drawn rather than shipped as a PNG.
///
/// Drawn because it has to be a *template* image — macOS tints it black or white
/// for the menu bar, and re-tints it when the menu opens or the appearance
/// changes. Vector strokes stay crisp at every scale factor and there is no
/// asset to keep in sync.
///
/// The shape is the mouse seen from above — the real thing is about twice as
/// long as it is wide, and getting that ratio wrong makes it read as a hat —
/// with three contact dots on the touch half. That is the whole app in two
/// shapes. Apple's own `computermouse` symbol was the obvious alternative, but
/// it draws a two-button mouse with a scroll wheel, which is precisely the
/// device this is not.
public enum MenuBarIcon {

    public static func image(height: CGFloat = 18) -> NSImage {
        let size = NSSize(width: (height * 0.58).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            draw(in: context, size: size)
            return true
        }
        // Without this the icon is a black blob on a dark menu bar.
        image.isTemplate = true
        return image
    }

    private static func draw(in context: CGContext, size: NSSize) {
        let unit = size.height / 18
        let line = max(1, 1.15 * unit)

        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Body: a capsule about 1:2, which is the Magic Mouse seen from above.
        // Get that ratio wrong and it reads as a hat.
        let bodyHeight = size.height - line
        let bodyWidth = min(size.width - line, bodyHeight / 1.95)
        let body = CGRect(x: (size.width - bodyWidth) / 2,
                          y: line / 2,
                          width: bodyWidth,
                          height: bodyHeight)
        context.setLineWidth(line)
        context.addPath(CGPath(roundedRect: body,
                               cornerWidth: bodyWidth / 2, cornerHeight: bodyWidth / 2,
                               transform: nil))
        context.strokePath()

        // Three contacts on the touch half. This is the whole idea of the app,
        // and three dots say it faster at 18 points than any arrow — a chevron
        // added here just fights the capsule for space and loses.
        let dot = max(1.1, unit * 1.45)
        let spread = bodyWidth * 0.28
        let dotsY = body.maxY - body.height * 0.235
        for offset in [-spread, 0, spread] {
            context.fillEllipse(in: CGRect(x: body.midX + offset - dot / 2,
                                           y: dotsY - dot / 2,
                                           width: dot, height: dot))
        }
    }
}
