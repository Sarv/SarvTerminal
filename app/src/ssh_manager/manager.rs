use std::collections::HashMap;

use warpui::elements::{
    Border, ChildView, ClippedScrollStateHandle, ClippedScrollable, Container,
    CrossAxisAlignment, Element, Expanded, Fill, Flex, MainAxisSize,
    MouseStateHandle, Padding, ParentElement, ScrollbarWidth, Shrinkable, Text,
};
use warpui::fonts::{Properties, Weight};
use warpui::ui_components::button::ButtonVariant;
use warpui::ui_components::components::{Coords, UiComponent, UiComponentStyles};
use warpui::{AppContext, Entity, SingletonEntity, TypedActionView, View, ViewContext, ViewHandle};

use persistence::model::{SshGroup, SshHost};

use crate::appearance::Appearance;
use crate::editor::{EditorView, Event as EditorEvent, SingleLineEditorOptions};
use crate::ssh_manager::host_form::{SshHostForm, SshHostFormEvent};

const SCROLLBAR_WIDTH: f32 = 6.;
const PANEL_PADDING: f32 = 20.;
const TITLE_FONT_SIZE: f32 = 16.;
const LABEL_FONT_SIZE: f32 = 12.;
const ROW_PADDING_V: f32 = 6.;
const TAB_FONT_SIZE: f32 = 12.;

// ── Events ──────────────────────────────────────────────────────────────────

pub enum SshManagerEvent {
    Close,
    Connect { alias: String, host: String, port: i32, user: String, pass: String },
    HostCreated { group_name: String, label: String, alias: String, host: String, port: i32, user: String, pass: String, notes: Option<String> },
    HostUpdated { id: i32, group_name: String, label: String, alias: String, host: String, port: i32, user: String, pass: String, notes: Option<String> },
    HostDeleted(i32),
    GroupCreated { name: String, parent_id: Option<i32> },
    GroupDeleted(i32),
    GroupRenamed { id: i32, name: String },
    LabelRenamed { old_name: String, new_name: String },
    LabelRemoved(String),
    LabelsCreated(Vec<String>),
}

// ── Actions ──────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub enum SshManagerAction {
    // Tab switching
    SwitchTab(SshManagerTab),
    // Servers tab
    Close,
    ConnectHost(i32),
    EditHost(i32),
    DeleteHost(i32),
    AddHost,
    OpenGroup(i32),
    NavigateToLevel(usize),
    // Groups tab
    AddGroup,
    DeleteGroup(i32),
    BeginRenameGroup(i32),
    ConfirmRenameGroup,
    CancelRenameGroup,
    // Labels tab
    BeginRenameLabel(String),
    ConfirmRenameLabel,
    CancelRenameLabel,
    RemoveLabel(String),
    AddLabel,
    // Group parent selector
    SelectParentGroup(Option<i32>),
    ConfirmDeleteGroup(i32),
    CancelDeleteGroup,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum SshManagerTab {
    Servers,
    Groups,
    Labels,
}

// ── Helper state structs ─────────────────────────────────────────────────────

struct HostRowStates {
    connect: MouseStateHandle,
    edit: MouseStateHandle,
    delete: MouseStateHandle,
}
impl HostRowStates {
    fn new() -> Self { Self { connect: Default::default(), edit: Default::default(), delete: Default::default() } }
}

struct GroupManageStates {
    rename: MouseStateHandle,
    delete: MouseStateHandle,
}
impl GroupManageStates {
    fn new() -> Self { Self { rename: Default::default(), delete: Default::default() } }
}

struct LabelManageStates {
    rename: MouseStateHandle,
    remove: MouseStateHandle,
}
impl LabelManageStates {
    fn new() -> Self { Self { rename: Default::default(), remove: Default::default() } }
}

// ── Main struct ───────────────────────────────────────────────────────────────

pub struct SshManager {
    pub groups: Vec<SshGroup>,
    pub hosts: Vec<SshHost>,

    // Tab
    active_tab: SshManagerTab,
    tab_servers_state: MouseStateHandle,
    tab_groups_state: MouseStateHandle,
    tab_labels_state: MouseStateHandle,

    // Host form (Servers tab)
    host_form: ViewHandle<SshHostForm>,
    show_form: bool,
    edit_host_id: Option<i32>,
    scroll_state: ClippedScrollStateHandle,
    add_state: MouseStateHandle,
    back_state: MouseStateHandle,
    row_states: Vec<HostRowStates>,
    search_editor: ViewHandle<EditorView>,
    nav_path: Vec<SshGroup>,
    /// One handle per group card at current level (stable across renders).
    group_card_states: Vec<MouseStateHandle>,
    /// Stable handle for the "Root" breadcrumb button.
    nav_root_crumb_state: MouseStateHandle,
    /// One handle per entry in nav_path (breadcrumb entries), rebuilt when nav_path changes.
    nav_crumb_states: Vec<MouseStateHandle>,

    // Groups tab
    groups_scroll: ClippedScrollStateHandle,
    group_manage_states: Vec<GroupManageStates>,
    rename_group_id: Option<i32>,
    rename_group_editor: ViewHandle<EditorView>,
    rename_group_confirm: MouseStateHandle,
    rename_group_cancel: MouseStateHandle,
    add_group_editor: ViewHandle<EditorView>,
    add_group_state: MouseStateHandle,
    add_group_parent_id: Option<i32>,
    /// Stable handle for the "Root" parent chip button in create-group form.
    add_group_none_chip_state: MouseStateHandle,
    add_group_parent_chip_states: Vec<MouseStateHandle>,
    pending_delete_group_id: Option<i32>,
    confirm_delete_group: MouseStateHandle,
    cancel_delete_group: MouseStateHandle,

