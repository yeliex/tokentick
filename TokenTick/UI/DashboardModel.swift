import Foundation
import Observation
import TokenTickCore

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "今天", week = "最近 7 天", month = "最近 30 天", all = "全部历史"
    var id: Self { self }
    func dates(timezone: TimeZone) -> (String?, String?) {
        guard self != .all else { return (nil, nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = Date()
        let days = self == .today ? 0 : self == .week ? 6 : 29
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        return (start.formatted(style), now.formatted(style))
    }
}

struct UsageDisplayRow: Identifiable, Sendable {
    let summary: UsageSummary
    let thread: ThreadInfo?
    var id: String { summary.group.map { "value:" + $0 } ?? "unknown" }
    var title: String { thread?.title ?? summary.group ?? "未知归属" }
}

@MainActor @Observable
final class DashboardModel {
    var rows: [UsageDisplayRow] = []
    var total: UsageSummary?
    var days: [UsageSummary] = []
    var models: [UsageSummary] = []
    var projects: [UsageSummary] = []
    var limits: [LimitWindow] = []
    var apiDays: [APIDailyBucket] = []
    var loading = false
    var error: String?
    var unknownDateTokens: Int64 = 0
    private var generation = 0

    func load(store: UsageStore, section: NavigationSection, period: UsagePeriod, timezone: String, page: Int) async {
        generation += 1
        let request = generation
        loading = true
        error = nil
        let dates = section == .data || section == .limits ? (nil, nil) : period.dates(timezone: TimeZone(identifier: timezone) ?? .gmt)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let grouping: UsageGrouping = section == .threads ? .thread : section == .projects ? .project : .day
                let query = UsageQuery(grouping: grouping, timezone: timezone, fromDate: dates.0,
                                       throughDate: dates.1, limit: 100, offset: page * 100)
                let report = try store.usageReport(query)
                let names = section == .threads ? try store.threadInfo(ids: report.rows.compactMap(\.group)) : [:]
                let rows = report.rows.map { UsageDisplayRow(summary: $0, thread: $0.group.flatMap { names[$0] }) }
                var totalQuery = query
                totalQuery.grouping = .total
                totalQuery.offset = 0
                let total = try store.usageReport(totalQuery).rows.first
                var chartQuery = totalQuery
                chartQuery.grouping = .day
                chartQuery.limit = 10_000
                let days = section == .overview || section == .daily ? try store.usageReport(chartQuery).rows : []
                chartQuery.grouping = .model
                let models = section == .overview || section == .data ? try store.usageReport(chartQuery).rows : []
                chartQuery.grouping = .project
                chartQuery.limit = 8
                let projects = section == .overview ? try store.usageReport(chartQuery).rows : []
                return (rows, total, days, models, projects, report.unknownDateTokens,
                        section == .limits ? try store.limitWindows(limit: 100) : [],
                        section == .data ? try store.apiDailyUsage(limit: 30) : [])
            }.value
            guard request == generation, !Task.isCancelled else { return }
            rows = result.0; total = result.1; days = result.2; models = result.3; projects = result.4
            unknownDateTokens = result.5; limits = result.6; apiDays = result.7
        } catch {
            if request == generation { self.error = error.localizedDescription }
        }
        if request == generation { loading = false }
    }
}
