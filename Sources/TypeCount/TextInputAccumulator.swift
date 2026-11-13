import Foundation

/// Keeps the last committed baseline when the editor exposes marked text.
struct TextInputAccumulator {
    enum Composition { case unknown, marked, committed }
    private var baseline: String?

    mutating func observe(text: String, composition: Composition, sameField: Bool, allowCounting: Bool) -> Int {
        guard sameField, let previous = baseline else {
            baseline = text
            return 0
        }
        if !allowCounting { baseline = text; return 0 }
        if composition == .marked { return 0 }
        baseline = text
        guard allowCounting else { return 0 }
        return TextDelta.addedCharacterCount(from: previous, to: text)
    }

    mutating func reset() { baseline = nil }
}
