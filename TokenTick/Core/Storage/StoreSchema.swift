import Foundation
import GRDB

enum StoreSchema {
    static let tables = ["threads", "scan_files", "prices", "usage", "statistics", "weekly_limit_cycles"]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // 尚未发布：结构变化直接重建，再从源日志采集，不维护旧结构迁移。
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("schema.3") { db in
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
                CREATE INDEX scan_files_thread ON scan_files(thread_id);
                CREATE TABLE prices (
                    model TEXT NOT NULL,
                    date TEXT NOT NULL,
                    tier TEXT NOT NULL,
                    input_price TEXT, output_price TEXT, cache_read_price TEXT, cache_write_price TEXT,
                    long_input_price TEXT, long_output_price TEXT, long_cache_read_price TEXT, long_cache_write_price TEXT,
                    long_context_threshold INTEGER,
                    context_rule TEXT NOT NULL CHECK(context_rule IN ('uniform','requestInputGreaterThan','unsupported')),
                    source_url TEXT NOT NULL,
                    is_bundled INTEGER CHECK(is_bundled IN (0,1)),
                    combination_rule TEXT,
                    combination_source TEXT,
                    PRIMARY KEY(model, date, tier)
                );
                CREATE TABLE usage (
                    id INTEGER PRIMARY KEY,
                    account_id TEXT,
                    thread_id TEXT,
                    turn_id TEXT,
                    response_id TEXT,
                    occurred_at REAL,
                    usage_date TEXT,
                    model TEXT,
                    tier TEXT,
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
                    rollout_id TEXT NOT NULL,
                    source_line INTEGER NOT NULL CHECK(source_line > 0),
                    source_ordinal INTEGER CHECK(source_ordinal >= 0),
                    hour INTEGER CHECK(hour BETWEEN 0 AND 23),
                    minute INTEGER CHECK(minute BETWEEN 0 AND 59),
                    turn_key TEXT,
                    turn_started_at REAL,
                    source_created_at REAL,
                    reasoning_effort TEXT,
                    pricing_tier TEXT,
                    pricing_source TEXT,
                    price_date TEXT,
                    legacy_total INTEGER,
                    legacy_input INTEGER,
                    legacy_output INTEGER,
                    legacy_cache_read INTEGER,
                    legacy_cache_write INTEGER,
                    legacy_reasoning INTEGER,
                    CHECK (occurred_at IS NOT NULL OR usage_date IS NOT NULL)
                );
                CREATE INDEX usage_thread_time ON usage(thread_id,occurred_at);
                CREATE INDEX usage_account_time ON usage(account_id,occurred_at);
                CREATE INDEX usage_model_time ON usage(model,occurred_at);
                CREATE INDEX usage_day_hour_minute ON usage(usage_date,hour,minute);
                CREATE INDEX usage_source_position ON usage(rollout_id,source_line);
                CREATE UNIQUE INDEX usage_turn_response ON usage(turn_key,response_id) WHERE response_id IS NOT NULL;
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
                    record_count INTEGER NOT NULL, known_amount INTEGER, unpriced_records INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_key, date, timezone, dimension, dimension_value)
                );
                CREATE TABLE app_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS usage_occurred_at ON usage(occurred_at);
                CREATE INDEX usage_turn_key ON usage(turn_key);
                CREATE INDEX usage_turn_legacy ON usage(turn_key,legacy_total);
                CREATE TABLE weekly_limit_cycles (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT,
                    limit_id TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    scheduled_reset_at INTEGER NOT NULL,
                    ended_at REAL NOT NULL,
                    reset_kind TEXT NOT NULL CHECK(reset_kind IN ('natural','early')),
                    last_observed_at REAL NOT NULL,
                    last_used_percent REAL,
                    source_file TEXT,
                    source_line INTEGER,
                    total_tokens INTEGER NOT NULL DEFAULT 0,
                    request_count INTEGER NOT NULL DEFAULT 0,
                    amount INTEGER,
                    known_amount INTEGER
                );
                CREATE INDEX weekly_cycles_start ON weekly_limit_cycles(started_at);
                CREATE INDEX weekly_cycles_account ON weekly_limit_cycles(account_id,started_at);

                INSERT INTO app_metadata(key,value) VALUES ('statistics_revision','0'),('statistics_dirty','true'),('statistics_timezone',?);
                CREATE TRIGGER usage_statistics_insert AFTER INSERT ON usage BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';

                 INSERT INTO app_metadata(key,value)
                 VALUES ('statistics_day:' || COALESCE(date(NEW.occurred_at,'unixepoch'),NEW.usage_date,'unknown'),
                    (SELECT value FROM app_metadata WHERE key='statistics_revision'))
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                 END;
                CREATE TRIGGER usage_statistics_update AFTER UPDATE ON usage BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';

                 INSERT INTO app_metadata(key,value)
                 VALUES ('statistics_day:' || COALESCE(date(OLD.occurred_at,'unixepoch'),OLD.usage_date,'unknown'),
                    (SELECT value FROM app_metadata WHERE key='statistics_revision'))
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value;

                 INSERT INTO app_metadata(key,value)
                 VALUES ('statistics_day:' || COALESCE(date(NEW.occurred_at,'unixepoch'),NEW.usage_date,'unknown'),
                    (SELECT value FROM app_metadata WHERE key='statistics_revision'))
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                 END;
                CREATE TRIGGER usage_statistics_delete AFTER DELETE ON usage BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';

                 INSERT INTO app_metadata(key,value)
                 VALUES ('statistics_day:' || COALESCE(date(OLD.occurred_at,'unixepoch'),OLD.usage_date,'unknown'),
                    (SELECT value FROM app_metadata WHERE key='statistics_revision'))
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                 END;
                CREATE TRIGGER thread_statistics_insert AFTER INSERT ON threads WHEN NEW.project_name IS NOT NULL BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';
                 DELETE FROM app_metadata WHERE key LIKE 'statistics_cache_revision:%';
                 END;
                CREATE TRIGGER thread_statistics_update AFTER UPDATE OF project_name ON threads WHEN OLD.project_name IS NOT NEW.project_name BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';
                 DELETE FROM app_metadata WHERE key LIKE 'statistics_cache_revision:%';
                 END;
                CREATE TRIGGER thread_statistics_delete AFTER DELETE ON threads WHEN OLD.project_name IS NOT NULL BEGIN
                 UPDATE app_metadata SET value=CAST(value AS INTEGER)+1 WHERE key='statistics_revision';
                 INSERT INTO app_metadata(key,value) VALUES ('statistics_dirty','true') ON CONFLICT(key) DO UPDATE SET value='true';
                 DELETE FROM app_metadata WHERE key LIKE 'statistics_cache_revision:%';
                 END;
                """, arguments: [TimeZone.current.identifier])
        }
        return migrator
    }
}
