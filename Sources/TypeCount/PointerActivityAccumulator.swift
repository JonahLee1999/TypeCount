import CoreGraphics
import Foundation

/// Cached display geometry; no display-server calls are made per movement.
struct PointerDisplayGeometry {
    let bounds: CGRect
    let metersPerPoint: CGSize

    init(bounds: CGRect, physicalMillimeters: CGSize) {
        self.bounds = bounds
        let validSize = physicalMillimeters.width.isFinite && physicalMillimeters.height.isFinite &&
            (50...3_000).contains(physicalMillimeters.width) && (50...3_000).contains(physicalMillimeters.height) &&
            bounds.width > 0 && bounds.height > 0
        // Some projectors, virtual displays and EDIDs do not report a usable size.
        let fallback = 0.0254 / 96
        metersPerPoint = validSize
            ? CGSize(width: physicalMillimeters.width / bounds.width / 1_000,
                     height: physicalMillimeters.height / bounds.height / 1_000)
            : CGSize(width: fallback, height: fallback)
    }
}

struct PointerActivityTotals: Equatable {
    var distanceMeters = 0.0
    var scrollPoints = 0.0
    var isEmpty: Bool { distanceMeters == 0 && scrollPoints == 0 }
}

/// O(1) numeric accumulation. Only the last cursor position is held in memory;
/// positions, paths, scroll direction and event sequences are never persisted.
struct PointerActivityAccumulator {
    private var previousLocation: CGPoint?
    private var previousDisplay: Int?
    private var pending = PointerActivityTotals()

    mutating func recordMovement(to location: CGPoint, displays: [PointerDisplayGeometry]) {
        guard location.x.isFinite, location.y.isFinite,
              let display = displays.firstIndex(where: { $0.bounds.contains(location) }) else {
            previousLocation = nil
            previousDisplay = nil
            return
        }
        defer { self.previousLocation = location; self.previousDisplay = display }
        guard let previousLocation, previousDisplay == display else { return }
        let dx = location.x - previousLocation.x
        let dy = location.y - previousLocation.y
        // Screen switches and large cursor warps must not become travelled meters.
        guard hypot(dx, dy) < 500 else { return }
        let scale = displays[display].metersPerPoint
        pending.distanceMeters = Self.add(pending.distanceMeters, hypot(dx * scale.width, dy * scale.height))
    }

    mutating func recordScroll(horizontal: Double, vertical: Double) {
        // Sum travel on both axes: reversing direction does not erase activity.
        if horizontal.isFinite { pending.scrollPoints = Self.add(pending.scrollPoints, abs(horizontal)) }
        if vertical.isFinite { pending.scrollPoints = Self.add(pending.scrollPoints, abs(vertical)) }
    }

    mutating func takePending() -> PointerActivityTotals {
        let result = pending
        pending = PointerActivityTotals()
        return result
    }

    mutating func reset() { self = PointerActivityAccumulator() }

    private static func add(_ lhs: Double, _ rhs: Double) -> Double {
        let value = lhs + rhs
        return value.isFinite ? value : .greatestFiniteMagnitude
    }
}
