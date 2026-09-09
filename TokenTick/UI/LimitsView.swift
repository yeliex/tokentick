import SwiftUI
import TokenTickCore

struct LimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var period = UsagePeriod.all
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @State private var account = ""
    @State private var bucket = ""
    @State private var kind: LimitWindowKind?
    @State private var latest = false
    @State private var filtersPresented = false
    @State private var page = 0
    @State private var windows: [LimitWindow] = []
    @State private var hasMore = false
    @State private var loadedQuery: LimitQuery?
    @State private var loading = false
    @State private var error: String?

    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var criteria: LimitQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = period == .custom ? (customFrom.formatted(style), customThrough.formatted(style)) : period.dates(timezone: timezone)
        return LimitQuery(timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1,
            account: account.isEmpty ? .all : .account(account), limitID: bucket.isEmpty ? nil : bucket,
            kind: kind, latestOnly: latest)
    }
    private var query: LimitQuery { var query = criteria; query.offset = page * 100; return query }
    private struct Request: Hashable { let query: LimitQuery; let refresh: Int }
    private var request: Request { Request(query: query, refresh: app.refreshID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("日期范围", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
                Toggle("每账号最新观测", isOn: $latest).toggleStyle(.checkbox)
                Button { filtersPresented.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                    .popover(isPresented: $filtersPresented) { filterForm }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding(16)
            VStack(alignment: .leading, spacing: 4) {
                Text("周期与范围重叠：\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今") · \(timezone.identifier)")
                Text("账号：\(account.isEmpty ? "全部" : account) · 额度桶：\(bucket.isEmpty ? "全部" : bucket) · \(kind?.rawValue ?? "全部窗口")")
                    .lineLimit(1).help("账号：\(account)；额度桶：\(bucket)")
                Text("百分比为最后观测值；开始时间由窗口时长推算，不代表已确认的完整周期。")
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
                            LimitWindowRow(window: window, timezone: timezone)
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
                let result = try await Task.detached(priority: .userInitiated) { try store.limitWindowPage(current) }.value
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
                Picker("窗口", selection: $kind) {
                    Text("全部").tag(nil as LimitWindowKind?)
                    Text("主窗口").tag(LimitWindowKind.primary as LimitWindowKind?)
                    Text("次窗口").tag(LimitWindowKind.secondary as LimitWindowKind?)
                }
            }
            if period == .custom {
                Section("日期范围") {
                    DatePicker("开始", selection: $customFrom, in: ...customThrough, displayedComponents: .date)
                    DatePicker("结束", selection: $customThrough, in: customFrom..., displayedComponents: .date)
                }
            }
            Button("清除筛选") { account = ""; bucket = ""; kind = nil; latest = false; period = .all }
        }.formStyle(.grouped).frame(width: 400, height: period == .custom ? 340 : 220)
            .environment(\.timeZone, timezone)
    }
}

private struct LimitWindowRow: View {
    let window: LimitWindow
    let timezone: TimeZone
    @State private var expanded = false
    @State private var sourceExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.limitID).fontWeight(.medium)
                Text(window.kind == "primary" ? "主窗口" : "次窗口").foregroundStyle(.secondary)
                Spacer()
                Text("最近观测已用 \(window.lastUsedPercent.formatted())%").monospacedDigit()
            }
            ProgressView(value: min(max(window.lastUsedPercent, 0), 100), total: 100)
            Text("重置：\(UsageFormatting.timestamp(Double(window.resetsAt), timezone: timezone))")
                .font(.caption).foregroundStyle(.secondary)
            Text("最后观测：\(UsageFormatting.timestamp(window.lastObservedAt, timezone: timezone))")
                .font(.caption).foregroundStyle(.secondary)
            Button { expanded.toggle() } label: {
                Label(expanded ? "收起周期详情" : "周期详情与统计证据", systemImage: expanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.borderless)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("账号", value: window.accountID)
                    LabeledContent("推算开始", value: UsageFormatting.timestamp(Double(window.startsAt), timezone: timezone))
                    LabeledContent("时长", value: "\(window.durationMinutes) 分钟")
                    LabeledContent("周期 tokens", value: UsageFormatting.tokens(window.tokens))
                    LabeledContent("输入金额 · USD", value: UsageFormatting.exactMoney(window.inputAmount))
                    LabeledContent("输出金额 · USD", value: UsageFormatting.exactMoney(window.outputAmount))
                    LabeledContent("缓存读取 · USD", value: UsageFormatting.exactMoney(window.cacheReadAmount))
                    LabeledContent("缓存写入 · USD", value: UsageFormatting.exactMoney(window.cacheWriteAmount))
                    LabeledContent("未定价 tokens", value: UsageFormatting.tokens(window.unpricedTokens))
                    Text("未确认周期归属的 tokens 和金额保留未知，不从额度百分比反推。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let source = window.sourceJSON {
                        Button(sourceExpanded ? "收起来源 JSON" : "查看来源 JSON") { sourceExpanded.toggle() }.buttonStyle(.borderless)
                        if sourceExpanded { Text(source).font(.system(.caption, design: .monospaced)) }
                    }
                }.textSelection(.enabled).padding(.vertical, 8)
            }
        }.padding(.vertical, 10)
            .accessibilityElement(children: .contain)
    }
}
