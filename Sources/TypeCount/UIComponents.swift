import AppKit
import SwiftUI

struct TypeAppIcon: View {
    let image: NSImage?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TypeApplicationRow: View {
    let app: ApplicationStatistics
    let excluded: Bool

    private var characterDisplay: String {
        if app.characters > 0 { return "≈\(app.characters.formatted())" }
        switch app.textReadability {
        case .available: return "≈0"
        case .unknown: return "—"
        case .unsupported, .tooLarge: return "仅按键"
        case .secure: return "已保护"
        }
    }

    private var characterHelp: String {
        let currentStatus: String
        switch app.textReadability {
        case .available:
            currentStatus = "当前应用的文本接口可用，显示估算新增字符。"
        case .unknown:
            currentStatus = "尚未确认当前应用的文本接口是否可用。"
        case .unsupported:
            currentStatus = "当前应用的文本接口不支持读取，仅记录按键次数。"
        case .tooLarge:
            currentStatus = "当前文档超过支持的文本长度，仅记录按键次数。"
        case .secure:
            currentStatus = "当前为受保护的输入区域，暂停统计字符与按键。"
        }
        return app.characters > 0 && app.textReadability != .available
            ? "字符数为已有历史记录；" + currentStatus
            : currentStatus
    }

    var body: some View {
        HStack(spacing: 10) {
            TypeAppIcon(image: app.icon)
            Text(app.name).lineLimit(1).truncationMode(.middle)
            if excluded {
                Image(systemName: "minus.circle").font(.caption).foregroundStyle(.secondary)
                    .help("已排除，不再新增统计")
            }
            Spacer(minLength: 8)
            Text(characterDisplay)
                .monospacedDigit().frame(width: 90, alignment: .trailing)
                .foregroundStyle(app.characters > 0 || app.textReadability == .available ? Color.primary : Color.secondary)
                .help(characterHelp)
            Text(app.keystrokes.formatted())
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

struct TypeNotice: View {
    let text: String
    let symbol: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TypeTrend: View {
    let days: [DailyStatistics]

    private var displayedDays: [DailyStatistics] { Array(days.suffix(7)) }
    private var maximum: Int { max(displayedDays.map(\.characters).max() ?? 0, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(displayedDays) { day in
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(Calendar.current.isDateInToday(day.date) ? 0.8 : 0.3))
                        .frame(height: max(2, 50 * CGFloat(day.characters) / CGFloat(maximum)))
                    Text(day.date, format: .dateTime.month().day())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.date.formatted(date: .abbreviated, time: .omitted))：约 \(day.characters.formatted()) 字符")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，约 \(day.characters.formatted()) 字符")
            }
        }
        .frame(height: 78)
        .padding(.top, 5).padding(.bottom, 3)
    }
}
