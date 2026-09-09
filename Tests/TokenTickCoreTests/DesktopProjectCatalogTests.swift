import Foundation
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
        #expect(catalog.projectName(threadID: "none", cwd: "/projects/tokentick") == nil)
        #expect(catalog.projectName(threadID: "child", cwd: "/projects/tokentick/Sources") == "TokenTick")
        #expect(catalog.projectName(threadID: "unrelated", cwd: "/projects/tokentick-other") == nil)
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
}
