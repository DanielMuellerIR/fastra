use gtk::{gio, glib, prelude::*};
use sourceview5::prelude::*;
pub(super) mod clipboard;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

#[derive(Clone, Copy)]
pub enum Error {
    Limit,
    Rows,
    Selection,
    Clipboard,
}

type Bounds = (i32, i32, i32, i32);
pub struct Rectangle {
    view: glib::WeakRef<sourceview5::View>,
    buffer: sourceview5::Buffer,
    bounds: Cell<Option<Bounds>>,
    marks: RefCell<Vec<(gtk::TextMark, gtk::TextMark)>>,
    editing: Cell<bool>,
    enabled: Cell<bool>,
    origin: Cell<(f64, f64)>,
    anchor: Cell<(i32, i32)>,
    head: Cell<(i32, i32)>,
    active: Cell<bool>,
    ending: Rc<dyn Fn() -> Option<fastra_core::encoding::LineEnding>>,
    dragging: Cell<bool>,
    tag: gtk::TextTag,
    peers: Rc<RefCell<Vec<std::rc::Weak<Rectangle>>>>,
    report: Rc<dyn Fn(Error)>,
    serial: Cell<u64>,
    tab_width: Cell<i32>,
}
impl Rectangle {
    pub fn attach(
        view: &sourceview5::View,
        peers: Rc<RefCell<Vec<std::rc::Weak<Self>>>>,
        report: Rc<dyn Fn(Error)>,
        ending: Rc<dyn Fn() -> Option<fastra_core::encoding::LineEnding>>,
    ) -> Rc<Self> {
        let buffer = view
            .buffer()
            .downcast::<sourceview5::Buffer>()
            .expect("source buffer");
        let tag = buffer
            .create_tag(None, &[("background", &"#9ebee8")])
            .expect("rectangle tag");
        let this = Rc::new(Self {
            view: view.downgrade(),
            buffer,
            bounds: Cell::new(None),
            marks: RefCell::new(Vec::new()),
            editing: Cell::new(false),
            enabled: Cell::new(false),
            origin: Cell::new((0., 0.)),
            anchor: Cell::new((0, 0)),
            head: Cell::new((0, 0)),
            active: Cell::new(false),
            ending,
            dragging: Cell::new(false),
            tag,
            peers: peers.clone(),
            report,
            serial: Cell::new(0),
            tab_width: Cell::new(view.tab_width().max(1) as i32),
        });
        peers.borrow_mut().push(Rc::downgrade(&this));
        let focus = gtk::EventControllerFocus::new();
        let weak = Rc::downgrade(&this);
        focus.connect_enter(move |_| {
            if let Some(rect) = weak.upgrade() {
                for peer in rect.peers.borrow().iter().filter_map(|weak| weak.upgrade()) {
                    peer.active.set(false);
                    if !std::ptr::eq(peer.as_ref(), rect.as_ref()) {
                        peer.serial.set(peer.serial.get().wrapping_add(1));
                    }
                }
                rect.active.set(true);
            }
        });
        view.add_controller(focus);
        let weak = Rc::downgrade(&this);
        view.connect_tab_width_notify(move |view| {
            if let Some(rect) = weak.upgrade() {
                let width = view.tab_width().max(1) as i32;
                if rect.tab_width.replace(width) != width {
                    // Neue Tabstopps entwerten die bisherige Spaltenbasis.
                    rect.dragging.set(false);
                    rect.clear();
                }
            }
        });
        let drag = gtk::GestureDrag::builder()
            .button(1)
            .propagation_phase(gtk::PropagationPhase::Capture)
            .build();
        let rect = this.clone();
        drag.connect_drag_begin(move |gesture, x, y| {
            for peer in rect.peers.borrow().iter().filter_map(|weak| weak.upgrade()) {
                peer.clear();
            }
            if !rect.enabled.get()
                && !gesture
                    .current_event_state()
                    .contains(gtk::gdk::ModifierType::ALT_MASK)
            {
                return;
            }
            gesture.set_state(gtk::EventSequenceState::Claimed);
            let Some(view) = rect.view.upgrade() else {
                return;
            };
            view.grab_focus();
            rect.dragging.set(true);
            rect.origin.set((x, y));
            let anchor = rect.position(x, y);
            rect.anchor.set(anchor);
            rect.select(anchor, anchor);
        });
        let rect = this.clone();
        drag.connect_drag_update(move |_, dx, dy| rect.drag_to(dx, dy));
        let rect = this.clone();
        drag.connect_drag_end(move |_, dx, dy| {
            rect.drag_to(dx, dy);
            rect.dragging.set(false)
        });
        view.add_controller(drag);
        let weak = Rc::downgrade(&this);
        this.buffer.connect_insert_text(move |buffer, at, text| {
            let Some(rect) = weak.upgrade() else { return };
            if rect.is_selected()
                && !rect.editing.get()
                && rect.view.upgrade().is_some_and(|view| view.has_focus())
            {
                buffer.stop_signal_emission_by_name("insert-text");
                rect.replace(text, false);
                *at = buffer.iter_at_mark(&buffer.get_insert());
            }
        });
        let weak = Rc::downgrade(&this);
        this.buffer.connect_changed(move |_| {
            if let Some(rect) = weak.upgrade() {
                if !rect.editing.get() {
                    rect.clear()
                }
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let rect = this.clone();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if matches!(
                key,
                gtk::gdk::Key::Control_L
                    | gtk::gdk::Key::Control_R
                    | gtk::gdk::Key::Shift_L
                    | gtk::gdk::Key::Shift_R
                    | gtk::gdk::Key::Alt_L
                    | gtk::gdk::Key::Alt_R
                    | gtk::gdk::Key::Super_L
                    | gtk::gdk::Key::Super_R
                    | gtk::gdk::Key::Meta_L
                    | gtk::gdk::Key::Meta_R
                    | gtk::gdk::Key::ISO_Level3_Shift
            ) {
                return glib::Propagation::Proceed;
            }
            let shortcut = modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
                && !modifiers.intersects(
                    gtk::gdk::ModifierType::ALT_MASK
                        | gtk::gdk::ModifierType::SUPER_MASK
                        | gtk::gdk::ModifierType::META_MASK,
                );
            if modifiers
                .contains(gtk::gdk::ModifierType::CONTROL_MASK | gtk::gdk::ModifierType::SHIFT_MASK)
                && !modifiers.intersects(
                    gtk::gdk::ModifierType::ALT_MASK
                        | gtk::gdk::ModifierType::SUPER_MASK
                        | gtk::gdk::ModifierType::META_MASK,
                )
                && matches!(key, gtk::gdk::Key::Up | gtk::gdk::Key::Down)
            {
                rect.extend_vertical(key == gtk::gdk::Key::Up);
                return glib::Propagation::Stop;
            }
            if !rect.is_selected() {
                return glib::Propagation::Proceed;
            }
            if shortcut && matches!(key, gtk::gdk::Key::c | gtk::gdk::Key::x) {
                rect.copy(key == gtk::gdk::Key::x);
                return glib::Propagation::Stop;
            }
            if key == gtk::gdk::Key::v && shortcut {
                rect.paste_mode(false);
                return glib::Propagation::Stop;
            }
            if key == gtk::gdk::Key::BackSpace || key == gtk::gdk::Key::Delete {
                rect.delete(key == gtk::gdk::Key::BackSpace);
                return glib::Propagation::Stop;
            }
            if matches!(
                key,
                gtk::gdk::Key::Escape
                    | gtk::gdk::Key::Left
                    | gtk::gdk::Key::Right
                    | gtk::gdk::Key::Up
                    | gtk::gdk::Key::Down
            ) || shortcut
            {
                rect.clear();
            }
            glib::Propagation::Proceed
        });
        view.add_controller(keys);
        this
    }
    fn drag_to(&self, dx: f64, dy: f64) {
        if self.dragging.get() {
            let (x, y) = self.origin.get();
            self.select(self.anchor.get(), self.position(x + dx, y + dy));
        }
    }
    fn next_column(&self, column: i32, character: char) -> i32 {
        column
            + if character == '\t' {
                self.tab_width.get() - column % self.tab_width.get()
            } else {
                1
            }
    }
    fn position(&self, x: f64, y: f64) -> (i32, i32) {
        let Some(view) = self.view.upgrade() else {
            return (0, 0);
        };
        let (x, y) = view.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let at = view
            .iter_at_location(x, y)
            .unwrap_or_else(|| self.buffer.end_iter());
        let mut start = self
            .buffer
            .iter_at_line(at.line())
            .unwrap_or_else(|| self.buffer.start_iter());
        let mut column = 0;
        while start.offset() < at.offset() {
            column = self.next_column(column, start.char());
            if !start.forward_cursor_position() {
                break;
            }
        }
        let rect = view.iter_location(&at);
        if at.ends_line() && x > rect.x() {
            let (width, _) = view.create_pango_layout(Some(" ")).pixel_size();
            column += (x - rect.x()) / width.max(1);
        }
        (at.line(), column.min(65536))
    }
    fn offset(&self, line: i32, column: i32, trailing: bool) -> (gtk::TextIter, i32) {
        let mut at = self
            .buffer
            .iter_at_line(line)
            .unwrap_or_else(|| self.buffer.end_iter());
        let mut current = 0;
        while !at.ends_line() && current < column {
            let next = self.next_column(current, at.char());
            if next > column && !trailing {
                break;
            };
            if !at.forward_cursor_position() {
                break;
            };
            current = next;
        }
        (at, current)
    }
    pub fn selection_generation(&self) -> u64 {
        self.serial.get()
    }
    pub fn clear(&self) {
        self.serial.set(self.serial.get() + 1);
        self.bounds.set(None);
        for (a, b) in self.marks.borrow_mut().drain(..) {
            self.buffer.delete_mark(&a);
            self.buffer.delete_mark(&b);
        }
        let (a, b) = self.buffer.bounds();
        self.buffer.remove_tag(&self.tag, &a, &b);
    }
    pub fn select(&self, anchor: (i32, i32), head: (i32, i32)) {
        self.clear();
        let bounds = (
            anchor.0.min(head.0),
            anchor.0.max(head.0),
            anchor.1.min(head.1),
            anchor.1.max(head.1),
        );
        if bounds.1 - bounds.0 > 2000
            || bounds.0 < 0
            || bounds.1 >= self.buffer.line_count()
            || bounds.2 < 0
            || bounds.3 > 65536
        {
            (self.report)(Error::Limit);
            return;
        }
        self.bounds.set(Some(bounds));
        self.anchor.set(anchor);
        self.head.set(head);
        for line in bounds.0..=bounds.1 {
            let (a, _) = self.offset(line, bounds.2, false);
            let (b, _) = self.offset(line, bounds.3, true);
            self.buffer.apply_tag(&self.tag, &a, &b);
            let mark = self.buffer.create_mark(None, &a, true);
            mark.set_visible(true);
            self.marks
                .borrow_mut()
                .push((mark, self.buffer.create_mark(None, &b, false)));
        }
        // Eine alte native Auswahl darf GtkTextView nicht vor unserem Insert löschen.
        if let Some((_, mark)) = self.marks.borrow().last() {
            self.buffer.place_cursor(&self.buffer.iter_at_mark(mark));
        }
    }
    pub fn extend_vertical(&self, upwards: bool) {
        let Some(view) = self
            .view
            .upgrade()
            .filter(|view| view.is_mapped() && view.is_sensitive())
        else {
            return;
        };
        let (anchor, head) = if self.bounds.get().is_some() {
            (self.anchor.get(), self.head.get())
        } else {
            if self.marks.borrow().len() > 1 {
                (self.report)(Error::Selection);
                return;
            }
            let (a, b) = self.buffer.selection_bounds().unwrap_or_else(|| {
                let at = self.buffer.iter_at_mark(&self.buffer.get_insert());
                (at, at)
            });
            if a.line() != b.line() {
                (self.report)(Error::Selection);
                return;
            }
            let anchor = (a.line(), self.position_column(&a));
            (anchor, (b.line(), self.position_column(&b)))
        };
        let line = head.0 + if upwards { -1 } else { 1 };
        if line < 0 || line >= self.buffer.line_count() {
            return;
        }
        self.dragging.set(false);
        for peer in self.peers.borrow().iter().filter_map(|weak| weak.upgrade()) {
            if !std::ptr::eq(peer.as_ref(), self) {
                peer.clear();
            }
        }
        self.select(anchor, (line, head.1));
        let (mut at, _) = self.offset(line, head.1, true);
        view.scroll_to_iter(&mut at, 0.1, false, 0., 0.);
        view.grab_focus();
    }
    pub fn copy(&self, cut: bool) {
        let Some(view) = self
            .view
            .upgrade()
            .filter(|view| view.is_mapped() && view.is_sensitive() && (!cut || view.is_editable()))
        else {
            return;
        };
        if self.bounds.get().is_none() || !self.is_selected() {
            return;
        }
        let Some(ending) = (self.ending)() else {
            return;
        };
        let separator = match ending {
            fastra_core::encoding::LineEnding::Lf => "\n",
            fastra_core::encoding::LineEnding::CrLf => "\r\n",
            fastra_core::encoding::LineEnding::Cr => "\r",
        };
        let mut output = String::new();
        let serial = self.serial.get();
        {
            let marks = self.marks.borrow();
            for (index, (a, b)) in marks.iter().enumerate() {
                let text = self.buffer.text(
                    &self.buffer.iter_at_mark(a),
                    &self.buffer.iter_at_mark(b),
                    true,
                );
                let extra = text.len().saturating_add(separator.len());
                if output.len().saturating_add(extra) > 4 * 1024 * 1024 || text.contains('\0') {
                    (self.report)(Error::Limit);
                    return;
                }
                output.push_str(&text);
                if marks.len() > 1 || index + 1 < marks.len() {
                    output.push_str(separator);
                }
            }
        }
        let provider = gtk::gdk::ContentProvider::for_value(&output.to_value());
        if view.clipboard().set_content(Some(&provider)).is_err() {
            (self.report)(Error::Clipboard);
            return;
        }
        if cut
            && self.serial.get() == serial
            && view.is_mapped()
            && view.is_editable()
            && (self.ending)().is_some()
        {
            self.replace("", false);
            view.grab_focus();
        }
        if self.serial.get() == serial && (self.ending)().is_some() {
            view.grab_focus();
        }
    }
    pub fn replace(&self, text: &str, pad: bool) {
        if !self.is_selected() {
            return;
        }
        let left = self.bounds.get().map_or(0, |bounds| bounds.2);
        let count = self.marks.borrow().len();
        if text.len() > 65536
            || (text.len().saturating_add(left as usize)).saturating_mul(count)
                + self
                    .buffer
                    .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true)
                    .len()
                > 4 * 1024 * 1024
        {
            self.clear();
            (self.report)(Error::Limit);
            return;
        }
        let values: Vec<_> = if pad {
            text.split('\n').collect()
        } else {
            vec![text]
        };
        if values.len() != 1 && values.len() != count {
            (self.report)(Error::Rows);
            return;
        }
        let rows: Vec<_> = self
            .marks
            .borrow()
            .iter()
            .map(|(a, b)| {
                let a = self.buffer.iter_at_mark(a);
                let b = self.buffer.iter_at_mark(b);
                let col = self.position_column(&a);
                (a.offset(), b.offset(), col)
            })
            .collect();
        self.editing.set(true);
        self.serial.set(self.serial.get() + 1);
        self.bounds.set(None);
        let (start, end) = self.buffer.bounds();
        self.buffer.remove_tag(&self.tag, &start, &end);
        self.buffer.begin_user_action();
        // Absteigende Offsets erhalten die Positionen aller noch unbearbeiteten logischen Zeilen.
        for (index, (a, b, col)) in rows.iter().enumerate().rev() {
            let mut a = self.buffer.iter_at_offset(*a);
            let mut b = self.buffer.iter_at_offset(*b);
            self.buffer.delete(&mut a, &mut b);
            let prefix = if pad {
                " ".repeat((left - col).max(0) as usize)
            } else {
                String::new()
            };
            let value = values[if values.len() == 1 { 0 } else { index }];
            self.buffer.insert(&mut a, &format!("{prefix}{value}"));
            let marks = self.marks.borrow();
            self.buffer.move_mark(&marks[index].0, &a);
            self.buffer.move_mark(&marks[index].1, &a);
        }
        self.buffer.end_user_action();
        // Beim Löschen von Zeilenumbrüchen können Cursor zusammenfallen.
        // Eine Position darf die nächste Eingabe nur einmal erhalten.
        let mut seen = std::collections::HashSet::new();
        self.marks.borrow_mut().retain(|(a, b)| {
            if seen.insert(self.buffer.iter_at_mark(a).offset()) {
                true
            } else {
                self.buffer.delete_mark(a);
                self.buffer.delete_mark(b);
                false
            }
        });
        if let Some((_, mark)) = self.marks.borrow().last() {
            self.buffer.place_cursor(&self.buffer.iter_at_mark(mark));
        }
        self.editing.set(false);
    }
    fn position_column(&self, at: &gtk::TextIter) -> i32 {
        let mut start = self.buffer.iter_at_line(at.line()).unwrap();
        let mut column = 0;
        while start.offset() < at.offset() {
            column = self.next_column(column, start.char());
            if !start.forward_cursor_position() {
                break;
            }
        }
        column
    }
    fn delete(&self, backwards: bool) {
        for (a, b) in self.marks.borrow().iter() {
            let mut start = self.buffer.iter_at_mark(a);
            let mut end = self.buffer.iter_at_mark(b);
            if start == end {
                if backwards {
                    start.backward_cursor_position();
                } else {
                    end.forward_cursor_position();
                }
                self.buffer.move_mark(a, &start);
                self.buffer.move_mark(b, &end);
            }
        }
        self.replace("", false);
    }
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.set(enabled);
        if !enabled {
            self.clear();
        }
    }
    pub fn is_selected(&self) -> bool {
        !self.marks.borrow().is_empty()
    }
    #[cfg(debug_assertions)]
    pub fn test_point(
        &self,
        window: &gtk::ApplicationWindow,
        line: i32,
        column: i32,
    ) -> (i32, i32) {
        let view = self.view.upgrade().unwrap();
        let (at, _) = self.offset(line, column, false);
        let rect = view.iter_location(&at);
        let (x, y) = view.buffer_to_window_coords(
            gtk::TextWindowType::Widget,
            rect.x() + 1,
            rect.y() + rect.height() / 2,
        );
        let point = view
            .compute_point(window, &gtk::graphene::Point::new(x as f32, y as f32))
            .unwrap();
        let (x, y) = window.surface_transform();
        (
            (point.x() as f64 - x).round() as i32,
            (point.y() as f64 - y).round() as i32,
        )
    }
    pub(super) fn invalidate_request(&self) {
        self.serial.set(self.serial.get().wrapping_add(1));
    }
    pub fn paste(self: &Rc<Self>) {
        let Some(view) = self
            .view
            .upgrade()
            .filter(|view| view.is_mapped() && view.is_sensitive() && view.is_editable())
        else {
            return;
        };
        view.grab_focus();
        // GTK liefert den Fokuswechsel des geschlossenen Popovers erst nach
        // dessen Klick zurück. Auswahl und Clipboard bleiben bis dahin gebunden.
        self.serial.set(self.serial.get().wrapping_add(1));
        let serial = self.serial.get();
        let clipboard = view.clipboard();
        let changed = Rc::new(Cell::new(false));
        let observed = changed.clone();
        let handler = clipboard.connect_changed(move |_| observed.set(true));
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            clipboard.disconnect(handler);
            let Some(rect) = weak.upgrade() else { return };
            if !changed.get() && rect.serial.get() == serial && (rect.ending)().is_some() {
                rect.paste_mode(true);
            }
        });
    }
    pub(super) fn paste_mode(self: &Rc<Self>, pad: bool) {
        let Some(view) = self
            .view
            .upgrade()
            .filter(|view| view.is_mapped() && view.is_sensitive() && view.is_editable())
        else {
            return;
        };
        if !self.is_selected() {
            if !pad {
                return;
            }
            let at = self.buffer.selection_bounds().map_or_else(
                || self.buffer.iter_at_mark(&self.buffer.get_insert()),
                |(a, _)| a,
            );
            let anchor = (at.line(), self.position_column(&at));
            for peer in self.peers.borrow().iter().filter_map(|weak| weak.upgrade()) {
                peer.clear();
            }
            self.select(anchor, anchor);
            if !self.is_selected() {
                return;
            }
        }
        self.serial.set(self.serial.get().wrapping_add(1));
        let serial = self.serial.get();
        let weak = Rc::downgrade(self);
        let request = clipboard::Request::new(view.clipboard(), view);
        glib::MainContext::default().spawn_local(async move {
            let result = request.read().await;
            let Some(rect) = weak.upgrade() else { return };
            if rect.serial.get() != serial
                || !rect.view.upgrade().is_some_and(|view| {
                    view.is_mapped() && view.is_sensitive() && view.is_editable()
                })
            {
                return;
            }
            match result.and_then(|text| rect.apply_clipboard(&text, pad)) {
                Ok(()) => (),
                Err(error) => (rect.report)(error),
            }
        });
    }
}

