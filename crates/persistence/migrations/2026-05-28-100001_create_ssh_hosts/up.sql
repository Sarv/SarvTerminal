CREATE TABLE ssh_hosts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    group_id   INTEGER NOT NULL REFERENCES ssh_groups(id) ON DELETE CASCADE,
    alias      TEXT    NOT NULL UNIQUE,
    host       TEXT    NOT NULL,
    port       INTEGER NOT NULL DEFAULT 22,
    user       TEXT    NOT NULL,
    pass       TEXT    NOT NULL DEFAULT '',
    notes      TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
