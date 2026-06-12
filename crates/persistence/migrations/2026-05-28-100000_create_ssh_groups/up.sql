CREATE TABLE ssh_groups (
    id         INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name       TEXT    NOT NULL,
    label      TEXT    NOT NULL DEFAULT 'default',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed a default group so every host always has a group
INSERT INTO ssh_groups (name, label) VALUES ('Default', 'default');
