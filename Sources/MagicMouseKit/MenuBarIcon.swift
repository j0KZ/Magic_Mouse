import AppKit

/// The menu bar icon.
///
/// Apple's `computermouse`, not a hand-drawn Magic Mouse. Drawing one was the
/// first instinct — the real device is a capsule seen from above, and the SF
/// symbol is a two-button mouse with a scroll wheel, which is precisely what
/// this is not. Every attempt read as a pill, and the tapered ones read as a
/// slipper. Apple's glyph reads as a mouse instantly, carries the right weight
/// for the menu bar, and sits correctly next to every other icon up there.
/// Accuracy about which mouse it is buys nothing at 18 points.
public enum MenuBarIcon {

    /// The idle icon: an outline.
    public static func image() -> NSImage { symbol("computermouse") }

    /// Filled, flashed for a moment when a gesture fires. Cheap acknowledgement
    /// that the flick registered, which matters on a gesture that is easy to do
    /// slightly wrong — otherwise nothing on screen distinguishes "not
    /// recognized" from "recognized but the action was a no-op".
    public static func activeImage() -> NSImage { symbol("computermouse.fill") }

    private static func symbol(_ name: String) -> NSImage {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Magic Mouse Gestures") {
            image.isTemplate = true
            return image
        }
        return fallback()
    }

    /// If the symbol ever disappears from a future macOS, draw something rather
    /// than showing an empty menu bar slot.
    private static func fallback(height: CGFloat = 16) -> NSImage {
        let size = NSSize(width: (height * 0.62).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let line: CGFloat = 1.4
            let body = rect.insetBy(dx: line / 2, dy: line / 2)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(line)
            context.addPath(CGPath(roundedRect: body,
                                   cornerWidth: body.width / 2, cornerHeight: body.width / 2,
                                   transform: nil))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
