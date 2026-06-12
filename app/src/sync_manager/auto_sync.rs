use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const DEBOUNCE_SECS: u64 = 3;

pub struct AutoSyncHandle {
    sender: mpsc::Sender<()>,
}

impl AutoSyncHandle {
    /// Trigger a debounced push. Multiple rapid calls collapse into one push.
    pub fn trigger(&self) {
        let _ = self.sender.send(());
    }
}

/// Spawn the background auto-sync thread. Returns a handle used to trigger syncs.
/// The thread reads the repo URL from the DB each time it wakes up, so config
/// changes take effect without a restart.
pub fn spawn() -> AutoSyncHandle {
    let (tx, rx) = mpsc::channel::<()>();

    thread::Builder::new()
        .name("warp-auto-sync".to_string())
        .spawn(move || {
            let debounce = Duration::from_secs(DEBOUNCE_SECS);
            loop {
                // Block until first trigger
                if rx.recv().is_err() {
                    break;
                }
                let mut deadline = Instant::now() + debounce;

                // Drain further triggers within the debounce window
                loop {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        break;
                    }
                    match rx.recv_timeout(remaining) {
                        Ok(()) => {
                            // Another trigger — extend deadline
                            deadline = Instant::now() + debounce;
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => break,
                        Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }

                // Perform push
                if let Some(repo_url) = read_repo_url() {
                    if !repo_url.is_empty() {
                        if let Err(e) = super::git_sync::push(&repo_url) {
                            log::warn!("auto-sync push failed: {e}");
                        } else {
                            log::debug!("auto-sync push ok");
                        }
                    }
                }
            }
        })
        .expect("failed to spawn auto-sync thread");

    AutoSyncHandle { sender: tx }
}

fn read_repo_url() -> Option<String> {
    #[cfg(feature = "local_fs")]
    {
        use crate::persistence::{database_file_path_for_scope, establish_ro_connection, PersistenceScope};
        let db_path = database_file_path_for_scope(&PersistenceScope::App);
        let mut conn = establish_ro_connection(db_path.to_str().unwrap_or("")).ok()?;
        super::db::get_config(&mut conn)
            .ok()
            .flatten()
            .map(|c| c.repo_url)
    }
    #[cfg(not(feature = "local_fs"))]
    None
}

