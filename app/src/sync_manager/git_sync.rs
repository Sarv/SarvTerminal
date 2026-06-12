use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};


pub enum SyncDirection {
    Push,
    Pull,
}

impl SyncDirection {
    pub fn as_str(&self) -> &'static str {
        match self {
            SyncDirection::Push => "push",
            SyncDirection::Pull => "pull",
        }
    }
}

fn sync_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".warp-sync")
}

fn repo_dir() -> PathBuf {
    sync_dir().join("repo")
}

fn warp_config_dir() -> PathBuf {
    warp_core::paths::data_dir()
}

/// Validate repo URL + PAT. Returns Ok(()) if reachable, Err with message otherwise.
pub fn test_connection(repo_url: &str, pat: &str) -> Result<()> {
    let out = Command::new("git")
        .args(["ls-remote", "--exit-code", repo_url, "HEAD"])
        .env("GIT_TERMINAL_PROMPT", "0")
        .envs(pat_env(pat))
        .output()
        .context("git ls-remote failed to start")?;
    if out.status.success() {
        Ok(())
    } else {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim())
    }
}

fn load_credentials() -> Result<(String, Option<String>)> {
    use crate::persistence::{database_file_path_for_scope, establish_ro_connection, PersistenceScope};
    let db_path = database_file_path_for_scope(&PersistenceScope::App);
    let mut conn = establish_ro_connection(db_path.to_str().unwrap_or(""))?;
    let (_, pat, master, ..) = crate::sync_manager::db::get_decrypted_config(&mut conn)?
        .context("Sync config not found — save settings first")?;
    let pat = if pat.is_empty() {
        bail!("PAT not saved — open Sync Settings and save first");
    } else {
        pat
    };
    let master = if master.is_empty() { None } else { Some(master) };
    Ok((pat, master))
}

/// Push local settings to remote.
pub fn push(repo_url: &str) -> Result<()> {
    let (pat, master) = load_credentials()?;

    ensure_repo(repo_url, &pat)?;

    let repo = repo_dir();
    let config_dst = repo.join("config");
    fs::create_dir_all(&config_dst)?;

    let warp_cfg = warp_config_dir();
    copy_file_if_exists(&warp_cfg.join("settings.toml"), &config_dst.join("settings.toml"))?;
    copy_file_if_exists(&warp_cfg.join("keybindings.yaml"), &config_dst.join("keybindings.yaml"))?;
    copy_dir_if_exists(&warp_cfg.join("themes"), &config_dst.join("themes"))?;
    copy_dir_if_exists(&warp_cfg.join("workflows"), &config_dst.join("workflows"))?;
    copy_dir_if_exists(
        &warp_cfg.join("launch_configurations"),
        &config_dst.join("launch_configurations"),
    )?;
    copy_dir_if_exists(&warp_cfg.join("tab_configs"), &config_dst.join("tab_configs"))?;
    copy_dir_if_exists(&warp_cfg.join("skills"), &config_dst.join("skills"))?;
    copy_file_if_exists(&warp_cfg.join(".mcp.json"), &config_dst.join(".mcp.json"))?;

    if let Some(ref pass) = master {
        if let Err(e) = stage_encrypted_ssh_hosts(&repo, pass) {
            log::warn!("sync push: SSH hosts not staged: {e}");
        }
    }
    if let Err(e) = stage_background_image(&config_dst) {
        log::warn!("sync push: background image not staged: {e}");
    }

    git_commit_and_push(&repo, &pat)
}