    // Labels tab
    labels_scroll: ClippedScrollStateHandle,
    /// Ordered list of unique labels (from hosts + standalone ssh_labels table).
    label_list: Vec<String>,
    standalone_labels: Vec<String>,
    label_manage_states: Vec<LabelManageStates>,
    rename_label_name: Option<String>,
    rename_label_editor: ViewHandle<EditorView>,
    rename_label_confirm: MouseStateHandle,
    rename_label_cancel: MouseStateHandle,
    add_label_editor: ViewHandle<EditorView>,
    add_label_state: MouseStateHandle,
}

impl SshManager {
    pub fn new(ctx: &mut ViewContext<Self>) -> Self {
        let host_form = ctx.add_typed_action_view(SshHostForm::new);
        ctx.subscribe_to_view(&host_form, |me, _, event, ctx| me.handle_form_event(event, ctx));

        let search_editor = ctx.add_typed_action_view(|ctx| {
            let mut e = EditorView::single_line(SingleLineEditorOptions::default(), ctx);
            e.set_placeholder_text("Search hosts…", ctx);
            e
        });
        ctx.subscribe_to_view(&search_editor, |_, _, event, ctx| {
            if !matches!(event, EditorEvent::Escape) { ctx.notify(); }
        });

        let rename_group_editor = ctx.add_typed_action_view(|ctx| {
            let mut e = EditorView::single_line(SingleLineEditorOptions::default(), ctx);
            e.set_placeholder_text("New group name…", ctx);
            e
        });
        ctx.subscribe_to_view(&rename_group_editor, |me, _, event, ctx| {
            if matches!(event, EditorEvent::Escape) { me.rename_group_id = None; ctx.notify(); }
        });

        let add_group_editor = ctx.add_typed_action_view(|ctx| {
            let mut e = EditorView::single_line(SingleLineEditorOptions::default(), ctx);
            e.set_placeholder_text("New group name…", ctx);
            e
        });

        let rename_label_editor = ctx.add_typed_action_view(|ctx| {
            let mut e = EditorView::single_line(SingleLineEditorOptions::default(), ctx);
            e.set_placeholder_text("New label name…", ctx);
            e
        });
        ctx.subscribe_to_view(&rename_label_editor, |me, _, event, ctx| {
            if matches!(event, EditorEvent::Escape) { me.rename_label_name = None; ctx.notify(); }
        });

        let add_label_editor = ctx.add_typed_action_view(|ctx| {
            let mut e = EditorView::single_line(SingleLineEditorOptions::default(), ctx);
            e.set_placeholder_text("New label name…", ctx);
            e
        });

        Self {
            groups: Vec::new(),
            hosts: Vec::new(),

            active_tab: SshManagerTab::Servers,
            tab_servers_state: Default::default(),
            tab_groups_state: Default::default(),
            tab_labels_state: Default::default(),

            host_form,
            show_form: false,
            edit_host_id: None,
            scroll_state: Default::default(),
            add_state: Default::default(),
            back_state: Default::default(),
            row_states: Vec::new(),
            search_editor,
            nav_path: Vec::new(),
            group_card_states: Vec::new(),
            nav_root_crumb_state: Default::default(),
            nav_crumb_states: Vec::new(),

            groups_scroll: Default::default(),
            group_manage_states: Vec::new(),
            rename_group_id: None,
            rename_group_editor,
            rename_group_confirm: Default::default(),
            rename_group_cancel: Default::default(),
            add_group_editor,
            add_group_state: Default::default(),
            add_group_parent_id: None,
            add_group_none_chip_state: Default::default(),
            add_group_parent_chip_states: Vec::new(),
            pending_delete_group_id: None,
            confirm_delete_group: Default::default(),
            cancel_delete_group: Default::default(),

            labels_scroll: Default::default(),
            label_list: Vec::new(),
            standalone_labels: Vec::new(),
            label_manage_states: Vec::new(),
            rename_label_name: None,
            rename_label_editor,
            rename_label_confirm: Default::default(),
            rename_label_cancel: Default::default(),
            add_label_editor,
            add_label_state: Default::default(),
        }
    }

    pub fn on_open(&mut self, groups: Vec<SshGroup>, hosts: Vec<SshHost>, standalone_labels: Vec<String>, ctx: &mut ViewContext<Self>) {
        self.groups = groups;
        self.hosts = hosts;
        self.standalone_labels = standalone_labels;
        self.show_form = false;
        self.edit_host_id = None;
        self.rename_group_id = None;
        self.rename_label_name = None;
        self.add_group_parent_id = None;
        self.nav_path = Vec::new();
        self.rebuild_row_states();
        self.rebuild_group_card_states();
        self.rebuild_group_manage_states();
        self.rebuild_add_group_parent_chip_states();
        self.rebuild_nav_crumb_states();
        self.rebuild_label_list();
        ctx.notify();
    }

    pub fn on_close(&mut self, ctx: &mut ViewContext<Self>) {
        self.show_form = false;
        self.edit_host_id = None;
        ctx.notify();
    }

    fn rebuild_row_states(&mut self) {
        self.row_states = self.hosts.iter().map(|_| HostRowStates::new()).collect();
    }

    fn rebuild_group_card_states(&mut self) {
        let current_group_id = self.nav_path.last().map(|g| g.id);
        let count = self.groups.iter().filter(|g| g.parent_id == current_group_id).count();
        if self.group_card_states.len() != count {
            self.group_card_states = (0..count).map(|_| MouseStateHandle::default()).collect();
        }
    }

