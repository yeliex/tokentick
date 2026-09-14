import Charts
import SwiftUI
import TokenTickCore

struct OverviewChartsView: View {
    let points: [OverviewTrendPoint]
    let hourly: Bool
    let monthly: Bool
    let weekly: Bool
    let query: UsageQuery
    let timezone: String
    @State private var selectedDate: Date?
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    private var bucket: Calendar.Component { monthly ? .month : weekly ? .weekOfYear : .day }
    private var selected: OverviewTrendPoint? {
        guard let selectedDate else { return nil }
        return points.first { calendar.dateInterval(of: bucket, for: $0.date)?.contains(selectedDate) == true }
    }
    private var tokenMaximum: Double { max(1, points.map { Double($0.summary.totalTokens) }.max() ?? 0) }
    private var moneyMaximum: Double { max(0.01, points.compactMap { $0.summary.knownAmountNanoUSD.map { Double($0) / 1_000_000_000 } }.max() ?? 0) }
    private var hasMoney: Bool { points.contains { $0.summary.knownAmountNanoUSD != nil } }
    private let tokenColor = Color(red: 0.43, green: 0.56, blue: 0.69)
    private let moneyColor = Color(red: 0.83, green: 0.59, blue: 0.34)
    private var bucketCount: Double {
        max(1, Double(calendar.dateComponents([bucket], from: domain.lowerBound, to: domain.upperBound).value(for: bucket) ?? points.count))
    }
    private var tokenMean: Double { points.reduce(0) { $0 + Double($1.summary.totalTokens) } / bucketCount }
    private var moneyMean: Double { points.reduce(0) { $0 + Double($1.summary.knownAmountNanoUSD ?? 0) / 1_000_000_000 } / bucketCount }
    private var meanTitle: String { monthly ? "月均" : weekly ? "周均" : "日均" }
    private var axisValues: [Double] { (0...4).map { tokenMaximum * Double($0) / 4 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("用量趋势").font(.headline)
                Spacer()
                Label("Tokens", systemImage: "square.fill").foregroundStyle(tokenColor)
                Label("金额 · USD", systemImage: "line.diagonal").foregroundStyle(moneyColor)
            }.font(.caption)
            if points.isEmpty {
                ContentUnavailableView("暂无用量", systemImage: "chart.bar").frame(height: 240)
            } else {
                HStack {
                    if let selected {
                        Text("\(UsageFormatting.timestamp(selected.date.timeIntervalSince1970, timezone: calendar.timeZone)) · \(UsageFormatting.tokens(selected.summary.totalTokens)) Tokens · \(UsageFormatting.money(selected.summary.knownAmountNanoUSD))")
                    } else { Text("Tokens / USD").foregroundStyle(.secondary) }
                }.font(.caption).monospacedDigit().frame(height: 18)
                Chart {
                    RuleMark(y: .value("平均 Tokens", tokenMean))
                        .foregroundStyle(tokenColor.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    if hasMoney {
                        RuleMark(y: .value("平均金额", moneyMean / moneyMaximum * tokenMaximum))
                            .foregroundStyle(moneyColor.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }
                    ForEach(points) { point in
                        BarMark(x: .value("时间", point.date, unit: bucket), y: .value("Tokens", Double(point.summary.totalTokens)))
                            .foregroundStyle(tokenColor.opacity(selected?.id == point.id ? 0.95 : selected == nil ? 0.48 : 0.2)).cornerRadius(3)
                            .accessibilityLabel(point.date.formatted())
                            .accessibilityValue(UsageFormatting.exactTokens(point.summary.totalTokens) + " Tokens")
                        if let amount = point.summary.knownAmountNanoUSD {
                            LineMark(x: .value("时间", point.date, unit: bucket),
                                y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum),
                                series: .value("连续金额", moneySegment(at: point.date)))
                                .foregroundStyle(moneyColor).lineStyle(StrokeStyle(lineWidth: 2))
                                .accessibilityLabel(point.date.formatted())
                                .accessibilityValue(UsageFormatting.money(amount))
                            if points.count == 1 {
                                PointMark(x: .value("时间", point.date, unit: bucket),
                                    y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum))
                                    .foregroundStyle(moneyColor)
                            }
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("选中时间", selected.date, unit: bucket))
                            .foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3]))
                    }
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: 0...(tokenMaximum * 1.08))
                .chartXSelection(value: $selectedDate)
                .chartYAxis {
                    AxisMarks(position: .leading, values: axisValues) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(compact(number)) }
                        }
                    }
                    if hasMoney {
                        AxisMarks(position: .trailing, values: axisValues) { value in
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("$" + compact(number / tokenMaximum * moneyMaximum)).foregroundStyle(moneyColor)
                                }
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: hourly ? .dateTime.hour().minute() : monthly ? .dateTime.year().month() : .dateTime.month().day())
                } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let plot = proxy.plotFrame {
                                    selectedDate = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                                }
                            case .ended: selectedDate = nil
                            }
                        }
                    }
                }.frame(height: 260)
                .accessibilityRepresentation {
                    VStack {
                        ForEach(points) { point in
                            Text("\(UsageFormatting.timestamp(point.date.timeIntervalSince1970, timezone: calendar.timeZone))：\(UsageFormatting.exactTokens(point.summary.totalTokens)) Tokens，\(UsageFormatting.money(point.summary.knownAmountNanoUSD))")
                        }
                    }.accessibilityElement(children: .contain)
                }
                HStack(spacing: 16) {
                    Text("\(meanTitle) \(compact(tokenMean)) Tokens").foregroundStyle(tokenColor)
                    if hasMoney { Text("\(meanTitle) $\(compact(moneyMean))").foregroundStyle(moneyColor) }
                    Spacer()
                }.font(.caption).help("按所选范围内的日／周／月计算，包含无用量的时间段；费用只汇总已知金额。")
            }
        }.usageSurface().environment(\.timeZone, calendar.timeZone).environment(\.calendar, calendar)
    }
    // 缺失金额打断折线，避免跨过未知值产生连续用量的错觉。
    private func moneySegment(at date: Date) -> Int {
        points.prefix { $0.date < date }.filter { $0.summary.knownAmountNanoUSD == nil }.count
    }
    private func compact(_ number: Double) -> String {
        number.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
    }
    private var domain: ClosedRange<Date> {
        if let from = query.filters.occurredFrom, let before = query.filters.occurredBefore {
            let start = calendar.dateInterval(of: bucket, for: Date(timeIntervalSince1970: from))?.start ?? Date(timeIntervalSince1970: from)
            let end = calendar.dateInterval(of: bucket, for: Date(timeIntervalSince1970: before - 0.001))?.end ?? Date(timeIntervalSince1970: before)
            return start...end
        }
        let first = points.first?.date ?? .now
        let last = points.last?.date ?? first
        if monthly, let start = calendar.dateInterval(of: .month, for: first)?.start,
           let end = calendar.dateInterval(of: .month, for: last)?.end { return start...end }
        let padding: TimeInterval = hourly ? 1800 : 43200
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }
}

