import SwiftUI
import Charts
import TokenTickCore

struct MenuUsageView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var totals: [OverviewPeriod: UsageSummary] = [:]
    @State private var month: OverviewReport?
    @State private var error: String?
    @State private var now = Date()
    @State private var hoveredDate: Date?
    private let periods: [OverviewPeriod] = [.day, .week, .month, .quarter]
    private var timezone: String { app.status?.timezone ?? TimeZone.current.identifier }
    private struct Request: Hashable { let refresh: Int; let timezone: String; let now: Date }
    private var request: Request { Request(refresh: app.usageRefreshID, timezone: timezone, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error {
                Text("用量查询失败").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
                Button("重试") { now = Date() }
            } else if let month {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    ForEach(periods) { period in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(period == .day ? "今天" : "近 \(period.rawValue)").font(.caption).foregroundStyle(.secondary)
                            Text(UsageFormatting.money(totals[period]?.knownAmountNanoUSD)).font(.system(size: 18, weight: .semibold))
                            Text("\(UsageFormatting.tokens(totals[period]?.totalTokens)) Tokens")
                                .font(.caption).foregroundStyle(.secondary)
                                .help(UsageFormatting.exactTokens(totals[period]?.totalTokens))
                        }.monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                chart(month)
            } else {
                ProgressView("正在读取用量…").frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: request) {
            guard let store = app.store else { return }
            let current = request
            do {
                let result = try await Task.detached(priority: .utility) {
                    var totals: [OverviewPeriod: UsageSummary] = [:]
                    for period in [OverviewPeriod.day, .week, .quarter] {
                        let query = period.query(now: current.now, timezone: current.timezone)
                        totals[period] = try store.usageReport(query).rows.first
                    }
                    let month = try store.overviewReport(period: .month, now: current.now, timezone: current.timezone)
                    totals[.month] = month.total
                    return (totals, month)
                }.value
                guard !Task.isCancelled else { return }
                totals = result.0; month = result.1; error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                now = Date()
            }
        }
    }

    private func chart(_ report: OverviewReport) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let start = Date(timeIntervalSince1970: report.query.filters.occurredFrom ?? now.addingTimeInterval(-30 * 86400).timeIntervalSince1970)
        let end = Date(timeIntervalSince1970: report.query.filters.occurredBefore ?? now.timeIntervalSince1970)
        let selected = hoveredDate.flatMap { date in
            report.trend.first { calendar.isDate($0.date, inSameDayAs: date) }
        }
        let tokenMaximum = max(1, report.trend.map { Double($0.summary.totalTokens) }.max() ?? 0)
        let moneyMaximum = max(0.01, report.trend.compactMap { $0.summary.knownAmountNanoUSD.map { Double($0) / 1_000_000_000 } }.max() ?? 0)
        let hasMoney = report.trend.contains { $0.summary.knownAmountNanoUSD != nil }
        // 滚动范围包含首尾两个不完整日期，日均按实际时长计算，包含无用量的时间。
        let days = max(1, end.timeIntervalSince(start) / 86400)
        let tokenMean = report.trend.reduce(0) { $0 + Double($1.summary.totalTokens) } / days
        let moneyMean = report.trend.reduce(0) { $0 + Double($1.summary.knownAmountNanoUSD ?? 0) / 1_000_000_000 } / days
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("近 30 天").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("峰值").foregroundStyle(.secondary)
                Text(UsageFormatting.tokens(report.trend.map { $0.summary.totalTokens }.max()))
                    .foregroundStyle(UsageChartColors.tokens)
                Text("/").foregroundStyle(.secondary)
                Text(report.trend.compactMap { $0.summary.knownAmountNanoUSD }.max().map {
                    "$" + (Double($0) / 1_000_000_000).formatted(.number.notation(.compactName).precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
                } ?? "—").foregroundStyle(UsageChartColors.money)
            }.font(.caption2).monospacedDigit()
            Chart {
                RuleMark(y: .value("日均 Tokens", tokenMean))
                    .foregroundStyle(UsageChartColors.tokens.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .accessibilityLabel("日均 Tokens")
                    .accessibilityValue(tokenMean.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))))
                if hasMoney {
                    RuleMark(y: .value("日均金额", moneyMean / moneyMaximum * tokenMaximum))
                        .foregroundStyle(UsageChartColors.money.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .accessibilityLabel("日均金额")
                        .accessibilityValue(moneyMean.formatted(.currency(code: "USD")))
                }
                ForEach(report.trend) { point in
                BarMark(x: .value("日期", point.date, unit: .day),
                        y: .value("Tokens", Double(point.summary.totalTokens)))
                    .foregroundStyle(UsageChartColors.tokens.opacity(selected == nil || selected?.id == point.id ? 0.8 : 0.35))
                    .cornerRadius(2)
                    .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                    .accessibilityValue(UsageFormatting.exactTokens(point.summary.totalTokens) + " Tokens")
                if let amount = point.summary.knownAmountNanoUSD {
                    // 缺失金额处断开折线，避免把未知值呈现成连续趋势。
                    let segment = report.trend.prefix { $0.date < point.date }.filter { $0.summary.knownAmountNanoUSD == nil }.count
                    LineMark(x: .value("日期", point.date, unit: .day),
                             y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum),
                             series: .value("连续金额", segment))
                        .foregroundStyle(UsageChartColors.money).lineStyle(StrokeStyle(lineWidth: 1.5))
                        .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                        .accessibilityValue(UsageFormatting.money(amount))
                    PointMark(x: .value("日期", point.date, unit: .day),
                              y: .value("金额", Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum))
                        .foregroundStyle(UsageChartColors.money).symbolSize(6)
                        .accessibilityHidden(true)
                }
                }
                if let selected {
                    RuleMark(x: .value("选中日期", selected.date, unit: .day))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: calendar.startOfDay(for: start)...end)
            .chartYScale(domain: 0...(tokenMaximum * 1.08))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $hoveredDate)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { hoveredDate = nil; return }
                            let plot = geometry[frame]
                            hoveredDate = plot.contains(location) ? proxy.value(atX: location.x - plot.minX, as: Date.self) : nil
                        case .ended: hoveredDate = nil
                        }
                    }
                }
            }
            .frame(height: 125)
            .overlay(alignment: .topTrailing) {
                if let selected {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone)))
                            .fontWeight(.medium)
                        Text("\(UsageFormatting.tokens(selected.summary.totalTokens)) Tokens")
                            .foregroundStyle(UsageChartColors.tokens)
                        Text(UsageFormatting.money(selected.summary.knownAmountNanoUSD))
                            .foregroundStyle(UsageChartColors.money)
                    }
                    .font(.caption2).monospacedDigit()
                    .padding(7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)) }
                    .padding(4)
                    .allowsHitTesting(false)
                }
            }
            .onDisappear { hoveredDate = nil }
            HStack {
                Text(start, format: .dateTime.month().day())
                Spacer()
                Text(end, format: .dateTime.month().day())
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
    }
}
