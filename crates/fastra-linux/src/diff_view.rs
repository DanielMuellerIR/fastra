//! Dateivergleich: gebundene Hintergrundbasis und eine bestätigte Editor-Übernahme.
use super::{buffer_text, chrome, git_view as support, Language, Ui};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::Arc,
};
fn document_error(lang: Language, error: fastra_document::Error) -> String {
    match error {
        fastra_document::Error::Stale => lang
            .text(
                "Die Vergleichsdatei hat sich geändert. Neu vergleichen.",
                "The comparison file changed. Compare again.",
            )
            .into(),
        fastra_document::Error::Cancelled => lang
            .text("Vergleich abgebrochen.", "Comparison cancelled.")
            .into(),
        other => format!(
            "{}: {other}",
            lang.text(
                "Datei nicht als vollständigen Text gelesen",
                "File not read as complete text"
            )
        ),
    }
}
fn diff_error(lang: Language, error: fastra_diff::Error) -> String {
    match error {
        fastra_diff::Error::Stale => lang
            .text(
                "Die Vergleichsbasis ist veraltet. Neu vergleichen.",
                "The comparison basis is stale. Compare again.",
            )
            .into(),
        fastra_diff::Error::Cancelled => lang
            .text("Vergleich abgebrochen.", "Comparison cancelled.")
            .into(),
        fastra_diff::Error::Limit(reason) => match reason {
            "diff work" => lang.text("Der Vergleich überschreitet das Rechenbudget. Kleinere Abschnitte vergleichen; es wurde kein Teilergebnis übernommen.", "The comparison exceeds the computation budget. Compare smaller sections; no partial result was adopted."),
            "unanchored diff range" => lang.text("Ein Bereich ohne gemeinsame Zeilen ist für den Vergleich zu groß. Kleinere Abschnitte vergleichen.", "A section without shared lines is too large to compare. Compare smaller sections."),
            "text bytes" | "transfer output" => lang.text("Vergleichstext oder Übernahme überschreitet 32 MiB. Kleinere Abschnitte vergleichen.", "Comparison text or transfer output exceeds 32 MiB. Compare smaller sections."),
            "line count" | "line count or memory" => lang.text("Der Vergleich überschreitet 200.000 Zeilen oder das Speicherbudget. Kleinere Abschnitte vergleichen.", "The comparison exceeds 200,000 lines or the memory budget. Compare smaller sections."),
            "diff report bytes" => lang.text("Der vollständige Bericht überschreitet 64 MiB. Nichts exportiert.", "The complete report exceeds 64 MiB. Nothing exported."),
            "normalization combining run" => lang.text("Eine Zeichenfolge enthält mehr als 4.096 kombinierende Zeichen. Der Vergleich wurde ohne Teilergebnis abgebrochen.", "A character sequence contains more than 4,096 combining marks. Comparison stopped without a partial result."),
            "diff memory" | "case key bytes" | "comparison key bytes" | "key bytes" | "key count" => lang.text("Der Vergleich überschreitet das Speicherbudget. Kleinere Abschnitte vergleichen; es wurde kein Teilergebnis übernommen.", "The comparison exceeds the memory budget. Compare smaller sections; no partial result was adopted."),
            _ => lang.text("Der Vergleich überschreitet eine unterstützte Grenze. Es wurde kein Teilergebnis übernommen.", "The comparison exceeds a supported limit. No partial result was adopted."),
        }.into(),
        fastra_diff::Error::InvalidBlock | fastra_diff::Error::OverlappingBlocks | fastra_diff::Error::InvalidRange => lang.text("Der gewählte Unterschied ist nicht mehr gültig. Neu vergleichen.", "The selected difference is no longer valid. Compare again.").into(),
        fastra_diff::Error::NoChange => lang.text("Der gewählte Unterschied ändert das Ziel nicht.", "The selected difference does not change the destination.").into(),
        other => format!(
            "{}: {other}",
            lang.text(
                "Vergleich oder Übernahme nicht möglich",
                "Comparison or transfer unavailable"
            )
        ),
    }
}
#[derive(Clone, Default)]
struct Cancel {
    diff: fastra_diff::Cancellation,
    io: fastra_core::Cancellation,
    viewer: crate::viewer::Cancellation,
}
impl Cancel {
    fn cancel(&self) {
        self.diff.cancel();
        self.io.cancel();
        self.viewer.cancel();
    }
}
mod alignment;
mod columns;
mod annotations;
mod export;
mod folding;
mod picker;
mod preferences;
mod presentation;
mod result;
mod ruler;
mod sources;
mod transfer;
mod palette;
mod view;
mod readonly;
pub(super) use readonly::{ReadOnly, ReadOnlyData};
pub(super) use result::State;
pub(super) fn open(ui: &Rc<Ui>) -> Rc<State> {
    result::open(ui)
}
pub(super) fn eligible(doc: &crate::Document) -> bool { sources::eligible(doc) }
pub(super) fn open_documents(ui: &Rc<Ui>, documents: [Rc<crate::Document>; 2]) -> Rc<State> {
    result::open_documents(ui, documents)
}

pub(super) fn open_pair(
    ui: &Rc<Ui>,
    left: PathBuf,
    right: PathBuf,
) -> Rc<State> {
    result::open_pair(ui, left, right)
}
pub(super) fn open_saved(ui: &Rc<Ui>) -> Option<Rc<State>> { result::open_saved(ui) }
pub(super) fn remember_opened(ui: &Rc<Ui>, path: PathBuf) {
    preferences::remember(ui, path);
}
#[cfg(debug_assertions)]
mod drop_selftest;
#[cfg(debug_assertions)]
mod interaction_selftest;
#[cfg(debug_assertions)]
mod entrypoints_selftest;
#[cfg(debug_assertions)]
mod export_selftest;
#[cfg(debug_assertions)]
mod guards_selftest;
#[cfg(debug_assertions)]
mod palette_selftest;
#[cfg(debug_assertions)]
mod large_selftest;
#[cfg(debug_assertions)]
mod rich_selftest;
#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
mod states_selftest;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