struct ModelUsageView: View {
    let models: [UsageSummary]
    @State private var money = false
    private let colors: [Color] = [
        Color(red: 0.43, green: 0.60, blue: 0.66), Color(red: 0.55, green: 0.53, blue: 0.74),
        Color(red: 0.80, green: 0.65, blue: 0.42), Color(red: 0.58, green: 0.70, blue: 0.57),
        Color(red: 0.75, green: 0.49, blue: 0.52), Color(red: 0.43, green: 0.53, blue: 0.73),
        Color(red: 0.72, green: 0.57, blue: 0.72), Color(red: 0.58, green: 0.65, blue: 0.69),
        Color(red: 0.74, green: 0.73, blue: 0.49), Color(red: 0.57, green: 0.72, blue: 0.68),
        Color(red: 0.75, green: 0.60, blue: 0.53)
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("模型使用").font(.headline)
                Spacer()
                Picker("模型构成指标", selection: $money) { Text("Tokens").tag(false); Text("金额").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            HStack(alignment: .center, spacing: 28) {
                Chart(Array(models.enumerated()), id: \.offset) { index, model in
                    let value = money ? Double(model.knownAmountNanoUSD ?? 0) : Double(model.totalTokens)
                    if value > 0 {
                        SectorMark(angle: .value(money ? "金额" : "Tokens", value), innerRadius: .ratio(0.6), angularInset: 2)
                            .foregroundStyle(colors[index % colors.count])
                            .accessibilityLabel(model.group ?? "其他")
                            .accessibilityValue(money ? UsageFormatting.money(model.knownAmountNanoUSD) : UsageFormatting.exactTokens(model.totalTokens))
                    }
                }.frame(width: 170, height: 170)
                VStack(spacing: 5) {
                    HStack {
                        Text("模型"); Spacer(); Text("金额 · USD").frame(width: 100, alignment: .trailing)
                        Text("Tokens").frame(width: 95, alignment: .trailing)
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                        HStack(spacing: 10) {
                            Circle().fill(colors[index % colors.count]).frame(width: 7, height: 7)
                            Text(model.group ?? "其他").lineLimit(1).help(model.group ?? "其他")
                            Spacer()
                            Text(UsageFormatting.money(model.knownAmountNanoUSD)).frame(width: 100, alignment: .trailing)
                            TokenText(value: model.totalTokens).frame(width: 95, alignment: .trailing)
                        }.monospacedDigit()
                        Divider()
                    }
                }.frame(maxWidth: 440)
            }.frame(maxWidth: .infinity)

        }.usageSurface()
    }
}
