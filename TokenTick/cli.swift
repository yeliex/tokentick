import TokenTickCore
import Darwin
import Foundation

@main
struct TokenTickCommand {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "help": print(help)
            case "version": print("\(ApplicationInfo.name) \(ApplicationInfo.version)")
            case "scan":
                let store = try UsageStore(databaseURL: options.database)
                let report = try LocalUsageScanner(store: store).scan(codexHome: options.codexHome)
                if options.json { try printJSON(report) }
                else {
                    print("发现 \(report.discoveredFiles) 个文件；扫描 \(report.scannedFiles)，未变化 \(report.unchangedFiles)。")
                    print("新增 \(report.insertedRequests) 个请求，补齐标识／归属 \(report.upgradedRequests)，重复 \(report.duplicateRequests)，继承事件 \(report.inheritedEvents)。")
                    for issue in report.issues {
                        print("\(issue.fileName)\(issue.line.map { ":\($0)" } ?? "")：\(issue.message)")
                    }
                    if report.issueCount > 0 { print("共 \(report.issueCount) 个问题，最多显示 100 个。") }
                }
                if report.issueCount > 0 { exit(1) }
            case "sync":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await UsageSynchronizer(store: store).synchronize(scope: options.scope,
                    codexHome: options.codexHome, codexExecutable: options.codexExecutable)
                try printJSON(report)
                if !report.issues.isEmpty { exit(1) }
            case "usage":
                let report = try UsageStore(databaseURL: options.database).usageReport(UsageQuery(
                    grouping: options.grouping, timezone: options.timezone, fromDate: options.fromDate,
                    throughDate: options.throughDate, account: options.account, limit: options.limit, offset: options.offset, filters: options.filters, sort: options.sort))
                if options.json { try printJSON(report) }
                else if report.rows.isEmpty { print("所选范围暂无用量。") }
                else {
                    print("时区：\(report.timezone)；日期无法确定的 tokens：\(report.unknownDateTokens)")
                    print("维度\t记录数\tTokens\t已知 USD\t未定价 Tokens")
                    for item in report.rows {
                        let amount = item.knownAmountNanoUSD.map { NSDecimalNumber(decimal: Decimal($0) / Decimal(1_000_000_000)).stringValue } ?? "未知"
                        print("\(item.group ?? (options.grouping == .total ? "总计" : "未知"))\t\(item.records)\t\(item.totalTokens)\t\(amount)\t\(item.unpricedTokens)")
                    }
                }
            case "records":
                try printJSON(UsageStore(databaseURL: options.database).usageRecords(UsageQuery(
                    timezone: options.timezone, fromDate: options.fromDate, throughDate: options.throughDate,
                    account: options.account, limit: options.limit, offset: options.offset, filters: options.filters, sort: options.sort)))
            case "rebuild":
                try printJSON(UsageStore(databaseURL: options.database).rebuildStatistics(timezone: options.timezone))
            case "prices":
                try printJSON(PriceOutput(rows: UsageStore(databaseURL: options.database).priceEntries(limit: options.limit)))
            case "sync-prices":
                let store = try UsageStore(databaseURL: options.database)
                try await printJSON(PriceSynchronizer(store: store).synchronize())
            case "reprice":
                try printJSON(UsageStore(databaseURL: options.database).repriceUsage())
            case "sync-api":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await CodexAPIClient.synchronize(store: store, executable: options.codexExecutable, codexHome: options.codexHome)
                try printJSON(report)
                if report.issue != nil || !report.accountAvailable { exit(1) }
            case "limits":
                try printJSON(UsageStore(databaseURL: options.database).limitWindowPage(LimitQuery(
                    timezone: options.timezone, fromDate: options.fromDate, throughDate: options.throughDate,
                    account: options.account, limitID: options.limitID, kind: options.windowKind,
                    latestOnly: options.latestLimits, limit: options.limit, offset: options.offset)))
            case "api-usage":
                try printJSON(APIUsageOutput(rows: UsageStore(databaseURL: options.database).apiDailyUsage(limit: options.limit)))
            case "status": try printJSON(UsageStore(databaseURL: options.database).status())
            default: throw CommandError.invalid("不支持的命令。")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(error is CommandError || error is UsageQueryError ? 2 : 1)
        }
    }

    private struct PriceOutput: Encodable {
        let priceUnit = "USD_per_million_tokens"
        let rows: [PriceEntry]
    }

    private struct APIUsageOutput: Encodable {
        let timezone: String? = nil
        let includedInLocalTotals = false
        let rows: [APIDailyBucket]
        enum CodingKeys: String, CodingKey { case timezone, includedInLocalTotals, rows }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(timezone, forKey: .timezone)
            try values.encode(includedInLocalTotals, forKey: .includedInLocalTotals)
            try values.encode(rows, forKey: .rows)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private enum CommandError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): "\(message) 使用 tokentick --help 查看帮助。" }
        }
    }

    private struct Options {
        var command: String
        var database = UsageStore.defaultDatabaseURL
        var codexHome = LocalUsageScanner.defaultCodexHome
        var codexExecutable: URL?
        var grouping = UsageGrouping.day
        var scope = SynchronizationScope.all
        var filters = UsageFilters()
        var sort = UsageSort.automatic
        var timezone: String?
        var fromDate: String?
        var throughDate: String?
        var account = UsageAccountScope.all
        var offset = 0
        var limit = 100
        var json = false
        var limitID: String?
        var windowKind: LimitWindowKind?
        var latestLimits = false

        init(arguments: [String]) throws {
            command = arguments.first ?? "help"
            if ["--help", "-h"].contains(command) { command = "help" }
            if command == "--version" { command = "version" }
            guard ["help", "version", "scan", "sync", "usage", "status", "prices", "sync-prices", "reprice", "sync-api", "limits", "api-usage", "rebuild", "records"].contains(command) else {
                throw CommandError.invalid("不支持的命令：\(command)。")
            }
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                if option == "--json" { json = true; continue }
                if option == "--latest", command == "limits" { latestLimits = true; continue }
                if option == "--unknown-account", ["usage", "records", "limits"].contains(command) {
                    guard account == .all else { throw CommandError.invalid("账号筛选参数不能重复。") }
                    account = .unknown
                    continue
                }
                if ["usage", "records"].contains(command), ["--unknown-thread", "--unknown-project", "--unknown-model", "--unknown-date"].contains(option) {
                    switch option {
                    case "--unknown-thread": try setFilter(.thread, value: .unknown)
                    case "--unknown-project": try setFilter(.project, value: .unknown)
                    case "--unknown-model": try setFilter(.model, value: .unknown)
                    default: try setFilter(.day, value: .unknown)
                    }
                    continue
                }
                guard index < arguments.count else { throw CommandError.invalid("\(option) 缺少参数。") }
                let value = arguments[index]
                index += 1
                switch option {
                case "--database": database = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--codex-home" where ["scan", "sync-api", "sync"].contains(command):
                    codexHome = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
                case "--codex-bin" where command == "sync-api" || command == "sync":
                    codexExecutable = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--scope" where command == "sync":
                    guard let scope = SynchronizationScope(rawValue: value) else { throw CommandError.invalid("同步范围为 all、local、prices 或 api。") }
                    self.scope = scope
                case let flag where ["usage", "records"].contains(command) && ["--thread", "--project", "--model", "--day"].contains(flag):
                    switch option {
                    case "--thread": try setFilter(.thread, value: .value(value))
                    case "--project": try setFilter(.project, value: .value(value))
                    case "--model": try setFilter(.model, value: .value(value))
                    default: try setFilter(.day, value: .value(value))
                    }
                case "--search" where ["usage", "records"].contains(command): filters.search = value
                case "--sort" where ["usage", "records"].contains(command):
                    guard let order = UsageSort(rawValue: value) else { throw CommandError.invalid("排序为 automatic、tokens、amount 或 name。") }
                    sort = order
                case "--limit-id" where command == "limits": limitID = value
                case "--window" where command == "limits":
                    guard let kind = LimitWindowKind(rawValue: value) else { throw CommandError.invalid("窗口为 primary 或 secondary。") }
                    windowKind = kind
                case "--group" where command == "usage":
                    guard let group = UsageGrouping(rawValue: value) else { throw CommandError.invalid("无效的统计维度。") }
                    grouping = group
                case "--timezone" where ["usage", "records", "rebuild", "limits"].contains(command):
                    guard TimeZone(identifier: value) != nil else { throw CommandError.invalid("无效的 IANA 时区。") }
                    timezone = value
                case "--from" where ["usage", "records", "limits"].contains(command): fromDate = value
                case "--through" where ["usage", "records", "limits"].contains(command): throughDate = value
                case "--account" where ["usage", "records", "limits"].contains(command):
                    guard account == .all, !value.isEmpty else { throw CommandError.invalid("账号筛选参数不能重复或为空。") }
                    account = .account(value)
                case "--offset" where ["usage", "records", "limits"].contains(command):
                    guard let count = Int(value), count >= 0 else { throw CommandError.invalid("offset 不能为负数。") }
                    offset = count
                case "--limit" where ["usage", "records", "prices", "limits", "api-usage"].contains(command):
                    guard let count = Int(value), (1...10_000).contains(count) else { throw CommandError.invalid("limit 必须为 1–10000。") }
                    limit = count
                default: throw CommandError.invalid("不支持的参数：\(option)。")
                }
            }
        }

        private mutating func setFilter(_ grouping: UsageGrouping, value: UsageValueFilter) throws {
            let key: WritableKeyPath<UsageFilters, UsageValueFilter>
            switch grouping {
            case .thread: key = \.thread
            case .project: key = \.project
            case .model: key = \.model
            default: key = \.day
            }
            guard filters[keyPath: key] == .all else { throw CommandError.invalid("同一维度的筛选不能重复。") }
            filters[keyPath: key] = value
        }
    }

    private static let help = """
    TokenTick — Codex 用量与成本统计

    用法：tokentick <命令> [参数]

      scan       增量采集 sessions 与 archived_sessions（含 .jsonl.zst）
      sync       采集、价格、API 与统计缓存；--scope all|local|prices|api
      usage      查询用量；--group total|day|thread|project|model，--limit 100
      records    分页查看用量明细与证据（JSON）
      rebuild    从事实表重建统计缓存；--timezone Asia/Shanghai
      prices     查看历史价格快照（JSON），--limit 100
      sync-prices 从 models.dev 同步当天价格（每天成功一次）
      reprice    按请求日期的历史价格重算分项金额
      sync-api   通过 Codex app-server 保存每日总量和额度观测
      api-usage  查看服务端每日总量缓存（当前不与本地相加）
      limits     查看已观测额度周期，百分比为最后观测值
      status     输出来源状态、统计时区、事实／缓存版本与表记录数
      --version  显示版本
      --help     显示帮助

    通用参数：--database <SQLite 路径>，--json
    scan／sync-api／sync 参数：--codex-home <Codex 数据目录>
    sync-api／sync 参数：--codex-bin <Codex 可执行文件路径>
    usage／records 参数：--from YYYY-MM-DD --through YYYY-MM-DD（含首尾日期）
                --timezone <IANA 时区> --offset 0 --account <账号 ID> 或 --unknown-account
    usage／records 组合筛选：--thread <ID> --project <名称> --model <模型> --day YYYY-MM-DD
                --search <任务标题或 ID> --sort automatic|tokens|amount|name
    未知归属：--unknown-thread／--unknown-project／--unknown-model／--unknown-date
    不同维度取交集，同一维度不能重复；排序后分页。
    limits 参数：--from YYYY-MM-DD --through YYYY-MM-DD --timezone <IANA 时区>
                --account <账号 ID> --limit-id <额度桶> --window primary|secondary
                --latest（每账号最近一次快照）--limit 100 --offset 0
    额度日期匹配与所选日期有重叠的周期，不拆分窗口或推算 token／金额。
    scan 存在解析问题时返回 1；参数错误返回 2。
    缺失价格和模式保持未知，金额单位为 nanoUSD（1 USD = 10^9 nanoUSD）。
    """
}
