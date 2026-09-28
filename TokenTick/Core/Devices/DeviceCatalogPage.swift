import Foundation
import GRDB

struct DeviceCatalogPage: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let title: String?
        let projectName: String?
        let cwd: String?
    }
    let entries: [Entry]
    let desktop: DesktopProjectCatalog?
    let next: String?
    let available: Bool

    var mappings: [ThreadMapping] {
        entries.map { entry in
            ThreadMapping(threadID: entry.id.lowercased(), title: entry.title,
                projectName: desktop.map { $0.projectName(threadID: entry.id, cwd: entry.cwd) }
                    ?? DesktopProjectCatalog.nonemptyName(entry.projectName))
        }
    }

    static func read(root: URL, after: String?) throws -> Self {
        try Reader(root: root).read(after: after)
    }

    /// One source connection and desktop snapshot per collection pass; each page has its own read transaction.
    final class Reader {
        private let source: DatabaseQueue?
        private let desktop: DesktopProjectCatalog?

        init(root: URL) throws {
            // SQLite WAL and locking guarantees have not been verified for network filesystems.
            guard try root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
                throw DeviceSourceFailure.unsupported
            }
            let databases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url -> (Int, URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                return (version, url)
            }.sorted { $0.0 > $1.0 }
            guard let url = databases.first?.1 else { source = nil; desktop = nil; return }
            for file in [url, root.appendingPathComponent(".codex-global-state.json")] {
                guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    throw DeviceSourceFailure.invalidPath
                }
            }
            source = try CodexSourceDatabase.open(url, busyTimeout: 2)
            desktop = try DesktopProjectCatalog.read(codexHome: root)
        }

        deinit { try? source?.close() }

        func read(after: String?) throws -> DeviceCatalogPage {
            guard let source else { return DeviceCatalogPage(entries: [], desktop: nil, next: nil, available: false) }
            return try source.read { db in
                let columns = Set(try db.columns(in: "threads").map(\.name))
                guard columns.isSuperset(of: ["id", "title"]) else { throw DeviceSourceFailure.unsupported }
                let title = columns.contains("name") ? "COALESCE(NULLIF(t.name, ''),t.title)" : "t.title"
                let projects = try columns.contains("project_id") && db.tableExists("projects")
                if projects, try !Set(db.columns(in: "projects").map(\.name)).isSuperset(of: ["id", "name"]) {
                    throw DeviceSourceFailure.unsupported
                }
                let cwd = columns.contains("cwd") ? "t.cwd" : "NULL"
                let join = projects ? "p.name AS project_name FROM threads t LEFT JOIN projects p ON p.id=t.project_id" : "NULL AS project_name FROM threads t"
                let rows = try Row.fetchAll(db, sql: "SELECT t.id,\(title) AS title,\(cwd) AS cwd,\(join) WHERE (? IS NULL OR t.id>?) ORDER BY t.id LIMIT 513", arguments: [after, after])
                let entries = rows.prefix(512).map { Entry(id: $0["id"], title: $0["title"], projectName: $0["project_name"], cwd: $0["cwd"]) }
                return DeviceCatalogPage(entries: entries, desktop: desktop, next: rows.count > 512 ? entries.last?.id : nil, available: true)
            }
        }
    }
}
