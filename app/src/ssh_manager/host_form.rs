use warpui::elements::{
    Border, ChildView, Container, CrossAxisAlignment, Element, Fill, Flex, MainAxisAlignment,
    MainAxisSize, MouseStateHandle, Padding, ParentElement, Shrinkable, Text,
};
use warpui::fonts::{Properties, Weight};
use warpui::ui_components::button::ButtonVariant;
use warpui::ui_components::components::{Coords, UiComponent, UiComponentStyles};
use warpui::{AppContext, Entity, SingletonEntity, TypedActionView, View, ViewContext, ViewHandle};

use persistence::model::{SshGroup, SshHost};

use crate::appearance::Appearance;
use crate::editor::{EditorView, Event as EditorEvent, SingleLineEditorOptions};

const PADDING: f32 = 20.;
const TITLE_FONT_SIZE: f32 = 16.;
const LABEL_FONT_SIZE: f32 = 12.;
const FIELD_GAP: f32 = 12.;
const FOOTER_BTN_HEIGHT: f32 = 36.;
const FOOTER_BTN_PAD_H: f32 = 20.;

pub enum SshHostFormEvent {
    Cancel,
    Submit {
        group_name: String,
        label: String,
        alias: String,
        host: String,
        port: i32,
        user: String,
        pass: String,
        notes: Option<String>,
    },
}

#[derive(Clone, Debug)]
pub enum SshHostFormAction {
    Cancel,
    Save,
    SelectGroup(String),
    SelectLabel(String),
}

pub struct SshHostForm {
    mode_title: &'static str,
    host_id: Option<i32>,
    groups: Vec<SshGroup>,
    alias_editor: ViewHandle<EditorView>,
    group_name_editor: ViewHandle<EditorView>,
    label_editor: ViewHandle<EditorView>,
    host_editor: ViewHandle<EditorView>,
    port_editor: ViewHandle<EditorView>,
    user_editor: ViewHandle<EditorView>,
    pass_editor: ViewHandle<EditorView>,
    notes_editor: ViewHandle<EditorView>,
    cancel_state: MouseStateHandle,
    save_state: MouseStateHandle,
    /// Stable states for group suggestion chips (one per group, rebuilt when groups change).
    group_chip_states: Vec<MouseStateHandle>,
    /// Available labels for suggestion chips.
    labels: Vec<String>,
    label_chip_states: Vec<MouseStateHandle>,
    error: Option<String>,
}

impl SshHostForm {
    pub fn new(ctx: &mut ViewContext<Self>) -> Self {
        let alias_editor = Self::build_editor("e.g. prod-web", false, ctx);
        let group_name_editor = Self::build_editor("e.g. Dev / Prod / Staging", false, ctx);
        let label_editor = Self::build_editor("e.g. AWS, Hetzner (comma-separated)", false, ctx);
        let host_editor = Self::build_editor("hostname or IP", false, ctx);
        let port_editor = Self::build_editor("22", false, ctx);
        let user_editor = Self::build_editor("username", false, ctx);
        let pass_editor = Self::build_editor("password (optional)", true, ctx);
        let notes_editor = Self::build_editor("notes (optional)", false, ctx);

        for editor in [&alias_editor, &label_editor, &host_editor, &port_editor, &user_editor, &pass_editor, &notes_editor] {
            ctx.subscribe_to_view(editor, |me, _, event, ctx| match event {
                EditorEvent::Enter => me.try_submit(ctx),
                EditorEvent::Escape => ctx.emit(SshHostFormEvent::Cancel),
                _ => {}
            });
        }

        // group_name_editor: notify on any change so suggestion chips update
        ctx.subscribe_to_view(&group_name_editor, |me, _, event, ctx| {
            match event {
                EditorEvent::Enter => me.try_submit(ctx),
                EditorEvent::Escape => ctx.emit(SshHostFormEvent::Cancel),
                _ => ctx.notify(),
            }
        });
        // label_editor: notify on any change so suggestion chips update
        ctx.subscribe_to_view(&label_editor, |me, _, event, ctx| {
            match event {
                EditorEvent::Enter => me.try_submit(ctx),
                EditorEvent::Escape => ctx.emit(SshHostFormEvent::Cancel),
                _ => ctx.notify(),
            }
        });

        Self {
            mode_title: "Add SSH Host",
            host_id: None,
            groups: Vec::new(),
            alias_editor,
            group_name_editor,
            label_editor,
            host_editor,
            port_editor,
            user_editor,
            pass_editor,
            notes_editor,
            cancel_state: Default::default(),
            save_state: Default::default(),
            group_chip_states: Vec::new(),
            labels: Vec::new(),
            label_chip_states: Vec::new(),
            error: None,
        }
    }

