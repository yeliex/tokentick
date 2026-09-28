import Foundation

/// SFTP v3 wire values stay independent of the remote operating system.
struct SFTPPacket: Sendable {
    static let maximumLength = 4 * 1_024 * 1_024
    private(set) var data: Data
    private var position = 0

    init(_ data: Data = Data()) { self.data = Data(data) }
    var remaining: Int { data.count - position }

    mutating func append(_ value: UInt8) { data.append(value) }
    mutating func append(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
    mutating func append(_ value: UInt64) {
        append(UInt32(truncatingIfNeeded: value >> 32))
        append(UInt32(truncatingIfNeeded: value))
    }
    mutating func append(bytes: Data) throws {
        guard bytes.count <= Self.maximumLength else { throw DeviceSourceFailure.invalidResponse }
        append(UInt32(bytes.count))
        data.append(bytes)
    }
    mutating func append(string: String) throws { try append(bytes: Data(string.utf8)) }

    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw DeviceSourceFailure.invalidResponse }
        defer { position += 1 }
        return data[position]
    }
    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw DeviceSourceFailure.invalidResponse }
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }
        return value
    }
    mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        return UInt64(high) << 32 | UInt64(try uint32())
    }
    mutating func bytes() throws -> Data {
        let count = Int(try uint32())
        guard count <= remaining else { throw DeviceSourceFailure.invalidResponse }
        defer { position += count }
        return data.subdata(in: position..<(position + count))
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else {
            throw DeviceSourceFailure.invalidResponse
        }
        return value
    }
    func framed() throws -> Data {
        guard !data.isEmpty, data.count <= Self.maximumLength else { throw DeviceSourceFailure.invalidResponse }
        var header = SFTPPacket()
        header.append(UInt32(data.count))
        return header.data + data
    }

    /// Leave fragmented frames buffered; reject oversized lengths before waiting for their body.
    static func take(from buffer: inout Data) throws -> SFTPPacket? {
        guard buffer.count >= 4 else { return nil }
        var header = SFTPPacket(Data(buffer.prefix(4)))
        let length = Int(try header.uint32())
        guard length > 0, length <= maximumLength else { throw DeviceSourceFailure.invalidResponse }
        guard buffer.count >= length + 4 else { return nil }
        let packet = SFTPPacket(Data(buffer.dropFirst(4).prefix(length)))
        buffer = Data(buffer.dropFirst(length + 4))
        return packet
    }

    static func readRequest(id: UInt32, handle: Data, offset: UInt64, count: UInt32) throws -> SFTPPacket {
        guard count > 0, count <= 32_768 else { throw DeviceSourceFailure.invalidResponse }
        var packet = SFTPPacket()
        packet.append(UInt8(5))
        packet.append(id)
        try packet.append(bytes: handle)
        packet.append(offset)
        packet.append(count)
        return packet
    }
}

struct SFTPAttributes: Sendable, Equatable {
    let size: UInt64?
    let permissions: UInt32?
    let modifiedAt: UInt32?

    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isRegularFile: Bool { permissions.map { $0 & 0o170000 == 0o100000 } ?? false }

    /// SFTP v3 has no inode identity. Permit monotonic appends between observations;
    /// the scanner separately checks committed prefix/tail evidence before resuming.
    func permitsAppend(from previous: Self) -> Bool {
        guard isRegularFile, previous.isRegularFile,
              let size, let oldSize = previous.size, size >= oldSize,
              let modifiedAt, let oldModified = previous.modifiedAt else { return false }
        return size == oldSize ? modifiedAt == oldModified : modifiedAt >= oldModified
    }

    init(packet: inout SFTPPacket) throws {
        let flags = try packet.uint32()
        guard flags & ~UInt32(0x8000000F) == 0 else { throw DeviceSourceFailure.invalidResponse }
        size = flags & 1 != 0 ? try packet.uint64() : nil
        if flags & 2 != 0 {
            _ = try packet.uint32()
            _ = try packet.uint32()
        }
        permissions = flags & 4 != 0 ? try packet.uint32() : nil
        if flags & 8 != 0 {
            _ = try packet.uint32()
            modifiedAt = try packet.uint32()
        } else { modifiedAt = nil }
        if flags & 0x80000000 != 0 {
            let count = try packet.uint32()
            // Each extension needs at least two string-length fields.
            guard count <= packet.remaining / 8 else { throw DeviceSourceFailure.invalidResponse }
            for _ in 0..<count {
                _ = try packet.bytes()
                _ = try packet.bytes()
            }
        }
    }
}
