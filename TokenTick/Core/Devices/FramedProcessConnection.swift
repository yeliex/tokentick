import Darwin
import Foundation

/// One owned process exchanges length-prefixed messages until collection ends.
actor FramedProcessConnection {
    private let maximumLength: Int
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private var buffered = Data()
    private var diagnostic = Data()
    private var closed = false
    private var exchanging = false
    private var receivedBytes: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var requests: UInt64 = 0

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [String],
         environment: [String: String]? = nil, maximumLength: Int = 4 * 1_024 * 1_024) throws {
        self.maximumLength = maximumLength
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        try process.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        for handle in [input, output, errors] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw DeviceCommand.Failure.io
            }
        }
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw DeviceCommand.Failure.io
        }
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.close()
        try? output.close()
        try? errors.close()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENTICK_SFTP_DIAGNOSTICS"] == "1" {
            let summary = "Device transfer: requests=\(requests) received=\(receivedBytes) sent=\(sentBytes)\n"
            try? FileHandle.standardError.write(contentsOf: Data(summary.utf8))
        }
        #endif
        try? input.close()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Process may finish on a different executor thread; do not block its run loop.
        while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        try? output.close()
        try? errors.close()
    }

    func exchange(_ message: Data, timeout: TimeInterval = 60) async throws -> Data {
        guard !closed, !exchanging else { throw DeviceSourceFailure.inaccessible }
        exchanging = true
        defer { exchanging = false }
        do {
            guard !message.isEmpty, message.count <= maximumLength else { throw DeviceSourceFailure.invalidResponse }
            let length = UInt32(message.count)
            let frame = Data(stride(from: 24, through: 0, by: -8).map { UInt8(truncatingIfNeeded: length >> $0) }) + message
            requests += 1
            var sent = 0
            let started = ContinuousClock.now
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                guard !closed else { throw DeviceSourceFailure.inaccessible }
                guard started.duration(to: .now) < .seconds(timeout) else { throw DeviceCommand.Failure.timeout }
                var writeFailed = false
                var madeProgress = false
                if sent < frame.count {
                    let count = frame.withUnsafeBytes {
                        Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: sent), min(65_536, frame.count - sent))
                    }
                    if count > 0 { sent += count; sentBytes += UInt64(count); madeProgress = true }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { writeFailed = true }
                }
                // Always drain stderr, even after reaching the retained diagnostic limit.
                let errorCount = Darwin.read(errors.fileDescriptor, &bytes, bytes.count)
                if errorCount > 0 {
                    diagnostic.append(contentsOf: bytes.prefix(min(errorCount, max(0, 8_192 - diagnostic.count))))
                } else if errorCount < 0 && errno != EAGAIN && errno != EINTR { throw DeviceCommand.Failure.io }
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    receivedBytes += UInt64(count)
                    guard buffered.count + count <= maximumLength + 4 else { throw DeviceCommand.Failure.outputLimit }
                    buffered.append(contentsOf: bytes.prefix(count))
                } else if count < 0 && errno != EAGAIN && errno != EINTR { throw DeviceCommand.Failure.io }
                if sent == frame.count, let response = try takeMessage() { return response }
                if count == 0 || writeFailed { throw classifiedFailure() }
                if !madeProgress && count < 0 && errorCount <= 0 {
                    // Wait for pipe readiness off the cooperative executor; cancellation is checked at most 100 ms later.
                    let inputFD = sent < frame.count ? input.fileDescriptor : -1
                    let outputFD = output.fileDescriptor
                    let errorFD = errorCount == 0 ? -1 : errors.fileDescriptor
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            var descriptors = [pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0),
                                               pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
                                               pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)]
                            _ = poll(&descriptors, nfds_t(descriptors.count), 100)
                            continuation.resume()
                        }
                    }
                }
            }
        } catch {
            // Once interrupted, packet boundaries are uncertain. A later request must reconnect.
            await close()
            throw error
        }
    }

    private func takeMessage() throws -> Data? {
        guard buffered.count >= 4 else { return nil }
        let length = buffered.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumLength else { throw DeviceSourceFailure.invalidResponse }
        guard buffered.count >= Int(length) + 4 else { return nil }
        let result = Data(buffered.dropFirst(4).prefix(Int(length)))
        buffered = Data(buffered.dropFirst(Int(length) + 4))
        return result
    }

    private func classifiedFailure() -> DeviceSourceFailure {
        let text = String(decoding: diagnostic, as: UTF8.self).lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return .hostVerification
        }
        if text.contains("permission denied") || text.contains("authentication failed") { return .authentication }
        if text.contains("cannot execute command-line and remote command") || text.contains("bad configuration option") {
            return .configuration
        }
        return .inaccessible
    }
}