    fn build_editor(placeholder: &str, is_password: bool, ctx: &mut ViewContext<Self>) -> ViewHandle<EditorView> {
        let placeholder = placeholder.to_string();
        ctx.add_typed_action_view(move |ctx| {
            let options = SingleLineEditorOptions { is_password, ..Default::default() };
            let mut editor = EditorView::single_line(options, ctx);
            editor.set_placeholder_text(&placeholder, ctx);
            editor
        })
    }

    fn rebuild_chip_states(&mut self) {
        let n = self.groups.len();
        if self.group_chip_states.len() != n {
            self.group_chip_states = (0..n).map(|_| MouseStateHandle::default()).collect();
        }
    }

    fn rebuild_label_chip_states(&mut self) {
        let n = self.labels.len();
        if self.label_chip_states.len() != n {
            self.label_chip_states = (0..n).map(|_| MouseStateHandle::default()).collect();
        }
    }

    pub fn open_add(&mut self, groups: Vec<SshGroup>, labels: Vec<String>, default_group_name: Option<String>, ctx: &mut ViewContext<Self>) {
        self.mode_title = "Add SSH Host";
        self.host_id = None;
        self.error = None;
        self.groups = groups;
        self.labels = labels;
        self.rebuild_chip_states();
        self.rebuild_label_chip_states();
        for editor in [
            &self.alias_editor.clone(),
            &self.group_name_editor.clone(),
            &self.label_editor.clone(),
            &self.host_editor.clone(),
            &self.port_editor.clone(),
            &self.user_editor.clone(),
            &self.pass_editor.clone(),
            &self.notes_editor.clone(),
        ] {
            editor.update(ctx, |e, ctx| {
                e.clear_buffer_and_reset_undo_stack(ctx);
            });
        }
        let default_group = default_group_name
            .or_else(|| self.groups.first().map(|g| g.name.clone()))
            .unwrap_or_else(|| "Default".to_string());
        self.group_name_editor.update(ctx, |e, ctx| {
            e.set_buffer_text_ignoring_undo(&default_group, ctx);
        });
        self.port_editor.update(ctx, |e, ctx| {
            e.set_buffer_text_ignoring_undo("22", ctx);
        });
        ctx.focus(&self.alias_editor);
        ctx.notify();
    }

    pub fn open_edit(&mut self, host: &SshHost, groups: Vec<SshGroup>, labels: Vec<String>, ctx: &mut ViewContext<Self>) {
        self.mode_title = "Edit SSH Host";
        self.host_id = Some(host.id);
        self.error = None;
        self.groups = groups.clone();
        self.labels = labels;
        self.rebuild_chip_states();
        self.rebuild_label_chip_states();

        macro_rules! fill {
            ($editor:expr, $text:expr) => {
                $editor.update(ctx, |e, ctx| {
                    e.set_buffer_text_ignoring_undo($text, ctx);
                });
            };
        }

        let group_name = groups
            .iter()
            .find(|g| g.id == host.group_id)
            .map(|g| g.name.clone())
            .unwrap_or_else(|| "Default".to_string());

        fill!(self.alias_editor, &host.alias);
        fill!(self.group_name_editor, &group_name);
        fill!(self.label_editor, &host.label);
        fill!(self.host_editor, &host.host);
        fill!(self.port_editor, &host.port.to_string());
        fill!(self.user_editor, &host.user);
        fill!(self.pass_editor, &host.pass);
        if let Some(ref notes) = host.notes {
            fill!(self.notes_editor, notes);
        } else {
            self.notes_editor.update(ctx, |e, ctx| {
                e.clear_buffer_and_reset_undo_stack(ctx);
            });
        }

        ctx.focus(&self.alias_editor);
        ctx.notify();
    }

    pub fn try_submit(&mut self, ctx: &mut ViewContext<Self>) {
        let alias = self.alias_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let group_name = self.group_name_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let label = self.label_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let host = self.host_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let port_str = self.port_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let user = self.user_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let pass = self.pass_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let notes_raw = self.notes_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
        let notes = if notes_raw.is_empty() { None } else { Some(notes_raw) };

        if alias.is_empty() {
            self.error = Some("Alias is required".to_string());
            ctx.notify();
            return;
        }
        if host.is_empty() {
            self.error = Some("Host is required".to_string());
            ctx.notify();
            return;
        }
        if user.is_empty() {
            self.error = Some("Username is required".to_string());
            ctx.notify();
            return;
        }
        let port: i32 = match port_str.parse() {
            Ok(p) if p > 0 && p <= 65535 => p,
            _ => {
                self.error = Some("Port must be 1–65535".to_string());
                ctx.notify();
                return;
            }
        };

        let group_name = if group_name.is_empty() { "Default".to_string() } else { group_name };

        self.error = None;
        ctx.emit(SshHostFormEvent::Submit {
            group_name,
            label,
            alias,
            host,
            port,
            user,
            pass,
            notes,
        });
    }

