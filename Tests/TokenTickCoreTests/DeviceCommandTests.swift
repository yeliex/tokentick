import Foundation
import Testing
@testable import TokenTickCore

struct DeviceCommandTests {
    @Test func drainsOutputWhileSendingLargeInput() async throws {
        let input = Data(repeating: 65, count: 2 * 1_024 * 1_024)
        let result = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: input)
        #expect(result.status == 0)
        #expect(result.output == input)
    }

    @Test func boundsOutputAndTimeout() async throws {
        await #expect(throws: DeviceCommand.Failure.outputLimit) {
            _ = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], outputLimit: 1_024)
        }
        await #expect(throws: DeviceCommand.Failure.timeout) {
            _ = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        }
    }

    @Test func cancellationTerminatesOnlyOwnedWorker() async throws {
        let task = Task {
            try await DeviceCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let next = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        #expect(next.status == 0)
    }
}
