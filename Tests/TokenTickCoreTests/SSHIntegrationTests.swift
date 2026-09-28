import Foundation
import Testing
@testable import TokenTickCore

struct SSHIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_SSH_CONFIG"] != nil))
    func containerSupportsInitialScanAppendRestartAndProjectChanges() async throws {
        let config = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_SSH_CONFIG"])
        let arguments = ["-F", config, "fixture"]
        func node(_ script: String) async throws {
            let result = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments + ["node -"], input: Data(script.utf8), timeout: 30)
            try #require(result.status == 0, "Fixture setup failed: \(String(decoding: result.diagnostic, as: UTF8.self))")
        }
        try await node(#"""
        const fs = require('node:fs');
        const { DatabaseSync } = require('node:sqlite');
        const root = '/root/.codex';
        const file = root + '/sessions/rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl';
        const header = {timestamp:'2026-09-09T00:00:00Z',type:'session_meta',payload:{id:'00000000-0000-0000-0000-000000000001'}};
        const turn = {type:'turn_context',payload:{turn_id:'turn-1',model:'gpt-test'}};
        const usage = {timestamp:'2026-09-09T00:00:01Z',type:'token_usage_record',payload:{thread_id:header.payload.id,turn_id:'turn-1',response_id:'one',usage:{input_tokens:100,output_tokens:20,total_tokens:120},thread_token_usage:{input_tokens:100,output_tokens:20,total_tokens:120}}};
        fs.writeFileSync(file,[header,turn,usage].map(JSON.stringify).join('\n')+'\n');
        const db = new DatabaseSync(root+'/state_5.sqlite');
        db.exec("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,project_id TEXT); CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT); INSERT INTO projects VALUES ('p','First'); INSERT INTO threads VALUES ('00000000-0000-0000-0000-000000000001','Task','p')");
        db.close();
        """#)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite"))
        let device = RemoteDevice(name: "Container", connection: .ssh(host: "fixture", user: nil, port: nil, codexHome: "/root/.codex"))
        let service = DeviceSyncService(store: store, executable: Bundle.main.executableURL!,
            sshConfiguration: URL(fileURLWithPath: config))
        let beforeTest = try store.tableCounts()
        let connection = try await service.test(device)
        #expect(connection.root == "/root/.codex")
        #expect(try store.tableCounts() == beforeTest)
        var configuration = DeviceConfiguration()
        configuration.devices = [device]
        #expect(try store.deviceCollectionDates(configuration).isEmpty)
        let first = try await service.synchronize(device)
        #expect(first.dataChanged)
        #expect(first.scan?.insertedRequests == 1 && first.scan?.issueCount == 0)
        #expect(try store.threadInfo(ids: ["00000000-0000-0000-0000-000000000001"]).values.first?.projectName == "First")
        try await node(#"""
        const fs=require('node:fs'),{DatabaseSync}=require('node:sqlite');
        const file='/root/.codex/sessions/rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl';
        const row=JSON.parse(fs.readFileSync(file,'utf8').trim().split('\n').at(-1));
        row.payload.response_id='two'; row.payload.thread_token_usage={input_tokens:200,output_tokens:40,total_tokens:240};
        fs.appendFileSync(file,JSON.stringify(row)+'\n');
        const db=new DatabaseSync('/root/.codex/state_5.sqlite');db.exec('UPDATE threads SET project_id=NULL');db.close();
        """#)
        let second = try await service.synchronize(device)
        #expect(second.scan?.insertedRequests == 1 && second.scan?.duplicateRequests == 0)
        let beforeRepeatTest = try store.tableCounts()
        let completionBeforeTest = try store.deviceCollectionDates(configuration)
        _ = try await service.test(device)
        #expect(try store.tableCounts() == beforeRepeatTest)
        #expect(try store.deviceCollectionDates(configuration) == completionBeforeTest)
        let unchanged = try await service.synchronize(device)
        #expect(unchanged.scan?.unchangedFiles == 1 && !unchanged.dataChanged)
        #expect(try store.threadInfo(ids: ["00000000-0000-0000-0000-000000000001"]).values.first?.projectName == nil)
        #expect(try store.usageRecords().rows.count == 2)
        try await node(#"""
        const fs=require('node:fs'),{zstdCompressSync}=require('node:zlib');
        const file='/root/.codex/sessions/rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl';
        fs.writeFileSync(file+'.zst',zstdCompressSync(fs.readFileSync(file)));fs.unlinkSync(file);
        """#)
        let compressed = try await service.synchronize(device)
        #expect(compressed.scan?.duplicateRequests == 2 && compressed.scan?.issueCount == 0)
        #expect(try await service.synchronize(device).scan?.unchangedFiles == 1)
        #expect(try store.usageRecords().rows.count == 2)
    }
}
