import SwiftUI
import TokenTickCore

struct CurrentLimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @AppStorage("limitsShowRemaining") private var showRemaining = true
    @AppStorage("limitsWorkingDays") private var workingDays = 5
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                if !compact {
                    HStack {
                        Text("当前额度").font(.title2.weight(.semibold))
                        Spacer()
                        if let plan = app.currentLimits?.planType, let name = Self.planName(plan) {
                            Text(name).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let snapshot = app.currentLimits {
                    let main = snapshot.windows.filter { $0.limitID == "codex" }
                    if !main.isEmpty { limitGroup(windows: main, snapshot: snapshot, now: context.date) }
                    else { Text("暂无主订阅额度").font(.callout).foregroundStyle(.secondary) }
                    if !compact {
                        let groups = Dictionary(grouping: snapshot.windows.filter { $0.limitID != "codex" }, by: \.limitID)
                        ForEach(groups.keys.sorted(), id: \.self) { name in
                            extendedGroup(windows: groups[name] ?? [], now: context.date)
                        }
                    }
                } else {
                    if app.isSyncing {
                        ProgressView("正在读取额度…").controlSize(.small).frame(maxWidth: .infinity, minHeight: compact ? 40 : 100)
                    } else {
                        Text("暂无当前额度，请刷新或检查 Codex 登录状态。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func limitGroup(windows: [CurrentLimitWindow], snapshot: CurrentLimitSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            ForEach(windows.sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }) { window in
                limitWindow(window, now: now, compact: compact || windows.count > 1)
            }
            if snapshot.availableResets != nil || snapshot.creditsBalance != nil || snapshot.unlimitedCredits == true {
                VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                    if let count = snapshot.availableResets {
                        HStack(alignment: .center, spacing: 8) {
                            Text("可用重置").fixedSize()
                            Text("\(count) 次").fixedSize()
                            Spacer(minLength: 12)
                            if let expirations = snapshot.resetCreditExpirations, !expirations.isEmpty {
                                let dates = expirations.map { expiry in
                                    expiry.map { Date(timeIntervalSince1970: Double($0)).formatted(.dateTime.month().day().hour().minute()) + " 到期" } ?? "永不过期"
                                }.joined(separator: " · ")
                                ScrollView(.horizontal) {
                                    Text(dates).fixedSize().help(dates)
                                }.scrollIndicators(.hidden).frame(height: 18)
                            }
                        }
                    }
                    if snapshot.unlimitedCredits == true || snapshot.creditsBalance != nil {
                        HStack(alignment: .center, spacing: 8) {
                            Text("Credits").fixedSize()
                            if snapshot.unlimitedCredits == true { Text("不限额") }
                            else if let balance = snapshot.creditsBalance {
                                Text(Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")).map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? balance)
                                    .help(balance)
                            }
                        }.frame(minHeight: 18)
                    }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.modifier(LimitSurface(compact: compact))
    }
    private func extendedGroup(windows: [CurrentLimitWindow], now: Date) -> some View {
        VStack(spacing: 18) {
            ForEach(windows.sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }) { window in
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(window.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (window.limitID == "codex_bengalfox" ? "Codex Spark" : "扩展额度"))
                            .fontWeight(.medium)
                        Text(periodName(window))
                        Text("\(showRemaining ? "剩余" : "已使用") \(displayPercent(window).formatted(.number.precision(.fractionLength(0...1))))%")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let reset = window.resetsAt {
                            Text(resetTime(reset, now: now))
                                .foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                    progress(displayPercent(window))
                }
            }
        }.padding(18).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
    }
    private func periodName(_ window: CurrentLimitWindow) -> String {
        window.durationMinutes.map { $0 == 10080 ? "7 天" : $0 == 300 ? "5 小时" : "\($0) 分钟" } ?? "额度"
    }
    private func progress(_ percent: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                }
        }.frame(height: 6)
    }
    private func limitWindow(_ window: CurrentLimitWindow, now: Date, compact: Bool, previewForecast: LimitForecast? = nil) -> some View {
        let forecast = previewForecast ?? app.limitSession.forecasts.forecast(for: window, now: now.timeIntervalSince1970)
        // 进度差与绿色时间标记共用口径，不依赖耗尽预测的历史采样。
        let progressDifference = window.expectedUsedPercent(now: now.timeIntervalSince1970).map { window.usedPercent - $0 }
        let expired = window.resetsAt.map { Double($0) <= now.timeIntervalSince1970 } ?? false
        return VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !compact || expired {
                Text(periodName(window)).font(.callout).foregroundStyle(.secondary)
            }
            if expired {
                Text("等待额度重置").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if compact {
                        Text(periodName(window)).font(.callout).foregroundStyle(.secondary)
                        Text("\(displayPercent(window).formatted(.number.precision(.fractionLength(0...1))))%")
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        Text(showRemaining ? "剩余" : "已使用").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(displayPercent(window).formatted(.number.precision(.fractionLength(0...1))))%")
                            .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(showRemaining ? "剩余" : "已使用").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let reset = window.resetsAt {
                        Text(resetTime(reset, now: now))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(UsageFormatting.timestamp(Double(reset)))
                    }
                }
                LimitProgressBar(window: window, now: now, showRemaining: showRemaining, workingDays: workingDays)
                    .padding(.top, compact ? -4 : -6)
                if progressDifference != nil || prediction(forecast, window: window, now: now) != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if let difference = progressDifference {
                            Text("\(difference > 0 ? "超前" : "结余") \(abs(difference).formatted(.number.precision(.fractionLength(0...1))))%")
                        }
                        Spacer(minLength: 8)
                        if let text = prediction(forecast, window: window, now: now) {
                            Text(text).multilineTextAlignment(.trailing)
                                .help(predictionDetail(forecast, window: window, now: now) ?? text)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func displayPercent(_ window: CurrentLimitWindow) -> Double {
        showRemaining ? max(0, 100 - window.usedPercent) : window.usedPercent
    }
    static func planName(_ value: String) -> String? {
        switch value {
        case "pro": "ChatGPT Pro"
        case "prolite": "ChatGPT Pro Lite"
        case "plus": "ChatGPT Plus"
        case "free": "ChatGPT Free"
        case "go": "ChatGPT Go"
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based": "ChatGPT Business"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise": "ChatGPT Enterprise"
        case "edu", "edu_plus", "edu_pro": "ChatGPT Edu"
        default: nil
        }
    }
    private func prediction(_ value: LimitForecast, window: CurrentLimitWindow, now: Date) -> String? {
        switch value.state {
        case .insufficient: return nil
        case .stale: return nil
        case .invalidBoundary: return nil
        case .idle: return nil
        case .exhausted: return "额度已耗尽"
        case .estimated:
            guard let exhaustion = value.exhaustsAt, let reset = window.resetsAt else { return nil }
            if exhaustion < Double(reset) {
                if exhaustion <= now.timeIntervalSince1970 { return "预计已耗尽，请刷新" }
                return "预计\(duration(exhaustion - now.timeIntervalSince1970))后耗尽"
            }
            return "预计重置时剩余 \((value.remainingAtReset ?? 0).formatted(.number.precision(.fractionLength(0...1))))%"
        }
    }
    private func predictionDetail(_ value: LimitForecast, window: CurrentLimitWindow, now: Date) -> String? {
        guard value.state == .estimated, let exhaustion = value.exhaustsAt,
              let reset = window.resetsAt, exhaustion > now.timeIntervalSince1970,
              exhaustion < Double(reset) else { return nil }
        return "比额度重置提前 \(duration(Double(reset) - exhaustion))耗尽"
    }
    private func resetTime(_ timestamp: Int64, now: Date) -> String {
        let seconds = Double(timestamp) - now.timeIntervalSince1970
        guard seconds > 0 else { return "等待重置" }
        if seconds < 86400 {
            let date = Date(timeIntervalSince1970: Double(timestamp))
            let day = Calendar.current.isDate(date, inSameDayAs: now) ? "今天" : "明天"
            return "\(day) \(date.formatted(.dateTime.hour().minute())) 重置"
        }
        return "\(duration(seconds))后重置"
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}

private struct LimitSurface: ViewModifier {
    let compact: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if compact { content } else { content.padding(.bottom, -12).usageSurface() }
    }
}

struct LimitProgressBar: View {
    let window: CurrentLimitWindow
    let now: Date
    let showRemaining: Bool
    let workingDays: Int
    private func position(_ used: Double) -> Double {
        min(1, max(0, (showRemaining ? 100 - used : used) / 100))
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08)).frame(height: 7)
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * position(window.usedPercent), height: 7)
                ForEach(window.usageTicks(workingDays: workingDays), id: \.self) { used in
                    Rectangle().fill(.primary.opacity(0.55)).frame(width: 1, height: 11)
                        .offset(x: geometry.size.width * position(used))
                        .help("已使用 \(used.formatted(.number.precision(.fractionLength(0...1))))%")
                }
                if let expected = window.expectedUsedPercent(now: now.timeIntervalSince1970) {
                    Rectangle().fill(.green).frame(width: 2, height: 13)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * position(expected) - 1)))
                        .accessibilityLabel("当前应使用 \(expected.formatted(.number.precision(.fractionLength(0...1))))%")
                }
            }
        }.frame(height: 13).padding(.top, 3)
            .accessibilityLabel("\(showRemaining ? "剩余" : "已使用") \((position(window.usedPercent) * 100).formatted())%")
    }
}

