import TokenTickCore
import Darwin
import Foundation

@main
struct TokenTickCommand {
    static func main() {
        switch Array(CommandLine.arguments.dropFirst()) {
        case [], ["--help"], ["-h"]:
            print("""
            \(ApplicationInfo.name) — Codex 用量与成本统计

            用法：tokentick [--help | --version]

              --help, -h   显示帮助
              --version    显示版本

            用量采集与查询命令将在数据层实现后提供。
            """)
        case ["--version"]:
            print("\(ApplicationInfo.name) \(ApplicationInfo.version)")
        default:
            FileHandle.standardError.write(Data("不支持的命令。使用 tokentick --help 查看帮助。\n".utf8))
            exit(2)
        }
    }
}