pub(super) fn append_menu(ui: &Rc<super::Ui>, menu: &gio::Menu, actions: &gio::SimpleActionGroup) {
    let rectangle = gio::Menu::new();
    for (name, de, en, command) in [
        ("rectangle-copy", "Rechteck kopieren", "Copy rectangle", 0u8),
        ("rectangle-cut", "Rechteck ausschneiden", "Cut rectangle", 1),
        ("rectangle-paste-column", "Spaltenpaste", "Column paste", 4),
        (
            "rectangle-up",
            "Rechteck nach oben · Ctrl+Shift+↑",
            "Extend rectangle up · Ctrl+Shift+↑",
            2,
        ),
        (
            "rectangle-down",
            "Rechteck nach unten · Ctrl+Shift+↓",
            "Extend rectangle down · Ctrl+Shift+↓",
            3,
        ),
    ] {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            let Some(ui) = weak.upgrade() else { return };
            let Some(doc) = ui.active() else { return };
            if !ui.source_edit_allowed(&doc) {
                return;
            }
            let target = target(&doc.rectangles.borrow());
            if let Some(rect) = target {
                if command < 2 {
                    if rect.bounds.get().is_none() {
                        ui.status.set_text(ui.lang.text(
                            "Zuerst ein Rechteck im Quelltext markieren.",
                            "Select a rectangle in the source first.",
                        ));
                        return;
                    }
                    rect.copy(command == 1);
                } else if command < 4 {
                    rect.extend_vertical(command == 2);
                } else {
                    rect.paste();
                }
            }
        });
        actions.add_action(&action);
        rectangle.append(Some(ui.lang.text(de, en)), Some(&format!("text.{name}")));
    }
    menu.append_submenu(
        Some(ui.lang.text("Rechteckauswahl", "Rectangle selection")),
        &rectangle,
    );
}

