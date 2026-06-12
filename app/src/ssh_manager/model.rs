#[cfg(feature = "local_fs")]
use diesel::SqliteConnection;
use persistence::model::{SshGroup, SshHost};
use warpui::{Entity, SingletonEntity};

pub enum SshManagerEvent {
    GroupsChanged,
    HostsChanged,
}

pub struct SshManagerModel {
    pub groups: Vec<SshGroup>,
    pub hosts: Vec<SshHost>,
}

impl Entity for SshManagerModel {
    type Event = SshManagerEvent;
}

impl SingletonEntity for SshManagerModel {}

impl SshManagerModel {
    pub fn new() -> Self {
        Self {
            groups: Vec::new(),
            hosts: Vec::new(),
        }
    }

    #[cfg(feature = "local_fs")]
    pub fn load(conn: &mut SqliteConnection) -> Self {
        let groups = super::db::list_groups(conn).unwrap_or_default();
        let hosts = super::db::list_all_hosts(conn).unwrap_or_default();
        Self { groups, hosts }
    }
}

impl Default for SshManagerModel {
    fn default() -> Self {
        Self::new()
    }
}
