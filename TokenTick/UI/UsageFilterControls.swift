import SwiftUI
import TokenTickCore

struct UsageFilterControls: View {
    @Binding var filters: UsageFilters
    @Binding var period: UsagePeriod
    @Binding var from: Date
    @Binding var through: Date
    let timezone: TimeZone

    var body: some View {
        Form {
            Section("日期") {
                Picker("范围", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                if period == .custom {
                    DatePicker("开始", selection: $from, in: ...through, displayedComponents: .date)
                    DatePicker("结束", selection: $through, in: from..., displayedComponents: .date)
                }
                Text(timezone.identifier).font(.caption).foregroundStyle(.secondary)
            }
            Section("组合筛选 · 所有条件同时满足") {
                ValueFilterControl(title: "任务 ID", value: $filters.thread)
                ValueFilterControl(title: "项目", value: $filters.project)
                ValueFilterControl(title: "模型", value: $filters.model)
                ValueFilterControl(title: "单日", value: $filters.day, placeholder: "YYYY-MM-DD")
            }
            Button("清除归属与搜索条件") { filters = UsageFilters() }
        }
        .formStyle(.grouped).frame(width: 440, height: period == .custom ? 540 : 460)
        .environment(\.timeZone, timezone)
    }
}

private struct ValueFilterControl: View {
    let title: String
    @Binding var value: UsageValueFilter
    var placeholder = "精确名称或 ID"
    private var mode: Binding<Int> {
        Binding(get: {
            switch value { case .all: 0; case .unknown: 1; case .value: 2 }
        }, set: { value = $0 == 0 ? .all : $0 == 1 ? .unknown : .value("") })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: mode) {
                Text("全部").tag(0)
                Text("未知").tag(1)
                Text("指定值").tag(2)
            }
            if case .value(let current) = value {
                TextField(placeholder, text: Binding(get: { current }, set: { value = .value($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel(title)
            }
        }
    }
}

extension UsageSort {
    var title: String {
        switch self {
        case .automatic: "默认顺序"
        case .tokens: "Tokens 从高到低"
        case .amount: "已知金额从高到低"
        case .name: "名称升序"
        }
    }
}

extension UsageFilters {
    var summary: String {
        [("任务", thread), ("项目", project), ("模型", model), ("单日", day)].compactMap { name, filter in
            switch filter {
            case .all: nil
            case .unknown: "\(name)：未知"
            case .value(let value): "\(name)：\(value)"
            }
        }.joined(separator: " · ")
    }
}