    fn rebuild_group_manage_states(&mut self) {
        let n = self.groups.len();
        if self.group_manage_states.len() != n {
            self.group_manage_states = (0..n).map(|_| GroupManageStates::new()).collect();
        }
    }

    fn rebuild_label_list(&mut self) {
        let mut seen = std::collections::HashSet::new();
        let mut all: Vec<String> = Vec::new();
        for l in &self.standalone_labels {
            if !l.is_empty() && seen.insert(l.clone()) {
                all.push(l.clone());
            }
        }
        for h in &self.hosts {
            for part in h.label.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
                if seen.insert(part.clone()) {
                    all.push(part);
                }
            }
        }
        all.sort();
        self.label_list = all;
        let n = self.label_list.len();
        if self.label_manage_states.len() != n {
            self.label_manage_states = (0..n).map(|_| LabelManageStates::new()).collect();
        }
    }

    fn rebuild_add_group_parent_chip_states(&mut self) {
        let n = self.groups.len();
        if self.add_group_parent_chip_states.len() != n {
            self.add_group_parent_chip_states = (0..n).map(|_| MouseStateHandle::default()).collect();
        }
    }

    fn rebuild_nav_crumb_states(&mut self) {
        let n = self.nav_path.len();
        if self.nav_crumb_states.len() != n {
            self.nav_crumb_states = (0..n).map(|_| MouseStateHandle::default()).collect();
        }
    }

    fn handle_form_event(&mut self, event: &SshHostFormEvent, ctx: &mut ViewContext<Self>) {
        match event {
            SshHostFormEvent::Cancel => {
                self.show_form = false;
                self.edit_host_id = None;
                ctx.notify();
            }
            SshHostFormEvent::Submit { group_name, label, alias, host, port, user, pass, notes } => {
                if let Some(id) = self.edit_host_id {
                    ctx.emit(SshManagerEvent::HostUpdated {
                        id,
                        group_name: group_name.clone(), label: label.clone(),
                        alias: alias.clone(), host: host.clone(), port: *port,
                        user: user.clone(), pass: pass.clone(), notes: notes.clone(),
                    });
                } else {
                    ctx.emit(SshManagerEvent::HostCreated {
                        group_name: group_name.clone(), label: label.clone(),
                        alias: alias.clone(), host: host.clone(), port: *port,
                        user: user.clone(), pass: pass.clone(), notes: notes.clone(),
                    });
                }
                self.show_form = false;
                self.edit_host_id = None;
                ctx.notify();
            }
        }
    }
}

// ── Render helpers ────────────────────────────────────────────────────────────

