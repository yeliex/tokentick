import Darwin
import Foundation

/// Run owned transport workers with bounded pipes; stalled network mounts cannot occupy the app's executor.
enum DeviceCommand {
    struct Result: Sendable {
        let output: Data
        let status: Int32
        // Callers classify fixed failures; remote stderr must never become product copy or telemetry.
        let diagnostic: Data
    }

    static func run(executable: URL, arguments: [String], input: Data = Data(),
                    environment: [String: String]? = nil, timeout: TimeInterval = 30,
                    outputLimit: Int = 8 * 1_024 * 1_024) async throws -> Result {
        let worker = Task.detached(priority: .utility) {
            try execute(executable: executable, arguments: arguments, input: input, environment: environment,
                        timeout: timeout, outputLimit: outputLimit)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func execute(executable: URL, arguments: [String], input: Data,
                                environment: [String: String]?, timeout: TimeInterval, outputLimit: Int) throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        let standardInput = Pipe(), standardOutput = Pipe(), standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        try? standardInput.fileHandleForReading.close()
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }
        let inputFD = standardInput.fileHandleForWriting.fileDescriptor
        let outputFD = standardOutput.fileHandleForReading.fileDescriptor
        let errorFD = standardError.fileHandleForReading.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw Failure.io }
        }
        // A peer exiting before consuming stdin is a transport failure, not a signal to terminate TokenTick.
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1 else { throw Failure.io }
        var output = Data(), diagnostic = Data()
        var inputOffset = 0
        var inputOpen = true, outputOpen = true, errorOpen = true
        let start = ContinuousClock.now
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while process.isRunning || outputOpen || errorOpen {
            try Task.checkCancellation()
            guard start.duration(to: .now) < .seconds(timeout) else { throw Failure.timeout }
            if inputOpen {
                if inputOffset == input.count {
                    try standardInput.fileHandleForWriting.close()
                    inputOpen = false
                } else {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset), min(65_536, input.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR {
                        try? standardInput.fileHandleForWriting.close()
                        inputOpen = false
                    }
                }
            }
            for isOutput in [true, false] {
                if isOutput ? !outputOpen : !errorOpen { continue }
                let count = Darwin.read(isOutput ? outputFD : errorFD, &buffer, buffer.count)
                if count == 0 {
                    if isOutput { outputOpen = false } else { errorOpen = false }
                } else if count > 0 {
                    if isOutput {
                        guard output.count <= outputLimit - count else { throw Failure.outputLimit }
                        output.append(contentsOf: buffer.prefix(count))
                    } else {
                        diagnostic.append(contentsOf: buffer.prefix(min(count, max(0, 8_192 - diagnostic.count))))
                    }
                } else if errno != EAGAIN && errno != EINTR { throw Failure.io }
            }
            var descriptors: [pollfd] = []
            if inputOpen { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
            if outputOpen { descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { descriptors.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
            _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 25) }
        }
        process.waitUntilExit()
        return Result(output: output, status: process.terminationStatus, diagnostic: diagnostic)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case timeout, outputLimit, io
        var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "The device did not respond in time. Try again when it is reachable.", bundle: .module)
            case .outputLimit: String(localized: "The device response exceeded the safe transfer limit.", bundle: .module)
            case .io: String(localized: "Unable to communicate with the device worker.", bundle: .module)
            }
        }
    }
}
