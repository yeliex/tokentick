import Foundation

/// Structured grouping metadata and error descriptions; credentials are scrubbed at the telemetry boundary.
public struct SynchronizationDiagnostic: Sendable {
    public let operation: String
    public let reason: String
    public let errorType: String?
    public let code: Int?
    public let errorMessage: String?
    public let rpcMethod: String?
    public let durationMilliseconds: Int?
    public let decodingFailure: String?
    public let count: Int?
    public let warning: Bool
    public let isCancellation: Bool

    init(operation: String, reason: String, code: Int? = nil, count: Int? = nil, warning: Bool = false, errorMessage: String? = nil) {
        self.operation = operation
        self.reason = reason
        errorType = nil
        self.errorMessage = errorMessage
        rpcMethod = nil
        durationMilliseconds = nil
        decodingFailure = nil
        self.code = code
        self.count = count
        self.warning = warning
        isCancellation = false
    }

    init(error: any Error, operation: String, warning: Bool = false, rpcMethod: String? = nil, durationMilliseconds: Int? = nil) {
        if case let CodexAPIError.rpc(_, message) = error {
            errorMessage = message ?? error.localizedDescription
        } else if error is DecodingError {
            errorMessage = String(describing: error)
        } else { errorMessage = error.localizedDescription }
        self.rpcMethod = rpcMethod
        self.durationMilliseconds = durationMilliseconds
        if let decoding = error as? DecodingError {
            switch decoding {
            case .typeMismatch: decodingFailure = "type_mismatch"
            case .valueNotFound: decodingFailure = "value_not_found"
            case .keyNotFound: decodingFailure = "key_not_found"
            case .dataCorrupted: decodingFailure = "data_corrupted"
            @unknown default: decodingFailure = "unknown"
            }
        } else { decodingFailure = nil }
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
            case .rpc(let rpcCode, _): reason = "rpc_error"; code = rpcCode
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
