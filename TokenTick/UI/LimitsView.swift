import SwiftUI
import TokenTickCore

struct LimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var period = UsagePeriod.all
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @State private var account = ""
    @State private var bucket = ""
    @State private var filtersPresented = false
    @State private var page = 0
    @State private var windows: [WeeklyLimitReset] = []
    @State private var hasMore = false
    @State private var loadedQuery: LimitQuery?
    @State private var loading = false
    @State private var error: String?

    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var criteria: LimitQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = period == .custom ? (customFrom.formatted(style), customThrough.formatted(style)) : period.dates(timezone: timezone)
        return LimitQuery(timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1,
            account: account.isEmpty ? .all : .account(account), limitID: bucket.isEmpty ? nil : bucket)
    }
    private var query: LimitQuery { var query = criteria; query.offset = page * 100; return query }
    private struct Request: Hashable { let query: LimitQuery; let refresh: Int }
    private var request: Request { Request(query: query, refresh: app.refreshID) }

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = app.currentLimits {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前额度观测").font(.headline)
                    Text("\(snapshot.accountID ?? "未知账号") · \(snapshot.source) · \(UsageFormatting.timestamp(snapshot.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.windows) { window in
                        HStack {
                            Text("\(window.limitID) · \(window.durationMinutes.map { "\($0) 分钟" } ?? window.kind)")
                            Spacer()
                            Text("已用 \(window.usedPercent.formatted())%")
                            Text("重置 \(UsageFormatting.timestamp(window.resetsAt.map(Double.init)))")
                        }.font(.callout)
                    }
                    DisclosureGroup("完整额度来源（含附加类型）") {
                        ScrollView { Text(snapshot.sourceJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 120)
                    }
                }.padding(16)
                Divider()
            }
            HStack {
                Picker("日期范围", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
                Button { filtersPresented.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                    .popover(isPresented: $filtersPresented) { filterForm }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding(16)
            VStack(alignment: .leading, spacing: 4) {
                Text("重置日期：\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今") · \(timezone.identifier)")
                Text("账号：\(account.isEmpty ? "全部" : account) · 额度桶：\(bucket.isEmpty ? "全部" : bucket) · 历史周额度")
                    .lineLimit(1).help("账号：\(account)；额度桶：\(bucket)")
                Text("百分比为重置前最后观测值，可能低于最终用量；未知账号按任务分别保留，不合并百分比。")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if let error { Text(error).font(.callout).textSelection(.enabled).padding(12) }
            if loadedQuery != query {
                ProgressView("正在查询额度历史").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if windows.isEmpty {
                ContentUnavailableView("所选范围暂无额度观测", systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("可调整筛选或同步服务端。未观测的历史不会补造。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(windows) { window in
                            WeeklyLimitRow(window: window, timezone: timezone)
                            Divider()
                        }
                    }.padding(.horizontal, 16)
                }
            }
            Divider()
            HStack {
                Text("第 \(page + 1) 页 · 每页 100 条").foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Button("下一页") { page += 1 }.disabled(!hasMore || loadedQuery != query)
            }.padding(12)
        }
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let store = app.store else { return }
            let current = query
            loading = true; error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) { try store.weeklyLimitHistory(current) }.value
                guard !Task.isCancelled else { return }
                windows = result.rows; hasMore = result.hasMore
            } catch {
                guard !Task.isCancelled else { return }
                windows = []; hasMore = false; self.error = error.localizedDescription
            }
            loadedQuery = current; loading = false
        }
        .onChange(of: criteria) { page = 0 }
        .onChange(of: period) { if period == .custom { filtersPresented = true } }
    }

    private var filterForm: some View {
        Form {
            Section("窗口归属") {
                TextField("账号 ID（空白为全部）", text: $account)
                TextField("额度桶 ID（空白为全部）", text: $bucket)

            }
            if period == .custom {
                Section("日期范围") {
                    DatePicker("开始", selection: $customFrom, in: ...customThrough, displayedComponents: .date)
                    DatePicker("结束", selection: $customThrough, in: customFrom..., displayedComponents: .date)
                }
            }
            Button("清除筛选") { account = ""; bucket = ""; period = .all }
        }.formStyle(.grouped).frame(width: 400, height: period == .custom ? 340 : 220)
            .environment(\.timeZone, timezone)
    }
}

private struct WeeklyLimitRow: View {
    let window: WeeklyLimitReset
    let timezone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.limitID).fontWeight(.medium)
                Text(window.kind == "natural" ? "自然重置" : window.kind == "manual" ? "疑似提前重置" : "边界变化待确认")
                Spacer()
                Text("重置前最后观测已用 \(window.usedPercentBeforeReset.formatted())%").monospacedDigit()
            }
            Text("\(window.accountID ?? "未知账号") · \(window.scopeKey)").font(.caption).foregroundStyle(.secondary)
            Text("原计划重置：\(UsageFormatting.timestamp(Double(window.scheduledResetAt), timezone: timezone))").font(.caption)
            Text("重置前观测：\(UsageFormatting.timestamp(window.lastObservedAt, timezone: timezone)) · 新周期观测：\(UsageFormatting.timestamp(window.detectedAt, timezone: timezone))")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("统计证据") {
                Text(window.sourceJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(.vertical, 10)
    }
}
