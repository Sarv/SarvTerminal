use warpui::elements::{
    Border, ChildView, ClippedScrollStateHandle, ClippedScrollable, Container,
    CrossAxisAlignment, Element, Expanded, Fill, Flex, MainAxisAlignment, MainAxisSize,
    MouseStateHandle, Padding, ParentElement, ScrollbarWidth, Shrinkable, Text,
};
use warpui::fonts::{Properties, Weight};
use warpui::ui_components::button::ButtonVariant;
use warpui::ui_components::components::{Coords, UiComponent, UiComponentStyles};
use warpui::{AppContext, Entity, SingletonEntity, TypedActionView, View, ViewContext, ViewHandle};

use crate::appearance::Appearance;
use crate::editor::{EditorView, Event as EditorEvent, SingleLineEditorOptions};

const PADDING: f32 = 20.;
const TITLE_FONT_SIZE: f32 = 16.;
const LABEL_FONT_SIZE: f32 = 12.;
const FIELD_GAP: f32 = 14.;
const FOOTER_BTN_HEIGHT: f32 = 32.;
const SCROLLBAR_WIDTH: f32 = 6.;

#[derive(Debug, Clone)]
pub enum SyncManagerAction {
    Close,
    Save,
    Test,
    PushToRemote,
    PullFromRemote,
}

pub enum SyncManagerEvent {
    Close,
    Save {
        repo_url: String,
        pat: String,
        master_pass: String,
        save_master_to_keychain: bool,
    },
    Test {
        repo_url: String,
        pat: String,
    },
    PushToRemote,
    PullFromRemote,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SyncStatus {
    Idle,
    Testing,
    TestOk,
    TestFailed(String),
    Syncing,
    LastSyncOk { direction: String, when: String },
    LastSyncFailed { direction: String, error: String },
}

pub struct SyncManager {
    repo_url_editor: ViewHandle<EditorView>,
    pat_editor: ViewHandle<EditorView>,
    master_pass_editor: ViewHandle<EditorView>,
    status: SyncStatus,
    save_state: MouseStateHandle,
    test_state: MouseStateHandle,
    push_state: MouseStateHandle,
    pull_state: MouseStateHandle,
    scroll_state: ClippedScrollStateHandle,
}

impl SyncManager {
    pub fn new(ctx: &mut ViewContext<Self>) -> Self {
        let repo_url_editor = Self::make_editor("https://github.com/you/warp-data", ctx);
        let pat_editor = Self::make_password_editor("ghp_your_token", ctx);
        let master_pass_editor = Self::make_password_editor("required — encrypts SSH hosts stored in git", ctx);

        for editor in [&repo_url_editor, &pat_editor, &master_pass_editor] {
            ctx.subscribe_to_view(editor, |_, _, event, _| {
                if matches!(event, EditorEvent::Escape) {}
            });
        }

        Self {
            repo_url_editor,
            pat_editor,
            master_pass_editor,
            status: SyncStatus::Idle,
            save_state: Default::default(),
            test_state: Default::default(),
            push_state: Default::default(),
            pull_state: Default::default(),
            scroll_state: Default::default(),
        }
    }

    pub fn on_open(
        &mut self,
        repo_url: &str,
        pat: &str,
        master_pass: &str,
        last_sync_direction: Option<&str>,
        last_sync_at: Option<&str>,
        last_sync_error: Option<&str>,
        ctx: &mut ViewContext<Self>,
    ) {
        fill_editor(&self.repo_url_editor, repo_url, ctx);
        fill_editor(&self.pat_editor, pat, ctx);
        fill_editor(&self.master_pass_editor, master_pass, ctx);
        self.status = match (last_sync_error, last_sync_direction, last_sync_at) {
            (Some(err), Some(dir), _) => SyncStatus::LastSyncFailed {
                direction: dir.to_string(),
                error: err.to_string(),
            },
            (None, Some(dir), Some(when)) => SyncStatus::LastSyncOk {
                direction: dir.to_string(),
                when: when.to_string(),
            },
            _ => SyncStatus::Idle,
        };
        ctx.notify();
    }

    pub fn set_status(&mut self, status: SyncStatus, ctx: &mut ViewContext<Self>) {
        self.status = status;
        ctx.notify();
    }

