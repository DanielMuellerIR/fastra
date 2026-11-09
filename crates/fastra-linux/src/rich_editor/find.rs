use super::*;

pub(super) struct Bar {
    editor: std::rc::Weak<RichEditor>,
    root: gtk::Box,
    entry: gtk::Entry,
    case: gtk::CheckButton,
    status: gtk::Label,
    generation: Cell<u64>,
    revision: Cell<u64>,
}
impl Bar {
    pub(super) fn show(self: &Rc<Self>) {
        if let Some(editor) = self.editor.upgrade().filter(|e| e.focused()) {
            if let Some(ui) = editor.ui.upgrade() {
                ui.search_section.set_expanded(false);
            }
            self.root.set_visible(true);
            self.entry.grab_focus();
            self.entry.select_region(0, -1);
            self.schedule();
        }
    }
    fn close(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        self.root.set_visible(false);
        if let Some(editor) = self.editor.upgrade() {
            if let Some(controller) = editor.view.find_controller() {
                controller.search_finish();
            }
            editor.view.grab_focus();
        }
    }
    fn schedule(self: &Rc<Self>) {
        let generation = self.generation.get().wrapping_add(1);
        self.generation.set(generation);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(120), move || {
            if let Some(bar) = weak.upgrade().filter(|b| b.generation.get() == generation) {
                bar.search(false);
            }
        });
    }
    pub(super) fn search(&self, backwards: bool) {
        let Some(editor) = self
            .editor
            .upgrade()
            .filter(|e| e.focused() && e.ready.get() && !e.failed.get() && !e.busy.get())
        else {
            return;
        };
        if !self.root.is_visible() {
            return;
        }
        let text = self.entry.text();
        let Some(controller) = editor.view.find_controller() else {
            self.status
                .set_text(editor.text("Textsuche nicht verfügbar", "Text search unavailable"));
            return;
        };
        controller.search_finish();
        self.revision.set(editor.input_revision.get());
        if text.is_empty() {
            self.status.set_text("");
            return;
        }
        self.status.set_text(editor.text("Suchen …", "Finding …"));
        let mut options = webkit6::FindOptions::WRAP_AROUND;
        if !self.case.is_active() {
            options |= webkit6::FindOptions::CASE_INSENSITIVE;
        }
        if backwards {
            options |= webkit6::FindOptions::BACKWARDS;
        }
        controller.search(&text, options.bits(), 10_000);
    }
    pub(super) fn next(&self, backwards: bool) {
        let Some(editor) = self
            .editor
            .upgrade()
            .filter(|e| e.focused() && !e.failed.get() && !e.busy.get())
        else {
            return;
        };
        if !self.root.is_visible() || self.entry.text().is_empty() {
            return;
        }
        let Some(controller) = editor.view.find_controller() else {
            self.status
                .set_text(editor.text("Textsuche nicht verfügbar", "Text search unavailable"));
            return;
        };
        if self.revision.get() != editor.input_revision.get()
            || controller.search_text().as_ref() != Some(&self.entry.text())
        {
            self.search(backwards);
        } else if backwards {
            controller.search_previous();
        } else {
            controller.search_next();
        }
    }
    fn source(&self) {
        let Some(editor) = self.editor.upgrade().filter(|e| e.focused()) else {
            return;
        };
        let Some(doc) = editor.document.upgrade() else {
            return;
        };
        let Some(toggle) = doc.rich_toggle.borrow().clone() else {
            return;
        };
        let ui = editor.ui.clone();
        let target = Rc::downgrade(&doc);
        toggle.set_active(false);
        let started = std::time::Instant::now();
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let (Some(ui), Some(doc)) = (ui.upgrade(), target.upgrade()) else {
                return glib::ControlFlow::Break;
            };
            if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                || started.elapsed() > Duration::from_secs(5)
            {
                return glib::ControlFlow::Break;
            }
            if doc.rich.borrow().is_some() {
                return if toggle.is_active() {
                    glib::ControlFlow::Break
                } else {
                    glib::ControlFlow::Continue
                };
            }
            chrome::show_search(&ui);
            glib::ControlFlow::Break
        });
    }
}
pub(super) fn install(editor: &Rc<RichEditor>, toolbar: &gtk::FlowBox) -> Rc<Bar> {
    let root = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    root.add_css_class("rich-find-bar");
    root.set_visible(false);
    let entry = gtk::Entry::builder()
        .hexpand(true)
        .max_length(1024)
        .placeholder_text(editor.text("Im formatierten Text suchen", "Find in formatted text"))
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(
        editor.text("Im formatierten Text suchen", "Find in formatted text"),
    )]);
    let previous = chrome::icon(
        "go-up-symbolic",
        editor.text("Voriger Treffer", "Previous match"),
    );
    let next = chrome::icon(
        "go-down-symbolic",
        editor.text("Nächster Treffer", "Next match"),
    );
    let case = gtk::CheckButton::with_label(editor.text("Groß/klein", "Match case"));
    let status = gtk::Label::new(None);
    status.set_width_chars(8);
    let source = gtk::Button::with_label(editor.text("Quelltext …", "Source …"));
    let close = chrome::icon(
        "window-close-symbolic",
        editor.text("Suchleiste schließen", "Close find bar"),
    );
    for child in [
        entry.upcast_ref::<gtk::Widget>(),
        previous.upcast_ref(),
        next.upcast_ref(),
        status.upcast_ref(),
        case.upcast_ref(),
        source.upcast_ref(),
        close.upcast_ref(),
    ] {
        root.append(child);
    }
    editor
        .widget
        .insert_child_after(&root, editor.widget.first_child().as_ref());
    let bar = Rc::new(Bar {
        editor: Rc::downgrade(editor),
        root,
        entry,
        case,
        status,
        generation: Cell::new(0),
        revision: Cell::new(0),
    });
    let button = chrome::icon(
        "fastra-search-symbolic",
        editor.text("Im formatierten Text suchen", "Find in formatted text"),
    );
    let weak = Rc::downgrade(&bar);
    button.connect_clicked(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.show();
        }
    });
    toolbar.insert(&button, -1);
    let weak = Rc::downgrade(&bar);
    bar.entry.connect_changed(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.schedule();
        }
    });
    let weak = Rc::downgrade(&bar);
    bar.case.connect_toggled(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.schedule();
        }
    });
    let weak = Rc::downgrade(&bar);
    bar.entry.connect_activate(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.next(false);
        }
    });
    for (button, backwards) in [(&previous, true), (&next, false)] {
        let weak = Rc::downgrade(&bar);
        button.connect_clicked(move |_| {
            if let Some(bar) = weak.upgrade() {
                bar.next(backwards);
            }
        });
    }
    let weak = Rc::downgrade(&bar);
    close.connect_clicked(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.close();
        }
    });
    let weak = Rc::downgrade(&bar);
    source.connect_clicked(move |_| {
        if let Some(bar) = weak.upgrade() {
            bar.source();
        }
    });
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(&bar);
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gtk::gdk::Key::Escape {
            if let Some(bar) = weak.upgrade() {
                bar.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    bar.root.add_controller(keys);
    if let Some(controller) = editor.view.find_controller() {
        let weak = Rc::downgrade(&bar);
        controller.connect_found_text(move |controller, count| {
            if let Some(bar) = weak.upgrade().filter(|bar| {
                bar.root.is_mapped() && controller.search_text().as_ref() == Some(&bar.entry.text())
            }) {
                if let Some(editor) = bar
                    .editor
                    .upgrade()
                    .filter(|e| e.focused() && e.input_revision.get() == bar.revision.get())
                {
                    bar.status.set_text(&if count > 10_000 {
                        editor
                            .text("Mehr als 10.000 Treffer", "More than 10,000 matches")
                            .into()
                    } else {
                        format!(
                            "{count} {}",
                            editor.text("Treffer", if count == 1 { "match" } else { "matches" })
                        )
                    });
                }
            }
        });
        let weak = Rc::downgrade(&bar);
        controller.connect_failed_to_find_text(move |controller| {
            if let Some(bar) = weak.upgrade().filter(|bar| {
                bar.root.is_mapped() && controller.search_text().as_ref() == Some(&bar.entry.text())
            }) {
                if let Some(editor) = bar
                    .editor
                    .upgrade()
                    .filter(|e| e.focused() && e.input_revision.get() == bar.revision.get())
                {
                    bar.status.set_text(editor.text("Kein Treffer", "No match"));
                }
            }
        });
    }
    bar
}

#[cfg(debug_assertions)]
pub(super) mod selftest;
