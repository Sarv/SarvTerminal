ALTER TABLE ssh_groups ADD COLUMN parent_id INTEGER REFERENCES ssh_groups(id);
