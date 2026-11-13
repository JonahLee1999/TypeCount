import Foundation

/// A best-effort text edit, measured in extended grapheme clusters, not UTF-16 units.
/// Snapshots are transient. Only the resulting number reaches the statistics store.
enum TextDelta {
    static func addedCharacterCount(from previous: String, to current: String) -> Int {
        guard previous != current else { return 0 }
        var oldStart = previous.startIndex
        var newStart = current.startIndex
        while oldStart != previous.endIndex, newStart != current.endIndex,
              previous[oldStart] == current[newStart] {
            previous.formIndex(after: &oldStart)
            current.formIndex(after: &newStart)
        }
        var oldEnd = previous.endIndex
        var newEnd = current.endIndex
        while oldEnd != oldStart, newEnd != newStart {
            let oldLast = previous.index(before: oldEnd)
            let newLast = current.index(before: newEnd)
            guard previous[oldLast] == current[newLast] else { break }
            oldEnd = oldLast
            newEnd = newLast
        }
        var count = 0
        for character in current[newStart..<newEnd] {
            if !character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { count += 1 }
        }
        return count
    }
}
