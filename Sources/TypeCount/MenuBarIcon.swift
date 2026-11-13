import AppKit

/// A single status-item image. Template alpha lets AppKit handle wallpaper,
/// dark mode, contrast, and the native highlighted-button appearance.
enum MenuBarIcon {
    static func image(badge: String?, paused: Bool) -> NSImage {
        let label = paused ? "Ⅱ" : badge
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            if let label {
                // Reserve separate horizontal regions: mark on the left,
                // counter to its right. Their vertical ranges overlap so the
                // number sits beside the mark instead of above its roof.
                drawBadgedMark()
                let text = label as NSString
                let fonts = [NSFont.systemFont(ofSize: 6.5, weight: .semibold),
                             NSFont.monospacedSystemFont(ofSize: 6.25, weight: .semibold),
                             NSFont.monospacedSystemFont(ofSize: 6, weight: .semibold)]
                let font = fonts.first { text.size(withAttributes: [.font: $0, .kern: -0.25]).width <= 14.25 } ?? fonts[2]
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .kern: -0.25,
                    .foregroundColor: NSColor.black
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: 21.5 - size.width, y: 15 - size.height), withAttributes: attributes)
            } else {
                drawMark(origin: NSPoint(x: 3, y: 2.5), scale: 1.2)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "字迹 · 已暂停" : "字迹输入统计"
        return image
    }

    private static func drawBadgedMark() {
        NSRect(x: 0.5, y: 12.2, width: 3.2, height: 1.3).fill()
        NSRect(x: 0.5, y: 7.8, width: 3.2, height: 1.3).fill()
        NSRect(x: 0.5, y: 3.4, width: 2.4, height: 1.3).fill()
        NSRect(x: 5.2, y: 3.2, width: 1.1, height: 6.7).fill()
        NSRect(x: 4.3, y: 3.2, width: 2.8, height: 1.3).fill()
        NSRect(x: 4.3, y: 8.6, width: 2.8, height: 1.3).fill()
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
