import Foundation

/// Catalog pages and their continuation commit together, so interruption never skips thread metadata.
struct DeviceCatalogCollector {
    let store: UsageStore
    let device: RemoteDevice
    var maximumPages = 32

    func collect(source: any DeviceFileSource, report: inout ScanReport) async throws {
        var cursor = try store.deviceCatalogCursor(device: device.id, sourceRevision: device.sourceRevision)
        for _ in 0..<maximumPages {
            let page = try await source.catalog(after: cursor)
            try Task.checkCancellation()
            guard page.next == nil || page.next != cursor else { throw DeviceSourceFailure.invalidResponse }
            let next = page.available ? page.next : nil
            let changed = try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
                try store.updateThreadMappings(page.available ? page.mappings : [], device: device.id,
                    catalogCheckpoint: (device.sourceRevision, next))
            }
            report.catalogAvailable = page.available
            report.refreshedThreads += changed
            guard let next else { return }
            cursor = next
        }
        report.pendingMetadata = true
    }
}
