import Foundation
import GRDB

extension UsageStore {
    func incrementalManifestDirectories(device: RemoteDevice, root: String, now: Date = Date()) throws -> [String]? {
        try pool.read { db in
            let key = "device_full_manifest:\(device.id):\(device.sourceRevision)"
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [key]),
                  let timestamp = TimeInterval(value), now.timeIntervalSince1970 >= timestamp,
                  now.timeIntervalSince1970 - timestamp < 1_800 else { return nil }
            let paths = try String.fetchAll(db, sql: "SELECT current_path FROM scan_files WHERE device=? AND source_revision=?",
                                            arguments: [device.id, device.sourceRevision])
            let prefix = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
            var directories = Set<String>()
            for path in paths {
                guard path.hasPrefix(prefix) else { return nil }
                directories.insert((String(path.dropFirst(prefix.count)) as NSString).deletingLastPathComponent)
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            for day in -7...1 {
                let date = calendar.date(byAdding: .day, value: day, to: now)!
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                directories.insert(String(format: "sessions/%04d/%02d/%02d", components.year!, components.month!, components.day!))
            }
            // Keep the worker request bounded; a large path set uses the full traversal instead.
            let selected = directories.sorted()
            return try JSONEncoder().encode(selected).count <= 32_768 ? selected : nil
        }
    }

    func recordFullDeviceManifest(_ device: RemoteDevice, at date: Date? = Date()) throws {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                let key = "device_full_manifest:\(device.id):\(device.sourceRevision)"
                guard let date else {
                    try db.execute(sql: "DELETE FROM app_metadata WHERE key=?", arguments: [key])
                    return
                }
                try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [key, String(date.timeIntervalSince1970)])
                try db.execute(sql: """
                    UPDATE app_metadata SET value='complete' WHERE key='weekly_cycles_rebuild' AND value='pending'
                    AND NOT EXISTS (SELECT 1 FROM scan_files
                        WHERE COALESCE(json_extract(parser_state_json,'$.version'),0)<>?
                           OR COALESCE(json_extract(file_state_json,'$.completed'),0)<>1)
                    """, arguments: [RolloutParserState.currentVersion])
            }
        }
    }

    func recordDeviceCollectionComplete(_ device: RemoteDevice) throws {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: ["device_collection_complete:\(device.id):\(device.sourceRevision)", String(Date().timeIntervalSince1970)])
            }
        }
    }

    public func deviceCoverageGaps(_ configuration: DeviceConfiguration) throws -> [String] {
        try pool.read { db in
            let keys = Set(try String.fetchAll(db, sql: "SELECT key FROM app_metadata WHERE key LIKE 'device_collection_complete:%'"))
            let active = configuration.devices.filter {
                !keys.contains("device_collection_complete:\($0.id):\($0.sourceRevision)")
            }.map(\.id)
            let removed = configuration.removedNames.keys.filter { id in
                !keys.contains(where: { $0.hasPrefix("device_collection_complete:\(id):") })
            }.sorted()
            return active + removed
        }
    }

    public func deviceCollectionDates(_ configuration: DeviceConfiguration) throws -> [String: Date] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key,value FROM app_metadata WHERE key LIKE 'device_collection_complete:%'")
            let values = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["key"] as String, row["value"] as String)
            })
            return Dictionary(uniqueKeysWithValues: configuration.devices.compactMap { device in
                guard let value = values["device_collection_complete:\(device.id):\(device.sourceRevision)"],
                      let timestamp = TimeInterval(value), timestamp.isFinite else { return nil }
                return (device.id, Date(timeIntervalSince1970: timestamp))
            })
        }
    }

    /// Retaining history preserves every collected row and checkpoint.
    public func removeDeviceData(device: String, deleteUsage: Bool) throws {
        guard UUID(uuidString: device) != nil else { throw DeviceConfigurationError.invalidConfiguration }
        guard deleteUsage else { return }
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                try db.execute(sql: "DELETE FROM scan_files WHERE device=?", arguments: [device])
                let prefix = "fast_trace_cursor:\(device):"
                try db.execute(sql: "DELETE FROM app_metadata WHERE substr(key,1,?)=?", arguments: [prefix.count, prefix])
                let catalogPrefix = "device_catalog_cursor:\(device):"
                try db.execute(sql: "DELETE FROM app_metadata WHERE substr(key,1,?)=?", arguments: [catalogPrefix.count, catalogPrefix])
                let manifestPrefix = "device_full_manifest:\(device):"
                try db.execute(sql: "DELETE FROM app_metadata WHERE substr(key,1,?)=?", arguments: [manifestPrefix.count, manifestPrefix])
                try db.execute(sql: "DELETE FROM usage WHERE device=?", arguments: [device])
                // Another source may hold the same events. Replay its facts instead of permanently hiding copies.
                try db.execute(sql: "UPDATE scan_files SET parser_state_json=NULL")
                // Remaining sources must replay copies before complete coverage can be established again.
                let idOffset = "device_collection_complete:".count + 1
                try db.execute(sql: """
                    DELETE FROM app_metadata WHERE key LIKE 'device_collection_complete:%'
                    AND (substr(key,?,36)=? OR substr(key,?,36) IN (SELECT device FROM scan_files))
                    """, arguments: [idOffset, device, idOffset])
                try db.execute(sql: "DELETE FROM threads WHERE device=?", arguments: [device])
            }
        }
    }
}
