import Foundation

/// SFTP packets use the same framing as the local directory worker.
struct SFTPTransport: Sendable {
    private let connection: FramedProcessConnection

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [String],
         environment: [String: String]? = nil) throws {
        connection = try FramedProcessConnection(executable: executable, arguments: arguments, environment: environment)
    }

    func exchange(_ packet: SFTPPacket, timeout: TimeInterval = 60) async throws -> SFTPPacket {
        SFTPPacket(try await connection.exchange(packet.data, timeout: timeout))
    }

    func close() async { await connection.close() }
}
