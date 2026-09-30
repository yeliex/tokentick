import Foundation

/// Sequential SFTP v3 requests with opaque server handles and bounded range reads.
actor SFTPClient {
    struct Entry: Sendable {
        let name: String
        let attributes: SFTPAttributes
    }
    struct Status: Error, Sendable, Equatable, LocalizedError {
        let code: UInt32
        var errorDescription: String? {
            switch code {
            case 5: DeviceSourceFailure.invalidResponse.errorDescription
            case 8: DeviceSourceFailure.unsupported.errorDescription
            default: DeviceSourceFailure.inaccessible.errorDescription
            }
        }
    }

    private let transport: SFTPTransport
    private var nextID: UInt32 = 0
    private var initialized = false
    private var busy = false

    init(transport: SFTPTransport) { self.transport = transport }
    func close() async { await transport.close() }

    func realpath(_ path: String) async throws -> String {
        let (_, packet) = try await request(type: 16, expected: 104) { try $0.append(string: path) }
        var response = packet
        guard try response.uint32() == 1 else { throw DeviceSourceFailure.invalidResponse }
        let result = try response.string()
        _ = try response.bytes()
        _ = try SFTPAttributes(packet: &response)
        guard response.remaining == 0, !result.isEmpty else { throw DeviceSourceFailure.invalidResponse }
        return result
    }

    func stat(_ path: String, followLinks: Bool = true) async throws -> SFTPAttributes {
        let (_, packet) = try await request(type: followLinks ? 17 : 7, expected: 105) { try $0.append(string: path) }
        var response = packet
        let attributes = try SFTPAttributes(packet: &response)
        guard response.remaining == 0 else { throw DeviceSourceFailure.invalidResponse }
        return attributes
    }

    func attributes(_ handle: Data) async throws -> SFTPAttributes {
        let (_, packet) = try await request(type: 8, expected: 105) { try $0.append(bytes: handle) }
        var response = packet
        let attributes = try SFTPAttributes(packet: &response)
        guard response.remaining == 0 else { throw DeviceSourceFailure.invalidResponse }
        return attributes
    }

    func open(_ path: String, directory: Bool = false) async throws -> Data {
        let (_, packet) = try await request(type: directory ? 11 : 3, expected: 102) {
            try $0.append(string: path)
            if !directory {
                $0.append(UInt32(1)) // SSH_FXF_READ; never create or modify source files.
                $0.append(UInt32(0))
            }
        }
        var response = packet
        let handle = try response.bytes()
        guard response.remaining == 0, handle.count <= 256 else { throw DeviceSourceFailure.invalidResponse }
        return handle
    }

    func closeHandle(_ handle: Data) async throws {
        _ = try await request(type: 4, expected: 101) { try $0.append(bytes: handle) }
    }

    func read(_ handle: Data, offset: UInt64, count: UInt32) async throws -> Data {
        guard count > 0, count <= 131_072 else { throw DeviceSourceFailure.invalidResponse }
        do {
            let (_, packet) = try await request(type: 5, expected: 103) {
                try $0.append(bytes: handle)
                $0.append(offset)
                $0.append(count)
            }
            var response = packet
            let bytes = try response.bytes()
            guard response.remaining == 0, !bytes.isEmpty, bytes.count <= count else { throw DeviceSourceFailure.invalidResponse }
            return bytes
        } catch let status as Status where status.code == 1 { return Data() }
    }

    func entries(_ handle: Data) async throws -> [Entry]? {
        do {
            let (_, packet) = try await request(type: 12, expected: 104) { try $0.append(bytes: handle) }
            var response = packet
            let count = try response.uint32()
            guard count > 0, count <= response.remaining / 12 else { throw DeviceSourceFailure.invalidResponse }
            var entries: [Entry] = []
            for _ in 0..<count {
                let name = try response.string()
                _ = try response.bytes()
                entries.append(Entry(name: name, attributes: try SFTPAttributes(packet: &response)))
            }
            guard response.remaining == 0 else { throw DeviceSourceFailure.invalidResponse }
            return entries
        } catch let status as Status where status.code == 1 { return nil }
    }

    private func request(type: UInt8, expected: UInt8,
                         body: @Sendable (inout SFTPPacket) throws -> Void) async throws -> (UInt8, SFTPPacket) {
        guard !busy else { throw DeviceSourceFailure.inaccessible }
        busy = true
        defer { busy = false }
        if !initialized {
            var hello = SFTPPacket()
            hello.append(UInt8(1))
            hello.append(UInt32(3))
            var response = try await transport.exchange(hello)
            guard try response.byte() == 2, try response.uint32() == 3 else { throw DeviceSourceFailure.unsupported }
            while response.remaining > 0 {
                _ = try response.bytes()
                _ = try response.bytes()
            }
            initialized = true
        }
        nextID &+= 1
        let id = nextID
        var packet = SFTPPacket()
        packet.append(type)
        packet.append(id)
        try body(&packet)
        var response = try await transport.exchange(packet)
        let responseType = try response.byte()
        guard try response.uint32() == id else {
            await transport.close()
            throw DeviceSourceFailure.invalidResponse
        }
        if responseType == 101 {
            let code = try response.uint32()
            _ = try response.bytes() // Remote diagnostic text is not exposed in UI or telemetry.
            _ = try response.bytes()
            guard response.remaining == 0 else { throw DeviceSourceFailure.invalidResponse }
            if code != 0 {
                #if DEBUG
                if ProcessInfo.processInfo.environment["TOKENTICK_SFTP_DIAGNOSTICS"] == "1", !(code == 1 && (type == 5 || type == 12)) {
                    try? FileHandle.standardError.write(contentsOf: Data("SFTP request \(type), status \(code)\n".utf8))
                }
                #endif
                throw Status(code: code)
            }
        }
        guard responseType == expected else { throw DeviceSourceFailure.invalidResponse }
        return (responseType, response)
    }
}
