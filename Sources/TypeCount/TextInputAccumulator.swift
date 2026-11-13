import Foundation

/// Keeps the last committed baseline when the editor exposes marked text.
struct TextInputAccumulator {
    enum Composition { case unknown, marked, committed }
    private var baseline: String?
    private var pendingVisibleText: String?
    private var wasDeferringUnverifiedLatin = false

    var hasPendingVisibleText: Bool {
        pendingVisibleText != nil && pendingVisibleText != baseline
    }

    mutating func observe(text: String, composition: Composition, sameField: Bool, allowCounting: Bool,
                          deferUnverifiedLatin: Bool = false) -> Int {
        let shouldDefer = deferUnverifiedLatin && composition == .unknown
        guard sameField, let previous = baseline else {
            baseline = text
            pendingVisibleText = nil
            wasDeferringUnverifiedLatin = shouldDefer
            return 0
        }
        if !allowCounting {
            baseline = text
            pendingVisibleText = nil
            wasDeferringUnverifiedLatin = shouldDefer
            return 0
        }
        if composition == .marked {
            // A known composition is never a visible-text commit candidate.
            pendingVisibleText = nil
            wasDeferringUnverifiedLatin = false
            return 0
        }
        if composition == .unknown, wasDeferringUnverifiedLatin, !shouldDefer {
            // Switching input sources does not prove that the previous source
            // committed its Latin preedit. Absorb it without charging it.
            baseline = text
            pendingVisibleText = nil
            wasDeferringUnverifiedLatin = false
            return 0
        }
        wasDeferringUnverifiedLatin = shouldDefer
        if shouldDefer { return observeUnverifiedText(text, previous: previous) }
        baseline = text
        pendingVisibleText = nil
        return TextDelta.addedCharacterCount(from: previous, to: text)
    }

    /// The caller must first confirm a commit/send boundary. A raw Return key,
    /// idle timeout or loss of focus alone does not establish such a boundary.
    mutating func commitPendingVisibleText() -> Int {
        guard let previous = baseline, let pendingVisibleText else { return 0 }
        let count = TextDelta.addedCharacterCount(from: previous, to: pendingVisibleText)
        baseline = pendingVisibleText
        self.pendingVisibleText = nil
        return count
    }

    mutating func discardPending() {
        pendingVisibleText = nil
    }

    mutating func reset() {
        baseline = nil
        pendingVisibleText = nil
        wasDeferringUnverifiedLatin = false
    }

    private mutating func observeUnverifiedText(_ text: String, previous: String) -> Int {
        // Locate only the changed window. Existing Chinese, punctuation or
        // spaces elsewhere in the document cannot confirm a new Latin run.
        var oldStart = previous.startIndex
        var newStart = text.startIndex
        while oldStart != previous.endIndex, newStart != text.endIndex,
              previous[oldStart] == text[newStart] {
            previous.formIndex(after: &oldStart)
            text.formIndex(after: &newStart)
        }
        var oldEnd = previous.endIndex
        var newEnd = text.endIndex
        while oldEnd != oldStart, newEnd != newStart {
            let oldLast = previous.index(before: oldEnd)
            let newLast = text.index(before: newEnd)
            guard previous[oldLast] == text[newLast] else { break }
            oldEnd = oldLast
            newEnd = newLast
        }
        let changed = text[newStart..<newEnd]
        guard changed.contains(where: Self.containsLatinLetter) else {
            baseline = text
            pendingVisibleText = nil
            return TextDelta.addedCharacterCount(from: previous, to: text)
        }
        pendingVisibleText = text
        // A replacement/multiple edits may contain unchanged Chinese or spaces
        // inside this window. Do not mistake them for a fresh commit boundary.
        guard oldStart == oldEnd else { return 0 }
        var confirmedEnd = newStart
        var index = newStart
        while index != newEnd {
            let character = text[index]
            text.formIndex(after: &index)
            if Self.isWhitespace(character) {
                // Pinyin preedit may separate syllables: "ni hao" is still
                // uncommitted. Only newly inserted trailing whitespace can
                // confirm a Latin run; an existing suffix was trimmed above.
                if index == newEnd { confirmedEnd = index }
            } else if !Self.isUnverifiedTokenCharacter(character) {
                confirmedEnd = index
            }
        }
        guard confirmedEnd != newStart else { return 0 }
        // Keep a final Latin run pending even if the same snapshot also gained
        // Chinese: nihao -> 你好shi must charge only 你好, not shi.
        let confirmed = String(text[..<confirmedEnd]) + String(text[newEnd...])
        baseline = confirmed
        if confirmedEnd == newEnd { pendingVisibleText = nil }
        return TextDelta.addedCharacterCount(from: previous, to: confirmed)
    }

    private static func containsLatinLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            guard CharacterSet.letters.contains(scalar) else { return false }
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A,
                 0x00C0...0x024F, 0x0250...0x02FF, 0x1D00...0x1DBF,
                 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
                 0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
                 0x10780...0x107BF, 0x1DF00...0x1DFFF:
                return true
            default: return false
            }
        }
    }

    private static func isUnverifiedTokenCharacter(_ character: Character) -> Bool {
        containsLatinLetter(character) || character == "'" || character == "’" || character == "ʼ" ||
            character.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            }
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
