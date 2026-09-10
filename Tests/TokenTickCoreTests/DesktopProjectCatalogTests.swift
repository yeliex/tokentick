import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DesktopProjectCatalogTests {
    @Test func explicitMappingAndProjectlessOverrideDirectoryHints() throws {
        let json = #"""
        {"local-projects":{"p":{"name":"TokenTick","rootPaths":["/projects/tokentick"]}},
         "thread-project-assignments":{"assigned":{"projectKind":"local","projectId":"p"}},
         "thread-workspace-root-hints":{"worktree":"/projects/tokentick","none":"/projects/tokentick"},
         "projectless-thread-ids":["none"]}
        """#
        let catalog = try JSONDecoder().decode(DesktopProjectCatalog.self, from: Data(json.utf8))
        #expect(catalog.projectName(threadID: "assigned", cwd: "/old-path") == "TokenTick")
        #expect(catalog.projectName(threadID: "worktree", cwd: "/.codex/worktrees/123") == "TokenTick")
        #expect(catalog.projectName(threadID: "none", cwd: "/projects/tokentick") == "Chat")
        #expect(catalog.projectName(threadID: "child", cwd: "/projects/tokentick/Sources") == "TokenTick")
        #expect(catalog.projectName(threadID: "unrelated", cwd: "/projects/tokentick-other") == "tokentick-other")
    }

    @Test func ambiguousRootsStayUnknownAndDeeperRootsWin() throws {
        let json = #"""
        {"local-projects":{
          "a":{"name":"A","rootPaths":["/projects"]},
          "b":{"name":"B","rootPaths":["/projects"]},
          "c":{"name":"C","rootPaths":["/projects/nested"]}
        }}
        """#
        let catalog = try JSONDecoder().decode(DesktopProjectCatalog.self, from: Data(json.utf8))
        #expect(catalog.projectName(threadID: "t", cwd: "/projects/other") == nil)
        #expect(catalog.projectName(threadID: "t", cwd: "/projects/nested/src") == "C")
    }

    @Test func missingNamesUseProjectRootBeforeWorktreeAndProjectlessWins() throws {
        let json = #"""
        {"local-projects":{"p":{"rootPaths":["/projects/tokentick"]}},
         "thread-project-assignments":{"assigned":{"projectKind":"local","projectId":"p"}},
         "thread-workspace-root-hints":{"hinted":"/projects/shuttle"},"projectless-thread-ids":["chat"]}
        """#
        let catalog = try JSONDecoder().decode(DesktopProjectCatalog.self, from: Data(json.utf8))
        #expect(catalog.projectName(threadID: "assigned", cwd: "/.codex/worktrees/123") == "tokentick")
        #expect(catalog.projectName(threadID: "hinted", cwd: "/.codex/worktrees/456") == "shuttle")
        #expect(catalog.projectName(threadID: "child", cwd: "/projects/tokentick/Sources") == "tokentick")
        #expect(catalog.projectName(threadID: "chat", cwd: "/projects/tokentick") == "Chat")
        #expect(catalog.projectName(threadID: "missing", cwd: nil) == nil)
    }

    @Test func remoteWindowsPathsNeverMatchTheMacWorkingDirectory() throws {
        let json: [String: Any] = ["local-projects": ["p": ["name": "本机项目", "rootPaths": [FileManager.default.currentDirectoryPath]]]]
        let catalog = try JSONDecoder().decode(DesktopProjectCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(catalog.projectName(threadID: "remote", cwd: #"D:\Users\someone\Documents\GitHub\AutomaticDSP"#) == "AutomaticDSP")
        #expect(catalog.projectName(threadID: "remote", cwd: #"\\server\share\repo"#) == "repo")
        #expect(catalog.projectName(threadID: "relative", cwd: "somewhere/repo") == nil)
        #expect(DesktopProjectCatalog.folderName("D:\\") == nil)
    }

    @Test func movingThreadReassignsAllHistoryAndInvalidatesCachedProjectTotals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let source = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try source.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT); INSERT INTO threads VALUES ('t','标题','/old/worktree')")
        }
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage(dedup_key,thread_id,source,usage_date,total_tokens,evidence_json) VALUES ('one','t','local','2026-09-01',100,'{}'),('two','t','local','2026-09-02',200,'{}')")
        }
        let facts = try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage ORDER BY id") }
        for project in ["A", "B", "Chat", "A"] {
            let assignments = project == "Chat" ? [:] : ["t": ["projectKind": "local", "projectId": project]]
            let catalog: [String: Any] = [
                "local-projects": ["A": ["name": "A", "rootPaths": ["/projects/a"]], "B": ["name": "B", "rootPaths": ["/projects/b"]]],
                "thread-project-assignments": assignments,
                "thread-workspace-root-hints": ["t": "/projects/a"],
                "projectless-thread-ids": project == "Chat" ? ["t"] : []
            ]
            try JSONSerialization.data(withJSONObject: catalog).write(to: root.appendingPathComponent(".codex-global-state.json"))
            #expect(try ThreadCatalogReader().refresh(codexHome: root, store: store) == 1)
            #expect(try !store.pool.read { try UsageStore.statisticsAreCurrent($0, timezone: "UTC") })
            let query = UsageQuery(grouping: .project, timezone: "UTC")
            let direct = try store.usageReport(query)
            #expect(direct.rows.count == 1 && direct.rows[0].group == project && direct.rows[0].totalTokens == 300)
            _ = try store.rebuildStatistics(timezone: "UTC")
            #expect(try store.usageReport(query).rows == direct.rows)
            #expect(try store.usageRecords().rows.allSatisfy { $0.projectName == project })
            #expect(try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage ORDER BY id") } == facts)
            #expect(try ThreadCatalogReader().refresh(codexHome: root, store: store) == 0)
        }
    }
}
