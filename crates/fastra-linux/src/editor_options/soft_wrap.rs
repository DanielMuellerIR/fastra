use super::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Default, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) enum Target {
    #[default]
    Window,
    PageGuide,
    FixedColumn,
}
#[derive(Clone, Copy, Default, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(super) enum Indentation {
    FlushLeft,
    #[default]
    FirstLine,
    Reverse,
}

// Nur der geprüfte native Tab-/Graphem-Patch exportiert diese versionierte ABI.
// Eine Pango-Versionsnummer allein belegt das korrigierte Verhalten nicht.
pub(super) fn capable() -> bool {
    static CAPABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *CAPABLE.get_or_init(|| unsafe {
        let symbol = libc::dlsym(
            libc::RTLD_DEFAULT,
            c"pango_fastra_wrap_capability_v1".as_ptr(),
        );
        if symbol.is_null() {
            return false;
        }
        let probe: unsafe extern "C" fn() -> u32 = std::mem::transmute(symbol);
        probe() == 0x4657_0002
    })
}
#[derive(Default)]
struct Pane {
    buffer: glib::WeakRef<gtk::TextBuffer>,
    table: glib::WeakRef<gtk::TextTagTable>,
    tags: Vec<gtk::TextTag>,
    geometry: Option<(i32, u32, u64)>,
    by_indent: BTreeMap<i32, gtk::TextTag>,
    next: Option<i32>,
    until: Option<i32>,
    dirty: Option<(gtk::TextMark, gtk::TextMark)>,
}
impl Pane {
    fn clear(&mut self) {
        if let Some(table) = self.table.upgrade() {
            // Die Table entfernt eigene Tags auch aus einem inzwischen gelösten
            // Buffer; die andere Pane besitzt separate Tags derselben Table.
            for tag in self.tags.drain(..) {
                table.remove(&tag);
            }
        }
        if let (Some(buffer), Some((a, b))) = (self.buffer.upgrade(), self.dirty.take()) {
            buffer.delete_mark(&a);
            buffer.delete_mark(&b);
        }
        self.tags.clear();
        self.by_indent.clear();
        self.next = None;
        self.until = None;
    }
}
impl Drop for Pane {
    fn drop(&mut self) {
        self.clear();
    }
}
#[derive(Default)]
pub(super) struct State {
    target: Cell<Target>,
    column: Cell<u32>,
    indentation: Cell<Indentation>,
    generation: Cell<u64>,
    panes: [RefCell<Pane>; 2],
    controls: RefCell<Vec<glib::WeakRef<gtk::Widget>>>,
}
impl State {
    pub(super) fn invalidate(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
    }
    pub(super) fn update(&self, patch: &profile::Patch) {
        if let Some(v) = patch.wrap_target {
            self.target.set(v);
        }
        if let Some(v) = patch.wrap_column {
            self.column.set(v);
        }
        if let Some(v) = patch.wrap_indentation {
            self.indentation.set(v);
        }
        self.invalidate();
    }
    pub(super) fn commit_controls(&self) {
        let spins: Vec<_> = self
            .controls
            .borrow()
            .iter()
            .filter_map(|w| w.upgrade())
            .filter_map(|w| w.downcast::<gtk::SpinButton>().ok())
            .collect();
        for spin in spins {
            spin.update();
        }
    }
    pub(super) fn clear_controls(&self) {
        self.controls.borrow_mut().clear();
    }
}
pub(super) fn install(state: &Rc<Options>) {
    if !capable() {
        return;
    }
    for (index, view) in state
        .views
        .iter()
        .enumerate()
        .filter_map(|(i, v)| v.upgrade().map(|v| (i, v)))
    {
        let weak = Rc::downgrade(state);
        view.buffer().connect_insert_text(move |buffer, at, _| {
            if let Some(state) = weak.upgrade() {
                mark_dirty(&state, index, buffer, at, at);
            }
        });
        let weak = Rc::downgrade(state);
        view.buffer()
            .connect_delete_range(move |buffer, start, end| {
                if let Some(state) = weak.upgrade() {
                    mark_dirty(&state, index, buffer, start, end);
                }
            });
        let weak = Rc::downgrade(state);
        view.add_tick_callback(move |view, _| {
            let Some(state) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            apply(&state, view, index);
            glib::ControlFlow::Continue
        });
    }
}
fn mark_dirty(
    state: &Options,
    index: usize,
    buffer: &gtk::TextBuffer,
    start: &gtk::TextIter,
    end: &gtk::TextIter,
) {
    let mut pane = state.soft_wrap.panes[index].borrow_mut();
    if pane.geometry.is_none() {
        return;
    }
    if pane.next.is_some() {
        state.soft_wrap.invalidate();
        return;
    }
    let mut start = *start;
    start.set_line_offset(0);
    let mut end = *end;
    end.forward_to_line_end();
    end.forward_char();
    if let Some((a, b)) = &pane.dirty {
        if start < buffer.iter_at_mark(a) {
            buffer.move_mark(a, &start);
        }
        if end > buffer.iter_at_mark(b) {
            buffer.move_mark(b, &end);
        }
    } else {
        pane.dirty = Some((
            buffer.create_mark(None, &start, true),
            buffer.create_mark(None, &end, false),
        ));
    }
}
fn apply(state: &Options, view: &sourceview5::View, index: usize) {
    let buffer = view.buffer();
    let width = view.visible_rect().width();
    if width <= 1 {
        return;
    }
    let signature = (
        width,
        view.pango_context().serial(),
        state.soft_wrap.generation.get(),
    );
    let mut pane = state.soft_wrap.panes[index].borrow_mut();
    if pane.buffer.upgrade().as_ref() != Some(&buffer) || pane.geometry != Some(signature) {
        pane.clear();
        pane.buffer = buffer.downgrade();
        pane.table = buffer.tag_table().downgrade();
        pane.geometry = Some(signature);
        pane.next = Some(0);
    } else if pane.next.is_none() && pane.dirty.is_none() {
        return;
    }
    if let Some((a, b)) = pane.dirty.take() {
        let start = buffer.iter_at_mark(&a);
        let end = buffer.iter_at_mark(&b);
        for tag in &pane.tags {
            buffer.remove_tag(tag, &start, &end);
        }
        pane.next = Some(start.offset());
        pane.until = Some(end.offset());
        buffer.delete_mark(&a);
        buffer.delete_mark(&b);
    }
    if view.wrap_mode() == gtk::WrapMode::None {
        pane.next = None;
        return;
    }
    let cell =
        f64::from(view.create_pango_layout(Some(" ")).size().0) / f64::from(gtk::pango::SCALE);
    if !cell.is_finite() || cell <= 0. {
        return;
    }
    // GtkTextView reserviert nativ ein Pixel für die Einfügemarke.
    let available = (width - view.left_margin() - view.right_margin() - 1).max(1);
    let columns = match state.soft_wrap.target.get() {
        Target::Window => None,
        Target::PageGuide => Some(view.right_margin_position()),
        Target::FixedColumn => Some(state.soft_wrap.column.get().clamp(20, 500)),
    };
    let max_width = columns
        .map_or(available, |n| (f64::from(n) * cell).ceil() as i32)
        .min(available)
        .max(1);
    let right = (available - max_width).max(0);
    let mode = state.soft_wrap.indentation.get();
    let mut start = buffer.iter_at_offset(pane.next.unwrap_or(0));
    let began = std::time::Instant::now();
    let mut processed = 0;
    loop {
        let mut end = start;
        end.forward_to_line_end();
        let mut scan = start;
        let mut leading = 0u32;
        // Nach dem Clamp ist weiterer führender Whitespace geometrisch wirkungslos.
        let limit = (f64::from(max_width) / cell).ceil() as u32 + 1;
        if mode != Indentation::FlushLeft {
            while scan < end && leading < limit {
                match scan.char() {
                    ' ' => leading += 1,
                    '\t' => {
                        let tab = view.tab_width().max(1);
                        leading += tab - leading % tab;
                    }
                    _ => break,
                }
                scan.forward_char();
            }
        }
        let extra = if mode == Indentation::Reverse {
            if view.is_insert_spaces_instead_of_tabs() {
                view.indent_width().max(1) as u32
            } else {
                view.tab_width()
            }
        } else {
            0
        };
        let offset = ((f64::from(leading + extra) * cell).round() as i32).clamp(0, max_width - 1);
        let tag = if let Some(tag) = pane.by_indent.get(&offset) {
            tag.clone()
        } else {
            // Unbenannte Tags sind auch in der gemeinsam genutzten TagTable pane-eindeutig.
            let tag = gtk::TextTag::builder()
                .left_margin(view.left_margin())
                .right_margin(view.right_margin() + right)
                .indent(-offset)
                // Quelltext erhält beim visuellen Umbruch keine erfundenen Bindestriche.
                .insert_hyphens(false)
                .build();
            buffer.tag_table().add(&tag);
            pane.tags.push(tag.clone());
            pane.by_indent.insert(offset, tag.clone());
            tag
        };
        let mut next = end;
        let more = next.forward_char();
        buffer.apply_tag(&tag, &start, &next);
        if !more || pane.until.is_some_and(|end| next.offset() >= end) {
            pane.next = None;
            pane.until = None;
            break;
        }
        start = next;
        pane.next = Some(start.offset());
        processed += 1;
        // GTK legt Absätze selbst aus. Nur die visuellen Absatzattribute werden
        // in kurzen Portionen gesetzt; große Dokumente blockieren keinen Frame.
        if processed >= 256 || began.elapsed() >= std::time::Duration::from_millis(3) {
            break;
        }
    }
}
pub(super) fn controls(state: &Rc<Options>, ui: &Ui, root: &gtk::Box) {
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let heading = super::super::git_view::label(ui.lang.text(
        "Visueller Zeilenumbruch pro Syntaxformat",
        "Visual wrapping per syntax format",
    ));
    heading.add_css_class("heading");
    root.append(&heading);
    if !capable() {
        root.append(&super::super::git_view::label(ui.lang.text("Feste Umbruchspalten und Folgezeileneinrückung benötigen die geprüfte optionale Textlaufzeit. Der Fensterumbruch bleibt verfügbar.","Fixed wrap columns and continuation indentation require the verified optional text runtime. Window wrapping remains available.")));
        return;
    }
    let row = |label: &str, widget: &gtk::Widget| {
        widget.update_property(&[gtk::accessible::Property::Description(label)]);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let label = super::super::git_view::label(label);
        label.set_hexpand(true);
        row.append(&label);
        row.append(widget);
        root.append(&row);
        state
            .soft_wrap
            .controls
            .borrow_mut()
            .push(widget.downgrade());
    };
    let target = gtk::DropDown::from_strings(&[
        ui.lang.text("Fensterbreite", "Window width"),
        ui.lang.text("Seitenlinie", "Page guide"),
        ui.lang.text("Feste Spalte", "Fixed column"),
    ]);
    target.set_selected(state.soft_wrap.target.get() as u32);
    row(
        ui.lang.text("Umbruchziel", "Wrap target"),
        target.upcast_ref(),
    );
    let weak = Rc::downgrade(state);
    target.connect_selected_notify(move |w| {
        if let Some(state) = weak.upgrade() {
            state.change_profile(profile::Patch {
                wrap: Some(true),
                wrap_target: Some(match w.selected() {
                    1 => Target::PageGuide,
                    2 => Target::FixedColumn,
                    _ => Target::Window,
                }),
                ..Default::default()
            });
        }
    });
    let column = gtk::SpinButton::with_range(20., 500., 1.);
    column.set_widget_name("fastra-wrap-column");
    column.set_value(f64::from(state.soft_wrap.column.get().clamp(20, 500)));
    row(
        ui.lang.text("Feste Umbruchspalte", "Fixed wrap column"),
        column.upcast_ref(),
    );
    let weak = Rc::downgrade(state);
    column.connect_value_changed(move |w| {
        if let Some(state) = weak.upgrade() {
            state.change_profile(profile::Patch {
                wrap: Some(true),
                wrap_target: Some(Target::FixedColumn),
                wrap_column: Some(w.value_as_int() as u32),
                ..Default::default()
            });
        }
    });
    let mode = gtk::DropDown::from_strings(&[
        ui.lang.text("Linksbündig", "Flush left"),
        ui.lang.text("Wie erste Zeile", "Match first line"),
        ui.lang
            .text("Zusätzlich einrücken", "One extra indentation level"),
    ]);
    mode.set_selected(state.soft_wrap.indentation.get() as u32);
    row(
        ui.lang.text("Folgezeilen", "Continuation lines"),
        mode.upcast_ref(),
    );
    let weak = Rc::downgrade(state);
    mode.connect_selected_notify(move |w| {
        if let Some(state) = weak.upgrade() {
            state.change_profile(profile::Patch {
                wrap_indentation: Some(match w.selected() {
                    0 => Indentation::FlushLeft,
                    2 => Indentation::Reverse,
                    _ => Indentation::FirstLine,
                }),
                ..Default::default()
            });
        }
    });
    readiness(state, !state.language_pending.get());
}
pub(super) fn readiness(state: &Options, ready: bool) {
    for widget in state
        .soft_wrap
        .controls
        .borrow()
        .iter()
        .filter_map(|w| w.upgrade())
    {
        widget.set_sensitive(ready);
    }
}
pub(super) fn sync_controls(state: &Options) {
    for (index, widget) in state
        .soft_wrap
        .controls
        .borrow()
        .iter()
        .enumerate()
        .filter_map(|(i, w)| w.upgrade().map(|w| (i, w)))
    {
        match index {
            0 => widget
                .downcast::<gtk::DropDown>()
                .unwrap()
                .set_selected(state.soft_wrap.target.get() as u32),
            1 => widget
                .downcast::<gtk::SpinButton>()
                .unwrap()
                .set_value(f64::from(state.soft_wrap.column.get().clamp(20, 500))),
            _ => widget
                .downcast::<gtk::DropDown>()
                .unwrap()
                .set_selected(state.soft_wrap.indentation.get() as u32),
        }
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
