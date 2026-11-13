import AppKit
import Carbon
import SwiftUI

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case compactCharacters
    case iconOnly
    case keystrokes
    case mouseClicks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compactCharacters: "图标与字数（推荐）"
        case .iconOnly: "仅图标"
        case .keystrokes: "图标与按键"
        case .mouseClicks: "图标与鼠标点击"
        }
    }
}

struct ActivityDetailsView: View {
    @ObservedObject var store: ActivityStatisticsStore
    let period: StatisticsPeriod
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let activity = store.snapshot(for: period)
        let frequentKeys = activity.keys.filter { $0.count > 0 }.sorted {
            $0.count == $1.count ? $0.keyCode < $1.keyCode : $0.count > $1.count
        }.prefix(12)
        VStack(spacing: 0) {
            if !embedded {
                HStack(spacing: 10) {
                    Text("键鼠活动").font(.system(size: 14, weight: .semibold))
                    Text(period.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(16)
                Divider()
            }
            if store.isDemo {
                TypeNotice(text: "演示模式 · 示例键鼠数据", symbol: "info.circle")
                Divider()
            }
            if let error = store.persistenceError {
                TypeNotice(text: error, symbol: "exclamationmark.triangle", isError: true)
                Divider()
            }
            HStack(spacing: 20) {
                metric("键盘敲击", count: activity.totalKeystrokes)
                Divider().frame(height: 35)
                metric("左键点击", count: activity.leftClicks)
                Divider().frame(height: 35)
                metric("右键点击", count: activity.rightClicks)
            }
            .padding(20)
            Divider()
            HStack(spacing: 18) {
                pointerMetric(
                    "鼠标移动",
                    value: PointerActivityFormatting.mouseDistance(activity.mouseDistanceMeters),
                    symbol: "arrow.up.left.and.arrow.down.right",
                    detail: "由指针移动量换算的估算距离，受屏幕缩放、设备和系统设置影响，不代表鼠标在桌面上的实际行程。"
                )
                pointerMetric(
                    "滚动量",
                    value: PointerActivityFormatting.scrollPixels(activity.scrollPoints),
                    symbol: "arrow.up.and.down",
                    detail: "单位为系统滚动像素（px），累计横向与纵向的绝对滚动量，包含触控板和惯性滚动；不是滚动次数，也不是页面实际位移。"
                )
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("24 小时键盘分布").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(period == .today ? "今日" : "按小时汇总")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                hourlyChart(activity.hours)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack {
                Text("常用键位")
                Spacer()
                Text("次数")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 9)
            Divider()
            if frequentKeys.isEmpty {
                Text("暂无按键分布").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(frequentKeys)) { key in
                            HStack {
                                Text(MacPhysicalKeyLabel.label(for: key.keyCode))
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(key.count.formatted()).font(.system(size: 12)).monospacedDigit()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 7)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("按 US QWERTY 物理键位标注，代表键位，不代表上屏字符。")
                Text("移动距离与滚动量从升级后开始记录，旧历史不回填。")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 580)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func metric(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(count.formatted()).font(.system(size: 27)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pointerMetric(_ title: String, value: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    private func hourlyChart(_ hours: [HourActivity]) -> some View {
        let counts = Dictionary(hours.map { ($0.hour, $0.keystrokes) }, uniquingKeysWith: +)
        let maximum = max(counts.values.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<24, id: \.self) { hour in
                let count = counts[hour, default: 0]
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(height: max(1, 52 * CGFloat(count) / CGFloat(maximum)))
                    Text(hour.isMultiple(of: 6) || hour == 23 ? String(hour) : " ")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(hour):00–\(hour + 1):00：\(count.formatted()) 次按键")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hour)点，\(count.formatted()) 次按键")
            }
        }
        .frame(height: 74)
    }
}

/// HIToolbox/Events.h defines ANSI virtual codes by physical US keyboard position.
/// Labels intentionally do not resolve the active layout or infer typed characters.
enum MacPhysicalKeyLabel {
    static func label(for keyCode: Int) -> String {
        labels[keyCode] ?? "Key\(keyCode)"
    }

    private static let labels: [Int: String] = [
        Int(kVK_ANSI_A): "A", Int(kVK_ANSI_S): "S", Int(kVK_ANSI_D): "D",
        Int(kVK_ANSI_F): "F", Int(kVK_ANSI_H): "H", Int(kVK_ANSI_G): "G",
        Int(kVK_ANSI_Z): "Z", Int(kVK_ANSI_X): "X", Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_V): "V", Int(kVK_ANSI_B): "B", Int(kVK_ANSI_Q): "Q",
        Int(kVK_ANSI_W): "W", Int(kVK_ANSI_E): "E", Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_Y): "Y", Int(kVK_ANSI_T): "T", Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_U): "U", Int(kVK_ANSI_I): "I", Int(kVK_ANSI_P): "P",
        Int(kVK_ANSI_L): "L", Int(kVK_ANSI_J): "J", Int(kVK_ANSI_K): "K",
        Int(kVK_ANSI_N): "N", Int(kVK_ANSI_M): "M",
        Int(kVK_ANSI_0): "0", Int(kVK_ANSI_1): "1", Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3", Int(kVK_ANSI_4): "4", Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6", Int(kVK_ANSI_7): "7", Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9", Int(kVK_ANSI_Equal): "=", Int(kVK_ANSI_Minus): "-",
        Int(kVK_ANSI_LeftBracket): "[", Int(kVK_ANSI_RightBracket): "]",
        Int(kVK_ANSI_Quote): "'", Int(kVK_ANSI_Semicolon): ";",
        Int(kVK_ANSI_Backslash): "\\", Int(kVK_ANSI_Comma): ",",
        Int(kVK_ANSI_Slash): "/", Int(kVK_ANSI_Period): ".", Int(kVK_ANSI_Grave): "`",
        Int(kVK_Return): "Return", Int(kVK_Tab): "Tab", Int(kVK_Space): "Space",
        Int(kVK_Delete): "Delete", Int(kVK_ForwardDelete): "Forward Delete",
        Int(kVK_Escape): "Esc", Int(kVK_Command): "⌘", Int(kVK_RightCommand): "右 ⌘",
        Int(kVK_Shift): "⇧", Int(kVK_RightShift): "右 ⇧", Int(kVK_CapsLock): "Caps Lock",
        Int(kVK_Option): "⌥", Int(kVK_RightOption): "右 ⌥",
        Int(kVK_Control): "⌃", Int(kVK_RightControl): "右 ⌃", Int(kVK_Function): "Fn",
        Int(kVK_LeftArrow): "←", Int(kVK_RightArrow): "→",
        Int(kVK_UpArrow): "↑", Int(kVK_DownArrow): "↓",
        Int(kVK_Home): "Home", Int(kVK_End): "End",
        Int(kVK_PageUp): "Page Up", Int(kVK_PageDown): "Page Down", Int(kVK_Help): "Help",
        Int(kVK_F1): "F1", Int(kVK_F2): "F2", Int(kVK_F3): "F3", Int(kVK_F4): "F4",
        Int(kVK_F5): "F5", Int(kVK_F6): "F6", Int(kVK_F7): "F7", Int(kVK_F8): "F8",
        Int(kVK_F9): "F9", Int(kVK_F10): "F10", Int(kVK_F11): "F11", Int(kVK_F12): "F12",
        Int(kVK_F13): "F13", Int(kVK_F14): "F14", Int(kVK_F15): "F15", Int(kVK_F16): "F16",
        Int(kVK_F17): "F17", Int(kVK_F18): "F18", Int(kVK_F19): "F19", Int(kVK_F20): "F20",
        Int(kVK_VolumeUp): "音量 +", Int(kVK_VolumeDown): "音量 -", Int(kVK_Mute): "静音",
        Int(kVK_ANSI_Keypad0): "Num 0", Int(kVK_ANSI_Keypad1): "Num 1",
        Int(kVK_ANSI_Keypad2): "Num 2", Int(kVK_ANSI_Keypad3): "Num 3",
        Int(kVK_ANSI_Keypad4): "Num 4", Int(kVK_ANSI_Keypad5): "Num 5",
        Int(kVK_ANSI_Keypad6): "Num 6", Int(kVK_ANSI_Keypad7): "Num 7",
        Int(kVK_ANSI_Keypad8): "Num 8", Int(kVK_ANSI_Keypad9): "Num 9",
        Int(kVK_ANSI_KeypadDecimal): "Num .", Int(kVK_ANSI_KeypadMultiply): "Num *",
        Int(kVK_ANSI_KeypadPlus): "Num +", Int(kVK_ANSI_KeypadClear): "Clear",
        Int(kVK_ANSI_KeypadDivide): "Num /", Int(kVK_ANSI_KeypadEnter): "Num Enter",
        Int(kVK_ANSI_KeypadMinus): "Num -", Int(kVK_ANSI_KeypadEquals): "Num =",
        Int(kVK_ISO_Section): "§", Int(kVK_JIS_Yen): "¥", Int(kVK_JIS_Underscore): "_",
        Int(kVK_JIS_KeypadComma): "Num ,", Int(kVK_JIS_Eisu): "英数", Int(kVK_JIS_Kana): "かな"
    ]
}
