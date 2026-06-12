use anyhow::Result;
use chrono::Utc;
use diesel::prelude::*;

use persistence::model::SyncConfig;
use persistence::schema::sync_config;

pub fn get_config(conn: &mut SqliteConnection) -> Result<Option<SyncConfig>> {
    Ok(sync_config::table
        .filter(sync_config::id.eq(1))
        .first::<SyncConfig>(conn)
        .optional()?)
}

/// Save repo_url, PAT, and master_pass.
/// PAT is encrypted with master_pass before being written to SQLite.
/// master_pass is stored in Keychain for auto-fill; NOT in SQLite.
pub fn upsert_config(
    conn: &mut SqliteConnection,
    repo_url: &str,
    pat: &str,
    master_pass: &str,
) -> Result<()> {
    let pat_enc = crate::sync_manager::keychain::encrypt_for_db(pat, master_pass)
        .unwrap_or_default();
    // Save master_pass to Keychain for auto-fill on next open
    if !master_pass.is_empty() {
        let _ = crate::sync_manager::keychain::save_master_password(master_pass);
    }
    diesel::insert_into(sync_config::table)
        .values((
            sync_config::id.eq(1),
            sync_config::repo_url.eq(repo_url),
            sync_config::pat_enc.eq(&pat_enc),
            sync_config::master_pass_enc.eq(""),
        ))
        .on_conflict(sync_config::id)
        .do_update()
        .set((
            sync_config::repo_url.eq(repo_url),
            sync_config::pat_enc.eq(&pat_enc),
            sync_config::master_pass_enc.eq(""),
        ))
        .execute(conn)?;
    Ok(())
}

/// Load config and decrypt PAT using master_pass from Keychain.
/// Returns (repo_url, pat, master_pass, direction, at, error).
/// If master_pass is not in Keychain, pat will be empty (user must re-enter).
pub fn get_decrypted_config(
    conn: &mut SqliteConnection,
) -> Result<Option<(String, String, String, Option<String>, Option<String>, Option<String>)>> {
    let Some(cfg) = get_config(conn)? else { return Ok(None) };
    let master = crate::sync_manager::keychain::get_master_password().unwrap_or_default();
    let pat = if master.is_empty() {
        String::new()
    } else {
        crate::sync_manager::keychain::decrypt_from_db(&cfg.pat_enc, &master).unwrap_or_default()
    };
    Ok(Some((
        cfg.repo_url,
        pat,
        master,
        cfg.last_sync_direction,
        cfg.last_sync_at.map(|t| t.to_string()),
        cfg.last_sync_error,
    )))
}

pub fn update_sync_result(
    conn: &mut SqliteConnection,
    direction: &str,
    error: Option<&str>,
) -> Result<()> {
    let now = Utc::now().naive_utc();
    diesel::update(sync_config::table.filter(sync_config::id.eq(1)))
        .set((
            sync_config::last_sync_at.eq(now),
            sync_config::last_sync_direction.eq(direction),
            sync_config::last_sync_error.eq(error),
        ))
        .execute(conn)?;
    Ok(())
}
