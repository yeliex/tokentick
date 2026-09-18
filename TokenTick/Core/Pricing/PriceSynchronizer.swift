import Foundation

public struct PriceSynchronizer: Sendable {
    public let store: UsageStore
    public init(store: UsageStore) { self.store = store }

    public func synchronize() async throws -> PriceSyncReport {
        let requestedDate = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        if try store.hasSyncedPrices(on: requestedDate) {
            return PriceSyncReport(date: requestedDate, alreadySynced: true, models: 0, insertedSnapshots: 0, unsupportedContextModels: [], missingPriceModels: [])
        }
        guard let url = URL(string: ModelsDevPrices.sourceURL) else { throw PriceError.invalidDocument }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("TokenTick/\(ApplicationInfo.version)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let maximum = 32 * 1_024 * 1_024
        guard response.expectedContentLength <= maximum else { throw SyncError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maximum else { throw SyncError.responseTooLarge }
            data.append(byte)
        }
        let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let prices = try ModelsDevPrices.decode(data, date: date)
        return try store.savePrices(prices, date: date)
    }

    enum SyncError: LocalizedError {
        case httpStatus(Int), responseTooLarge
        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): String(localized: "The models.dev request failed (HTTP \(code)). Existing prices were kept.", bundle: .module)
            case .responseTooLarge: String(localized: "The price response exceeds 32 MiB. The snapshot was not updated.", bundle: .module)
            }
        }
    }
}
