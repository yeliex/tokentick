import Charts
import SwiftUI
import TokenTickCore

struct UsageTrendView: View {
    let days: [UsageSummary]
    var selectDay: ((String) -> Void)? = nil
    @State private var selectedDate: Date?
    @State private var showMoney = false

    // 统计日期已经按查询时区分组；这里只把日期键映射为日期轴坐标，不再次换算日边界。
    private var dateStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
    }

    private var chartCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private var plottedDays: [(date: Date, summary: UsageSummary)] {
        days.reversed().compactMap { day in
            guard let key = day.group, let date = try? dateStyle.parse(key),
                  !showMoney || day.knownAmountNanoUSD != nil else { return nil }
            return (date, day)
        }
    }

    var body: some View {
        let points = plottedDays
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
                Chart(points, id: \.date) { point in
                    let day = point.summary
                    if let date = day.group {
                        BarMark(x: .value("日期", point.date, unit: .day), y: .value(showMoney ? "USD" : "Tokens",
                            showMoney ? Double(day.knownAmountNanoUSD ?? 0) / 1_000_000_000 : Double(day.totalTokens)))
                        .foregroundStyle(.tint.opacity(0.8))
                        .cornerRadius(3)
                        .accessibilityLabel(date)
                        .accessibilityValue(showMoney ? UsageFormatting.money(day.knownAmountNanoUSD) : UsageFormatting.tokens(day.totalTokens))
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartGesture { proxy in
                    SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                }
                .onChange(of: selectedDate) {
                    if let selectedDate {
                        let key = selectedDate.formatted(dateStyle)
                        if days.contains(where: { $0.group == key && (!showMoney || $0.knownAmountNanoUSD != nil) }) {
                            selectDay?(key)
                        }
                    }
                }
                .chartXAxis {
                    if let first = points.first, let last = points.last {
                        let span = chartCalendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0
                        let labelStyle: Date.FormatStyle = span > 365 ? .dateTime.year().month().day() : .dateTime.month().day()
                        // 日汇总不生成小时刻度，跨度较大时减少日期标签。
                        AxisMarks(values: .stride(by: .day, count: max(1, (span + 3) / 4))) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: labelStyle)
                        }
                    }
                }
                .environment(\.calendar, chartCalendar)
                .environment(\.timeZone, .gmt)
                .frame(height: 200)
            }
        }
    }
}
