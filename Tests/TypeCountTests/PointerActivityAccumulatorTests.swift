import CoreGraphics
import Testing
@testable import TypeCount

struct PointerActivityAccumulatorTests {
    private let screen = PointerDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1_000, height: 500),
                                                 physicalMillimeters: CGSize(width: 500, height: 250))

    @Test func scaledMovementAccumulatesAcrossDrainsWithoutKeepingAPath() {
        var accumulator = PointerActivityAccumulator()
        accumulator.recordMovement(to: CGPoint(x: 100, y: 100), displays: [screen])
        accumulator.recordMovement(to: CGPoint(x: 103, y: 104), displays: [screen])
        #expect(abs(accumulator.takePending().distanceMeters - 0.0025) < 1e-10)
        #expect(accumulator.takePending().isEmpty)
        accumulator.recordMovement(to: CGPoint(x: 106, y: 108), displays: [screen])
        #expect(abs(accumulator.takePending().distanceMeters - 0.0025) < 1e-10)
    }

    @Test func displayTransitionsWarpsAndSessionResetsNeverChargeTheGap() {
        let second = PointerDisplayGeometry(bounds: CGRect(x: 1_000, y: 0, width: 1_000, height: 500),
                                            physicalMillimeters: .zero)
        var accumulator = PointerActivityAccumulator()
        accumulator.recordMovement(to: CGPoint(x: 10, y: 10), displays: [screen, second])
        accumulator.recordMovement(to: CGPoint(x: 900, y: 10), displays: [screen, second])
        accumulator.recordMovement(to: CGPoint(x: 1_100, y: 10), displays: [screen, second])
        #expect(accumulator.takePending().isEmpty)
        accumulator.reset()
        accumulator.recordMovement(to: CGPoint(x: 300, y: 300), displays: [screen])
        accumulator.recordMovement(to: CGPoint(x: Double.nan, y: 0), displays: [screen])
        accumulator.recordMovement(to: CGPoint(x: 301, y: 300), displays: [screen])
        #expect(accumulator.takePending().isEmpty)
    }

    @Test func signedScrollingAddsBothAxesWithoutCancellationOrNonFiniteValues() {
        var accumulator = PointerActivityAccumulator()
        accumulator.recordScroll(horizontal: 2, vertical: -10)
        accumulator.recordScroll(horizontal: -2, vertical: 10)
        accumulator.recordScroll(horizontal: .nan, vertical: .infinity)
        #expect(accumulator.takePending().scrollPoints == 24)
        accumulator.recordScroll(horizontal: .greatestFiniteMagnitude, vertical: .greatestFiniteMagnitude)
        #expect(accumulator.takePending().scrollPoints == .greatestFiniteMagnitude)
        accumulator.reset()
        #expect(accumulator.takePending().isEmpty)
    }

    @Test func unknownDisplaySizeUsesTheDocumentedNinetySixPointFallback() {
        let display = PointerDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1_000, height: 500),
                                             physicalMillimeters: .zero)
        var accumulator = PointerActivityAccumulator()
        accumulator.recordMovement(to: CGPoint(x: 10, y: 10), displays: [display])
        accumulator.recordMovement(to: CGPoint(x: 106, y: 10), displays: [display])
        #expect(abs(accumulator.takePending().distanceMeters - 0.0254) < 1e-10)
    }
}