    fn render_field(
        label: &str,
        editor: &ViewHandle<EditorView>,
        appearance: &Appearance,
    ) -> Box<dyn Element> {
        let theme = appearance.theme();
        let font = appearance.ui_font_family();

        let label_el = Text::new_inline(label.to_string(), font, LABEL_FONT_SIZE)
            .with_color(theme.sub_text_color(theme.background()).into())
            .finish();

        Flex::column()
            .with_child(
                Container::new(label_el)
                    .with_margin_bottom(4.)
                    .finish(),
            )
            .with_child(ChildView::new(editor).finish())
            .finish()
    }
}

impl Entity for SshHostForm {
    type Event = SshHostFormEvent;
}

impl View for SshHostForm {
    fn ui_name() -> &'static str {
        "SshHostForm"
    }

    fn render(&self, app: &AppContext) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let theme = appearance.theme();
        let font = appearance.ui_font_family();

        // Header
        let title = Text::new_inline(self.mode_title.to_string(), font, TITLE_FONT_SIZE)
            .with_style(Properties::default().weight(Weight::Bold))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let header = Container::new(title)
            .with_padding(Padding::uniform(PADDING))
            .with_padding_bottom(12.)
            .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
            .finish();

        // Form fields
        let mut form = Flex::column();

        macro_rules! add_field {
            ($label:expr, $editor:expr) => {
                form.add_child(
                    Container::new(Self::render_field($label, $editor, &appearance))
                        .with_margin_bottom(FIELD_GAP)
                        .finish(),
                );
            };
        }

        add_field!("Alias", &self.alias_editor);

        // Group field with suggestion chips
        {
            let typed = self.group_name_editor.as_ref(app).buffer_text(app).trim().to_lowercase();

            let matching: Vec<(usize, &SshGroup)> = self
                .groups
                .iter()
                .enumerate()
                .filter(|(_, g)| {
                    typed.is_empty() || g.name.to_lowercase().contains(&typed)
                })
                .collect();

            let lbl = Text::new_inline("Group".to_string(), font, LABEL_FONT_SIZE)
                .with_color(theme.sub_text_color(theme.background()).into())
                .finish();

            let mut group_col = Flex::column()
                .with_child(Container::new(lbl).with_margin_bottom(4.).finish())
                .with_child(ChildView::new(&self.group_name_editor).finish());

            if !matching.is_empty() {
                let mut chips = Flex::row()
                    .with_main_axis_size(MainAxisSize::Max)
                    .with_spacing(4.);

                for (idx, group) in &matching {
                    let g_name = group.name.clone();
                    let chip_state = self
                        .group_chip_states
                        .get(*idx)
                        .cloned()
                        .unwrap_or_default();
                    let chip = appearance
                        .ui_builder()
                        .button(ButtonVariant::Basic, chip_state)
                        .with_text_label(g_name.clone())
                        .with_style(
                            UiComponentStyles::default()
                                .set_font_size(LABEL_FONT_SIZE)
                                .set_padding(Coords::uniform(4.).left(8.).right(8.)),
                        )
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshHostFormAction::SelectGroup(
                                g_name.clone(),
                            ));
                        })
                        .finish();
                    chips.add_child(chip);
                }

                group_col = group_col
                    .with_child(Container::new(chips.finish()).with_margin_top(4.).finish());
            }

            form.add_child(
                Container::new(group_col.finish())
                    .with_margin_bottom(FIELD_GAP)
                    .finish(),
            );
        }

        // Label field with suggestion chips (comma-separated multi-label support)
        {
            let full_typed = self.label_editor.as_ref(app).buffer_text(app);
            // Filter suggestions on the last word after the last comma
            let last_word = full_typed
                .rsplit(',')
                .next()
                .unwrap_or("")
                .trim()
                .to_lowercase();
            // Already-typed labels so we don't re-suggest them
            let already: std::collections::HashSet<String> = full_typed
                .split(',')
                .map(|s| s.trim().to_lowercase())
                .collect();

            let matching: Vec<(usize, &String)> = self
                .labels
                .iter()
                .enumerate()
                .filter(|(_, l)| {
                    let ll = l.to_lowercase();
                    !already.contains(&ll) && (last_word.is_empty() || ll.contains(&last_word))
                })
                .collect();

            let lbl = Text::new_inline("Label (optional)".to_string(), font, LABEL_FONT_SIZE)
                .with_color(theme.sub_text_color(theme.background()).into())
                .finish();

            let mut label_col = Flex::column()
                .with_child(Container::new(lbl).with_margin_bottom(4.).finish())
                .with_child(ChildView::new(&self.label_editor).finish());

            if !matching.is_empty() {
                let mut chips = Flex::row()
                    .with_main_axis_size(MainAxisSize::Max)
                    .with_spacing(4.);

                for (idx, label_name) in &matching {
                    let l_name = (*label_name).clone();
                    let chip_state = self
                        .label_chip_states
                        .get(*idx)
                        .cloned()
                        .unwrap_or_default();
                    let chip = appearance
                        .ui_builder()
                        .button(ButtonVariant::Basic, chip_state)
                        .with_text_label(l_name.clone())
                        .with_style(
                            UiComponentStyles::default()
                                .set_font_size(LABEL_FONT_SIZE)
                                .set_padding(Coords::uniform(4.).left(8.).right(8.)),
                        )
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshHostFormAction::SelectLabel(
                                l_name.clone(),
                            ));
                        })
                        .finish();
                    chips.add_child(chip);
                }

                label_col = label_col
                    .with_child(Container::new(chips.finish()).with_margin_top(4.).finish());
            }

            form.add_child(
                Container::new(label_col.finish())
                    .with_margin_bottom(FIELD_GAP)
                    .finish(),
            );
        }
        add_field!("Host", &self.host_editor);
        add_field!("Port", &self.port_editor);
        add_field!("Username", &self.user_editor);
        add_field!("Password", &self.pass_editor);
        add_field!("Notes (optional)", &self.notes_editor);

        // Error message
        if let Some(ref err) = self.error {
            form.add_child(
                Text::new_inline(err.clone(), font, LABEL_FONT_SIZE)
                    .with_color(theme.ui_error_color())
                    .finish(),
            );
        }

        let form_container = Container::new(form.finish())
            .with_padding(Padding::uniform(PADDING))
            .finish();

        // Footer buttons
        let cancel_btn = appearance
            .ui_builder()
            .button(ButtonVariant::Text, self.cancel_state.clone())
            .with_text_label("Cancel".to_string())
            .with_style(UiComponentStyles {
                font_color: Some(theme.main_text_color(theme.background()).into()),
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(
                    Coords::uniform(0.)
                        .left(FOOTER_BTN_PAD_H)
                        .right(FOOTER_BTN_PAD_H),
                ),
                background: Some(Fill::None),
                border_width: Some(0.),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshHostFormAction::Cancel);
            })
            .finish();

        let save_btn = appearance
            .ui_builder()
            .button(ButtonVariant::Accent, self.save_state.clone())
            .with_text_label("Save".to_string())
            .with_style(UiComponentStyles {
                height: Some(FOOTER_BTN_HEIGHT),
                padding: Some(
                    Coords::uniform(0.)
                        .left(FOOTER_BTN_PAD_H)
                        .right(FOOTER_BTN_PAD_H),
                ),
                ..Default::default()
            })
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshHostFormAction::Save);
            })
            .finish();

        let footer = Container::new(
            Flex::row()
                .with_main_axis_size(MainAxisSize::Max)
                .with_main_axis_alignment(MainAxisAlignment::End)
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(8.)
                .with_child(cancel_btn)
                .with_child(save_btn)
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
            .with_child(Shrinkable::new(1., form_container).finish())
            .with_child(footer)
            .finish()
    }
}