/// Pull settings from remote and restore locally.
pub fn pull(repo_url: &str) -> Result<()> {
    let (pat, master) = load_credentials()?;

    ensure_repo(repo_url, &pat)?;
    git_pull_remote(&repo_dir(), &pat)?;

    let repo = repo_dir();
    let config_src = repo.join("config");
    let warp_cfg = warp_config_dir();
    fs::create_dir_all(&warp_cfg)?;

    copy_file_if_exists(&config_src.join("settings.toml"), &warp_cfg.join("settings.toml"))?;
    copy_file_if_exists(&config_src.join("keybindings.yaml"), &warp_cfg.join("keybindings.yaml"))?;
    copy_dir_if_exists(&config_src.join("themes"), &warp_cfg.join("themes"))?;
    copy_dir_if_exists(&config_src.join("workflows"), &warp_cfg.join("workflows"))?;
    copy_dir_if_exists(
        &config_src.join("launch_configurations"),
        &warp_cfg.join("launch_configurations"),
    )?;
    copy_dir_if_exists(&config_src.join("tab_configs"), &warp_cfg.join("tab_configs"))?;
    copy_dir_if_exists(&config_src.join("skills"), &warp_cfg.join("skills"))?;
    copy_file_if_exists(&config_src.join(".mcp.json"), &warp_cfg.join(".mcp.json"))?;

    let enc_file = repo.join("ssh").join("hosts.enc");
    if enc_file.exists() {
        match master {
            Some(ref pass) => {
                if let Err(e) = restore_encrypted_ssh_hosts(&enc_file, pass) {
                    bail!("SSH hosts restore failed: {e}");
                }
            }
            None => {
                log::warn!("sync: ssh/hosts.enc present but no master password — SSH hosts skipped");
            }
        }
    }
    if let Err(e) = restore_background_image(&config_src, &warp_cfg) {
        log::warn!("sync pull: background image not restored: {e}");
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn ensure_repo(repo_url: &str, pat: &str) -> Result<()> {
    let repo = repo_dir();
    if repo.join(".git").exists() {
        return Ok(());
    }
    fs::create_dir_all(sync_dir())?;
    let out = Command::new("git")
        .args(["clone", repo_url, repo.to_str().unwrap_or("")])
        .envs(pat_env(pat))
        .output()
        .context("git clone")?;
    if !out.status.success() {
        bail!("git clone: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn git_pull_remote(repo: &Path, pat: &str) -> Result<()> {
    let out = Command::new("git")
        .arg("-C").arg(repo)
        .args(["pull", "origin", "main", "--quiet"])
        .envs(pat_env(pat))
        .output()
        .context("git pull")?;
    if !out.status.success() {
        bail!("git pull: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn git_commit_and_push(repo: &Path, pat: &str) -> Result<()> {
    Command::new("git").arg("-C").arg(repo).args(["add", "-A"]).output()?;

    let no_changes = Command::new("git")
        .arg("-C").arg(repo)
        .args(["diff", "--cached", "--quiet"])
        .status()?
        .success();
    if no_changes {
        return Ok(());
    }

    let msg = format!("sync {}", chrono::Utc::now().format("%Y-%m-%d %H:%M"));
    Command::new("git")
        .arg("-C").arg(repo)
        .args(["commit", "-m", &msg, "--quiet"])
        .output()?;

    let out = Command::new("git")
        .arg("-C").arg(repo)
        .args(["push", "origin", "HEAD:main", "--quiet"])
        .envs(pat_env(pat))
        .output()
        .context("git push")?;
    if !out.status.success() {
        bail!("git push: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn stage_encrypted_ssh_hosts(repo: &Path, master_pass: &str) -> Result<()> {
    let db_path = crate::persistence::database_file_path_for_scope(
        &crate::persistence::PersistenceScope::App,
    );
    if !db_path.exists() { return Ok(()); }

    let has_table_out = Command::new("sqlite3")
        .arg(&db_path)
        .arg("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ssh_hosts';")
        .output()?;
    if String::from_utf8_lossy(&has_table_out.stdout).trim() != "1" {
        return Ok(());
    }

    // Guard: never overwrite git's hosts.enc with empty data. If this machine has
    // no actual SSH hosts (e.g. fresh install reading an empty DB), leave whatever
    // is in git untouched so the repo remains the source of truth.
    let host_count_out = Command::new("sqlite3")
        .arg(&db_path)
        .arg("SELECT COUNT(*) FROM ssh_hosts;")
        .output()?;
    let host_count: u64 = String::from_utf8_lossy(&host_count_out.stdout)
        .trim()
        .parse()
        .unwrap_or(0);
    if host_count == 0 {
        log::info!("sync push: no SSH hosts in DB — skipping hosts.enc to preserve git data");
        return Ok(());
    }

    let json_out = Command::new("sqlite3")
        .arg("-json")
        .arg(&db_path)
        .arg(
            "SELECT g.id AS group_id, g.name AS group_name, g.label, \
             h.id, h.alias, h.host, h.port, h.user, h.pass, h.notes \
             FROM ssh_groups g LEFT JOIN ssh_hosts h ON h.group_id = g.id \
             ORDER BY g.name, h.alias;",
        )
        .output()?;

    let json = String::from_utf8_lossy(&json_out.stdout);
    let trimmed = json.trim();
    if trimmed.is_empty() || trimmed == "[]" {
        return Ok(());
    }

    let ssh_dir = repo.join("ssh");
    fs::create_dir_all(&ssh_dir)?;

    // Write plaintext hosts.json with passwords stripped for easy auditing
    stage_plaintext_hosts_json(&db_path, &ssh_dir)?;

    let enc_path = ssh_dir.join("hosts.enc");

    // Pipe JSON into openssl enc via stdin
    let mut child = Command::new("openssl")
        .args([
            "enc", "-aes-256-cbc", "-pbkdf2",
            "-pass", &format!("pass:{master_pass}"),
            "-out", enc_path.to_str().unwrap_or(""),
        ])
        .stdin(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("openssl enc spawn")?;

    if let Some(ref mut stdin) = child.stdin {
        stdin.write_all(trimmed.as_bytes())?;
    }
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("openssl enc: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// Write ssh/hosts.json — same data as hosts.enc but with `pass` redacted.
/// Lets you audit what's in git without decrypting.
/// Only called after stage_encrypted_ssh_hosts has already verified host_count > 0.
fn stage_plaintext_hosts_json(db_path: &Path, ssh_dir: &Path) -> Result<()> {
    let json_out = Command::new("sqlite3")
        .arg("-json")
        .arg(db_path)
        .arg(
            "SELECT g.id AS group_id, g.name AS group_name, g.label, \
             h.id, h.alias, h.host, h.port, h.user, h.notes \
             FROM ssh_groups g INNER JOIN ssh_hosts h ON h.group_id = g.id \
             ORDER BY g.name, h.alias;",
        )
        .output()?;

    let json = String::from_utf8_lossy(&json_out.stdout);
    let trimmed = json.trim();
    if trimmed.is_empty() || trimmed == "[]" {
        return Ok(());
    }

    fs::write(ssh_dir.join("hosts.json"), trimmed.as_bytes())?;
    Ok(())
}

fn restore_encrypted_ssh_hosts(enc_file: &Path, master_pass: &str) -> Result<()> {
    let db_path = crate::persistence::database_file_path_for_scope(
        &crate::persistence::PersistenceScope::App,
    );

    let dec = Command::new("openssl")
        .args([
            "enc", "-d", "-aes-256-cbc", "-pbkdf2",
            "-pass", &format!("pass:{master_pass}"),
            "-in", enc_file.to_str().unwrap_or(""),
        ])
        .output()
        .context("openssl dec")?;

    if !dec.status.success() {
        bail!("Wrong master password or corrupted hosts.enc");
    }

    let json = String::from_utf8(dec.stdout).context("invalid UTF-8 in decrypted data")?;
    let sql = build_import_sql(&json)?;

    // Guard: refuse to wipe local data if the decrypted payload contains no real
    // hosts. build_import_sql already skips null-host rows, so an empty sql means
    // hosts.enc was pushed from a machine with an empty DB. Preserve what's here.
    if !sql.contains("INSERT OR REPLACE INTO ssh_hosts") {
        log::warn!("sync pull: hosts.enc has no actual hosts — aborting DELETE to protect local data");
        return Ok(());
    }

    let full = format!("DELETE FROM ssh_hosts; DELETE FROM ssh_groups;\n{sql}");
    let out = Command::new("sqlite3").arg(&db_path).arg(&full).output()?;
    if !out.status.success() {
        bail!("sqlite3 import: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

fn build_import_sql(json: &str) -> Result<String> {
    #[derive(serde::Deserialize)]
    struct Row {
        group_id: i64,
        group_name: String,
        label: String,
        alias: Option<String>,
        host: Option<String>,
        port: Option<i64>,
        user: Option<String>,
        pass: Option<String>,
        notes: Option<String>,
    }

    let rows: Vec<Row> = serde_json::from_str(json).context("invalid JSON")?;
    let mut sql = String::new();

    let mut groups: std::collections::HashMap<i64, (String, String)> = Default::default();
    for row in &rows {
        groups.entry(row.group_id).or_insert_with(|| (row.group_name.clone(), row.label.clone()));
    }
    for (gid, (name, label)) in &groups {
        sql.push_str(&format!(
            "INSERT OR IGNORE INTO ssh_groups (id, name, label) VALUES ({gid}, '{}', '{}');\n",
            esc(name), esc(label)
        ));
    }
    for row in &rows {
        let (Some(alias), Some(host), Some(port), Some(user), Some(pass)) =
            (&row.alias, &row.host, row.port, &row.user, &row.pass)
        else {
            continue;
        };
        let notes_val = match &row.notes {
            Some(n) => format!("'{}'", esc(n)),
            None => "NULL".to_string(),
        };
        sql.push_str(&format!(
            "INSERT OR REPLACE INTO ssh_hosts \
             (group_id, alias, host, port, user, pass, notes) \
             VALUES ({}, '{}', '{}', {port}, '{}', '{}', {notes_val});\n",
            row.group_id, esc(alias), esc(host), esc(user), esc(pass)
        ));
    }
    Ok(sql)
}

fn esc(s: &str) -> String {
    s.replace('\'', "''")
}

/// Copy the user's background image (if set) into `config_dst/bg_image.<ext>`
/// and replace its absolute path in the repo's settings.toml with a stable
/// placeholder so it survives copy to a different machine.
fn stage_background_image(config_dst: &Path) -> Result<()> {
    let settings_path = config_dst.join("settings.toml");
    if !settings_path.exists() {
        return Ok(());
    }
    let content = fs::read_to_string(&settings_path)?;

    // Find: image_path = "/some/path/file.jpg"
    let img_path = content.lines().find_map(|line| {
        let t = line.trim();
        if !t.starts_with("image_path") {
            return None;
        }
        let after_eq = t.splitn(2, '=').nth(1)?.trim();
        if after_eq.starts_with('"') && after_eq.ends_with('"') && after_eq.len() > 2 {
            Some(after_eq[1..after_eq.len() - 1].to_string())
        } else {
            None
        }
    });

    let Some(img_path) = img_path else {
        return Ok(());
    };
    let src = Path::new(&img_path);
    if !src.exists() {
        return Ok(());
    }

    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("jpg");
    fs::copy(src, config_dst.join(format!("bg_image.{ext}")))?;

    // Replace the absolute path in the repo's settings.toml with a placeholder.
    let patched = content.replace(
        &format!("\"{}\"", img_path),
        "\"__WARP_SYNC_BG__\"",
    );
    fs::write(&settings_path, patched)?;
    Ok(())
}

/// If the repo contains a `bg_image.*` file, copy it to a stable location
/// inside `warp_cfg` and patch that path into settings.toml.
fn restore_background_image(repo_config: &Path, warp_cfg: &Path) -> Result<()> {
    let bg_src = ["jpg", "jpeg", "png", "gif", "webp", "tiff", "bmp"]
        .iter()
        .map(|ext| repo_config.join(format!("bg_image.{ext}")))
        .find(|p| p.exists());

    let Some(bg_src) = bg_src else {
        return Ok(());
    };

    let ext = bg_src.extension().and_then(|e| e.to_str()).unwrap_or("jpg");
    let stable = warp_cfg.join(format!("bg_image.{ext}"));
    fs::copy(&bg_src, &stable)?;

    let settings_path = warp_cfg.join("settings.toml");
    if settings_path.exists() {
        let content = fs::read_to_string(&settings_path)?;
        let abs = stable.to_str().unwrap_or("").to_string();
        let patched = content.replace("\"__WARP_SYNC_BG__\"", &format!("\"{}\"", abs));
        fs::write(&settings_path, patched)?;
    }
    Ok(())
}

fn copy_file_if_exists(src: &Path, dst: &Path) -> Result<()> {
    if !src.exists() { return Ok(()); }
    if let Some(p) = dst.parent() { fs::create_dir_all(p)?; }
    fs::copy(src, dst)?;
    Ok(())
}

fn copy_dir_if_exists(src: &Path, dst: &Path) -> Result<()> {
    if !src.is_dir() { return Ok(()); }
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let d = dst.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_if_exists(&entry.path(), &d)?;
        } else {
            fs::copy(entry.path(), d)?;
        }
    }
    Ok(())
}

fn pat_env(pat: &str) -> Vec<(&'static str, String)> {
    vec![
        ("GIT_TERMINAL_PROMPT", "0".to_string()),
        ("GIT_CONFIG_COUNT", "2".to_string()),
        ("GIT_CONFIG_KEY_0", "credential.helper".to_string()),
        ("GIT_CONFIG_VALUE_0", String::new()),
        ("GIT_CONFIG_KEY_1", "credential.helper".to_string()),
        (
            "GIT_CONFIG_VALUE_1",
            format!("!f(){{ echo username=x; echo password={pat}; }}; f"),
        ),
    ]
}
