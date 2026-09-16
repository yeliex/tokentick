import TokenTickTelemetry
import Foundation
import Observation
import TokenTickCore

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, quarter, year, all, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .quarter: String(localized: "90 days")
        case .year: String(localized: "1 year")
        case .all: String(localized: "Lifetime")
        case .custom: String(localized: "Custom")
        }
    }

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
    var title: String { grouping == .project ? UsageFormatting.project(summary.group) : thread?.title ?? summary.group ?? String(localized: "Unattributed") }
}

@MainActor @Observable
final class DashboardModel {
    var rows: [UsageDisplayRow] = []
    var total: UsageSummary?
    var dataFromDate: String?
    var dataThroughDate: String?
    var loadedQuery: UsageQuery?
    var hasMore = false
    var totalGroups = 0
    var error: String?
    private var generation = 0

    func load(store: UsageStore, query: UsageQuery) async {
        generation += 1
        let request = generation
        error = nil
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let report = try store.usageReport(query)
                try Task.checkCancellation()
                let names = query.grouping == .thread ? try store.threadInfo(ids: report.rows.compactMap(\.group)) : [:]
                let rows = report.rows.map { UsageDisplayRow(summary: $0, thread: $0.group.flatMap { names[$0] }, grouping: query.grouping) }
                var totalQuery = query
                totalQuery.grouping = .total
                totalQuery.offset = 0
                try Task.checkCancellation()
                let totalReport = try store.usageReport(totalQuery)
                let total = totalReport.rows.first
                return (rows, total, report.hasMore, report.totalGroups,
                        totalReport.dataFromDate, totalReport.dataThroughDate)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            if rows != result.0 { rows = result.0 }
            if total != result.1 { total = result.1 }
            hasMore = result.2; totalGroups = result.3
            dataFromDate = result.4; dataThroughDate = result.5
            loadedQuery = query
        } catch {
            if request == generation && !Task.isCancelled {
                AppTelemetry.capture(error, operation: "usage.query")
                self.error = error.localizedDescription
                loadedQuery = query
                dataFromDate = nil; dataThroughDate = nil
                rows = []; total = nil; hasMore = false; totalGroups = 0
            }
        }
    }
}
