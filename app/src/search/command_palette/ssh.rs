use fuzzy_match::{match_indices_case_insensitive, FuzzyMatchResult};
use ordered_float::OrderedFloat;
use warpui::elements::{ConstrainedBox, Container, Flex, ParentElement, Text};
use warpui::fonts::{Properties, Weight};
use warpui::{AppContext, Element, Entity, SingletonEntity};

use crate::appearance::Appearance;
use crate::search::command_palette::mixer::CommandPaletteItemAction;
use crate::search::command_palette::render_util;
use crate::search::data_source::{DataSourceSearchError, Query, QueryResult};
use crate::search::mixer::{DataSourceRunErrorWrapper, SyncDataSource};
use crate::search::result_renderer::ItemHighlightState;
use crate::ui_components::icons::Icon;

// ── SearchItem ────────────────────────────────────────────────────────────────

struct SshSearchItem {
    alias: String,
    host: String,
    port: i32,
    user: String,
    pass: String,
    match_result: FuzzyMatchResult,
}

impl crate::search::item::SearchItem for SshSearchItem {
    type Action = CommandPaletteItemAction;

    fn is_multiline(&self) -> bool {
        true
    }

    fn render_icon(
        &self,
        highlight_state: ItemHighlightState,
        appearance: &Appearance,
    ) -> Box<dyn Element> {
        let color = appearance.theme().foreground().into_solid();
        render_util::render_search_item_icon(appearance, Icon::Globe4, color, highlight_state)
    }

    fn render_item(
        &self,
        highlight_state: ItemHighlightState,
        app: &AppContext,
    ) -> Box<dyn Element> {
        let appearance = Appearance::as_ref(app);
        let font_size = appearance.monospace_font_size();

        let alias_text = Text::new_inline(
            self.alias.clone(),
            appearance.ui_font_family(),
            font_size,
        )
        .with_color(highlight_state.main_text_fill(appearance).into_solid())
        .with_style(Properties::default().weight(Weight::Bold))
        .finish();

        let subtitle = format!("{}@{}:{}", self.user, self.host, self.port);
        let subtitle_text = Text::new_inline(
            subtitle,
            appearance.ui_font_family(),
            font_size * 0.875,
        )
        .with_color(highlight_state.sub_text_fill(appearance).into_solid())
        .finish();

        let mut col = Flex::column();
        col.add_child(alias_text);
        col.add_child(
            Container::new(subtitle_text)
                .with_margin_top(3.)
                .finish(),
        );

        ConstrainedBox::new(Container::new(col.finish()).with_padding_top(8.).with_padding_bottom(8.).finish())
            .with_min_height(56.)
            .finish()
    }

    fn priority_tier(&self) -> u8 {
        // Prioritize SSH hosts above all other command palette results.
        1
    }

    fn score(&self) -> OrderedFloat<f64> {
        OrderedFloat(self.match_result.score as f64)
    }

    fn accept_result(&self) -> Self::Action {
        CommandPaletteItemAction::ConnectSshHost {
            alias: self.alias.clone(),
            host: self.host.clone(),
            port: self.port,
            user: self.user.clone(),
            pass: self.pass.clone(),
        }
    }

    fn execute_result(&self) -> Self::Action {
        self.accept_result()
    }

    fn accessibility_label(&self) -> String {
        format!("Connect to SSH host: {}", self.alias)
    }

    fn accessibility_help_message(&self) -> Option<String> {
        Some("Press enter to connect.".into())
    }
}

// ── DataSource ────────────────────────────────────────────────────────────────

pub struct DataSource;

impl DataSource {
    pub fn new() -> Self {
        Self
    }
}

impl Entity for DataSource {
    type Event = ();
}

impl SyncDataSource for DataSource {
    type Action = CommandPaletteItemAction;

    fn run_query(
        &self,
        query: &Query,
        _app: &AppContext,
    ) -> Result<Vec<QueryResult<Self::Action>>, DataSourceRunErrorWrapper> {
        #[cfg(not(feature = "local_fs"))]
        {
            return Ok(vec![]);
        }

        #[cfg(feature = "local_fs")]
        {
            use crate::persistence::{
                database_file_path_for_scope, establish_rw_connection, PersistenceScope,
            };
            use crate::ssh_manager::db::list_all_hosts;

            let db_path = database_file_path_for_scope(&PersistenceScope::App);
            let hosts = establish_rw_connection(db_path.to_str().unwrap_or(""))
                .map_err(|e| {
                    Box::new(DataSourceSearchError::new(e.to_string()))
                        as DataSourceRunErrorWrapper
                })
                .and_then(|mut conn| {
                    list_all_hosts(&mut conn).map_err(|e| {
                        Box::new(DataSourceSearchError::new(e.to_string()))
                            as DataSourceRunErrorWrapper
                    })
                })?;

            let q = query.text.trim().to_lowercase();

            let results: Vec<QueryResult<Self::Action>> = hosts
                .into_iter()
                .filter_map(|h| {
                    let search_text = format!(
                        "{} {} {} {}",
                        h.alias,
                        h.host,
                        h.user,
                        h.label
                    )
                    .to_lowercase();

                    let match_result = if q.is_empty() {
                        FuzzyMatchResult::no_match()
                    } else {
                        match_indices_case_insensitive(&h.alias, &q)
                            .or_else(|| match_indices_case_insensitive(&search_text, &q))?
                    };

                    Some(QueryResult::from(SshSearchItem {
                        alias: h.alias,
                        host: h.host,
                        port: h.port,
                        user: h.user,
                        pass: h.pass,
                        match_result,
                    }))
                })
                .collect();

            Ok(results)
        }
    }
}
