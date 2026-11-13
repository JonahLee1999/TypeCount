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

    @Test func largeCountBoundariesStayWithinFourASCIICharacters() {
        #expect(MenuBarFormatting.compactCount(999_999_999) == "999m")
        #expect(MenuBarFormatting.compactCount(1_000_000_000) == "1b")
        #expect(MenuBarFormatting.compactCount(1_299_999_999) == "1.2b")
        #expect(MenuBarFormatting.compactCount(999_999_999_999) == "999b")
        #expect(MenuBarFormatting.compactCount(1_000_000_000_000) == "1t+")
        #expect(MenuBarFormatting.compactCount(Int.max) == "1t+")
        #expect(MenuBarFormatting.compactCount(Int.min) == "0")

        for value in [Int.min, 999_999_999, 1_000_000_000, 1_299_999_999,
                      999_999_999_999, 1_000_000_000_000, Int.max] {
            let compact = MenuBarFormatting.compactCount(value)
            #expect(compact.count <= 4)
            #expect(compact.utf8.allSatisfy { $0 < 128 })
        }
    }
}
