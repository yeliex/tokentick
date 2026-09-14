import SwiftUI
import TokenTickCore

struct UsageTableView: View {
    let rows: [UsageDisplayRow]
    let isThread: Bool
    let hasMore: Bool
    let totalGroups: Int
    @Binding var selection: String?
    @Binding var page: Int
    var openRow: (UsageDisplayRow) -> Void
    var showDetails: (UsageDisplayRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn(isThread ? "任务" : "名称") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Button { openRow(row) } label: {
                            HStack {
                                Text(row.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if isThread { Text(UsageFormatting.project(row.thread?.projectName)).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 7).help(row.title)
                }.width(min: 180, ideal: 340)
                TableColumn("Tokens") { row in TokenText(value: row.summary.totalTokens).monospacedDigit() }
                    .width(min: 105, ideal: 125)
                TableColumn("预估费用") { row in Text(UsageFormatting.money(row.summary.knownAmountNanoUSD)).monospacedDigit()
                    .help(row.summary.unpricedTokens > 0 ? "部分用量未定价" : "按公开 API 价格估算") }
                    .width(min: 90, ideal: 110)
                TableColumn("请求次数") { row in Text(row.summary.records.formatted()).monospacedDigit() }
                    .width(min: 75, ideal: 90)

                TableColumn("详情") { row in
                    Button("详情") { showDetails(row) }.buttonStyle(.borderless)
                }.width(50)
            }.tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("第 \(totalGroups == 0 ? 0 : page + 1) / \((totalGroups + 99) / 100) 页 · 共 \(totalGroups) 条").foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { selection = nil; page -= 1 }.disabled(page == 0)
                Button("下一页") { selection = nil; page += 1 }.disabled(!hasMore)
            }.padding(12)
        }
    }
}
