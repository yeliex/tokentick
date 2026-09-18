import Foundation

/// Only fixed reasons and error metadata cross the telemetry boundary, never localized descriptions or userInfo.
public struct SynchronizationDiagnostic: Sendable {
    public let operation: String
    public let reason: String
    public let errorType: String?
    public let code: Int?
    public let count: Int?
    public let warning: Bool
    public let isCancellation: Bool

    init(operation: String, reason: String, code: Int? = nil, count: Int? = nil, warning: Bool = false) {
        self.operation = operation
        self.reason = reason
        errorType = nil
        self.code = code
        self.count = count
        self.warning = warning
        isCancellation = false
    }

    init(error: any Error, operation: String, warning: Bool = false) {
        count = nil
        self.warning = warning
        let nsError = error as NSError
        isCancellation = error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
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
        } else if let price = error as? PriceSynchronizer.SyncError {
            switch price {
            case .httpStatus(let status): reason = "http_status"; code = status
            case .responseTooLarge: reason = "response_too_large"
            }
        } else if let price = error as? PriceError {
            switch price {
            case .invalidRate: reason = "invalid_rate"
            case .invalidDocument: reason = "invalid_document"
            case .invalidDate: reason = "invalid_date"
            case .amountOverflow: reason = "amount_overflow"
            case .invalidUsage: reason = "invalid_usage"
            }
        } else if error is DecodingError {
            reason = "invalid_document"
        } else {
            reason = "operation_failed"
        }
        self.code = code
    }
}
