import Foundation

enum MenuBarFormatting {
    /// A compact visual summary. The tooltip always retains the full count.
    static func compactCount(_ count: Int) -> String {
        let value = max(0, count)
        if value < 1_000 { return String(value) }
        if value < 1_000_000 { return abbreviated(value, divisor: 1_000, suffix: "k") }
        if value < 1_000_000_000 { return abbreviated(value, divisor: 1_000_000, suffix: "m") }
        if value < 1_000_000_000_000 { return abbreviated(value, divisor: 1_000_000_000, suffix: "b") }
        return "1t+"
    }

    private static func abbreviated(_ value: Int, divisor: Int, suffix: String) -> String {
        let whole = value / divisor
        guard whole < 10 else { return "\(whole)\(suffix)" }
        let tenths = (value % divisor) / (divisor / 10)
        return tenths == 0 ? "\(whole)\(suffix)" : "\(whole).\(tenths)\(suffix)"
    }
}
