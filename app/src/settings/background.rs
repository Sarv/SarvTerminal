use serde::{Deserialize, Serialize};
use settings::macros::define_settings_group;
use settings::{RespectUserSyncSetting, SupportedPlatforms, SyncToCloud};

#[derive(
    Clone,
    Copy,
    Debug,
    PartialEq,
    Eq,
    Serialize,
    Deserialize,
    Default,
    schemars::JsonSchema,
    settings_value::SettingsValue,
)]
#[serde(rename_all = "snake_case")]
#[schemars(description = "How the background image is sized to fit the terminal.")]
pub enum BackgroundFit {
    #[default]
    #[schemars(description = "Scale to cover the terminal area, preserving aspect ratio (may crop).")]
    Cover,
    #[schemars(description = "Scale to fit within the terminal area, preserving aspect ratio.")]
    Contain,
    #[schemars(description = "Stretch to fill the terminal area, ignoring aspect ratio.")]
    Stretch,
    #[schemars(description = "Display at original size without scaling.")]
    Original,
}

impl std::fmt::Display for BackgroundFit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BackgroundFit::Cover => write!(f, "Cover"),
            BackgroundFit::Contain => write!(f, "Contain"),
            BackgroundFit::Stretch => write!(f, "Stretch"),
            BackgroundFit::Original => write!(f, "Original"),
        }
    }
}

#[derive(
    Clone,
    Copy,
    Debug,
    PartialEq,
    Eq,
    Serialize,
    Deserialize,
    Default,
    schemars::JsonSchema,
    settings_value::SettingsValue,
)]
#[serde(rename_all = "snake_case")]
#[schemars(description = "Where to anchor the background image within the terminal.")]
pub enum BackgroundPosition {
    #[schemars(description = "Top-left corner.")]
    TopLeft,
    #[schemars(description = "Top-center.")]
    TopCenter,
    #[schemars(description = "Top-right corner.")]
    TopRight,
    #[schemars(description = "Center-left edge.")]
    CenterLeft,
    #[default]
    #[schemars(description = "Centered (default).")]
    Center,
    #[schemars(description = "Center-right edge.")]
    CenterRight,
    #[schemars(description = "Bottom-left corner.")]
    BottomLeft,
    #[schemars(description = "Bottom-center.")]
    BottomCenter,
    #[schemars(description = "Bottom-right corner.")]
    BottomRight,
}

define_settings_group!(BackgroundSettings, settings: [
    image_path: BackgroundImagePath {
        type: Option<String>,
        default: None,
        supported_platforms: SupportedPlatforms::ALL,
        sync_to_cloud: SyncToCloud::Never,
        private: false,
        toml_path: "appearance.background.image_path",
        description: "Absolute path to a background image shown behind the terminal.",
    },
    image_opacity: BackgroundImageOpacity {
        type: u8,
        default: 50,
        supported_platforms: SupportedPlatforms::ALL,
        sync_to_cloud: SyncToCloud::Globally(RespectUserSyncSetting::Yes),
        private: false,
        toml_path: "appearance.background.opacity",
        description: "Opacity of the terminal background image (0 = transparent, 100 = opaque).",
    },
    image_fit: BackgroundImageFit {
        type: BackgroundFit,
        default: BackgroundFit::Cover,
        supported_platforms: SupportedPlatforms::ALL,
        sync_to_cloud: SyncToCloud::Globally(RespectUserSyncSetting::Yes),
        private: false,
        toml_path: "appearance.background.fit",
        description: "How the background image is sized to fit the terminal.",
    },
    image_position: BackgroundImagePosition {
        type: BackgroundPosition,
        default: BackgroundPosition::Center,
        supported_platforms: SupportedPlatforms::ALL,
        sync_to_cloud: SyncToCloud::Globally(RespectUserSyncSetting::Yes),
        private: false,
        toml_path: "appearance.background.position",
        description: "Where to anchor the background image within the terminal.",
    },
]);
