//! Live-Auslöser bleiben von der Invalidierung innerhalb eines Suchlaufs getrennt.
use super::*;
#[cfg(debug_assertions)]
pub(super) mod selftest;
#[cfg(debug_assertions)]
pub(super) mod detail_test;
fn visible(ui: &Ui) -> bool {
    matches!(ui.scope.selected(), 0 | 4)
        && ui.window.is_visible()
        && ui
            .chrome
            .borrow()
            .as_ref()
            .is_some_and(|shell| shell.search_window.is_visible())
}
pub(super) fn changed(ui: &Rc<Ui>) {
    ui.invalidate();
    schedule(ui);
}
pub(super) fn schedule(ui: &Rc<Ui>) {
    if !visible(ui) || ui.find.text().is_empty() {
        return;
    }
    let generation = ui.generation.get();
    let weak = Rc::downgrade(ui);
    glib::timeout_add_local_once(Duration::from_millis(120), move || {
        let Some(ui) = weak.upgrade().filter(|ui| {
            ui.generation.get() == generation && visible(ui) && !ui.find.text().is_empty()
        }) else {
            return;
        };
        if ui
            .active()
            .is_some_and(|doc| doc.has_source_text() && !doc.is_rich_active() && !doc.close_pending.get())
        {
            ui.search();
        }
    });
}

use unicode_segmentation::UnicodeSegmentation;
pub(super) fn folder_ready(pattern: &str) -> bool {
    pattern
        .trim_matches(|ch: char| ch.is_whitespace() || ch == '\u{200b}')
        .graphemes(true)
        .take(3)
        .count()
        == 3
}
struct SearchWindow {
    owner: std::rc::Weak<Ui>,
    window: glib::WeakRef<gtk::Window>,
    find: glib::WeakRef<gtk::Entry>,
    scope: u32,
}
thread_local! {static WINDOWS:RefCell<Vec<SearchWindow>>=const{RefCell::new(Vec::new())};}
pub(super) fn register(ui: &Rc<Ui>, window: &gtk::Window, find: &gtk::Entry, scope: u32) {
    WINDOWS.with_borrow_mut(|entries| {
        entries.retain(|entry| {
            entry.owner.strong_count() > 0
                && entry.window.upgrade().is_some_and(|old| old.is_visible())
        });
        entries.push(SearchWindow {
            owner: Rc::downgrade(ui),
            window: window.downgrade(),
            find: find.downgrade(),
            scope,
        });
    });
}
pub(super) fn present(ui: &Rc<Ui>) -> bool {
    WINDOWS.with_borrow(|entries| {
        let Some(entry) = entries.iter().rev().find(|entry| {
            entry.scope == ui.scope.selected()
                && entry
                    .owner
                    .upgrade()
                    .is_some_and(|owner| Rc::ptr_eq(&owner, ui))
                && entry
                    .window
                    .upgrade()
                    .is_some_and(|window| window.is_visible())
        }) else {
            return false;
        };
        entry.window.upgrade().unwrap().present();
        if let Some(find) = entry.find.upgrade() {
            find.grab_focus();
            find.select_region(0, -1);
        }
        true
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_folder_live_threshold_counts_visible_characters_and_trims_foundation_spaces() {
        for (text, expected) in [
            ("", false),
            ("a", false),
            ("ab", false),
            ("abc", true),
            (" a b ", true),
            ("e\u{301}x", false),
            ("e\u{301}xy", true),
            ("👩\u{200d}💻x", false),
            ("👩\u{200d}💻xy", true),
            ("\u{200b}\u{200b}\u{200b}", false),
        ] {
            assert_eq!(folder_ready(text), expected, "{text:?}");
        }
    }
}