impl SshManager {
    fn render_tab_bar(&self, appearance: &Appearance) -> Box<dyn Element> {
        let theme = appearance.theme();

        let make_tab = |label: &str, tab: SshManagerTab, state: MouseStateHandle| {
            let active = self.active_tab == tab;
            appearance
                .ui_builder()
                .button(
                    if active { ButtonVariant::Accent } else { ButtonVariant::Text },
                    state,
                )
                .with_text_label(label.to_string())
                .with_style(
                    UiComponentStyles::default()
                        .set_font_size(TAB_FONT_SIZE)
                        .set_border_width(0.)
                        .set_padding(Coords::uniform(6.).left(12.).right(12.)),
                )
                .build()
                .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                    ctx.dispatch_typed_action(SshManagerAction::SwitchTab(tab));
                })
                .finish()
        };

        Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(4.)
                .with_child(make_tab("Servers", SshManagerTab::Servers, self.tab_servers_state.clone()))
                .with_child(make_tab("Groups", SshManagerTab::Groups, self.tab_groups_state.clone()))
                .with_child(make_tab("Labels", SshManagerTab::Labels, self.tab_labels_state.clone()))
                .finish(),
        )
        .with_padding_left(PANEL_PADDING)
        .with_padding_right(PANEL_PADDING)
        .with_padding_top(8.)
        .with_padding_bottom(4.)
        .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
        .finish()
    }

    fn render_host_row(&self, ssh_host: &SshHost, appearance: &Appearance) -> Box<dyn Element> {
        let theme = appearance.theme();
        let font = appearance.ui_font_family();
        let idx = self.hosts.iter().position(|h| h.id == ssh_host.id).unwrap_or(0);
        let states = &self.row_states[idx.min(self.row_states.len().saturating_sub(1))];
        let host_id = ssh_host.id;

        let alias_text = Text::new_inline(ssh_host.alias.clone(), font, appearance.ui_font_size())
            .with_style(Properties::default().weight(Weight::Medium))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let label_parts: Vec<&str> = ssh_host.label.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
        let sub_parts: Vec<String> = label_parts.iter().map(|s| s.to_string())
            .chain(std::iter::once(format!("{}@{}:{}", ssh_host.user, ssh_host.host, ssh_host.port)))
            .collect();

        let detail_text = Text::new_inline(sub_parts.join("  ·  "), font, LABEL_FONT_SIZE)
            .with_color(theme.sub_text_color(theme.background()).into())
            .finish();

        let connect_btn = appearance.ui_builder()
            .button(ButtonVariant::Accent, states.connect.clone())
            .with_text_label("Connect".to_string())
            .build()
            .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::ConnectHost(host_id));
            })
            .finish();

        let edit_btn = appearance.ui_builder()
            .button(ButtonVariant::Basic, states.edit.clone())
            .with_text_label("Edit".to_string())
            .build()
            .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::EditHost(host_id));
            })
            .finish();

        let delete_btn = appearance.ui_builder()
            .button(ButtonVariant::Basic, states.delete.clone())
            .with_text_label("Delete".to_string())
            .build()
            .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::DeleteHost(host_id));
            })
            .finish();

        let btn_row = Flex::row()
            .with_cross_axis_alignment(CrossAxisAlignment::Center)
            .with_main_axis_size(MainAxisSize::Min)
            .with_spacing(8.)
            .with_child(connect_btn)
            .with_child(edit_btn)
            .with_child(delete_btn)
            .finish();

        let mut info_col = Flex::column();
        info_col.add_child(alias_text);
        info_col.add_child(detail_text);

        Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_main_axis_size(MainAxisSize::Max)
                .with_child(Expanded::new(1., info_col.finish()).finish())
                .with_child(btn_row)
                .finish(),
        )
        .with_padding_top(ROW_PADDING_V)
        .with_padding_bottom(ROW_PADDING_V)
        .with_padding_left(PANEL_PADDING)
        .with_padding_right(PANEL_PADDING)
        .finish()
    }

    fn render_servers_tab(&self, app: &AppContext) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let theme = appearance.theme();
        let font = appearance.ui_font_family();

        let query = self.search_editor.as_ref(app).buffer_text(app).trim().to_lowercase();
        let searching = !query.is_empty();

        // Header: title + Add button
        let title = Text::new_inline("SSH Manager".to_string(), font, TITLE_FONT_SIZE)
            .with_style(Properties::default().weight(Weight::Bold))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let add_btn = appearance.ui_builder()
            .button(ButtonVariant::Basic, self.add_state.clone())
            .with_text_label("+ Add".to_string())
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::AddHost);
            })
            .finish();

        let header = Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_main_axis_size(MainAxisSize::Max)
                .with_child(
                    Expanded::new(1., title).finish(),
                )
                .with_child(add_btn)
                .finish(),
        )
        .with_padding(Padding::uniform(PANEL_PADDING))
        .with_padding_bottom(8.)
        .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
        .finish();

        // Search bar with visible border
        let search_bar = Container::new(ChildView::new(&self.search_editor).finish())
            .with_padding_left(PANEL_PADDING)
            .with_padding_right(PANEL_PADDING)
            .with_padding_top(8.)
            .with_padding_bottom(4.)
            .finish();

        let mut top = Flex::column().with_cross_axis_alignment(CrossAxisAlignment::Stretch);
        top.add_child(header);
        top.add_child(self.render_tab_bar(appearance));
        top.add_child(search_bar);

        // Breadcrumb (when inside a group and not searching)
        if !self.nav_path.is_empty() && !searching {
            let back_btn = appearance.ui_builder()
                .button(ButtonVariant::Text, self.back_state.clone())
                .with_text_label("←".to_string())
                .build()
                .on_click(|ctx: &mut warpui::EventContext, _, _| {
                    ctx.dispatch_typed_action(SshManagerAction::NavigateToLevel(usize::MAX));
                })
                .finish();

            let mut crumbs = Flex::row().with_cross_axis_alignment(CrossAxisAlignment::Center).with_spacing(4.);

            crumbs.add_child(
                appearance.ui_builder()
                    .button(ButtonVariant::Text, self.nav_root_crumb_state.clone())
                    .with_text_label("Root".to_string())
                    .build()
                    .on_click(|ctx: &mut warpui::EventContext, _, _| {
                        ctx.dispatch_typed_action(SshManagerAction::NavigateToLevel(0));
                    })
                    .finish()
            );

            for (i, group) in self.nav_path.iter().enumerate() {
                let sep = Text::new_inline(" ›".to_string(), font, LABEL_FONT_SIZE)
                    .with_color(theme.sub_text_color(theme.background()).into())
                    .finish();
                crumbs.add_child(sep);

                let level = i + 1;
                let name = group.name.clone();
                let is_last = i == self.nav_path.len() - 1;
                let crumb_state = self.nav_crumb_states.get(i).cloned().unwrap_or_default();
                crumbs.add_child(
                    appearance.ui_builder()
                        .button(if is_last { ButtonVariant::Accent } else { ButtonVariant::Text }, crumb_state)
                        .with_text_label(name)
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::NavigateToLevel(level));
                        })
                        .finish()
                );
            }

            top.add_child(
                Container::new(
                    Flex::row()
                        .with_cross_axis_alignment(CrossAxisAlignment::Center)
                        .with_spacing(8.)
                        .with_child(back_btn)
                        .with_child(crumbs.finish())
                        .finish(),
                )
                .with_padding_left(PANEL_PADDING)
                .with_padding_right(PANEL_PADDING)
                .with_padding_top(4.)
                .with_padding_bottom(4.)
                .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
                .finish(),
            );
        }

        // Body
        let mut body = Flex::column();

        if searching {
            let matched: Vec<&SshHost> = self.hosts.iter()
                .filter(|h| {
                    h.alias.to_lowercase().contains(&query)
                        || h.label.to_lowercase().contains(&query)
                        || h.host.to_lowercase().contains(&query)
                        || h.user.to_lowercase().contains(&query)
                })
                .collect();
            if matched.is_empty() {
                body.add_child(
                    Container::new(
                        Text::new_inline("No matching hosts.".to_string(), font, appearance.ui_font_size())
                            .with_color(theme.sub_text_color(theme.background()).into())
                            .finish(),
                    )
                    .with_padding(Padding::uniform(PANEL_PADDING))
                    .finish(),
                );
            } else {
                for h in matched { body.add_child(self.render_host_row(h, appearance)); }
            }
        } else {
            let current_group_id = self.nav_path.last().map(|g| g.id);

            let subgroups: Vec<&SshGroup> = self.groups.iter()
                .filter(|g| g.parent_id == current_group_id)
                .collect();

            let level_hosts: Vec<&SshHost> = if current_group_id.is_some() {
                self.hosts.iter().filter(|h| Some(h.group_id) == current_group_id).collect()
            } else {
                vec![]
            };

            if subgroups.is_empty() && level_hosts.is_empty() {
                body.add_child(
                    Container::new(
                        Text::new_inline("No SSH hosts here. Click + Add to create one.".to_string(), font, appearance.ui_font_size())
                            .with_color(theme.sub_text_color(theme.background()).into())
                            .finish(),
                    )
                    .with_padding(Padding::uniform(PANEL_PADDING))
                    .finish(),
                );
            } else {
                for (idx, group) in subgroups.iter().enumerate() {
                    let group_id = group.id;
                    let host_count = self.hosts.iter().filter(|h| h.group_id == group_id).count();
                    let label = format!("{}  ({} host{})", group.name, host_count, if host_count == 1 { "" } else { "s" });

                    let card_state = self.group_card_states.get(idx).cloned().unwrap_or_default();
                    body.add_child(
                        Container::new(
                            appearance.ui_builder()
                                .button(ButtonVariant::Basic, card_state)
                                .with_text_label(label)
                                .build()
                                .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                                    ctx.dispatch_typed_action(SshManagerAction::OpenGroup(group_id));
                                })
                                .finish()
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .finish(),
                    );
                }
                for h in level_hosts { body.add_child(self.render_host_row(h, appearance)); }
            }
        }

        let scrollable = ClippedScrollable::vertical(
            self.scroll_state.clone(),
            Container::new(body.finish()).with_padding_top(4.).finish(),
            ScrollbarWidth::Custom(SCROLLBAR_WIDTH),
            theme.disabled_text_color(theme.background()).into(),
            theme.main_text_color(theme.background()).into(),
            Fill::None,
        )
        .finish();

        Flex::column()
            .with_main_axis_size(MainAxisSize::Min)
            .with_cross_axis_alignment(CrossAxisAlignment::Stretch)
            .with_child(top.finish())
            .with_child(Shrinkable::new(1., scrollable).finish())
            .finish()
    }

    fn render_groups_tab(&self, app: &AppContext) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let theme = appearance.theme();
        let font = appearance.ui_font_family();

        let title = Text::new_inline("Manage Groups".to_string(), font, TITLE_FONT_SIZE)
            .with_style(Properties::default().weight(Weight::Bold))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let header = Container::new(title)
            .with_padding(Padding::uniform(PANEL_PADDING))
            .with_padding_bottom(8.)
            .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
            .finish();

        // Add-group form
        let add_btn = appearance.ui_builder()
            .button(ButtonVariant::Accent, self.add_group_state.clone())
            .with_text_label("Create".to_string())
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::AddGroup);
            })
            .finish();

        let add_row = Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(8.)
                .with_child(Shrinkable::new(1., ChildView::new(&self.add_group_editor).finish()).finish())
                .with_child(add_btn)
                .finish(),
        )
        .with_padding_left(PANEL_PADDING)
        .with_padding_right(PANEL_PADDING)
        .with_padding_top(12.)
        .with_padding_bottom(4.)
        .finish();

        // Parent group selector chips
        let parent_label_text = Text::new_inline(
            {
                let name = self.add_group_parent_id
                    .and_then(|pid| self.groups.iter().find(|g| g.id == pid).map(|g| g.name.clone()))
                    .unwrap_or_else(|| "Root".to_string());
                format!("Parent: {name}")
            },
            font, LABEL_FONT_SIZE,
        )
        .with_color(theme.sub_text_color(theme.background()).into())
        .finish();

        let mut parent_chips = Flex::row()
            .with_cross_axis_alignment(CrossAxisAlignment::Center)
            .with_spacing(4.);

        parent_chips.add_child(
            appearance.ui_builder()
                .button(
                    if self.add_group_parent_id.is_none() { ButtonVariant::Accent } else { ButtonVariant::Basic },
                    self.add_group_none_chip_state.clone(),
                )
                .with_text_label("Root".to_string())
                .with_style(UiComponentStyles::default().set_font_size(LABEL_FONT_SIZE).set_padding(Coords::uniform(4.).left(8.).right(8.)))
                .build()
                .on_click(|ctx: &mut warpui::EventContext, _, _| {
                    ctx.dispatch_typed_action(SshManagerAction::SelectParentGroup(None));
                })
                .finish(),
        );

        for (idx, group) in self.groups.iter().enumerate() {
            let gid = group.id;
            let gname = group.name.clone();
            let chip_state = self.add_group_parent_chip_states.get(idx).cloned().unwrap_or_default();
            parent_chips.add_child(
                appearance.ui_builder()
                    .button(
                        if self.add_group_parent_id == Some(gid) { ButtonVariant::Accent } else { ButtonVariant::Basic },
                        chip_state,
                    )
                    .with_text_label(gname)
                    .with_style(UiComponentStyles::default().set_font_size(LABEL_FONT_SIZE).set_padding(Coords::uniform(4.).left(8.).right(8.)))
                    .build()
                    .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                        ctx.dispatch_typed_action(SshManagerAction::SelectParentGroup(Some(gid)));
                    })
                    .finish(),
            );
        }

        let parent_row = Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(8.)
                .with_child(parent_label_text)
                .with_child(parent_chips.finish())
                .finish(),
        )
        .with_padding_left(PANEL_PADDING)
        .with_padding_right(PANEL_PADDING)
        .with_padding_bottom(8.)
        .finish();

        let mut body = Flex::column();
        body.add_child(add_row);
        body.add_child(parent_row);

        let host_counts: HashMap<i32, usize> = {
            let mut m = HashMap::new();
            for h in &self.hosts { *m.entry(h.group_id).or_insert(0) += 1; }
            m
        };

        if self.groups.is_empty() {
            body.add_child(
                Container::new(
                    Text::new_inline("No groups yet. Create one above.".to_string(), font, appearance.ui_font_size())
                        .with_color(theme.sub_text_color(theme.background()).into())
                        .finish(),
                )
                .with_padding(Padding::uniform(PANEL_PADDING))
                .finish(),
            );
        } else {
            for (idx, group) in self.groups.iter().enumerate() {
                let group_id = group.id;
                let count = host_counts.get(&group_id).copied().unwrap_or(0);
                let states = &self.group_manage_states[idx.min(self.group_manage_states.len().saturating_sub(1))];

                if self.rename_group_id == Some(group_id) {
                    // Inline rename editor
                    let confirm_btn = appearance.ui_builder()
                        .button(ButtonVariant::Accent, self.rename_group_confirm.clone())
                        .with_text_label("Save".to_string())
                        .build()
                        .on_click(|ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::ConfirmRenameGroup);
                        })
                        .finish();
                    let cancel_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, self.rename_group_cancel.clone())
                        .with_text_label("Cancel".to_string())
                        .build()
                        .on_click(|ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::CancelRenameGroup);
                        })
                        .finish();
                    body.add_child(
                        Container::new(
                            Flex::row()
                                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                                .with_spacing(8.)
                                .with_child(Shrinkable::new(1., ChildView::new(&self.rename_group_editor).finish()).finish())
                                .with_child(confirm_btn)
                                .with_child(cancel_btn)
                                .finish(),
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
                        .finish(),
                    );
                } else if self.pending_delete_group_id == Some(group_id) {
                    // Confirmation row: "Delete 'Name'? (N servers will be removed)"
                    let warn_text = Text::new_inline(
                        format!("Delete \"{}\"? {} server{} will be removed.", group.name, count, if count == 1 { "" } else { "s" }),
                        font, LABEL_FONT_SIZE,
                    )
                    .with_color(theme.ui_error_color())
                    .finish();

                    let yes_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, self.confirm_delete_group.clone())
                        .with_text_label("Delete".to_string())
                        .with_style(UiComponentStyles { font_color: Some(theme.ui_error_color()), ..Default::default() })
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::ConfirmDeleteGroup(group_id));
                        })
                        .finish();

                    let no_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, self.cancel_delete_group.clone())
                        .with_text_label("Cancel".to_string())
                        .build()
                        .on_click(|ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::CancelDeleteGroup);
                        })
                        .finish();

                    body.add_child(
                        Container::new(
                            Flex::row()
                                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                                .with_main_axis_size(MainAxisSize::Max)
                                .with_child(Expanded::new(1., warn_text).finish())
                                .with_child(
                                    Flex::row()
                                        .with_main_axis_size(MainAxisSize::Min)
                                        .with_spacing(8.)
                                        .with_child(yes_btn)
                                        .with_child(no_btn)
                                        .finish(),
                                )
                                .finish(),
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .with_border(Border::bottom(1.).with_border_fill(theme.ui_error_color()))
                        .finish(),
                    );
                } else {
                    let name_text = Text::new_inline(
                        format!("{}  ({} host{})", group.name, count, if count == 1 { "" } else { "s" }),
                        font, appearance.ui_font_size(),
                    )
                    .with_color(theme.main_text_color(theme.background()).into())
                    .finish();

                    let rename_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, states.rename.clone())
                        .with_text_label("Rename".to_string())
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::BeginRenameGroup(group_id));
                        })
                        .finish();

                    let delete_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, states.delete.clone())
                        .with_text_label("Delete".to_string())
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::DeleteGroup(group_id));
                        })
                        .finish();

                    body.add_child(
                        Container::new(
                            Flex::row()
                                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                                .with_main_axis_size(MainAxisSize::Max)
                                .with_child(Expanded::new(1., name_text).finish())
                                .with_child(
                                    Flex::row()
                                        .with_main_axis_size(MainAxisSize::Min)
                                        .with_spacing(8.)
                                        .with_child(rename_btn)
                                        .with_child(delete_btn)
                                        .finish(),
                                )
                                .finish(),
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .finish(),
                    );
                }
            }
        }

        let scrollable = ClippedScrollable::vertical(
            self.groups_scroll.clone(),
            body.finish(),
            ScrollbarWidth::Custom(SCROLLBAR_WIDTH),
            theme.disabled_text_color(theme.background()).into(),
            theme.main_text_color(theme.background()).into(),
            Fill::None,
        )
        .finish();

        Flex::column()
            .with_main_axis_size(MainAxisSize::Min)
            .with_cross_axis_alignment(CrossAxisAlignment::Stretch)
            .with_child(header)
            .with_child(self.render_tab_bar(appearance))
            .with_child(Shrinkable::new(1., scrollable).finish())
            .finish()
    }

    fn render_labels_tab(&self, app: &AppContext) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let theme = appearance.theme();
        let font = appearance.ui_font_family();

        let title = Text::new_inline("Manage Labels".to_string(), font, TITLE_FONT_SIZE)
            .with_style(Properties::default().weight(Weight::Bold))
            .with_color(theme.main_text_color(theme.background()).into())
            .finish();

        let header = Container::new(title)
            .with_padding(Padding::uniform(PANEL_PADDING))
            .with_padding_bottom(8.)
            .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
            .finish();

        // Add-label form
        let add_label_btn = appearance.ui_builder()
            .button(ButtonVariant::Accent, self.add_label_state.clone())
            .with_text_label("Create".to_string())
            .build()
            .on_click(|ctx: &mut warpui::EventContext, _, _| {
                ctx.dispatch_typed_action(SshManagerAction::AddLabel);
            })
            .finish();

        let add_label_row = Container::new(
            Flex::row()
                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                .with_spacing(8.)
                .with_child(Shrinkable::new(1., ChildView::new(&self.add_label_editor).finish()).finish())
                .with_child(add_label_btn)
                .finish(),
        )
        .with_padding_left(PANEL_PADDING)
        .with_padding_right(PANEL_PADDING)
        .with_padding_top(12.)
        .with_padding_bottom(8.)
        .finish();

        let mut body = Flex::column();
        body.add_child(add_label_row);

        let counts: HashMap<&str, usize> = {
            let mut m = HashMap::new();
            for h in &self.hosts {
                if !h.label.is_empty() { *m.entry(h.label.as_str()).or_insert(0) += 1; }
            }
            m
        };

        if self.label_list.is_empty() {
            body.add_child(
                Container::new(
                    Text::new_inline("No labels in use yet.".to_string(), font, appearance.ui_font_size())
                        .with_color(theme.sub_text_color(theme.background()).into())
                        .finish(),
                )
                .with_padding(Padding::uniform(PANEL_PADDING))
                .finish(),
            );
        } else {
            for (idx, label_name) in self.label_list.iter().enumerate() {
                let count = counts.get(label_name.as_str()).copied().unwrap_or(0);
                let states = &self.label_manage_states[idx.min(self.label_manage_states.len().saturating_sub(1))];
                let lname = label_name.clone();

                if self.rename_label_name.as_deref() == Some(label_name.as_str()) {
                    let confirm_btn = appearance.ui_builder()
                        .button(ButtonVariant::Accent, self.rename_label_confirm.clone())
                        .with_text_label("Save".to_string())
                        .build()
                        .on_click(|ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::ConfirmRenameLabel);
                        })
                        .finish();
                    let cancel_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, self.rename_label_cancel.clone())
                        .with_text_label("Cancel".to_string())
                        .build()
                        .on_click(|ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::CancelRenameLabel);
                        })
                        .finish();
                    body.add_child(
                        Container::new(
                            Flex::row()
                                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                                .with_spacing(8.)
                                .with_child(Shrinkable::new(1., ChildView::new(&self.rename_label_editor).finish()).finish())
                                .with_child(confirm_btn)
                                .with_child(cancel_btn)
                                .finish(),
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .with_border(Border::bottom(1.).with_border_fill(theme.outline()))
                        .finish(),
                    );
                } else {
                    let name_text = Text::new_inline(
                        format!("{}  ({} host{})", label_name, count, if count == 1 { "" } else { "s" }),
                        font, appearance.ui_font_size(),
                    )
                    .with_color(theme.main_text_color(theme.background()).into())
                    .finish();

                    let rename_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, states.rename.clone())
                        .with_text_label("Rename".to_string())
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::BeginRenameLabel(lname.clone()));
                        })
                        .finish();

                    let lname2 = label_name.clone();
                    let remove_btn = appearance.ui_builder()
                        .button(ButtonVariant::Basic, states.remove.clone())
                        .with_text_label("Remove".to_string())
                        .build()
                        .on_click(move |ctx: &mut warpui::EventContext, _, _| {
                            ctx.dispatch_typed_action(SshManagerAction::RemoveLabel(lname2.clone()));
                        })
                        .finish();

                    body.add_child(
                        Container::new(
                            Flex::row()
                                .with_cross_axis_alignment(CrossAxisAlignment::Center)
                                .with_main_axis_size(MainAxisSize::Max)
                                .with_child(Expanded::new(1., name_text).finish())
                                .with_child(
                                    Flex::row()
                                        .with_main_axis_size(MainAxisSize::Min)
                                        .with_spacing(8.)
                                        .with_child(rename_btn)
                                        .with_child(remove_btn)
                                        .finish(),
                                )
                                .finish(),
                        )
                        .with_padding_top(ROW_PADDING_V)
                        .with_padding_bottom(ROW_PADDING_V)
                        .with_padding_left(PANEL_PADDING)
                        .with_padding_right(PANEL_PADDING)
                        .finish(),
                    );
                }
            }
        }

        let scrollable = ClippedScrollable::vertical(
            self.labels_scroll.clone(),
            body.finish(),
            ScrollbarWidth::Custom(SCROLLBAR_WIDTH),
            theme.disabled_text_color(theme.background()).into(),
            theme.main_text_color(theme.background()).into(),
            Fill::None,
        )
        .finish();

        Flex::column()
            .with_main_axis_size(MainAxisSize::Min)
            .with_cross_axis_alignment(CrossAxisAlignment::Stretch)
            .with_child(header)
            .with_child(self.render_tab_bar(appearance))
            .with_child(Shrinkable::new(1., scrollable).finish())
            .finish()
    }
}

