// The caller supplies request through stdin before this program, never through shell arguments.
// Return bounded source projections; interpretation and durable cursors belong to Swift.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const fail = reason => { throw Object.assign(new Error(reason), { reason }); };
const encode = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? JSON.rawJSON(v.toString()) : v);
try {
    let DatabaseSync;
    try { DatabaseSync = require('node:sqlite').DatabaseSync; } catch { fail('unsupported'); }
    if (typeof DatabaseSync !== 'function' || typeof JSON.rawJSON !== 'function') fail('unsupported');
    const root = fs.realpathSync(request.root || process.env.CODEX_HOME || path.join(os.homedir(), '.codex'));
    function source(name) {
        if (typeof name !== 'string' || path.basename(name) !== name || name.includes('\\') || name.includes('/')) fail('invalidPath');
        const result = fs.realpathSync(path.join(root, name));
        const relative = path.relative(root, result);
        if (!relative || relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) fail('invalidPath');
        return result;
    }
    function database(name, body) {
        const db = new DatabaseSync(source(name), { readOnly: true, timeout: 250 });
        try {
            // A short read transaction keeps each page and its cursor on the same source snapshot.
            db.exec('BEGIN');
            return body(db);
        } finally { db.close(); }
    }
    function columns(db, table) { return new Set(db.prepare('PRAGMA table_info(' + table + ')').all().map(row => row.name)); }
    const names = () => fs.readdirSync(root);
    let result;
    switch (request.operation) {
    case 'root': result = root; break;
    case 'catalog': {
        const files = names().filter(name => /^state_\d+\.sqlite$/.test(name))
            .sort((a, b) => Number(b.slice(6, -7)) - Number(a.slice(6, -7)));
        if (!files.length) { result = { entries: [], desktop: null, next: null, available: false }; break; }
        result = database(files[0], db => {
            const fields = columns(db, 'threads');
            if (!fields.has('id') || !fields.has('title')) fail('unsupported');
            const title = fields.has('name') ? "COALESCE(NULLIF(t.name,''),t.title)" : 't.title';
            const cwd = fields.has('cwd') ? 't.cwd' : 'NULL';
            const projects = fields.has('project_id') && db.prepare("SELECT 1 FROM sqlite_schema WHERE type='table' AND name='projects'").get();
            if (projects && !['id', 'name'].every(name => columns(db, 'projects').has(name))) fail('unsupported');
            const join = projects ? 'p.name AS projectName FROM threads t LEFT JOIN projects p ON p.id=t.project_id' : 'NULL AS projectName FROM threads t';
            const after = request.after ?? null;
            if (after !== null && (typeof after !== 'string' || after.length > 256)) fail('invalidResponse');
            const rows = db.prepare(`SELECT t.id,${title} AS title,${cwd} AS cwd,${join} WHERE (? IS NULL OR t.id>?) ORDER BY t.id LIMIT 513`).all(after, after);
            return { entries: rows.slice(0, 512), desktop: null, next: rows.length > 512 ? rows[511].id : null, available: true };
        });
        if (request.includeDesktop !== false && names().includes('.codex-global-state.json')) {
            const file = source('.codex-global-state.json');
            const fd = fs.openSync(file, 'r');
            try {
                if (fs.fstatSync(fd).size > 32 * 1024 * 1024) fail('unsupported');
                const bytes = Buffer.alloc(32 * 1024 * 1024 + 1);
                let size = 0, n;
                while ((n = fs.readSync(fd, bytes, size, bytes.length - size, null)) > 0) {
                    size += n;
                    if (size === bytes.length) fail('unsupported');
                }
                const state = JSON.parse(bytes.subarray(0, size).toString('utf8'));
                result.desktop = Object.fromEntries(['local-projects', 'thread-project-assignments', 'thread-workspace-root-hints', 'projectless-thread-ids', 'thread-projectless-output-directories'].filter(key => state[key] !== undefined).map(key => [key, state[key]]));
            } finally { fs.closeSync(fd); }
        }
        break;
    }
    case 'traceFiles': result = names().filter(name => /^logs_\d+\.sqlite$/.test(name)).sort(); break;
    case 'tracePage': {
        if (typeof request.file !== 'string' || !/^logs_\d+\.sqlite$/.test(request.file)) fail('invalidPath');
        const file = source(request.file);
        const before = fs.statSync(file, { bigint: true });
        result = database(request.file, db => {
            function integers(sql) {
                const statement = db.prepare(sql);
                statement.setReadBigInts(true);
                return statement;
            }
            const maximum = integers('SELECT COALESCE(MAX(id),0) AS id FROM logs').get().id;
            const anchor = id => {
                const row = db.prepare('SELECT json_array(ts,length(feedback_log_body),substr(feedback_log_body,1,512)) AS value FROM logs WHERE id=?').get(id);
                return row ? crypto.createHash('sha256').update(row.value).digest('hex') : null;
            };
            let start = 0n;
            const previous = request.cursor;
            if (previous && BigInt(previous.inode) === before.ino && BigInt(previous.device) === before.dev && BigInt(previous.lastID) <= maximum && previous.anchor === anchor(BigInt(previous.lastID))) start = BigInt(previous.lastID);
            const thread = columns(db, 'logs').has('thread_id') ? 'thread_id' : 'NULL';
            const rows = integers(`SELECT id,ts AS timestamp,${thread} AS threadID,feedback_log_body AS body FROM logs WHERE id>? AND id<=? AND length(CAST(feedback_log_body AS BLOB))<=4194304 AND (feedback_log_body LIKE '%websocket request:%' OR feedback_log_body LIKE '%Submission sub=Submission {%') ORDER BY id LIMIT 65`).iterate(start, maximum);
            const entries = [];
            let bytes = 0, more = false;
            for (const row of rows) {
                const size = Buffer.byteLength(encode(row));
                if (entries.length && (entries.length >= 64 || bytes + size > 8 * 1024 * 1024)) { more = true; break; }
                entries.push(row); bytes += size;
            }
            const last = more ? entries.at(-1).id : maximum;
            return { entries, cursor: { inode: before.ino, device: before.dev, lastID: last, anchor: anchor(last) }, hasMore: more };
        });
        const after = fs.statSync(file, { bigint: true });
        if (after.ino !== before.ino || after.dev !== before.dev || after.size < before.size) fail('changed');
        break;
    }
    default: fail('unsupported');
    }
    const output = encode({ result });
    if (Buffer.byteLength(output) > 32 * 1024 * 1024) fail('unsupported');
    process.stdout.write(output);
} catch (error) {
    // Never forward SQLite, path, or source-content diagnostics into product copy.
    process.stdout.write(JSON.stringify({ failure: error.reason || 'inaccessible' }));
}