#if DEBUG
extension CurrentLimitsView {
    var previewGallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("额度布局 · 状态预览").font(.title2.bold())
                Text("以下为固定示例数据，复用实际额度组件，不影响当前账号。预测文字悬浮可查看提前耗尽时间。")
                    .font(.callout).foregroundStyle(.secondary)
                previewCard("单窗口 · 暂无节奏和预测", scenarios: [.init(used: 29, rate: nil)])
                previewCard("单窗口 · 结余，预计重置时仍有剩余", scenarios: [.init(used: 29, rate: 0.6)])
                previewCard("单窗口 · 超前，预计提前耗尽", scenarios: [.init(used: 85, rate: 1)])
                previewCard("多窗口 · 不同消耗节奏", scenarios: [
                    .init(minutes: 300, remaining: 7200, used: 58, rate: 30),
                    .init(used: 29, rate: 0.6)
                ])
                previewCard("多窗口 · 暂无预测", scenarios: [
                    .init(minutes: 300, remaining: 7200, used: 58, rate: nil),
                    .init(used: 29, rate: nil)
                ])
                previewCard("额度耗尽", scenarios: [.init(minutes: 300, remaining: 7200, used: 100, rate: 0)])
                previewCard("已到重置时间 · 等待更新", scenarios: [.init(remaining: -60, used: 100, rate: nil)])
                previewCard("只有节奏 · 使用速度为零", scenarios: [.init(used: 29, rate: 0)])
                previewCard("菜单栏宽度 · 多窗口", scenarios: [
                    .init(minutes: 300, remaining: 7200, used: 58, rate: 30),
                    .init(used: 29, rate: 0.6)
                ]).frame(width: 360)
            }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }

    private struct PreviewScenario {
        var minutes: Int64 = 10080
        var remaining: Double = 345600
        var used: Double
        var rate: Double?
    }

    private func previewCard(_ title: String, scenarios: [PreviewScenario]) -> some View {
        let now = Date(timeIntervalSince1970: 1789455600)
        return VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
            ForEach(scenarios.indices, id: \.self) { index in
                let scenario = scenarios[index]
                let snapshot = previewSnapshot(scenario, now: now, offset: 0)
                let window = snapshot.windows[0]
                let forecast = previewForecast(scenario, now: now)
                limitWindow(window, now: now, compact: scenarios.count > 1, previewForecast: forecast)
            }
        }.usageSurface()
    }

    private func previewSnapshot(_ scenario: PreviewScenario, now: Date, offset: Double) -> CurrentLimitSnapshot {
        let object: [String: Any] = [
            "accountID": "preview", "observedAt": now.timeIntervalSince1970 + offset,
            "source": "api", "scopeKey": "preview", "sourceJSON": "{}",
            "windows": [["limitID": "codex", "kind": "primary",
                         "usedPercent": scenario.used + (scenario.rate ?? 0) * offset / 3600,
                         "durationMinutes": scenario.minutes,
                         "resetsAt": Int64(now.timeIntervalSince1970 + scenario.remaining)]]
        ]
        // 固定预览数据必须能解码；失败时直接暴露样例错误。
        return try! JSONDecoder().decode(CurrentLimitSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func previewForecast(_ scenario: PreviewScenario, now: Date) -> LimitForecast {
        var history = LimitForecastHistory()
        history.confirmAccount("preview")
        if scenario.rate != nil {
            for offset in [-600.0, -300.0, 0.0] {
                let snapshot = previewSnapshot(scenario, now: now, offset: offset)
                history.record(snapshot, now: snapshot.observedAt)
            }
        }
        return history.forecast(for: previewSnapshot(scenario, now: now, offset: 0).windows[0], now: now.timeIntervalSince1970)
    }
}

#Preview("额度各状态") {
    CurrentLimitsView().previewGallery.environment(ApplicationModel())
        .frame(width: 900, height: 900)
}
#endif
