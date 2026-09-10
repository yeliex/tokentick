import TokenTickCore
import SwiftUI

struct OverviewView: View {
    let model: DashboardModel
    let timezone: String
    var focus: (UsageGrouping, String?) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 32) {
                    metric("Token 用量", value: UsageFormatting.tokens(model.total?.totalTokens), detail: timezone).help(UsageFormatting.exactTokens(model.total?.totalTokens))
                    metric("已知金额", value: UsageFormatting.money(model.total?.knownAmountNanoUSD), detail: "按公开价格换算 · USD")
                    metric("未定价 Tokens", value: UsageFormatting.tokens(model.total?.unpricedTokens), detail: "金额或计价依据不完整").help(UsageFormatting.exactTokens(model.total?.unpricedTokens))
                }
                UsageTrendView(days: model.days) { focus(.day, $0) }
                    .padding(22).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top, spacing: 28) {
                    contribution("模型构成", rows: model.models, grouping: .model)
                    contribution("项目贡献", rows: model.projects, grouping: .project)
                }
                if model.unknownDateTokens > 0 {
                    Label("\(UsageFormatting.tokens(model.unknownDateTokens)) tokens 无法确定日期，未绘入趋势。", systemImage: "calendar.badge.exclamationmark").help(UsageFormatting.exactTokens(model.unknownDateTokens))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("金额是 API 等值金额，不等同于订阅账单；未知金额以 — 表示。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().textSelection(.enabled)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contribution(_ title: String, rows: [UsageSummary], grouping: UsageGrouping) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            ForEach(rows, id: \.group) { row in
                Button { focus(grouping, row.group) } label: {
                    HStack {
                        Text(row.group ?? (grouping == .model ? "其他" : "未知归属"))
                            .lineLimit(1).help(row.group ?? (grouping == .model ? "其他" : "未知归属"))
                        Spacer(minLength: 12)
                        TokenText(value: row.totalTokens).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.callout).contentShape(Rectangle())
                }.buttonStyle(.plain).help("查看该范围的任务")
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
