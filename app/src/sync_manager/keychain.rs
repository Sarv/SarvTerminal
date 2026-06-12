use anyhow::{bail, Context, Result};
use std::io::Write as IoWrite;
use std::process::{Command, Stdio};

const SERVICE_MASTER: &str = "warp-sync-master";
const ACCOUNT: &str = "warp-sync";

// ── Encrypt / Decrypt ────────────────────────────────────────────────────────
// The master password is the encryption key. Same password on any machine
// decrypts the same ciphertext — no machine-specific vault key needed.

/// Encrypt `plaintext` with AES-256-CBC using `key`; returns base64 ciphertext.
pub fn encrypt_for_db(plaintext: &str, key: &str) -> Result<String> {
    if plaintext.is_empty() || key.is_empty() {
        return Ok(String::new());
    }
    let mut child = Command::new("openssl")
        .args(["enc", "-aes-256-cbc", "-pbkdf2", "-a", "-pass", &format!("pass:{key}")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("openssl enc spawn")?;
    child.stdin.as_mut().unwrap().write_all(plaintext.as_bytes())?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("openssl enc: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Decrypt base64 ciphertext produced by `encrypt_for_db` using the same `key`.
pub fn decrypt_from_db(ciphertext: &str, key: &str) -> Result<String> {
    if ciphertext.is_empty() || key.is_empty() {
        return Ok(String::new());
    }
    let mut child = Command::new("openssl")
        .args(["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-a", "-pass", &format!("pass:{key}")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("openssl dec spawn")?;
    child.stdin.as_mut().unwrap().write_all(ciphertext.as_bytes())?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("openssl dec: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

// ── Master password (Keychain) ───────────────────────────────────────────────
// Stored for auto-fill convenience only — not relied on for security.

pub fn save_master_password(pass: &str) -> Result<()> {
    delete_entry(SERVICE_MASTER);
    Command::new("security")
        .args([
            "add-generic-password",
            "-a", ACCOUNT,
            "-s", SERVICE_MASTER,
            "-w", pass,
            "-T", "",
            "-U",
        ])
        .output()
        .context("security add-generic-password (master) failed")?;
    Ok(())
}

pub fn get_master_password() -> Option<String> {
    read_entry(SERVICE_MASTER)
}

fn read_entry(service: &str) -> Option<String> {
    let out = Command::new("security")
        .args(["find-generic-password", "-a", ACCOUNT, "-s", service, "-w"])
        .output()
        .ok()?;
    if out.status.success() {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if s.is_empty() { None } else { Some(s) }
    } else {
        None
    }
}

fn delete_entry(service: &str) {
    let _ = Command::new("security")
        .args(["delete-generic-password", "-a", ACCOUNT, "-s", service])
        .output();
}
