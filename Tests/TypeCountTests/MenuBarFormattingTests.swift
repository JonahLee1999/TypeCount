import Testing
@testable import TypeCount

struct MenuBarFormattingTests {
    @Test func exactSmallCountsAndInvalidNegatives() {
        #expect(MenuBarFormatting.compactCount(-1) == "0")
        #expect(MenuBarFormatting.compactCount(0) == "0")
        #expect(MenuBarFormatting.compactCount(999) == "999")
    }
    @Test func compactThousandsAndMillionsRemainShort() {
        #expect(MenuBarFormatting.compactCount(1_000) == "1k")
        #expect(MenuBarFormatting.compactCount(1_972) == "1.9k")
        #expect(MenuBarFormatting.compactCount(10_001) == "10k")
        #expect(MenuBarFormatting.compactCount(999_999) == "999k")
        #expect(MenuBarFormatting.compactCount(1_200_000) == "1.2m")
    }
}
