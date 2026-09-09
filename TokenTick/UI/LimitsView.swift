import SwiftUI
import TokenTickCore

struct LimitsView: View {
    let windows: [LimitWindow]
    var body: some View {
        if windows.isEmpty {
            ContentUnavailableView("暂无额度观测", systemImage: "gauge.with.dots.needle.33percent",
                                   description: Text("同步服务端后记录当前窗口，应用关闭期间的历史不会补造。"))
        } else {
            List {
                Text("百分比为最后观测值；开始时间由窗口时长推算，不代表已确认的完整周期。")
                    .font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(window.limitID).fontWeight(.medium)
                            Text(window.kind == "primary" ? "主窗口" : "次窗口").foregroundStyle(.secondary)
                            Spacer()
                            Text("已使用 \(window.lastUsedPercent.formatted())%").monospacedDigit()
                        }
                        ProgressView(value: min(max(window.lastUsedPercent, 0), 100), total: 100)
                        HStack {
                            Text("重置：\(UsageFormatting.timestamp(Double(window.resetsAt)))")
                            Spacer()
                            Text("已采集：\(UsageFormatting.tokens(window.tokens)) tokens")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text("最后观测：\(UsageFormatting.timestamp(window.lastObservedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("账号 \(window.accountID.prefix(8))…").font(.caption).foregroundStyle(.secondary).help(window.accountID)
                    }.padding(.vertical, 10)
                }
            }
        }
    }
}
