import AppKit

/// A single status-item image. Template alpha lets AppKit handle wallpaper,
/// dark mode, contrast, and the native highlighted-button appearance.
enum MenuBarIcon {
    static func image(badge: String?, paused: Bool) -> NSImage {
        let label = paused ? "Ⅱ" : badge
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setFill()
            if let label {
                // A shorter cursor leaves a dedicated upper-right corner.
                // The left text strokes still reach up beside the counter.
                drawBadgedMark()
                let text = label as NSString
                let systemFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)
                let font = text.size(withAttributes: [.font: systemFont]).width <= 15
                    ? systemFont : NSFont.monospacedSystemFont(ofSize: 6, weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: 19.5 - size.width, y: 18.5 - size.height), withAttributes: attributes)
            } else {
                drawMark(origin: NSPoint(x: 2, y: 4), scale: 1.2)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "字迹 · 已暂停" : "字迹输入统计"
        return image
    }

    private static func drawBadgedMark() {
        NSRect(x: 1, y: 10.5, width: 7.5, height: 1.4).fill()
        NSRect(x: 1, y: 6.3, width: 7.5, height: 1.4).fill()
        NSRect(x: 1, y: 2, width: 5, height: 1.4).fill()
        NSRect(x: 11.1, y: 1, width: 1.4, height: 7.5).fill()
        NSRect(x: 9.7, y: 1, width: 4.2, height: 1.4).fill()
        NSRect(x: 9.7, y: 7.1, width: 4.2, height: 1.4).fill()
    }

    private static func drawMark(origin: NSPoint, scale: CGFloat) {
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            NSRect(x: origin.x + x * scale, y: origin.y + y * scale,
                   width: width * scale, height: height * scale).fill()
        }
        rect(0, 8, 7.5, 1.4)
        rect(0, 4.5, 7.5, 1.4)
        rect(0, 1, 5, 1.4)
        rect(10.1, 0, 1.4, 10.5)
        rect(8.7, 0, 4.2, 1.4)
        rect(8.7, 9.1, 4.2, 1.4)
    }
}
