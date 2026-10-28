import TokenTickTelemetry
import SwiftUI
import Observation
import TokenTickCore

@MainActor @Observable
final class LimitsPageState {
    var period = UsagePeriod.all
    var customFrom = Date()
    var customThrough = Date()
    var account = UsageAccountScope.all
    var accounts: [String] = []
    var page = 0
    var selectedWindow: String?
    var windows: [WeeklyLimitWindow] = []
    var hasMore = false
    var loadedQuery: LimitQuery?
    var error: String?
    var retry = 0
    var currentUsage: WeeklyLimitWindow?
    var currentUsageError: String?
    var currentUsageLoading = false
}

struct LimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @Bindable var state: LimitsPageState
    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var criteria: LimitQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = state.period == .custom
            ? (state.customFrom.formatted(style), state.customThrough.formatted(style))
            : state.period.dates(timezone: timezone)
        return LimitQuery(timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1,
                          account: state.account, limitID: "codex")
    }
    private var query: LimitQuery { var value = criteria; value.offset = state.page * 100; return value }
    private struct Request: Hashable { let query: LimitQuery; let refresh: Int; let retry: Int }
    private var request: Request { Request(query: query, refresh: app.refreshID, retry: state.retry) }
    private var currentWindow: CurrentLimitWindow? {
        guard let snapshot = app.currentLimits, let account = snapshot.accountID,
              state.account == .all || state.account == .account(account) else { return nil }
        return snapshot.windows.first { $0.limitID == "codex" && $0.durationMinutes == 10_080 && $0.resetsAt != nil }
    }
    private var currentSelection: String? {
        currentWindow.flatMap { _ in app.currentLimits?.accountID.map { "current:" + $0 } }
    }
    private struct CurrentRequest: Hashable { let account: String?; let reset: Int64?; let refresh: Int; let retry: Int }
    private var currentRequest: CurrentRequest {
        CurrentRequest(account: currentWindow == nil ? nil : app.currentLimits?.accountID,
                       reset: currentWindow?.resetsAt, refresh: app.refreshID, retry: state.retry)
    }
    private var currentUsage: WeeklyLimitWindow? {
        guard let usage = state.currentUsage, usage.id == currentSelection,
              usage.scheduledResetAt == currentWindow?.resetsAt else { return nil }
        return usage
    }
    private var historyWindows: [WeeklyLimitWindow] {
        guard state.loadedQuery == query else { return [] }
        return state.windows.filter { window in
            guard let reset = currentWindow?.resetsAt else { return true }
            return window.accountID != app.currentLimits?.accountID || abs(window.scheduledResetAt - reset) > 60
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                UsageDateFilter(period: $state.period, from: $state.customFrom, through: $state.customThrough,
                                periods: [.month, .quarter, .year, .all], timezone: timezone)
                AccountScopeControl(account: $state.account, accounts: state.accounts,
                                    currentAccount: app.currentLimits?.accountID)
            }
            if let error = state.error, currentWindow == nil {
                ContentUnavailableView {
                    Label(String(localized: "Unable to load limit history"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button(String(localized: "Retry")) { state.retry += 1 } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.loadedQuery != query && currentWindow == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if historyWindows.isEmpty && currentWindow == nil {
                ContentUnavailableView {
                    Label(String(localized: "No limit history yet"), systemImage: "calendar")
                } actions: {
                    if state.period != .all || state.account != .all {
                        Button(String(localized: "Show all records")) { state.period = .all; state.account = .all }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 12) {
                        List(selection: $state.selectedWindow) {
                            if let window = currentWindow, let selection = currentSelection {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    VStack(alignment: .leading, spacing: 9) {
                                        HStack(spacing: 6) {
                                            Text(String(localized: "Current cycle"))
                                            if let usage = currentUsage {
                                                Text("•").foregroundStyle(.tertiary)
                                                Text(shortDate(Double(usage.startedAtInferred)))
                                            }
                                        }.font(.callout.weight(.medium))
                                        HStack {
                                            if let reset = window.resetsAt {
                                                Text(Double(reset) <= context.date.timeIntervalSince1970
                                                     ? String(localized: "Waiting for limit reset")
                                                     : String(localized: "Expected reset: \(shortDate(Double(reset)))"))
                                            }
                                            Spacer()
                                            Text(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                                                .monospacedDigit()
                                        }.font(.caption).foregroundStyle(.secondary)
                                        ProgressView(value: min(100, max(0, window.usedPercent)), total: 100).tint(.primary).opacity(0.65)
                                    }.padding(.vertical, 9)
                                }.tag(selection)
                            }
                            if let error = state.error {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button(String(localized: "Retry")) { state.retry += 1 }
                            } else if state.loadedQuery != query {
                                ProgressView()
                            }
                            ForEach(historyWindows) { window in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(shortDate(Double(window.startedAtInferred)))
                                        Text("—").foregroundStyle(.tertiary)
                                        Text(shortDate(Double(window.endsAt)))
                                    }.font(.callout.weight(.medium))
                                    if Set(state.accounts + [app.currentLimits?.accountID].compactMap { $0 }).count > 1 {
                                        Text(window.observedAccountIDs.map { id in
                                            id == app.currentLimits?.accountID ? String(localized: "Current account") : String(localized: "Account · ") + String(id.suffix(8))
                                        }.joined(separator: "、"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    HStack {
                                        Text(window.endsAt > Date().timeIntervalSince1970 ? String(localized: "Active") : String(localized: "Ended"))
                                        if window.resetKind == "early" { Text(String(localized: "· Early reset")) }
                                        Spacer()
                                        Text(window.lastUsedPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                                            .monospacedDigit()
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if let percent = window.lastUsedPercent {
                                        ProgressView(value: min(100, max(0, percent)), total: 100).tint(.primary).opacity(0.65)
                                    } else {
                                        Text(String(localized: "Inconsistent usage records")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 9).tag(window.id)
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                        if state.page > 0 || state.hasMore {
                            HStack {
                                Button { state.page -= 1 } label: { Image(systemName: "chevron.left") }
                                    .disabled(state.page == 0).help(String(localized: "Previous"))
                                Spacer()
                                Text(String(localized: "Page \(state.page + 1)")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { state.page += 1 } label: { Image(systemName: "chevron.right") }
                                    .disabled(!state.hasMore).help(String(localized: "Next"))
                            }.padding(12)
                        }
                    }.frame(minWidth: 230, idealWidth: 270, maxWidth: 310, maxHeight: .infinity)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
                    ScrollView {
                        if let window = currentWindow, state.selectedWindow == currentSelection {
                            WeeklyCycleDetail(current: window, usage: currentUsage, timezone: timezone).padding(.vertical, 8)
                            if state.currentUsageLoading && currentUsage == nil { ProgressView() }
                            if let error = state.currentUsageError {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button(String(localized: "Retry")) { state.retry += 1 }
                            }
                        } else if let window = historyWindows.first(where: { $0.id == state.selectedWindow }) {
                            WeeklyCycleDetail(window: window, timezone: timezone).padding(.vertical, 8)
                        } else {
                            ContentUnavailableView(String(localized: "Select a cycle"), systemImage: "calendar")
                        }
                    }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(.horizontal, 24)
        .padding(.bottom, 24)
        .task(id: request) {
            guard let store = app.store else { return }
            let current = query
            do {
                let result = try await Task.detached(priority: .userInitiated) { try store.weeklyLimitHistory(current) }.value
                guard !Task.isCancelled, current == query else { return }
                if state.windows != result.rows { state.windows = result.rows }
                state.hasMore = result.hasMore
                if state.selectedWindow == nil || (state.selectedWindow != currentSelection && !state.windows.contains(where: { $0.id == state.selectedWindow })) {
                    state.selectedWindow = currentSelection ?? state.windows.first?.id
                }
                state.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                AppTelemetry.capture(error, operation: "limits.query")
                state.error = error.localizedDescription
            }
            state.loadedQuery = current
        }
        .task(id: currentRequest) {
            let current = currentRequest
            guard let store = app.store, let account = current.account, let reset = current.reset else {
                state.currentUsage = nil
                state.currentUsageError = nil
                state.currentUsageLoading = false
                return
            }
            state.currentUsageLoading = true
            state.currentUsageError = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try store.currentWeeklyLimitUsage(accountID: account, resetsAt: reset)
                }.value
                guard !Task.isCancelled, current == currentRequest else { return }
                if state.currentUsage != result { state.currentUsage = result }
                state.currentUsageError = nil
                state.currentUsageLoading = false
            } catch {
                guard !Task.isCancelled, current == currentRequest else { return }
                AppTelemetry.capture(error, operation: "limits.current")
                state.currentUsageError = error.localizedDescription
                state.currentUsageLoading = false
            }
        }
        .task(id: app.refreshID) {
            guard let store = app.store else { return }
            do {
                let options = try await Task.detached { try store.usageFilterOptions() }.value
                guard !Task.isCancelled else { return }
                if state.accounts != options.accounts { state.accounts = options.accounts }
            } catch {
                guard !Task.isCancelled else { return }
                AppTelemetry.capture(error, operation: "limits.filters")
                state.error = error.localizedDescription
            }
        }
        .onChange(of: currentSelection, initial: true) { old, new in
            if state.selectedWindow == nil || state.selectedWindow == old { state.selectedWindow = new ?? historyWindows.first?.id }
        }
        .onChange(of: criteria) { state.page = 0; state.selectedWindow = currentSelection }
        .onChange(of: state.page) {
            if state.selectedWindow != currentSelection { state.selectedWindow = nil }
        }
    }

    private func shortDate(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timezone))
    }
}

private struct WeeklyCycleDetail: View {
    let window: WeeklyLimitWindow?
    let current: CurrentLimitWindow?
    let timezone: TimeZone
    init(window: WeeklyLimitWindow, timezone: TimeZone) {
        self.window = window; self.current = nil; self.timezone = timezone
    }
    init(current: CurrentLimitWindow, usage: WeeklyLimitWindow?, timezone: TimeZone) {
        self.window = usage; self.current = current; self.timezone = timezone
    }
    private var percent: Double? { current?.usedPercent ?? window?.lastUsedPercent }
    private func date(_ value: Double) -> String { UsageFormatting.timestamp(value, timezone: timezone) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text(current == nil ? String(localized: "Cycle details") : String(localized: "Current cycle")).font(.title3.weight(.semibold))
                    if let current, let reset = current.resetsAt {
                        let expectedReset = String(localized: "Expected reset: \(date(Double(reset)))")
                        Text(window.map { "\(date(Double($0.startedAtInferred))) — \(expectedReset)" } ?? expectedReset)
                            .font(.caption).foregroundStyle(.secondary)
                        if Double(reset) <= context.date.timeIntervalSince1970 {
                            Text(String(localized: "Waiting for limit reset")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let window {
                        Text("\(date(Double(window.startedAtInferred))) — \(date(Double(window.endsAt)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let window, window.resetKind == "early" {
                        Text(String(localized: "Originally scheduled reset: \(date(Double(window.scheduledResetAt)))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "used")).font(.callout).foregroundStyle(.secondary)
                        Text(percent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                            .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    }
                    Spacer()
                    if window?.resetKind == "early" {
                        Text(String(localized: "Early reset")).font(.caption).padding(8)
                            .background(.primary.opacity(0.05), in: Capsule())
                    }
                }
                if let percent {
                    ProgressView(value: min(100, max(0, percent)), total: 100).tint(.primary)
                }
                Divider().padding(.vertical, 4)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Local tokens")).font(.caption).foregroundStyle(.secondary)
                        Text(UsageFormatting.tokens(window?.totalTokens)).font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Estimated cost")).font(.caption).foregroundStyle(.secondary)
                        Text(UsageFormatting.money(window?.knownAmountNanoUSD ?? window?.amountNanoUSD)).font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Requests")).font(.caption).foregroundStyle(.secondary)
                        Text(window?.requestCount.map { $0.formatted() } ?? "—").font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.monospacedDigit()
            }.usageSurface()
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
