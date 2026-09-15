import Charts
import SwiftUI
import TokenTickCore

enum UsageChartColors {
    static let tokens = Color.accentColor
    static let money = Color(red: 0.83, green: 0.59, blue: 0.34)
}

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
                Label("Tokens", systemImage: "square.fill").foregroundStyle(UsageChartColors.tokens)
                Label("金额", systemImage: "line.diagonal").foregroundStyle(UsageChartColors.money)
            }.font(.caption)
            if points.isEmpty {
                ContentUnavailableView("暂无用量", systemImage: "chart.bar").frame(height: 240)
            } else {
                HStack {
                    if let selected {
                        Text("\(UsageFormatting.timestamp(selected.date.timeIntervalSince1970, timezone: calendar.timeZone)) · \(UsageFormatting.tokens(selected.summary.totalTokens)) Tokens · \(UsageFormatting.money(selected.summary.knownAmountNanoUSD))")
                    } else { Text("Tokens / $").foregroundStyle(.secondary) }
                }.font(.caption).monospacedDigit().frame(height: 18)
                Chart {
                    RuleMark(y: .value("平均 Tokens", tokenMean))
                        .foregroundStyle(UsageChartColors.tokens.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    if hasMoney {
                        RuleMark(y: .value("平均金额", moneyMean / moneyMaximum * tokenMaximum))
                            .foregroundStyle(UsageChartColors.money.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }
                    ForEach(points) { point in
                        BarMark(x: .value("时间", point.date, unit: bucket), y: .value("Tokens", Double(point.summary.totalTokens)))
                            .foregroundStyle(UsageChartColors.tokens.opacity(selected?.id == point.id ? 1 : selected == nil ? 0.8 : 0.45)).cornerRadius(3)
                            .accessibilityLabel(point.date.formatted())
                            .accessibilityValue(UsageFormatting.exactTokens(point.summary.totalTokens) + " Tokens")
                        if let amount = point.summary.knownAmountNanoUSD {
                            LineMark(x: .value("时间", point.date, unit: bucket),
                                y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum),
                                series: .value("连续金额", moneySegment(at: point.date)))
                                .foregroundStyle(UsageChartColors.money).lineStyle(StrokeStyle(lineWidth: 2))
                                .accessibilityLabel(point.date.formatted())
                                .accessibilityValue(UsageFormatting.money(amount))
                            if points.count == 1 {
                                PointMark(x: .value("时间", point.date, unit: bucket),
                                    y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum))
                                    .foregroundStyle(UsageChartColors.money)
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
                            if let number = value.as(Double.self) { Text(compact(number)).foregroundStyle(UsageChartColors.tokens) }
                        }
                    }
                    if hasMoney {
                        AxisMarks(position: .trailing, values: axisValues) { value in
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("$" + compact(number / tokenMaximum * moneyMaximum)).foregroundStyle(UsageChartColors.money)
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
                    Text("\(meanTitle) \(compact(tokenMean)) Tokens").foregroundStyle(UsageChartColors.tokens)
                    if hasMoney { Text("\(meanTitle) $\(compact(moneyMean))").foregroundStyle(UsageChartColors.money) }
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
    let modes: [OverviewUsageShare]
    let efforts: [OverviewUsageShare]
    @State private var money = false
    @State private var hovered: SliceID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct SliceID: Equatable { let ring: Int; let name: String }
    private let radii: [CGFloat] = [101, 73, 45]
    private var modelShares: [OverviewUsageShare] {
        (models.filter { $0.group != nil } + models.filter { $0.group == nil })
            .map { OverviewUsageShare(name: $0.group ?? "未知", tokens: $0.totalTokens, amount: $0.knownAmountNanoUSD) }
    }
    private var modeShares: [OverviewUsageShare] { modes.filter { $0.name != "未知" } + modes.filter { $0.name == "未知" } }
    private var effortShares: [OverviewUsageShare] { efforts.filter { $0.name != "未知" } + efforts.filter { $0.name == "未知" } }
    private let colors: [Color] = [
        Color(red: 0.43, green: 0.60, blue: 0.66), Color(red: 0.55, green: 0.53, blue: 0.74),
        Color(red: 0.80, green: 0.65, blue: 0.42), Color(red: 0.58, green: 0.70, blue: 0.57),
        Color(red: 0.75, green: 0.49, blue: 0.52), Color(red: 0.43, green: 0.53, blue: 0.73),
        Color(red: 0.72, green: 0.57, blue: 0.72), Color(red: 0.58, green: 0.65, blue: 0.69)
    ]
    private func value(_ item: OverviewUsageShare) -> Double { Double(money ? item.amount ?? 0 : item.tokens) }
    private func color(_ item: OverviewUsageShare, index: Int, ring: Int) -> Color {
        item.name == "未知" ? .secondary.opacity(0.45) : colors[(index + ring * 2) % colors.count]
    }
    private func effortTitle(_ name: String) -> String {
        switch name {
        case "none": "无推理"
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "极高"
        case "max": "最高"
        case "ultra": "超高"
        default: name
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("模型使用").font(.headline)
                Spacer()
                Picker("统计指标", selection: $money) { Text("Tokens").tag(false); Text("金额").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    rings
                    shareColumns.frame(minWidth: 530)
                }
                VStack(spacing: 20) {
                    rings
                    shareColumns
                }
            }
        }.usageSurface()
            .onChange(of: money) { hovered = nil }
    }
    private var shareColumns: some View {
        HStack(alignment: .top, spacing: 16) {
            shareList(modelShares, title: "模型", ring: 0)
            shareList(modeShares, title: "使用模式", ring: 1)
            shareList(effortShares, title: "推理深度", ring: 2)
        }
    }
    private var rings: some View {
        ZStack {
            ring(modelShares, index: 0)
            ring(modeShares, index: 1)
            ring(effortShares, index: 2)
        }.frame(width: 220, height: 220)
            .overlay {
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let dx = point.x - 110, dy = point.y - 110
                        let distance = hypot(dx, dy)
                        guard let index = radii.indices.first(where: { abs(distance - radii[$0]) <= 12 }) else {
                            hovered = nil; return
                        }
                        let angle = (atan2(dy, dx) + .pi / 2 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
                        let items = [modelShares, modeShares, effortShares][index]
                        let total = items.reduce(0) { $0 + value($1) }
                        var end = 0.0
                        hovered = nil
                        for item in items where value(item) > 0 {
                            end += value(item) / total
                            if angle < end { hovered = SliceID(ring: index, name: item.name); break }
                        }
                    case .ended: hovered = nil
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
    private func ring(_ items: [OverviewUsageShare], index: Int) -> some View {
        let total = items.reduce(0) { $0 + value($1) }
        return ZStack {
            if total == 0 { Circle().stroke(.quaternary, lineWidth: 18) }
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if value(item) > 0 {
                    let start = items.prefix(offset).reduce(0) { $0 + value($1) } / total
                    let end = start + value(item) / total
                    let gap = items.filter { value($0) > 0 }.count == 1 ? 0 : min(0.002, (end - start) / 4)
                    let selected = hovered == SliceID(ring: index, name: item.name)
                    Circle().trim(from: start + gap, to: end - gap)
                        .stroke(color(item, index: offset, ring: index), style: StrokeStyle(lineWidth: selected ? 24 : 18, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(selected ? 1.025 : 1)
                        .opacity(hovered == nil || selected ? 1 : 0.45)
                        .accessibilityLabel(index == 2 ? effortTitle(item.name) : item.name)
                        .accessibilityValue(money ? UsageFormatting.money(item.amount) : UsageFormatting.exactTokens(item.tokens))
                }
            }
        }.frame(width: radii[index] * 2, height: radii[index] * 2)
    }
    private func shareList(_ items: [OverviewUsageShare], title: String, ring: Int) -> some View {
        let total = items.reduce(0) { $0 + value($1) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.medium).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 3)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = hovered == SliceID(ring: ring, name: item.name)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(color(item, index: index, ring: ring)).frame(width: 6, height: 6)
                        Text(ring == 2 ? effortTitle(item.name) : item.name).lineLimit(1).help(item.name)
                        Spacer(minLength: 2)
                        Text(total > 0 ? (value(item) / total).formatted(.percent.precision(.fractionLength(0...1))) : "—")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Text(UsageFormatting.money(item.amount))
                        Text("·")
                        Text(UsageFormatting.tokens(item.tokens) + " Tokens").help(UsageFormatting.exactTokens(item.tokens))
                    }.foregroundStyle(.secondary).lineLimit(1).padding(.leading, 12)
                }.monospacedDigit().padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? color(item, index: index, ring: ring).opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = SliceID(ring: ring, name: item.name) }
                        else if selected { hovered = nil }
                    }
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
