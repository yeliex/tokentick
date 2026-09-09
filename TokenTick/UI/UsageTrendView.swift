import Charts
import SwiftUI
import TokenTickCore

struct UsageTrendView: View {
    let days: [UsageSummary]
    @State private var showMoney = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("每日趋势").font(.headline)
                Spacer()
                Picker("统计指标", selection: $showMoney) {
                    Text("Tokens").tag(false)
                    Text("已知金额").tag(true)
                }.pickerStyle(.segmented).frame(width: 180)
            }
            if showMoney && !days.contains(where: { $0.knownAmountNanoUSD != nil }) {
                ContentUnavailableView("暂无可计算金额", systemImage: "dollarsign.circle",
                    description: Text("需要对应日期的模型价格与完整计价依据。"))
                    .frame(height: 180)
            } else {
                Chart(days.reversed(), id: \.group) { day in
                    if let date = day.group, !showMoney || day.knownAmountNanoUSD != nil {
                        BarMark(x: .value("日期", date), y: .value(showMoney ? "USD" : "Tokens",
                            showMoney ? Double(day.knownAmountNanoUSD ?? 0) / 1_000_000_000 : Double(day.totalTokens)))
                        .foregroundStyle(.tint.opacity(0.8))
                        .cornerRadius(3)
                        .accessibilityLabel(date)
                        .accessibilityValue(showMoney ? UsageFormatting.money(day.knownAmountNanoUSD) : UsageFormatting.tokens(day.totalTokens))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 200)
            }
        }
    }
}
