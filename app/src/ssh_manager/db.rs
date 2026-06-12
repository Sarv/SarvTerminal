use anyhow::Result;
use chrono::Utc;
use diesel::prelude::*;
use diesel::sqlite::SqliteConnection;
use persistence::model::{NewSshGroup, NewSshHost, NewSshLabel, SshGroup, SshHost, SshLabel};
use persistence::schema::{ssh_groups, ssh_hosts, ssh_labels};

// --- Groups ---

pub fn list_groups(conn: &mut SqliteConnection) -> Result<Vec<SshGroup>> {
    Ok(ssh_groups::table
        .order(ssh_groups::name.asc())
        .load::<SshGroup>(conn)?)
}

pub fn create_group(conn: &mut SqliteConnection, name: &str, label: &str, parent_id: Option<i32>) -> Result<SshGroup> {
    let new_group = NewSshGroup { name, label, parent_id };
    diesel::insert_into(ssh_groups::table)
        .values(&new_group)
        .execute(conn)?;
    Ok(ssh_groups::table
        .order(ssh_groups::id.desc())
        .first::<SshGroup>(conn)?)
}

pub fn rename_group(conn: &mut SqliteConnection, id: i32, new_name: &str) -> Result<()> {
    diesel::update(ssh_groups::table.filter(ssh_groups::id.eq(id)))
        .set(ssh_groups::name.eq(new_name))
        .execute(conn)?;
    Ok(())
}

pub fn delete_group(conn: &mut SqliteConnection, id: i32) -> Result<()> {
    // Cascade deletes all hosts in this group via the FK constraint
    diesel::delete(ssh_groups::table.filter(ssh_groups::id.eq(id))).execute(conn)?;
    Ok(())
}

pub fn get_or_create_default_group(conn: &mut SqliteConnection) -> Result<SshGroup> {
    if let Ok(group) = ssh_groups::table
        .filter(ssh_groups::label.eq("default"))
        .first::<SshGroup>(conn)
    {
        return Ok(group);
    }
    create_group(conn, "Default", "default", None)
}

/// List groups at root level (parent_id IS NULL).
pub fn list_root_groups(conn: &mut SqliteConnection) -> Result<Vec<SshGroup>> {
    Ok(ssh_groups::table
        .filter(ssh_groups::parent_id.is_null())
        .order(ssh_groups::name.asc())
        .load::<SshGroup>(conn)?)
}

/// List immediate child groups of `parent_id`.
pub fn list_subgroups(conn: &mut SqliteConnection, parent_id: i32) -> Result<Vec<SshGroup>> {
    Ok(ssh_groups::table
        .filter(ssh_groups::parent_id.eq(parent_id))
        .order(ssh_groups::name.asc())
        .load::<SshGroup>(conn)?)
}

pub fn get_or_create_group_by_name(conn: &mut SqliteConnection, name: &str) -> Result<SshGroup> {
    let trimmed = name.trim();
    let lower = trimmed.to_lowercase();
    let groups = ssh_groups::table.load::<SshGroup>(conn)?;
    if let Some(g) = groups.into_iter().find(|g| g.name.to_lowercase() == lower) {
        return Ok(g);
    }
    create_group(conn, trimmed, &lower, None)
}

// --- Hosts ---

pub fn list_hosts_in_group(conn: &mut SqliteConnection, group_id: i32) -> Result<Vec<SshHost>> {
    Ok(ssh_hosts::table
        .filter(ssh_hosts::group_id.eq(group_id))
        .order(ssh_hosts::alias.asc())
        .load::<SshHost>(conn)?)
}

pub fn list_all_hosts(conn: &mut SqliteConnection) -> Result<Vec<SshHost>> {
    Ok(ssh_hosts::table
        .order(ssh_hosts::alias.asc())
        .load::<SshHost>(conn)?)
}

pub fn get_host_by_alias(conn: &mut SqliteConnection, alias: &str) -> Result<SshHost> {
    Ok(ssh_hosts::table
        .filter(ssh_hosts::alias.eq(alias))
        .first::<SshHost>(conn)?)
}

pub fn create_host(
    conn: &mut SqliteConnection,
    group_id: i32,
    alias: &str,
    host: &str,
    port: i32,
    user: &str,
    pass: &str,
    notes: Option<&str>,
    label: &str,
) -> Result<SshHost> {
    let new_host = NewSshHost {
        group_id,
        alias,
        host,
        port,
        user,
        pass,
        notes,
        label,
    };
    diesel::insert_into(ssh_hosts::table)
        .values(&new_host)
        .execute(conn)?;
    Ok(ssh_hosts::table
        .filter(ssh_hosts::alias.eq(alias))
        .first::<SshHost>(conn)?)
}

pub fn update_host(
    conn: &mut SqliteConnection,
    id: i32,
    group_id: i32,
    alias: &str,
    host: &str,
    port: i32,
    user: &str,
    pass: &str,
    notes: Option<&str>,
    label: &str,
) -> Result<()> {
    let now = Utc::now().naive_utc();
    diesel::update(ssh_hosts::table.filter(ssh_hosts::id.eq(id)))
        .set((
            ssh_hosts::group_id.eq(group_id),
            ssh_hosts::alias.eq(alias),
            ssh_hosts::host.eq(host),
            ssh_hosts::port.eq(port),
            ssh_hosts::user.eq(user),
            ssh_hosts::pass.eq(pass),
            ssh_hosts::notes.eq(notes),
            ssh_hosts::label.eq(label),
            ssh_hosts::updated_at.eq(now),
        ))
        .execute(conn)?;
    Ok(())
}

