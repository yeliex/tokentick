import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case overview, daily, threads, projects, limits, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "总览"
        case .daily: "每日用量"
        case .threads: "任务"
        case .projects: "项目"
        case .limits: "额度周期"
        case .data: "数据状态"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .daily: "calendar"
        case .threads: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .limits: "gauge.with.dots.needle.33percent"
        case .data: "externaldrive"
        }
    }

    var emptyTitle: String {
        switch self {
        case .overview: "暂无用量数据"
        case .daily: "暂无每日记录"
        case .threads: "暂无任务记录"
        case .projects: "暂无项目记录"
        case .limits: "暂无额度周期记录"
        case .data: "尚未采集数据"
        }
    }

    var emptyDescription: String {
        switch self {
        case .overview: "在这里查看 Codex 的 token 用量与已知金额。"
        case .daily: "按日期比较用量、模型构成和已知金额。"
        case .threads: "按任务查看请求用量、使用模型和分项金额。"
        case .projects: "按任务最新所属项目汇总用量和金额。"
        case .limits: "查看已观测的额度百分比和周期内已采集用量。"
        case .data: "在这里核对日志采集、价格更新和数据完整性。"
        }
    }
}
