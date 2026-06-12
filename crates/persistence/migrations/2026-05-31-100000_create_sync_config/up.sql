CREATE TABLE IF NOT EXISTS sync_config (
    id INTEGER PRIMARY KEY NOT NULL DEFAULT 1,
    repo_url TEXT NOT NULL DEFAULT '',
    last_sync_at TIMESTAMP,
    last_sync_error TEXT,
    last_sync_direction TEXT
);
INSERT OR IGNORE INTO sync_config (id, repo_url) VALUES (1, '');