pub fn delete_host(conn: &mut SqliteConnection, id: i32) -> Result<()> {
    diesel::delete(ssh_hosts::table.filter(ssh_hosts::id.eq(id))).execute(conn)?;
    Ok(())
}

pub fn rename_label_on_hosts(conn: &mut SqliteConnection, old_label: &str, new_label: &str) -> Result<()> {
    let hosts = list_all_hosts(conn)?;
    for h in hosts {
        let parts: Vec<&str> = h.label.split(',').map(|s| s.trim()).collect();
        if parts.iter().any(|&p| p == old_label) {
            let updated: Vec<String> = parts.iter()
                .map(|&p| if p == old_label { new_label.to_string() } else { p.to_string() })
                .collect();
            diesel::update(ssh_hosts::table.filter(ssh_hosts::id.eq(h.id)))
                .set(ssh_hosts::label.eq(updated.join(", ")))
                .execute(conn)?;
        }
    }
    Ok(())
}

pub fn remove_label_from_hosts(conn: &mut SqliteConnection, label: &str) -> Result<()> {
    let hosts = list_all_hosts(conn)?;
    for h in hosts {
        let parts: Vec<&str> = h.label.split(',').map(|s| s.trim()).filter(|&p| !p.is_empty()).collect();
        if parts.iter().any(|&p| p == label) {
            let updated: Vec<String> = parts.iter()
                .filter(|&&p| p != label)
                .map(|p| p.to_string())
                .collect();
            diesel::update(ssh_hosts::table.filter(ssh_hosts::id.eq(h.id)))
                .set(ssh_hosts::label.eq(updated.join(", ")))
                .execute(conn)?;
        }
    }
    Ok(())
}

// --- Standalone labels (ssh_labels table) ---

pub fn list_standalone_labels(conn: &mut SqliteConnection) -> Result<Vec<String>> {
    Ok(ssh_labels::table
        .order(ssh_labels::name.asc())
        .load::<SshLabel>(conn)?
        .into_iter()
        .map(|l| l.name)
        .collect())
}

pub fn create_standalone_label(conn: &mut SqliteConnection, name: &str) -> Result<()> {
    diesel::insert_or_ignore_into(ssh_labels::table)
        .values(NewSshLabel { name })
        .execute(conn)?;
    Ok(())
}

pub fn delete_standalone_label(conn: &mut SqliteConnection, name: &str) -> Result<()> {
    diesel::delete(ssh_labels::table.filter(ssh_labels::name.eq(name))).execute(conn)?;
    Ok(())
}

pub fn rename_standalone_label(conn: &mut SqliteConnection, old: &str, new_name: &str) -> Result<()> {
    diesel::update(ssh_labels::table.filter(ssh_labels::name.eq(old)))
        .set(ssh_labels::name.eq(new_name))
        .execute(conn)?;
    Ok(())
}

/// Export all groups and hosts as JSON for encrypted backup.
pub fn export_as_json(conn: &mut SqliteConnection) -> Result<String> {
    #[derive(serde::Serialize)]
    struct Export {
        groups: Vec<SshGroup>,
        hosts: Vec<SshHost>,
    }
    let export = Export {
        groups: list_groups(conn)?,
        hosts: list_all_hosts(conn)?,
    };
    Ok(serde_json::to_string_pretty(&export)?)
}

/// Import groups and hosts from JSON backup, replacing existing data.
pub fn import_from_json(conn: &mut SqliteConnection, json: &str) -> Result<()> {
    #[derive(serde::Deserialize)]
    struct Export {
        groups: Vec<SshGroup>,
        hosts: Vec<SshHost>,
    }

    let export: Export = serde_json::from_str(json)?;

    conn.transaction(|conn| {
        // Clear existing data and re-insert from backup
        diesel::delete(ssh_hosts::table).execute(conn)?;
        diesel::delete(ssh_groups::table).execute(conn)?;

        for g in &export.groups {
            diesel::insert_into(ssh_groups::table)
                .values(NewSshGroup {
                    name: &g.name,
                    label: &g.label,
                    parent_id: g.parent_id,
                })
                .execute(conn)?;
        }

        // Re-map group IDs: old id → new id
        let new_groups = list_groups(conn)?;
        let id_map: std::collections::HashMap<_, _> = export
            .groups
            .iter()
            .zip(new_groups.iter())
            .map(|(old, new)| (old.id, new.id))
            .collect();

        for h in &export.hosts {
            let new_group_id = id_map.get(&h.group_id).copied().unwrap_or(1);
            diesel::insert_into(ssh_hosts::table)
                .values(NewSshHost {
                    group_id: new_group_id,
                    alias: &h.alias,
                    host: &h.host,
                    port: h.port,
                    user: &h.user,
                    pass: &h.pass,
                    notes: h.notes.as_deref(),
                    label: &h.label,
                })
                .execute(conn)?;
        }

        Ok(())
    })
}