// ── Entity / View / TypedActionView ──────────────────────────────────────────

impl Entity for SshManager {
    type Event = SshManagerEvent;
}

impl View for SshManager {
    fn ui_name() -> &'static str { "SshManager" }

    fn render(&self, app: &AppContext) -> Box<dyn Element> {
        if self.show_form {
            return ChildView::new(&self.host_form).finish();
        }
        match self.active_tab {
            SshManagerTab::Servers => self.render_servers_tab(app),
            SshManagerTab::Groups  => self.render_groups_tab(app),
            SshManagerTab::Labels  => self.render_labels_tab(app),
        }
    }
}

impl TypedActionView for SshManager {
    type Action = SshManagerAction;

    fn handle_action(&mut self, action: &SshManagerAction, ctx: &mut ViewContext<Self>) {
        match action {
            SshManagerAction::SwitchTab(tab) => {
                self.active_tab = *tab;
                ctx.notify();
            }
            SshManagerAction::Close => ctx.emit(SshManagerEvent::Close),

            // ── Servers tab ──────────────────────────────────────────────────
            SshManagerAction::ConnectHost(id) => {
                if let Some(h) = self.hosts.iter().find(|h| h.id == *id).cloned() {
                    ctx.emit(SshManagerEvent::Connect {
                        alias: h.alias, host: h.host, port: h.port, user: h.user, pass: h.pass,
                    });
                }
            }
            SshManagerAction::EditHost(id) => {
                if let Some(h) = self.hosts.iter().find(|h| h.id == *id).cloned() {
                    self.edit_host_id = Some(*id);
                    self.show_form = true;
                    let groups = self.groups.clone();
                    let labels = self.label_list.clone();
                    self.host_form.update(ctx, |f, ctx| f.open_edit(&h, groups, labels, ctx));
                    ctx.notify();
                }
            }
            SshManagerAction::DeleteHost(id) => ctx.emit(SshManagerEvent::HostDeleted(*id)),
            SshManagerAction::AddHost => {
                self.show_form = true;
                self.edit_host_id = None;
                let groups = self.groups.clone();
                let labels = self.label_list.clone();
                let default_group = self.nav_path.last().map(|g| g.name.clone());
                self.host_form.update(ctx, |f, ctx| f.open_add(groups, labels, default_group, ctx));
                ctx.notify();
            }
            SshManagerAction::OpenGroup(group_id) => {
                if let Some(g) = self.groups.iter().find(|g| g.id == *group_id).cloned() {
                    self.nav_path.push(g);
                    self.rebuild_group_card_states();
                    self.rebuild_nav_crumb_states();
                    ctx.notify();
                }
            }
            SshManagerAction::NavigateToLevel(level) => {
                if *level == usize::MAX { self.nav_path.pop(); } else { self.nav_path.truncate(*level); }
                self.rebuild_group_card_states();
                self.rebuild_nav_crumb_states();
                ctx.notify();
            }

            // ── Groups tab ───────────────────────────────────────────────────
            SshManagerAction::AddGroup => {
                let name = self.add_group_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
                if !name.is_empty() {
                    ctx.emit(SshManagerEvent::GroupCreated { name, parent_id: self.add_group_parent_id });
                    self.add_group_editor.update(ctx, |e, ctx| e.clear_buffer_and_reset_undo_stack(ctx));
                    self.add_group_parent_id = None;
                    ctx.notify();
                }
            }
            SshManagerAction::SelectParentGroup(pid) => {
                self.add_group_parent_id = *pid;
                ctx.notify();
            }
            SshManagerAction::DeleteGroup(id) => {
                let count = self.hosts.iter().filter(|h| h.group_id == *id).count();
                if count > 0 {
                    self.pending_delete_group_id = Some(*id);
                    ctx.notify();
                } else {
                    ctx.emit(SshManagerEvent::GroupDeleted(*id));
                }
            }
            SshManagerAction::ConfirmDeleteGroup(id) => {
                self.pending_delete_group_id = None;
                ctx.emit(SshManagerEvent::GroupDeleted(*id));
            }
            SshManagerAction::CancelDeleteGroup => {
                self.pending_delete_group_id = None;
                ctx.notify();
            }
            SshManagerAction::BeginRenameGroup(id) => {
                if let Some(g) = self.groups.iter().find(|g| g.id == *id) {
                    self.rename_group_id = Some(*id);
                    let name = g.name.clone();
                    self.rename_group_editor.update(ctx, |e, ctx| e.set_buffer_text_ignoring_undo(&name, ctx));
                    ctx.notify();
                }
            }
            SshManagerAction::ConfirmRenameGroup => {
                if let Some(id) = self.rename_group_id {
                    let name = self.rename_group_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
                    if !name.is_empty() { ctx.emit(SshManagerEvent::GroupRenamed { id, name }); }
                    self.rename_group_id = None;
                    ctx.notify();
                }
            }
            SshManagerAction::CancelRenameGroup => {
                self.rename_group_id = None;
                ctx.notify();
            }

            // ── Labels tab ───────────────────────────────────────────────────
            SshManagerAction::BeginRenameLabel(name) => {
                self.rename_label_name = Some(name.clone());
                self.rename_label_editor.update(ctx, |e, ctx| e.set_buffer_text_ignoring_undo(name, ctx));
                ctx.notify();
            }
            SshManagerAction::ConfirmRenameLabel => {
                if let Some(ref old) = self.rename_label_name.take() {
                    let new_name = self.rename_label_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
                    if !new_name.is_empty() && &new_name != old {
                        ctx.emit(SshManagerEvent::LabelRenamed { old_name: old.clone(), new_name });
                    }
                }
                ctx.notify();
            }
            SshManagerAction::CancelRenameLabel => {
                self.rename_label_name = None;
                ctx.notify();
            }
            SshManagerAction::RemoveLabel(name) => ctx.emit(SshManagerEvent::LabelRemoved(name.clone())),
            SshManagerAction::AddLabel => {
                let input = self.add_label_editor.as_ref(ctx).buffer_text(ctx).trim().to_string();
                let new_labels: Vec<String> = input
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty() && !self.label_list.contains(s))
                    .collect();
                if !new_labels.is_empty() {
                    ctx.emit(SshManagerEvent::LabelsCreated(new_labels));
                    self.add_label_editor.update(ctx, |e, ctx| e.clear_buffer_and_reset_undo_stack(ctx));
                }
            }
        }
    }
}
