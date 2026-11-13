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
}
