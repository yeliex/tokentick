import Foundation
import Testing
@testable import TokenTickCore

struct SFTPTransportTests {
    @Test func keepsInputOpenAcrossExchanges() async throws {
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        for id: UInt32 in [1, 2, 3] {
            let packet = try SFTPPacket.readRequest(id: id, handle: Data([255, 0]), offset: UInt64(id) * 5_000_000_000, count: 4096)
            let response = try await transport.exchange(packet, timeout: 2)
            #expect(response.data == packet.data)
        }
        await transport.close()
    }

    @Test func timeoutClosesConnection() async throws {
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        let packet = SFTPPacket(Data([1, 0, 0, 0, 3]))
        await #expect(throws: DeviceCommand.Failure.timeout) { try await transport.exchange(packet, timeout: 0.05) }
        await #expect(throws: DeviceSourceFailure.inaccessible) { try await transport.exchange(packet) }
    }

    @Test func cancellationClosesOnlyOwnedConnection() async throws {
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        let task = Task { try await transport.exchange(SFTPPacket(Data([1, 0, 0, 0, 3]))) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let other = try SFTPTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let packet = SFTPPacket(Data([1, 0, 0, 0, 3]))
        #expect(try await other.exchange(packet).data == packet.data)
        await other.close()
    }
}
