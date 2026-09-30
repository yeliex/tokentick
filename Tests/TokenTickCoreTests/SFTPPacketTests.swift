import Foundation
import Testing
@testable import TokenTickCore

struct SFTPPacketTests {
    @Test func rangeRequestPreservesLargeOffsetAndOpaqueHandle() throws {
        let handle = Data([0, 255, 128, 10])
        var packet = try SFTPPacket.readRequest(id: 17, handle: handle, offset: 0x100000123, count: 4096)
        #expect(try packet.byte() == 5)
        #expect(try packet.uint32() == 17)
        #expect(try packet.bytes() == handle)
        #expect(try packet.uint64() == 0x100000123)
        #expect(try packet.uint32() == 4096)
        #expect(packet.remaining == 0)
    }

    @Test func fragmentedAndCoalescedFrames() throws {
        var first = SFTPPacket()
        first.append(UInt8(2))
        first.append(UInt32(3))
        let frame = try first.framed()
        var buffer = Data()
        for byte in frame.dropLast() {
            buffer.append(byte)
            #expect(try SFTPPacket.take(from: &buffer) == nil)
        }
        buffer.append(frame.last!)
        buffer.append(frame)
        #expect(try SFTPPacket.take(from: &buffer)?.data == first.data)
        #expect(try SFTPPacket.take(from: &buffer)?.data == first.data)
        #expect(buffer.isEmpty)
    }

    @Test func malformedLengthsAndTruncatedFieldsAreRejected() throws {
        for bytes: [UInt8] in [[0, 0, 0, 0], [255, 255, 255, 255]] {
            var buffer = Data(bytes)
            #expect(throws: DeviceSourceFailure.invalidResponse) { try SFTPPacket.take(from: &buffer) }
        }
        var truncated = SFTPPacket(Data([0, 0, 0, 8, 1]))
        #expect(throws: DeviceSourceFailure.invalidResponse) { try truncated.bytes() }
        var invalidUTF8 = SFTPPacket(Data([0, 0, 0, 1, 255]))
        #expect(throws: DeviceSourceFailure.invalidResponse) { try invalidUTF8.string() }
        #expect(throws: DeviceSourceFailure.invalidResponse) {
            try SFTPPacket.readRequest(id: 1, handle: Data(), offset: 0, count: 32_769)
        }
    }
}

extension SFTPPacketTests {
    @Test func attributesConsumeUnknownExtensionsWithoutLosingNextEntry() throws {
        var packet = SFTPPacket()
        packet.append(UInt32(0x8000000F))
        packet.append(UInt64(5_000_000_000))
        packet.append(UInt32(1000))
        packet.append(UInt32(1000))
        packet.append(UInt32(0o100600))
        packet.append(UInt32(10))
        packet.append(UInt32(20))
        packet.append(UInt32(1))
        try packet.append(string: "future@example.test")
        try packet.append(bytes: Data([255, 0]))
        packet.append(UInt8(42))
        let attributes = try SFTPAttributes(packet: &packet)
        #expect(attributes.size == 5_000_000_000)
        #expect(attributes.modifiedAt == 20)
        #expect(attributes.isRegularFile)
        #expect(!attributes.isDirectory)
        #expect(try packet.byte() == 42)
    }

    @Test func absentAttributesStayUnknownAndInvalidExtensionCountFails() throws {
        var empty = SFTPPacket(Data([0, 0, 0, 0]))
        let attributes = try SFTPAttributes(packet: &empty)
        #expect(attributes.size == nil)
        #expect(attributes.modifiedAt == nil)
        #expect(!attributes.isRegularFile)
        var invalid = SFTPPacket(Data([128, 0, 0, 0, 255, 255, 255, 255]))
        #expect(throws: DeviceSourceFailure.invalidResponse) { try SFTPAttributes(packet: &invalid) }
    }
}


extension SFTPPacketTests {
    @Test func appendObservationsRejectTruncationRewriteAndClockRegression() throws {
        func attributes(_ size: UInt64, _ modified: UInt32, regular: Bool = true) throws -> SFTPAttributes {
            var packet = SFTPPacket()
            packet.append(UInt32(13))
            packet.append(size)
            packet.append(UInt32(regular ? 0o100600 : 0o040700))
            packet.append(modified)
            packet.append(modified)
            return try SFTPAttributes(packet: &packet)
        }
        let baseline = try attributes(100, 10)
        #expect(try attributes(100, 10).permitsAppend(from: baseline))
        #expect(try attributes(101, 10).permitsAppend(from: baseline))
        #expect(try attributes(102, 11).permitsAppend(from: baseline))
        #expect(try !attributes(99, 11).permitsAppend(from: baseline))
        #expect(try !attributes(100, 11).permitsAppend(from: baseline))
        #expect(try !attributes(101, 9).permitsAppend(from: baseline))
        #expect(try !attributes(101, 11, regular: false).permitsAppend(from: baseline))
        var empty = SFTPPacket(Data([0, 0, 0, 0]))
        #expect(try !SFTPAttributes(packet: &empty).permitsAppend(from: baseline))
    }
}
