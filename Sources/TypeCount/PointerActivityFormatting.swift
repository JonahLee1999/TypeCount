import Foundation

/// Display-only rounding. Stored activity aggregates retain their full precision.
enum PointerActivityFormatting {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func mouseDistance(_ meters: Double) -> String {
        let value = nonnegativeFinite(meters)
        guard value > 0 else { return "0 m" }
        if value < 0.1 { return "<0.1 m" }
        // Promote values that would round to 1000 m, keeping the unit boundary tidy.
        if value < 999.95 { return "≈\(decimal(value)) m" }
        let kilometers = value / 1_000
        let number = kilometers < 1_000_000 ? decimal(kilometers) : scientific(kilometers)
        return "≈\(number) km"
    }

    static func scrollPixels(_ pixels: Double) -> String {
        let value = nonnegativeFinite(pixels)
        guard value > 0 else { return "0 px" }
        if value < 0.1 { return "<0.1 px" }
        guard value < 1_000_000_000_000_000 else { return "\(scientific(value)) px" }

        let scales: [Double] = [1, 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000]
        let suffixes = ["", "k", "m", "b", "t"]
        var index = 0
        while index < scales.count - 1, value / scales[index] >= 999.95 { index += 1 }
        return "\(decimal(value / scales[index]))\(suffixes[index]) px"
    }

    private static func nonnegativeFinite(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func decimal(_ value: Double) -> String {
        let result = String(format: "%.1f", locale: locale, value)
        return result.hasSuffix(".0") ? String(result.dropLast(2)) : result
    }

    private static func scientific(_ value: Double) -> String {
        let parts = String(format: "%.1e", locale: locale, value).split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return "0" }
        let mantissa = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return "\(mantissa)e\(exponent)"
    }
}
