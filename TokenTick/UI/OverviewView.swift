import TokenTickCore
import SwiftUI

struct OverviewView: View {
    let model: DashboardModel
    let timezone: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 32) {
                    metric("Token 用量", value: UsageFormatting.tokens(model.total?.totalTokens), detail: timezone)
                    metric("已知金额", value: UsageFormatting.money(model.total?.knownAmountNanoUSD), detail: "按公开价格换算 · USD")
                    metric("未定价 Tokens", value: UsageFormatting.tokens(model.total?.unpricedTokens), detail: "金额或计价依据不完整")
                }
                UsageTrendView(days: model.days)
                    .padding(22).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top, spacing: 28) {
                    contribution("模型构成", rows: model.models)
                    contribution("项目贡献", rows: model.projects)
                }
                if model.unknownDateTokens > 0 {
                    Label("\(model.unknownDateTokens.formatted()) tokens 无法确定日期，未绘入趋势。", systemImage: "calendar.badge.exclamationmark")
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

    private func contribution(_ title: String, rows: [UsageSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            ForEach(rows, id: \.group) { row in
                HStack {
                    Text(row.group ?? "未知归属").lineLimit(1).help(row.group ?? "未知归属")
                    Spacer(minLength: 12)
                    Text(UsageFormatting.tokens(row.totalTokens)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
                Divider()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