    fn collect_fields(&self, ctx: &ViewContext<Self>) -> (String, String, String) {
        let repo = self.repo_url_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let pat = self.pat_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let pass = self.master_pass_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        (repo, pat, pass)
    }

    fn make_editor(placeholder: &str, ctx: &mut ViewContext<Self>) -> ViewHandle<EditorView> {
        Self::make_editor_inner(placeholder, false, ctx)
    }

    fn make_password_editor(placeholder: &str, ctx: &mut ViewContext<Self>) -> ViewHandle<EditorView> {
        Self::make_editor_inner(placeholder, true, ctx)
    }

    fn make_editor_inner(placeholder: &str, is_password: bool, ctx: &mut ViewContext<Self>) -> ViewHandle<EditorView> {
        let ph = placeholder.to_string();
        ctx.add_typed_action_view(move |ctx| {
            let options = SingleLineEditorOptions { is_password, ..Default::default() };
            let mut e = EditorView::single_line(options, ctx);
            e.set_placeholder_text(&ph, ctx);
            e
        })
    }
}

impl Entity for SyncManager {
    type Event = SyncManagerEvent;
}

impl View for SyncManager {
    fn ui_name() -> &'static str {
        "SyncManager"
    }

    fn render(&self, app: &AppContext) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let theme = appearance.theme();
        let font = appearance.ui_font_family();
        let ui = appearance.ui_builder();

        // Header
        let title = Text::new_inline("Sync Settings".to_string(), font, TITLE_FONT_SIZE)
            .with_style(Properties::default().weight(Weight::Bold))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let header = Container::new(title)
            .with_padding(Padding::uniform(PADDING))
            .with_padding_bottom(12.)
            .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
            .finish();

        // Form
        let mut form = Flex::column();

        macro_rules! field {
            ($label:expr, $editor:expr) => {{
                let lbl = Text::new_inline($label.to_string(), font, LABEL_FONT_SIZE)
                    .with_color(theme.sub_text_color(theme.background()).into())
                    .finish();
                form.add_child(
                    Container::new(
                        Flex::column()
                            .with_child(Container::new(lbl).with_margin_bottom(4.).finish())
                            .with_child(ChildView::new($editor).finish())
                            .finish(),
                    )
                    .with_margin_bottom(FIELD_GAP)
                    .finish(),
                );
            }};
        }

        field!("GitHub Repo URL", &self.repo_url_editor);
        field!("Personal Access Token (PAT)", &self.pat_editor);
        field!("Master Password (required — encrypts SSH hosts in git)", &self.master_pass_editor);

        // Status line
        let (status_color, status_text) = match &self.status {
            SyncStatus::Idle => (theme.sub_text_color(theme.background()).into(), "No sync yet.".to_string()),
            SyncStatus::Testing => (theme.sub_text_color(theme.background()).into(), "Testing connection…".to_string()),
            SyncStatus::TestOk => (theme.main_text_color(theme.background()).into(), "✓ Connection successful".to_string()),
            SyncStatus::TestFailed(msg) => (theme.ui_error_color(), format!("✕ {msg}")),
            SyncStatus::Syncing => (theme.sub_text_color(theme.background()).into(), "Syncing…".to_string()),
            SyncStatus::LastSyncOk { direction, when } => (
                theme.main_text_color(theme.background()).into(),
                format!("✓ Last {direction}: {when}"),
            ),
            SyncStatus::LastSyncFailed { direction, error } => (
                theme.ui_error_color(),
                format!("⚠ Last {direction} failed: {error}"),
            ),
        };
        form.add_child(
            Text::new_inline(status_text, font, LABEL_FONT_SIZE)
                .with_color(status_color)
                .finish(),
        );

        let form_container = Container::new(form.finish()).with_padding(Padding::uniform(PADDING)).finish();

        let scrollable = ClippedScrollable::vertical(
            self.scroll_state.clone(),
            form_container,
            ScrollbarWidth::Custom(SCROLLBAR_WIDTH),
            theme.disabled_text_color(theme.background()).into(),
            theme.main_text_color(theme.background()).into(),
            Fill::None,
        )
        .finish();

