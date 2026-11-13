import Testing
@testable import TypeCount

struct TextDeltaTests {
    @Test func insertionUsesGraphemes() {
        #expect(TextDelta.addedCharacterCount(from: "你好", to: "你好，世界👨‍👩‍👧‍👦e\u{301}" ) == 5)
    }

    @Test func deletionDoesNotSubtract() {
        #expect(TextDelta.addedCharacterCount(from: "hello world", to: "hello") == 0)
    }

    @Test func insertedMiddleAndSelectionReplacement() {
        #expect(TextDelta.addedCharacterCount(from: "abef", to: "abcdef") == 2)
        #expect(TextDelta.addedCharacterCount(from: "abc", to: "a世界c") == 2)
    }

    @Test func whitespaceDoesNotCountAndIdenticalTextIsIgnored() {
        #expect(TextDelta.addedCharacterCount(from: "", to: " a\t\n中　!") == 3)
        #expect(TextDelta.addedCharacterCount(from: "same", to: "same") == 0)
    }

    @Test func separatedEditsDoNotChargeTheUnchangedMiddle() {
        #expect(TextDelta.addedCharacterCount(from: "a123456789z", to: "b123456789y") == 2)
        #expect(TextDelta.addedCharacterCount(from: "a123456789z", to: "123456789") == 0)
        #expect(TextDelta.addedCharacterCount(from: "a123456789z", to: "b123456789") == 1)
        #expect(TextDelta.addedCharacterCount(from: "abc middle xyz", to: "aQbc middle xyRz") == 2)
    }

    @Test func repeatedCharactersUseAnOrderedMatch() {
        #expect(TextDelta.addedCharacterCount(from: "aaaaabaaaaacaaaaa", to: "aaaaaxaaaaayaaaaa") == 2)
        #expect(TextDelta.addedCharacterCount(from: "abababab", to: "babababa") == 1)
    }

    @Test func separatedEditsPreserveEmojiAndCombinedGraphemes() {
        let middle = "👨‍👩‍👧‍👦e\u{301}"
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)z", to: "b\(middle)y") == 2)
        #expect(TextDelta.addedCharacterCount(from: "a \(middle)\nz", to: "b\t\(middle) y") == 2)
    }

    @Test func largePureInsertionsKeepTheirFullCount() {
        let document = String(repeating: "中", count: 100_000)
        #expect(TextDelta.addedCharacterCount(from: document, to: document + "👨‍👩‍👧‍👦e\u{301}") == 2)
        #expect(TextDelta.addedCharacterCount(from: "headtail", to: "head" + document + "tail") == 100_000)
        #expect(TextDelta.addedCharacterCount(from: document, to: "") == 0)
    }

    @Test func largeSeparatedEditsUseABoundedConservativeCount() {
        let middle = String(repeating: "中", count: 20_000)
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)z", to: "b\(middle)y") == 2)
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)z", to: middle) == 0)
        // An ambiguous large reordering may be undercounted, rather than
        // charging the entire unchanged middle as newly entered characters.
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)b", to: "b\(middle)a") == 0)
    }

    @Test func veryDiverseLargeEditsFallBackToNetGrowth() {
        let middle = String((0..<5_000).compactMap { UnicodeScalar(0x4E00 + $0) }.map(Character.init))
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)z", to: "b\(middle)y") == 0)
        #expect(TextDelta.addedCharacterCount(from: "a\(middle)z", to: "b\(middle)yz") == 1)
    }
}
