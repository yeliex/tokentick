import SwiftUI
import TokenTickCore

struct UsageTableView: View {
    let rows: [UsageDisplayRow]
    let isThread: Bool
    let hasMore: Bool
    @Binding var selection: String?
    @Binding var page: Int

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn(isThread ? "任务" : "名称") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).lineLimit(1)
                        if isThread { Text(UsageFormatting.project(row.thread?.projectName)).font(.caption).foregroundStyle(.secondary) }
                    }.help(row.title)
                }.width(min: 180, ideal: 340)
                TableColumn("Tokens") { row in TokenText(value: row.summary.totalTokens).monospacedDigit() }
                    .width(min: 105, ideal: 125)
                TableColumn("已知金额") { row in Text(UsageFormatting.money(row.summary.knownAmountNanoUSD)).monospacedDigit() }
                    .width(min: 90, ideal: 110)
                TableColumn("未定价 Tokens") { row in TokenText(value: row.summary.unpricedTokens).foregroundStyle(.secondary).monospacedDigit() }
                    .width(min: 105, ideal: 130)
            }
            Divider()
            HStack {
                Text("第 \(page + 1) 页 · 每页 100 条").foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { selection = nil; page -= 1 }.disabled(page == 0)
                Button("下一页") { selection = nil; page += 1 }.disabled(!hasMore)
            }.padding(12)
        }
    }
}
