import Foundation
import Observation
import TokenTickCore

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "1天", week = "7天", month = "30天", quarter = "90天", year = "1年", all = "所有", custom = "自定义"
    var id: Self { self }
    func dates(timezone: TimeZone) -> (String?, String?) {
        guard self != .all && self != .custom else { return (nil, nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = Date()
        let days: Int
        switch self {
        case .today: days = 0
        case .week: days = 6
        case .month: days = 29
        case .quarter: days = 89
        case .year: days = 364
        case .all, .custom: return (nil, nil)
        }
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        return (start.formatted(style), now.formatted(style))
    }
}

struct UsageDisplayRow: Identifiable, Sendable, Equatable {
    let summary: UsageSummary
    let thread: ThreadInfo?
    let grouping: UsageGrouping
    var id: String { summary.group.map { "value:" + $0 } ?? "unknown" }
    var title: String { grouping == .project ? UsageFormatting.project(summary.group) : thread?.title ?? summary.group ?? "未知归属" }
}

@MainActor @Observable
final class DashboardModel {
    var rows: [UsageDisplayRow] = []
    var total: UsageSummary?
    var dataFromDate: String?
    var dataThroughDate: String?
    var days: [UsageSummary] = []
    var models: [UsageSummary] = []
    var projects: [UsageSummary] = []
    var loadedQuery: UsageQuery?
    var loadedSection: NavigationSection?
    var hasMore = false
    var totalGroups = 0
    var loading = false
    var error: String?
    var unknownDateTokens: Int64 = 0
    private var generation = 0

    func load(store: UsageStore, section: NavigationSection, query: UsageQuery) async {
        generation += 1
        let request = generation
        loading = loadedQuery != query || loadedSection != section
        error = nil
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let report = try store.usageReport(query)
                try Task.checkCancellation()
                let names = section == .threads ? try store.threadInfo(ids: report.rows.compactMap(\.group)) : [:]
                let rows = report.rows.map { UsageDisplayRow(summary: $0, thread: $0.group.flatMap { names[$0] }, grouping: query.grouping) }
                var totalQuery = query
                totalQuery.grouping = .total
                totalQuery.offset = 0
                try Task.checkCancellation()
                let totalReport = try store.usageReport(totalQuery)
                let total = totalReport.rows.first
                var chartQuery = totalQuery
                chartQuery.grouping = .day
                chartQuery.limit = 10_000
                chartQuery.sort = .automatic
                let days = section == .overview ? try store.usageReport(chartQuery).rows : []
                chartQuery.grouping = .model
                chartQuery.sort = query.sort
                let models = section == .overview || section == .data ? try store.usageReport(chartQuery).rows : []
                chartQuery.grouping = .project
                chartQuery.limit = 8
                let projects = section == .overview ? try store.usageReport(chartQuery).rows : []
                return (rows, total, days, models, projects, report.unknownDateTokens,
                        report.hasMore, report.totalGroups, totalReport.dataFromDate, totalReport.dataThroughDate)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            if rows != result.0 { rows = result.0 }
            if total != result.1 { total = result.1 }
            if days != result.2 { days = result.2 }
            if models != result.3 { models = result.3 }
            if projects != result.4 { projects = result.4 }
            dataFromDate = result.8; dataThroughDate = result.9
            loadedQuery = query; loadedSection = section
            unknownDateTokens = result.5; hasMore = result.6; totalGroups = result.7
        } catch {
            if request == generation && !Task.isCancelled {
                self.error = error.localizedDescription
                loadedQuery = query; loadedSection = section
                dataFromDate = nil; dataThroughDate = nil
                rows = []; total = nil; days = []; models = []; projects = []; hasMore = false; totalGroups = 0
            }
        }
        if request == generation { loading = false }
    }
}
