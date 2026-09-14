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
    @State private var selectedWindow: String?
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
            HStack {
                Picker("日期范围", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 160)
                Button { filtersPresented.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                    .popover(isPresented: $filtersPresented) { filterForm }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding(16)
            HStack {
                Text("Codex · 每周额度").font(.headline)
                Spacer()
                Text("\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今")")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.bottom, 20)
            if let error { Text(error).font(.callout).textSelection(.enabled).padding(12) }
            if loadedQuery != query {
                ProgressView("正在查询额度历史").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if windows.isEmpty {
                ContentUnavailableView("所选范围暂无额度观测", systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("调整日期范围或同步后再查看。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(windows, selection: $selectedWindow) {
                    TableColumn("额度周期") { window in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(UsageFormatting.timestamp(Double(window.startedAtInferred), timezone: timezone))
                            Text("至 " + UsageFormatting.timestamp(Double(window.scheduledResetAt), timezone: timezone))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.width(min: 170, ideal: 210)
                    TableColumn("最后观测") { window in
                        Text(window.lastUsedPercent.map { $0.formatted() + "%" } ?? "—")
                    }.width(min: 85, ideal: 100)
                    TableColumn("观测峰值") { window in Text(window.peakUsedPercent.formatted() + "%") }
                        .width(min: 85, ideal: 100)
                    TableColumn("Tokens") { window in TokenText(value: window.totalTokens) }.width(min: 90, ideal: 110)
                    TableColumn("预估费用") { window in Text(UsageFormatting.money(window.knownAmountNanoUSD)) }
                        .width(min: 100, ideal: 125)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).monospacedDigit().scrollContentBackground(.hidden)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Divider()
            HStack {
                Text("第 \(page + 1) 页 · 每页 100 条").foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Button("下一页") { page += 1 }.disabled(!hasMore || loadedQuery != query)
            }.padding(12)
        }
        .padding(24)
        .inspector(isPresented: Binding(get: { selectedWindow != nil }, set: { if !$0 { selectedWindow = nil } })) {
            if loadedQuery == query, let window = windows.first(where: { $0.id == selectedWindow }) {
                ScrollView { WeeklyLimitRow(window: window, timezone: timezone).padding(18) }
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 400)
            }
        }
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let store = app.store else { return }
            let current = query
            loading = loadedQuery != current; error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) { try store.weeklyLimitHistory(current) }.value
                guard !Task.isCancelled else { return }
                if windows != result.rows { windows = result.rows }
                if hasMore != result.hasMore { hasMore = result.hasMore }
                if excludedObservations != result.excludedObservations { excludedObservations = result.excludedObservations }
            } catch {
                guard !Task.isCancelled else { return }
                windows = []; hasMore = false; self.error = error.localizedDescription
            }
            loadedQuery = current; loading = false
        }
        .onChange(of: criteria) { page = 0; selectedWindow = nil }
        .onChange(of: page) { selectedWindow = nil }
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
            VStack(alignment: .leading, spacing: 8) {
                Text(window.limitID).fontWeight(.medium)
                Text("窗口起算（推算）：\(UsageFormatting.timestamp(Double(window.startedAtInferred), timezone: timezone))")
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
            VStack(alignment: .leading, spacing: 6) {
                Text("本地 Tokens：\(UsageFormatting.tokens(window.totalTokens))")
                Text("已知金额：\(UsageFormatting.money(window.knownAmountNanoUSD ?? window.amountNanoUSD))")
                Text("未定价 Tokens：\(UsageFormatting.tokens(window.unpricedTokens))")
            }.font(.caption)
            DisclosureGroup("统计证据") {
                Text(window.sourceJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("起算时间由稳定截止减七天推算；跨界轮次按开始时间归属，不代表额度实际扣费。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10).textSelection(.enabled)
    }
}
