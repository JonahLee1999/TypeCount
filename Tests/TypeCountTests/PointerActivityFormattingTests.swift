import Testing
@testable import TypeCount

struct PointerActivityFormattingTests {
    @Test func distanceUsesReadableUnitsAndPromotesRoundedKilometerBoundary() {
        #expect(PointerActivityFormatting.mouseDistance(0) == "0 m")
        #expect(PointerActivityFormatting.mouseDistance(0.01) == "<0.1 m")
        #expect(PointerActivityFormatting.mouseDistance(708.8) == "≈708.8 m")
        #expect(PointerActivityFormatting.mouseDistance(999.94) == "≈999.9 m")
        #expect(PointerActivityFormatting.mouseDistance(999.95) == "≈1 km")
        #expect(PointerActivityFormatting.mouseDistance(1_234) == "≈1.2 km")
    }

    @Test func scrollingKeepsPixelUnitsAndCompactScaleBoundaries() {
        #expect(PointerActivityFormatting.scrollPixels(0) == "0 px")
        #expect(PointerActivityFormatting.scrollPixels(0.01) == "<0.1 px")
        #expect(PointerActivityFormatting.scrollPixels(23.1) == "23.1 px")
        #expect(PointerActivityFormatting.scrollPixels(999.94) == "999.9 px")
        #expect(PointerActivityFormatting.scrollPixels(999.95) == "1k px")
        #expect(PointerActivityFormatting.scrollPixels(23_100) == "23.1k px")
        #expect(PointerActivityFormatting.scrollPixels(999_950) == "1m px")
    }

    @Test func invalidAmountsBecomeZeroAndExtremeAmountsStayBounded() {
        for value in [-1.0, -Double.infinity, Double.infinity, Double.nan, -0.0] {
            #expect(PointerActivityFormatting.mouseDistance(value) == "0 m")
            #expect(PointerActivityFormatting.scrollPixels(value) == "0 px")
        }
        for value in [1e15, Double.greatestFiniteMagnitude] {
            let distance = PointerActivityFormatting.mouseDistance(value)
            let scrolling = PointerActivityFormatting.scrollPixels(value)
            #expect(distance.count < 24)
            #expect(scrolling.count < 24)
            #expect(distance.hasSuffix(" km"))
            #expect(scrolling.hasSuffix(" px"))
            #expect(!distance.lowercased().contains("inf"))
            #expect(!scrolling.lowercased().contains("inf"))
        }
    }
}
