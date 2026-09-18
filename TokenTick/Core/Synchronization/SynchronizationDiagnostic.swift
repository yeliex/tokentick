import Foundation

/// Only fixed reasons and error metadata cross the telemetry boundary, never localized descriptions or userInfo.
public struct SynchronizationDiagnostic: Sendable {
    public let operation: String
    public let reason: String
    public let errorType: String?
    public let code: Int?

    init(operation: String, reason: String) {
        self.operation = operation
        self.reason = reason
        errorType = nil
        code = nil
    }

    init(error: any Error, operation: String) {
        self.operation = operation
        errorType = String(reflecting: type(of: error))
        var code = (error as NSError).code
        if let api = error as? CodexAPIError {
            switch api {
            case .missingExecutable: reason = "missing_executable"
            case .timeout: reason = "timeout"
            case .processExited: reason = "process_exited"
            case .invalidResponse: reason = "invalid_response"
            case .oversizedResponse: reason = "oversized_response"
            case .rpc(let rpcCode): reason = "rpc_error"; code = rpcCode
            case .invalidStatistics: reason = "invalid_statistics"
            }
        } else {
            reason = "operation_failed"
        }
        self.code = code
    }
}
