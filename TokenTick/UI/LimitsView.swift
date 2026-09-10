import SwiftUI
import TokenTickCore

struct LimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var period = UsagePeriod.all
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @State private var account = ""
    @State private var filtersPresented = false
    @State private var page = 0
    @State private var windows: [WeeklyLimitWindow] = []
    @State private var hasMore = false
    @State private var excludedObservations: [String: Int] = [:]
    @State private var loadedQuery: LimitQuery?
    @State private var loading = false
    @State private var error: String?

    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var criteria: LimitQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = period == .custom ? (customFrom.formatted(style), customThrough.formatted(style)) : period.dates(timezone: timezone)
        return LimitQuery(timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1,
            account: account.isEmpty ? .all : .account(account), limitID: "codex")
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
                Text("窗口起算日期：\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今") · \(timezone.identifier)")
                Text("账号：\(account.isEmpty ? "全部" : account) · 主限额 codex · 七天限额窗口")
                    .lineLimit(1).help("账号：\(account)")
                Text("按稳定截止减七天展示起算时间；额度恢复后空闲期间的滚动零值不新增窗口。最后观测不代表最终用量。")
                Text("周期 token／金额缺少账号及额度桶归属证据，暂不估算。")
                if !excludedObservations.isEmpty {
                    Text("已排除回放、过期及冲突点：\(excludedObservations.values.reduce(0, +).formatted()) 条")
                }
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
                windows = result.rows; hasMore = result.hasMore; excludedObservations = result.excludedObservations
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
            }
            if period == .custom {
                Section("日期范围") {
                    DatePicker("开始", selection: $customFrom, in: ...customThrough, displayedComponents: .date)
                    DatePicker("结束", selection: $customThrough, in: customFrom..., displayedComponents: .date)
                }
            }
            Button("清除筛选") { account = ""; period = .all }
        }.formStyle(.grouped).frame(width: 400, height: period == .custom ? 340 : 220)
            .environment(\.timeZone, timezone)
    }
}

private struct WeeklyLimitRow: View {
    let window: WeeklyLimitWindow
    let timezone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.limitID).fontWeight(.medium)
                Text("窗口起算（推算）：\(UsageFormatting.timestamp(Double(window.startedAtInferred), timezone: timezone))")
                Spacer()
                Text("最后观测：\(window.lastUsedPercent.map { $0.formatted() + "%" } ?? "同刻冲突")").monospacedDigit()
            }
            Text("\(window.accountID ?? (window.scopeKey == "all" ? "全部账号的窗口证据" : "未知账号")) · 观测最高 \(window.peakUsedPercent.formatted())% · \(window.observationCount) 条观测")
                .font(.caption).foregroundStyle(.secondary)
            Text("稳定截止：\(UsageFormatting.timestamp(Double(window.scheduledResetAt), timezone: timezone))").font(.caption)
            Text("首次观测：\(UsageFormatting.timestamp(window.firstObservedAt, timezone: timezone)) · 最后观测：\(UsageFormatting.timestamp(window.lastObservedAt, timezone: timezone))")
                .font(.caption).foregroundStyle(.secondary)
            Text("首次正用量：\(UsageFormatting.timestamp(window.firstPositiveAt, timezone: timezone)) · 未归属账号观测 \(window.unknownAccountObservations) 条")
                .font(.caption).foregroundStyle(.secondary)
            if let recovery = window.recoveryObservedAt {
                Text("明确账号的额度归零观测：\(UsageFormatting.timestamp(recovery, timezone: timezone))（不等于窗口起算）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("统计证据") {
                Text(window.sourceJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(.vertical, 10)
    }
}
