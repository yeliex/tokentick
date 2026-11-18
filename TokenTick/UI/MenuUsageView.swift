import TokenTickTelemetry
import SwiftUI
import Charts
import TokenTickCore

struct MenuUsageView: View {
    let isPresented: Bool
    var openOverview: () -> Void
    @Environment(ApplicationModel.self) private var app
    @State private var error: String?
    private var now: Date { app.usageAsOf }
    @State private var hoveredDate: Date?
    private let periods: [OverviewPeriod] = [.day, .week, .month, .quarter]
    private var timezone: String { app.status?.timezone ?? TimeZone.current.identifier }
    private func request(for period: OverviewPeriod) -> OverviewUsageRequest {
        let sections: OverviewReport.Sections = period == app.visibleOverviewPeriod ? .all : period == .month ? .trend : .total
        return app.overviewUsageRequest(for: period, sections: sections)
    }

    private func report(for period: OverviewPeriod) -> OverviewReport? {
        app.overviewUsageReport(for: app.overviewUsageRequest(for: period, sections: period == .month ? .trend : .total),
                                keepPreviousCycle: true)
    }

    var body: some View {
        let reports = Dictionary(uniqueKeysWithValues: periods.compactMap { period in
            report(for: period).map { (period, $0) }
        })
        VStack(alignment: .leading, spacing: 14) {
            if !reports.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    ForEach(periods) { period in
                        let report = reports[period]
                        if period == .week {
                            let query = report?.query ?? app.overviewQuery(for: .week)
                            Button(action: app.advanceWeekRange) {
                                usageTile(total: report?.total, loading: report == nil) {
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text(app.weekRange == .lastSevenDays ? String(localized: "Last 7 days") : app.weekRange.title)
                                        if query.filters.usesCycleTurnDates, let start = query.filters.occurredFrom {
                                            let style = Date.FormatStyle(timeZone: TimeZone(identifier: timezone) ?? .current)
                                                .month(.abbreviated).day().hour().minute()
                                            Text("since \(Date(timeIntervalSince1970: start).formatted(style))").foregroundStyle(.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.triangle.2.circlepath").imageScale(.small).fixedSize()
                                    }
                                }
                            }.buttonStyle(.plain).help(String(localized: "Switch usage period"))
                        } else {
                            Button(action: openOverview) {
                                usageTile(total: report?.total, loading: report == nil) {
                                    Text(period == .day ? String(localized: "Today") : String(localized: "Last \(period.title)"))
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let month = reports[.month] {
                    chart(month)
                        .simultaneousGesture(TapGesture().onEnded { openOverview() })
                        .accessibilityAction(named: Text(String(localized: "Overview")), openOverview)
                }
            } else if error == nil {
                ProgressView(String(localized: "Loading usage…")).frame(maxWidth: .infinity, minHeight: 180)
            }
            if let error {
                Text(String(localized: "Unable to load usage")).font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
                Button(String(localized: "Retry")) { app.reloadUsage() }
            }
        }
        .task(id: isPresented ? periods.map { request(for: $0) } : []) {
            guard isPresented else { return }
            let requests = periods.map { request(for: $0) }
            error = nil
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for current in requests {
                        group.addTask { try await app.loadOverviewUsage(current) }
                    }
                    try await group.waitForAll()
                }
            } catch {
                guard !Task.isCancelled, requests == periods.map({ request(for: $0) }), !(error is CancellationError) else { return }
                AppTelemetry.capture(error, operation: "menu.query")
                self.error = error.localizedDescription
            }
        }
        .task(id: isPresented) {
            guard isPresented else { return }
            app.updateUsageTime()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                app.updateUsageTime()
            }
        }
    }

    private func usageTile(total: UsageSummary?, loading: Bool = false,
                           @ViewBuilder title: () -> some View) -> some View {
        let amount = total?.knownAmountNanoUSD
        let tokenCount = total?.totalTokens
        let apiAmount = total?.apiKnownAmountNanoUSD
        let tokens = UsageFormatting.tokens(tokenCount) + " Tokens"
        return VStack(alignment: .leading, spacing: 4) {
            title().font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if loading {
                ProgressView().controlSize(.small).frame(height: 22, alignment: .leading)
                    .accessibilityLabel(String(localized: "Loading usage…"))
            } else {
                Text(UsageFormatting.money(amount)).font(.system(size: 18, weight: .semibold))
            }
            Group {
                if loading {
                    Text(verbatim: tokens).hidden()
                } else if let api = UsageFormatting.differingAPIAmount(amount, apiAmount) {
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: "\(tokens) • \(UsageFormatting.money(api)) API").fixedSize()
                        Text(verbatim: "\(tokens) • \(UsageFormatting.compactMoney(api)) API")
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                } else { Text(verbatim: tokens) }
            }.font(.caption).foregroundStyle(.secondary)
                .help(UsageFormatting.exactTokens(tokenCount))
        }.monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
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
        // Rolling ranges include partial boundary days; average over elapsed time, including idle periods.
        let days = max(1, end.timeIntervalSince(start) / 86400)
        let tokenMean = report.trend.reduce(0) { $0 + Double($1.summary.totalTokens) } / days
        let moneyMean = report.trend.reduce(0) { $0 + Double($1.summary.knownAmountNanoUSD ?? 0) / 1_000_000_000 } / days
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Last 30 days")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "Peak")).foregroundStyle(.secondary)
                Text(UsageFormatting.tokens(report.trend.map { $0.summary.totalTokens }.max()))
                    .foregroundStyle(UsageChartColors.tokens)
                Text("/").foregroundStyle(.secondary)
                Text(report.trend.compactMap { $0.summary.knownAmountNanoUSD }.max().map {
                    "$" + (Double($0) / 1_000_000_000).formatted(.number.notation(.compactName).precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
                } ?? "—").foregroundStyle(UsageChartColors.money)
            }.font(.caption2).monospacedDigit()
            Chart {
                RuleMark(y: .value(String(localized: "Daily average tokens"), tokenMean))
                    .foregroundStyle(UsageChartColors.tokens.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .accessibilityLabel(String(localized: "Daily average tokens"))
                    .accessibilityValue(tokenMean.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))))
                if hasMoney {
                    RuleMark(y: .value(String(localized: "Daily average cost"), moneyMean / moneyMaximum * tokenMaximum))
                        .foregroundStyle(UsageChartColors.money.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .accessibilityLabel(String(localized: "Daily average cost"))
                        .accessibilityValue(moneyMean.formatted(.currency(code: "USD")))
                }
                ForEach(report.trend) { point in
                BarMark(x: .value(String(localized: "Date"), point.date, unit: .day),
                        y: .value("Tokens", Double(point.summary.totalTokens)))
                    .foregroundStyle(UsageChartColors.tokens.opacity(selected == nil || selected?.id == point.id ? 0.8 : 0.35))
                    .cornerRadius(2)
                    .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                    .accessibilityValue(UsageFormatting.exactTokens(point.summary.totalTokens) + " Tokens")
                if let amount = point.summary.knownAmountNanoUSD {
                    // Break the line at missing amounts so unknown values do not imply a continuous trend.
                    let segment = report.trend.prefix { $0.date < point.date }.filter { $0.summary.knownAmountNanoUSD == nil }.count
                    LineMark(x: .value(String(localized: "Date"), point.date, unit: .day),
                             y: .value(String(localized: "Cost"), Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum),
                             series: .value(String(localized: "Cost segment"), segment))
                        .foregroundStyle(UsageChartColors.money).lineStyle(StrokeStyle(lineWidth: 1.5))
                        .accessibilityLabel(point.date.formatted(.dateTime.month().day()))
                        .accessibilityValue(UsageFormatting.money(amount))
                    PointMark(x: .value(String(localized: "Date"), point.date, unit: .day),
                              y: .value(String(localized: "Cost"), Double(amount) / 1_000_000_000 / moneyMaximum * tokenMaximum))
                        .foregroundStyle(UsageChartColors.money).symbolSize(6)
                        .accessibilityHidden(true)
                }
                }
                if let selected {
                    RuleMark(x: .value(String(localized: "Selected date"), selected.date, unit: .day))
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
                        APIAmountNote(estimate: selected.summary.knownAmountNanoUSD, api: selected.summary.apiKnownAmountNanoUSD, font: .caption2)
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