impl TypedActionView for SshHostForm {
    type Action = SshHostFormAction;

    fn handle_action(&mut self, action: &SshHostFormAction, ctx: &mut ViewContext<Self>) {
        match action {
            SshHostFormAction::Cancel => ctx.emit(SshHostFormEvent::Cancel),
            SshHostFormAction::Save => self.try_submit(ctx),
            SshHostFormAction::SelectGroup(name) => {
                let name = name.clone();
                self.group_name_editor.update(ctx, |e, ctx| {
                    e.set_buffer_text_ignoring_undo(&name, ctx);
                });
            }
            SshHostFormAction::SelectLabel(name) => {
                let current = self.label_editor.as_ref(ctx).buffer_text(ctx);
                let new_text = if current.trim().is_empty() {
                    name.clone()
                } else if current.trim_end().ends_with(',') {
                    format!("{} {}", current.trim_end(), name)
                } else {
                    // Replace the last word (what the user is currently typing) with the chip
                    let prefix = match current.rfind(',') {
                        Some(pos) => &current[..=pos],
                        None => "",
                    };
                    format!("{} {}", prefix.trim_end(), name).trim_start().to_string()
                };
                self.label_editor.update(ctx, |e, ctx| {
                    e.set_buffer_text_ignoring_undo(&new_text, ctx);
                });
            }
        }
    }
}
