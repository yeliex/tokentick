import SwiftUI
import TokenTickCore

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
            case .value(let value): "\(name)：\(name == "项目" ? UsageFormatting.project(value) : value)"
            }
        }.joined(separator: " · ")
    }
}

struct UsageDateFilter: View {
    @Binding var period: UsagePeriod
    @Binding var from: Date
    @Binding var through: Date
    let periods: [UsagePeriod]
    let timezone: TimeZone
    @State private var showingCalendar = false
    @State private var draftFrom = Date()
    @State private var draftThrough = Date()

    var body: some View {
        Menu {
            ForEach(periods) { value in
                Button { period = value } label: {
                    if period == value { Label(value.rawValue, systemImage: "checkmark") }
                    else { Text(value.rawValue) }
                }
            }
            Divider()
            Button("自定义…") { openCalendar() }
        } label: {
            Text(period == .custom ? "自定义" : period.rawValue)
        }.frame(width: 90).accessibilityLabel("日期范围")
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 20) {
                Text("选择日期范围").font(.headline)
                DatePicker("开始日期", selection: $draftFrom, in: ...draftThrough, displayedComponents: .date)
                DatePicker("结束日期", selection: $draftThrough, in: draftFrom..., displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("取消") { showingCalendar = false }.keyboardShortcut(.cancelAction)
                    Button("应用") {
                        from = draftFrom; through = draftThrough; period = .custom
                        showingCalendar = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.environment(\.timeZone, timezone).padding(24).frame(width: 380)
        }
    }

    private func openCalendar() {
        if period == .custom { draftFrom = from; draftThrough = through }
        else {
            let dates = period.dates(timezone: timezone)
            let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
            draftFrom = dates.0.flatMap { try? style.parse($0) } ?? from
            draftThrough = dates.1.flatMap { try? style.parse($0) } ?? through
        }
        showingCalendar = true
    }
}