pub(super) fn detected_ending(text: &str) -> fastra_core::encoding::LineEnding {
    use fastra_core::encoding::LineEnding;
    let mut counts = [0usize; 3];
    let mut cursor = 0;
    while let Some(at) = text[cursor..].find(['\r', '\n']) {
        cursor += at;
        let kind = if text.as_bytes()[cursor] == b'\n' {
            cursor += 1;
            0
        } else if text.as_bytes().get(cursor + 1) == Some(&b'\n') {
            cursor += 2;
            1
        } else {
            cursor += 1;
            2
        };
        counts[kind] += 1;
        if counts[kind] >= 15 {
            break;
        }
    }
    let largest = *counts.iter().max().unwrap();
    if counts.iter().filter(|count| **count == largest).count() != 1 {
        return LineEnding::Lf;
    }
    match counts.iter().position(|count| *count == largest).unwrap() {
        1 => LineEnding::CrLf,
        2 => LineEnding::Cr,
        _ => LineEnding::Lf,
    }
}
#[cfg(debug_assertions)]
mod commands_gui_test;
#[cfg(debug_assertions)]
pub(super) fn commands_selftest(ui: Rc<super::Ui>) {
    commands_gui_test::run(ui);
}

pub(super) fn target(rectangles: &[Rc<Rectangle>]) -> Option<Rc<Rectangle>> {
    let mapped = |rect: &&Rc<Rectangle>| rect.view.upgrade().is_some_and(|view| view.is_mapped());
    rectangles
        .iter()
        .filter(mapped)
        .find(|rect| rect.active.get())
        .or_else(|| rectangles.iter().find(mapped))
        .cloned()
}
