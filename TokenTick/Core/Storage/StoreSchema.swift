import Foundation
import GRDB

enum StoreSchema {
    static let tables = ["threads", "scan_files", "prices", "usage", "api_daily_usage", "limit_windows", "statistics"]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.initial") { db in
            try db.execute(sql: """
                CREATE TABLE threads (
                    thread_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT,
                    project_name TEXT
                );
                CREATE TABLE scan_files (
                    rollout_id TEXT PRIMARY KEY NOT NULL,
                    thread_id TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    current_path TEXT,
                    scanned_line INTEGER NOT NULL DEFAULT 0 CHECK (scanned_line >= 0),
                    scanned_offset INTEGER NOT NULL DEFAULT 0 CHECK (scanned_offset >= 0),
                    last_scanned_at REAL,
                    file_state_json TEXT,
                    parser_state_json TEXT
                );
                CREATE TABLE prices (
                    model TEXT NOT NULL,
                    date TEXT NOT NULL,
                    input_price TEXT,
                    output_price TEXT,
                    cache_read_price TEXT,
                    cache_write_price TEXT,
                    fast_input_price TEXT,
                    fast_output_price TEXT,
                    fast_cache_read_price TEXT,
                    fast_cache_write_price TEXT,
                    long_input_price TEXT,
                    long_output_price TEXT,
                    long_cache_read_price TEXT,
                    long_cache_write_price TEXT,
                    fast_long_input_price TEXT,
                    fast_long_output_price TEXT,
                    fast_long_cache_read_price TEXT,
                    fast_long_cache_write_price TEXT,
                    long_context_threshold INTEGER,
                    source_json TEXT NOT NULL,
                    PRIMARY KEY (model, date)
                );
                CREATE TABLE usage (
                    id INTEGER PRIMARY KEY,
                    dedup_key TEXT NOT NULL UNIQUE,
                    account_id TEXT,
                    thread_id TEXT,
                    turn_id TEXT,
                    request_id TEXT,
                    response_id TEXT,
                    occurred_at REAL,
                    usage_date TEXT,
                    model TEXT,
                    is_fast INTEGER CHECK (is_fast IN (0, 1)),
                    is_long_context INTEGER CHECK (is_long_context IN (0, 1)),
                    input_tokens INTEGER CHECK (input_tokens >= 0),
                    output_tokens INTEGER CHECK (output_tokens >= 0),
                    cache_read_tokens INTEGER CHECK (cache_read_tokens >= 0),
                    cache_write_tokens INTEGER CHECK (cache_write_tokens >= 0),
                    reasoning_tokens INTEGER CHECK (reasoning_tokens >= 0),
                    total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
                    input_price TEXT,
                    output_price TEXT,
                    cache_read_price TEXT,
                    cache_write_price TEXT,
                    input_amount INTEGER CHECK (input_amount >= 0),
                    output_amount INTEGER CHECK (output_amount >= 0),
                    cache_read_amount INTEGER CHECK (cache_read_amount >= 0),
                    cache_write_amount INTEGER CHECK (cache_write_amount >= 0),
                    amount INTEGER CHECK (amount >= 0),
                    source TEXT NOT NULL CHECK (source IN ('local', 'api')),
                    rollout_id TEXT,
                    source_line INTEGER,
                    evidence_json TEXT NOT NULL,
                    CHECK (occurred_at IS NOT NULL OR usage_date IS NOT NULL)
                );
                CREATE INDEX usage_thread_time ON usage(thread_id, occurred_at);
                CREATE INDEX usage_account_time ON usage(account_id, occurred_at);
                CREATE INDEX usage_model_time ON usage(model, occurred_at);
                CREATE INDEX scan_files_thread ON scan_files(thread_id);
                CREATE TABLE api_daily_usage (
                    account_id TEXT NOT NULL,
                    start_date TEXT NOT NULL,
                    tokens INTEGER NOT NULL CHECK (tokens >= 0),
                    fetched_at REAL NOT NULL,
                    PRIMARY KEY (account_id, start_date)
                );
                CREATE TABLE limit_windows (
                    account_id TEXT NOT NULL,
                    limit_id TEXT NOT NULL,
                    window_kind TEXT NOT NULL,
                    resets_at INTEGER NOT NULL,
                    window_duration_mins INTEGER NOT NULL CHECK (window_duration_mins > 0),
                    starts_at INTEGER NOT NULL,
                    used_percent REAL NOT NULL CHECK (used_percent >= 0),
                    last_observed_at REAL NOT NULL,
                    source_json TEXT NOT NULL,
                    tokens INTEGER,
                    input_amount INTEGER,
                    output_amount INTEGER,
                    cache_read_amount INTEGER,
                    cache_write_amount INTEGER,
                    unpriced_tokens INTEGER,
                    PRIMARY KEY (account_id, limit_id, window_kind, resets_at)
                );
                CREATE TABLE statistics (
                    account_key TEXT NOT NULL,
                    date TEXT NOT NULL,
                    timezone TEXT NOT NULL,
                    dimension TEXT NOT NULL,
                    dimension_value TEXT NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    cache_write_tokens INTEGER,
                    reasoning_tokens INTEGER,
                    input_amount INTEGER,
                    output_amount INTEGER,
                    cache_read_amount INTEGER,
                    cache_write_amount INTEGER,
                    complete_amount INTEGER,
                    unpriced_tokens INTEGER NOT NULL,
                    unattributed_tokens INTEGER NOT NULL,
                    record_count INTEGER NOT NULL,
                    PRIMARY KEY (account_key, date, timezone, dimension, dimension_value)
                );
                CREATE TABLE app_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2.usage-dedup-alias") { db in
            try db.execute(sql: """
                CREATE INDEX usage_legacy_alias ON usage(json_extract(evidence_json, '$.legacyKey'))
                WHERE source = 'local';
                """)
        }
        migrator.registerMigration("v3.statistics-cache") { db in
            try db.execute(sql: """
                ALTER TABLE statistics ADD COLUMN known_amount INTEGER;
                ALTER TABLE statistics ADD COLUMN unpriced_records INTEGER NOT NULL DEFAULT 0;
                DELETE FROM statistics;
                INSERT INTO app_metadata(key, value) VALUES ('statistics_revision', '0');
                INSERT INTO app_metadata(key, value) VALUES ('statistics_timezone', ?);
                INSERT INTO app_metadata(key, value) VALUES ('statistics_dirty', 'true')
                    ON CONFLICT(key) DO UPDATE SET value = 'true';
                """, arguments: [TimeZone.current.identifier])
            // 失效跟随事实事务提交，后续采集入口不会因忘记通知 UI 而留下旧缓存。
            for (name, event) in [("insert", "INSERT"), ("update", "UPDATE"), ("delete", "DELETE")] {
                try db.execute(sql: """
                    CREATE TRIGGER usage_statistics_\(name) AFTER \(event) ON usage BEGIN
                        UPDATE app_metadata SET value = CAST(value AS INTEGER) + 1 WHERE key = 'statistics_revision';
                        INSERT INTO app_metadata(key, value) VALUES ('statistics_dirty', 'true')
                            ON CONFLICT(key) DO UPDATE SET value = 'true';
                    END;
                    """)
            }
            for (name, event, condition) in [
                ("insert", "INSERT", "NEW.project_name IS NOT NULL"),
                ("update", "UPDATE OF project_name", "OLD.project_name IS NOT NEW.project_name"),
                ("delete", "DELETE", "OLD.project_name IS NOT NULL")
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER thread_statistics_\(name) AFTER \(event) ON threads WHEN \(condition) BEGIN
                        UPDATE app_metadata SET value = CAST(value AS INTEGER) + 1 WHERE key = 'statistics_revision';
                        INSERT INTO app_metadata(key, value) VALUES ('statistics_dirty', 'true')
                            ON CONFLICT(key) DO UPDATE SET value = 'true';
                    END;
                    """)
            }
        }
        migrator.registerMigration("v4.statistics-recovery") { db in
            // 内部暂存允许同一维度跨批次重复，只有发布时才合并进正式缓存。
            try db.execute(sql: """
                CREATE TABLE statistics_rebuild AS SELECT
                    account_key, date, timezone, dimension, dimension_value, total_tokens, input_tokens,
                    output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, input_amount,
                    output_amount, cache_read_amount, cache_write_amount, complete_amount, unpriced_tokens,
                    unattributed_tokens, record_count, known_amount, unpriced_records
                FROM statistics WHERE 0;
                CREATE INDEX statistics_rebuild_timezone ON statistics_rebuild(timezone);
                """)
        }
        return migrator
    }
}