        // Footer: Test + Save on the right; Push / Pull on the left
        let test_btn = ui
            .button(ButtonVariant::Basic, self.test_state.clone())
            .with_text_label("Test".to_string())
            .with_style(UiComponentStyles {
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(Coords::uniform(0.).left(12.).right(12.)),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| ctx.dispatch_typed_action(SyncManagerAction::Test))
            .finish();

        let save_btn = ui
            .button(ButtonVariant::Accent, self.save_state.clone())
            .with_text_label("Save".to_string())
            .with_style(UiComponentStyles {
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(Coords::uniform(0.).left(12.).right(12.)),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| ctx.dispatch_typed_action(SyncManagerAction::Save))
            .finish();

        let push_btn = ui
            .button(ButtonVariant::Basic, self.push_state.clone())
            .with_text_label("↑ Push to Remote".to_string())
            .with_style(UiComponentStyles {
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(Coords::uniform(0.).left(12.).right(12.)),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| ctx.dispatch_typed_action(SyncManagerAction::PushToRemote))
            .finish();

        let pull_btn = ui
            .button(ButtonVariant::Basic, self.pull_state.clone())
            .with_text_label("↓ Pull from Remote".to_string())
            .with_style(UiComponentStyles {
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(Coords::uniform(0.).left(12.).right(12.)),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| ctx.dispatch_typed_action(SyncManagerAction::PullFromRemote))
            .finish();

        let footer = Container::new(
            Flex::row()
                .with_main_axis_size(MainAxisSize::Max)
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(8.)
                .with_child(push_btn)
                .with_child(pull_btn)
                .with_child(
                    Expanded::new(
                        1.,
                        Flex::row()
                            .with_main_axis_alignment(MainAxisAlignment::End)
                            .with_spacing(8.)
                            .with_child(test_btn)
                            .with_child(save_btn)
                            .finish(),
                    )
                    .finish(),
                )
                .finish(),
        )
        .with_padding_top(12.)
        .with_padding_bottom(12.)
        .with_padding_left(PADDING)
        .with_padding_right(PADDING)
        .with_border(Border::top(1.).with_border_fill(theme.outline()))
        .finish();

        Flex::column()
            .with_main_axis_size(MainAxisSize::Min)
            .with_cross_axis_alignment(CrossAxisAlignment::Stretch)
            .with_child(header)
            .with_child(Shrinkable::new(1., scrollable).finish())
            .with_child(footer)
            .finish()
    }
}

impl TypedActionView for SyncManager {
    type Action = SyncManagerAction;

    fn handle_action(&mut self, action: &SyncManagerAction, ctx: &mut ViewContext<Self>) {
        match action {
            SyncManagerAction::Close => ctx.emit(SyncManagerEvent::Close),
            SyncManagerAction::Save => {
                let (repo, pat, pass) = self.collect_fields(ctx);
                let mut missing = Vec::new();
                if repo.is_empty() { missing.push("GitHub Repo URL"); }
                if pat.is_empty() { missing.push("Personal Access Token"); }
                if pass.is_empty() { missing.push("Master Password"); }
                if !missing.is_empty() {
                    self.status = SyncStatus::TestFailed(
                        format!("Required: {}", missing.join(", ")),
                    );
                    ctx.notify();
                    return;
                }
                ctx.emit(SyncManagerEvent::Save {
                    repo_url: repo,
                    pat,
                    master_pass: pass,
                    save_master_to_keychain: true,
                });
            }
            SyncManagerAction::Test => {
                let (repo, pat, _) = self.collect_fields(ctx);
                self.status = SyncStatus::Testing;
                ctx.notify();
                ctx.emit(SyncManagerEvent::Test { repo_url: repo, pat });
            }
            SyncManagerAction::PushToRemote => {
                self.status = SyncStatus::Syncing;
                ctx.notify();
                ctx.emit(SyncManagerEvent::PushToRemote);
            }
            SyncManagerAction::PullFromRemote => {
                self.status = SyncStatus::Syncing;
                ctx.notify();
                ctx.emit(SyncManagerEvent::PullFromRemote);
            }
        }
    }
}

fn fill_editor(editor: &ViewHandle<EditorView>, text: &str, ctx: &mut ViewContext<SyncManager>) {
    editor.update(ctx, |e, ctx| {
        e.set_buffer_text_ignoring_undo(text, ctx);
    });
}
