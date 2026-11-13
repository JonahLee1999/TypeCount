import Foundation

/// A best-effort text edit, measured in extended grapheme clusters, not UTF-16 units.
/// Snapshots are transient. Only the resulting number reaches the statistics store.
enum TextDelta {
    private static let maximumLCSCells = 65_536
    private static let maximumFallbackDistinctCharacters = 4_096

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
        let oldSegment = previous[oldStart..<oldEnd]
        let newSegment = current[newStart..<newEnd]
        let newCount = countedLength(newSegment)
        guard newCount > 0 else { return 0 }
        // A single insertion, including a large append or insertion in the
        // middle of a document, needs neither a diff matrix nor a dictionary.
        guard !oldSegment.isEmpty else { return newCount }
        let oldCount = countedLength(oldSegment)
        guard oldCount > 0 else { return newCount }

        if oldCount <= maximumLCSCells / newCount {
            // Whitespace has no weight in this metric. Matching only counted
            // graphemes also avoids a whitespace match displacing a real one.
            let oldCharacters = oldSegment.compactMap { isCounted($0) ? $0 : nil }
            let newCharacters = newSegment.compactMap { isCounted($0) ? $0 : nil }
            return newCount - longestCommonSubsequence(oldCharacters, newCharacters)
        }
        return conservativeAddedCount(from: oldSegment, to: newSegment,
                                      oldCount: oldCount, newCount: newCount)
    }

    private static func isCounted(_ character: Character) -> Bool {
        !character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func countedLength(_ text: Substring) -> Int {
        text.reduce(into: 0) { count, character in
            if isCounted(character) { count += 1 }
        }
    }

    private static func longestCommonSubsequence(_ first: [Character], _ second: [Character]) -> Int {
        let shorter = first.count <= second.count ? first : second
        let longer = first.count <= second.count ? second : first
        var previousRow = [Int](repeating: 0, count: shorter.count + 1)
        var currentRow = previousRow
        for character in longer {
            currentRow[0] = 0
            for index in shorter.indices {
                currentRow[index + 1] = character == shorter[index]
                    ? previousRow[index] + 1
                    : max(previousRow[index + 1], currentRow[index])
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[shorter.count]
    }

    private static func conservativeAddedCount(from previous: Substring, to current: Substring,
                                               oldCount: Int, newCount: Int) -> Int {
        // For large, disjoint edits, a full edit-distance search could block
        // the main actor. A frequency difference is a lower bound on inserted
        // graphemes: reordered old text is never charged as newly typed text.
        // Bound the dictionary too; very diverse text falls back to net growth.
        var remaining: [Character: Int] = [:]
        for character in previous where isCounted(character) {
            if remaining[character] == nil,
               remaining.count == maximumFallbackDistinctCharacters {
                return max(0, newCount - oldCount)
            }
            remaining[character, default: 0] += 1
        }
        var added = 0
        for character in current where isCounted(character) {
            if let count = remaining[character], count > 0 {
                remaining[character] = count - 1
            } else {
                added += 1
            }
        }
        return added
    }
}
