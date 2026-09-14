import SwiftUI
import TokenTickCore

struct CurrentLimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @AppStorage("limitsShowRemaining") private var showRemaining = true
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("当前额度").font(.title2.weight(.semibold))
                    Spacer()
                    if let plan = app.currentLimits?.planType, let name = planName(plan) {
                        Text(name).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let snapshot = app.currentLimits {
                    if context.date.timeIntervalSince1970 - snapshot.observedAt > 900 {
                        Label("额度已过期，请刷新", systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                    } else {
                        let main = snapshot.windows.filter { $0.limitID == "codex" }
                        if !main.isEmpty { limitGroup(windows: main, snapshot: snapshot, now: context.date) }
                        else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 100) }
                        Group {
                            let groups = Dictionary(grouping: snapshot.windows.filter { $0.limitID != "codex" }, by: \.limitID)
                            ForEach(groups.keys.sorted(), id: \.self) { name in
                                extendedGroup(windows: groups[name] ?? [], now: context.date)
                            }
                        }

                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 100)
                }
            }
        }
    }
    private func limitGroup(windows: [CurrentLimitWindow], snapshot: CurrentLimitSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: windows.count > 1 ? 18 : 24) {
            ForEach(windows.sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }) { window in
                limitWindow(window, now: now, compact: windows.count > 1)
            }
            if snapshot.availableResets != nil || snapshot.creditsBalance != nil || snapshot.unlimitedCredits == true {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
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
        }.usageSurface()
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
    private func limitWindow(_ window: CurrentLimitWindow, now: Date, compact: Bool) -> some View {
        let forecast = app.limitSession.forecasts.forecast(for: window, now: now.timeIntervalSince1970)
        let expired = window.resetsAt.map { Double($0) <= now.timeIntervalSince1970 } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(periodName(window)).font(.callout).foregroundStyle(.secondary)
                if compact && !expired {
                    Spacer()
                    Text("\(showRemaining ? "剩余" : "已使用") \(displayPercent(window).formatted(.number.precision(.fractionLength(0...1))))%")
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                }
            }
            if expired {
                Text("等待额度重置").foregroundStyle(.secondary)
            } else {
                if !compact {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(displayPercent(window).formatted(.number.precision(.fractionLength(0...1))))%")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(showRemaining ? "剩余" : "已使用").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.07)).frame(height: 7)
                        Capsule().fill(.primary.opacity(0.8))
                            .frame(width: geometry.size.width * min(1, max(0, displayPercent(window) / 100)), height: 7)
                        ForEach(ticks(window), id: \.self) { used in
                            Rectangle().fill(.white.opacity(used == 50 || used == 80 ? 0.85 : 0.45)).blendMode(.difference)
                                .frame(width: 1, height: used == 50 || used == 80 ? 13 : 9)
                                .offset(x: geometry.size.width * (showRemaining ? 100 - used : used) / 100)
                                .help("已使用 \(used.formatted(.number.precision(.fractionLength(0...1))))%")
                        }
                    }
                }.frame(height: 7).padding(.vertical, 3)
                    .accessibilityLabel("\(showRemaining ? "剩余" : "已使用") \(displayPercent(window))%")
                HStack {
                    if let difference = forecast.progressDifference {
                        Text("\(difference > 0 ? "超前" : "结余") \(abs(difference).formatted(.number.precision(.fractionLength(0...1))))%")
                    }
                    Spacer()
                    if let reset = window.resetsAt {
                        Text(resetTime(reset, now: now))
                            .help(UsageFormatting.timestamp(Double(reset)))
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if let prediction = prediction(forecast, window: window, now: now) {
                    Text(prediction).font(.callout)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func displayPercent(_ window: CurrentLimitWindow) -> Double {
        showRemaining ? max(0, 100 - window.usedPercent) : window.usedPercent
    }
    private func ticks(_ window: CurrentLimitWindow) -> [Double] {
        guard window.durationMinutes != 300 else { return [] }
        let days = min(90, Int((window.durationMinutes ?? 0) / 1440))
        let daily = days > 1 ? (1..<days).map { Double($0) * 100 / Double(days) } : []
        return Array(Set(daily + [50, 80])).sorted()
    }
    private func planName(_ value: String) -> String? {
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
                return "预计\(duration(exhaustion - now.timeIntervalSince1970))后耗尽 · 提前 \(duration(Double(reset) - exhaustion))"
            }
            return "预计重置时剩余 \((value.remainingAtReset ?? 0).formatted(.number.precision(.fractionLength(0...1))))%"
        }
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
