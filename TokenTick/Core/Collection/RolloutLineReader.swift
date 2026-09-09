import Foundation
import libzstd

/// 只保留固定大小的读缓冲和当前行；压缩文件的游标以解压后的字节数计。
final class RolloutLineReader {
    enum ReadError: Error, LocalizedError {
        case lineTooLarge, invalidCompression(String), truncatedCompression
        var errorDescription: String? {
            switch self {
            case .lineTooLarge: "单行超过 16 MiB，已停止该文件扫描，游标未越过该行。"
            case .invalidCompression(let reason): "Zstandard 解压失败：\(reason)"
            case .truncatedCompression: "Zstandard 文件不完整。"
            }
        }
    }

    private let handle: FileHandle
    private let stream: OpaquePointer?
    private var input = Data()
    private var inputPosition = 0
    private var chunk = Data()
    private var chunkPosition = 0
    private var frameRemaining = 0
    private var readCompressedBytes = false
    private let maximumLineBytes: Int
    private(set) var incompleteTail = Data()
    private(set) var offset: UInt64

    init(url: URL, compressed: Bool, offset: UInt64 = 0, maximumLineBytes: Int = 16 * 1_024 * 1_024) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.maximumLineBytes = maximumLineBytes
        self.offset = offset
        if compressed {
            guard let decoder = ZSTD_createDStream() else {
                throw ReadError.invalidCompression("无法创建解码器")
            }
            stream = decoder
            let result = ZSTD_initDStream(decoder)
            guard ZSTD_isError(result) == 0 else {
                ZSTD_freeDStream(decoder)
                throw ReadError.invalidCompression(String(cString: ZSTD_getErrorName(result)))
            }
            // 日志没有理由声明数 GiB 的压缩窗口；限制解码器的内存上界。
            let limit = ZSTD_DCtx_setParameter(decoder, ZSTD_d_windowLogMax, 27)
            guard ZSTD_isError(limit) == 0 else {
                ZSTD_freeDStream(decoder)
                throw ReadError.invalidCompression(String(cString: ZSTD_getErrorName(limit)))
            }
            self.offset = 0
        } else {
            stream = nil
            try handle.seek(toOffset: offset)
        }
    }

    deinit {
        if let stream { ZSTD_freeDStream(stream) }
        try? handle.close()
    }

    /// 活跃 JSONL 的未完成末行留到下次读取，不推进已提交游标。
    func nextLine() throws -> Data? {
        var line = Data()
        var lineBytes = 0
        var irrelevant = false
        while true {
            if chunkPosition == chunk.count {
                chunk = try nextChunk()
                chunkPosition = 0
                if chunk.isEmpty { incompleteTail = line; return nil }
            }
            let suffix = chunk[chunkPosition...]
            let end = suffix.firstIndex(of: 10) ?? chunk.endIndex
            lineBytes += end - chunkPosition
            if !irrelevant {
                guard line.count + end - chunkPosition <= maximumLineBytes else { throw ReadError.lineTooLarge }
                line.append(contentsOf: chunk[chunkPosition..<end])
                if Self.isIrrelevant(line) {
                    irrelevant = true
                    line.removeAll(keepingCapacity: false)
                }
            }
            if end < chunk.endIndex {
                chunkPosition = end + 1
                offset += UInt64(lineBytes + 1)
                return line
            }
            chunkPosition = end
        }
    }

    // 仅在顶层标准 envelope 前缀能明确识别时跳过正文；未知布局仍走有界 JSON 解码。
    private static let ignoredEnvelope = try? NSRegularExpression(pattern:
        #"^\s*\{\s*"timestamp"\s*:\s*"[^"\\]*"\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"(?:response_item|compacted|world_state|retained_context|inter_agent_communication|inter_agent_communication_metadata|security_risk_score|realtime_item)"\s*,\s*"payload"\s*:"#)
    private static let ignoredEvent = try? NSRegularExpression(pattern:
        #"^\s*\{\s*"timestamp"\s*:\s*"[^"\\]*"\s*,\s*(?:"ordinal"\s*:\s*\d+\s*,\s*)?"type"\s*:\s*"event_msg"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"(?!token_count")[^"]+""#)

    private static func isIrrelevant(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        let range = NSRange(prefix.startIndex..., in: prefix)
        return ignoredEnvelope?.firstMatch(in: prefix, range: range) != nil
            || ignoredEvent?.firstMatch(in: prefix, range: range) != nil
    }

    func nextChunk() throws -> Data {
        guard let stream else { return try handle.read(upToCount: 64 * 1_024) ?? Data() }
        while true {
            if inputPosition == input.count {
                input = try handle.read(upToCount: 64 * 1_024) ?? Data()
                inputPosition = 0
                if input.isEmpty {
                    guard readCompressedBytes, frameRemaining == 0 else { throw ReadError.truncatedCompression }
                    return Data()
                }
                readCompressedBytes = true
            }
            var output = Data(count: 64 * 1_024)
            var outputSize = 0
            let result = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: input.count, pos: inputPosition)
                    var outBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    inputPosition = inBuffer.pos
                    outputSize = outBuffer.pos
                    return result
                }
            }
            guard ZSTD_isError(result) == 0 else {
                throw ReadError.invalidCompression(String(cString: ZSTD_getErrorName(result)))
            }
            frameRemaining = result
            if outputSize > 0 {
                output.count = outputSize
                return output
            }
        }
    }
}
