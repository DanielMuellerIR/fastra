use super::*;
use fastra_workflow::comparison_preferences::{Change, Settings};
pub(super) struct Picker {
    pub window: gtk::Window,
    pub compare: gtk::Button,
    pub options: [gtk::CheckButton; 4],
    pub status: gtk::Label,
    choose: [gtk::Button; 2],
    icons: [gtk::Image; 2],
    errors: [gtk::Label; 2],
    fields: [gtk::Label; 2],
    details: [gtk::Label; 2],
    menus: [gtk::MenuButton; 2],
    problems: RefCell<[Option<String>; 2]>,
    probes: [Cell<u64>; 2],
    loaded: Cell<bool>,
    updating: Cell<bool>,
    settings: RefCell<Settings>,
}
impl Picker {
    #[cfg(debug_assertions)]
    pub(super) fn test_loaded(&self) -> bool {
        self.loaded.get()
    }
    pub fn new(ui: &Rc<Ui>) -> Self {
        let lang = ui.lang;
        let window = gtk::Window::builder()
            .title(lang.text("Dateien vergleichen", "Compare files"))
            .transient_for(&ui.window)
            .modal(true)
            .destroy_with_parent(true)
            .resizable(false)
            .default_width(640)
            .build();
        if let Some(app) = ui.window.application() {
            window.set_application(Some(&app));
        }
        window.set_decorated(false);
        window.add_css_class("fastra-tool");
        window.add_css_class("fastra-compare-picker");
        let root = gtk::Box::new(gtk::Orientation::Vertical, 14);
        root.set_margin_top(20);
        root.set_margin_bottom(20);
        root.set_margin_start(20);
        root.set_margin_end(20);
        let title = support::label(lang.text("Dateien vergleichen", "Compare files"));
        title.add_css_class("heading");
        root.append(&title);
        let sources = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let choose =
            std::array::from_fn(|_| gtk::Button::with_label(lang.text("Auswählen…", "Choose…")));
        let icons = std::array::from_fn(|_| gtk::Image::from_icon_name("document-new-symbolic"));
        let errors = std::array::from_fn(|_| {
            let label = support::label("");
            label.add_css_class("error");
            label.set_visible(false);
            label
        });
        let fields = std::array::from_fn(|_| {
            gtk::Label::builder()
                .xalign(0.5)
                .ellipsize(gtk::pango::EllipsizeMode::Middle)
                .max_width_chars(23)
                .build()
        });
        let details = std::array::from_fn(|_| {
            gtk::Label::builder()
                .xalign(0.5)
                .ellipsize(gtk::pango::EllipsizeMode::Middle)
                .max_width_chars(23)
                .build()
        });
        let menus = std::array::from_fn(|_| {
            let menu = gtk::MenuButton::new();
            let content = gtk::Box::new(gtk::Orientation::Horizontal, 5);
            let icon = gtk::Image::from_icon_name("document-open-recent-symbolic");
            icon.set_pixel_size(13);
            content.append(&icon);
            content.append(&gtk::Label::new(Some(
                lang.text("Tabs & zuletzt geöffnet", "Tabs & recent files"),
            )));
            menu.set_child(Some(&content));
            menu
        });
        for side in 0..2 {
            if side == 1 {
                let arrow = gtk::Image::from_icon_name("fastra-compare-symbolic");
                arrow.set_pixel_size(18);
                arrow.set_valign(gtk::Align::Start);
                arrow.set_margin_top(44);
                arrow.add_css_class("compare-arrow");
                sources.append(&arrow);
            }
            let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
            column.set_hexpand(true);
            let role = support::label(if side == 0 {
                lang.text("Links", "Left")
            } else {
                lang.text("Rechts", "Right")
            });
            role.add_css_class("dim-label");
            column.append(&role);
            let panel = gtk::Box::new(gtk::Orientation::Vertical, 4);
            panel.set_can_target(true);
            panel.add_css_class("compare-source");
            panel.set_size_request(250, 76);
            let top = gtk::Box::new(gtk::Orientation::Vertical, 0);
            top.set_vexpand(true);
            panel.append(&top);
            icons[side].set_pixel_size(18);
            icons[side].set_halign(gtk::Align::Center);
            panel.append(&icons[side]);
            panel.append(&fields[side]);
            details[side].add_css_class("dim-label");
            panel.append(&details[side]);
            let bottom = gtk::Box::new(gtk::Orientation::Vertical, 0);
            bottom.set_vexpand(true);
            panel.append(&bottom);
            column.append(&panel);
            let controls = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            controls.append(&choose[side]);
            controls.append(&menus[side]);
            column.append(&controls);
            column.append(&errors[side]);
            sources.append(&column);
        }
        root.append(&sources);
        let options = [
            gtk::CheckButton::with_label(
                lang.text("Leerraum am Zeilenende", "Trailing whitespace"),
            ),
            gtk::CheckButton::with_label(
                lang.text("Alle Leerraum-Unterschiede", "All whitespace differences"),
            ),
            gtk::CheckButton::with_label(lang.text("Leerzeilen", "Blank lines")),
            gtk::CheckButton::with_label(lang.text("Groß-/Kleinschreibung", "Case")),
        ];
        let settings = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let caption =
            support::label(lang.text("Beim Vergleichen ignorieren", "Ignore when comparing"));
        caption.add_css_class("dim-label");
        settings.append(&caption);
        let checks = gtk::Box::new(gtk::Orientation::Vertical, 4);
        for option in &options {
            checks.append(option);
        }
        settings.append(&checks);
        root.append(&settings);
        let status = support::label("");
        status.add_css_class("error");
        status.set_visible(false);
        root.append(&status);
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        footer.set_halign(gtk::Align::End);
        let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
        let target = window.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(window) = target.upgrade() {
                window.close();
            }
        });
        let compare = gtk::Button::with_label(lang.text("Vergleichen", "Compare"));
        compare.add_css_class("suggested-action");
        compare.set_sensitive(false);
        footer.append(&cancel);
        footer.append(&compare);
        root.append(&footer);
        window.set_default_widget(Some(&compare));
        window.set_child(Some(&root));
        let keys = gtk::EventControllerKey::new();
        let target = window.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gtk::gdk::Key::Escape {
                if let Some(window) = target.upgrade() {
                    window.close();
                }
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(keys);
        Self {
            window,
            compare,
            options,
            status,
            choose,
            icons,
            errors,
            fields,
            details,
            menus,
            problems: RefCell::new([None, None]),
            probes: [Cell::new(0), Cell::new(0)],
            loaded: Cell::new(false),
            updating: Cell::new(false),
            settings: RefCell::new(Settings::default()),
        }
    }
    pub fn connect(state: &Rc<State>) {
        for side in 0..2 {
            let choose = state.picker.choose[side].clone();
            let owner = Rc::downgrade(state);
            choose.connect_clicked(move |_| {
                let Some(state) = owner.upgrade() else { return };
                let owner = Rc::downgrade(&state);
                gtk::FileDialog::new().open(
                    Some(&state.picker.window),
                    None::<&gio::Cancellable>,
                    move |result| {
                        if let (Ok(file), Some(state)) = (
                            result,
                            owner.upgrade().filter(|s| s.picker.window.is_visible()),
                        ) {
                            if let Some(path) = file.path() {
                                state.choose(side, sources::Choice::File(path));
                            }
                        }
                    },
                );
            });
            let owner = Rc::downgrade(state);
            state.picker.menus[side].set_create_popup_func(move |_| {
                if let Some(state) = owner.upgrade() {
                    state.picker.populate(&state, side);
                }
            });
        }
        let formats = gtk::gdk::ContentFormats::for_type(gtk::gdk::FileList::static_type())
            .union_deserialize_mime_types();
        let drop = gtk::DropTargetAsync::new(Some(formats.clone()), gtk::gdk::DragAction::COPY);
        drop.set_propagation_phase(gtk::PropagationPhase::Capture);
        drop.connect_accept(move |_, offered| offered.formats().match_(&formats));
        for motion in [false, true] {
            let owner = Rc::downgrade(state);
            let hover = move |_: &gtk::DropTargetAsync, _: &gtk::gdk::Drop, x, y| {
                let Some(state) = owner.upgrade() else {
                    return gtk::gdk::DragAction::empty();
                };
                let side = (!state.busy.get())
                    .then(|| state.picker.side_at(x, y))
                    .flatten();
                state.picker.highlight(side);
                if side.is_some() {
                    gtk::gdk::DragAction::COPY
                } else {
                    gtk::gdk::DragAction::empty()
                }
            };
            if motion {
                drop.connect_drag_motion(hover);
            } else {
                drop.connect_drag_enter(hover);
            }
        }
        let owner = Rc::downgrade(state);
        drop.connect_drag_leave(move |_, _| {
            if let Some(state) = owner.upgrade() {
                state.picker.highlight(None);
            }
        });
        let owner = Rc::downgrade(state);
        drop.connect_drop(move |_, offered, x, y| {
            let Some(state) = owner.upgrade() else {
                return false;
            };
            state.picker.highlight(None);
            let Some(side) = state.picker.side_at(x, y).filter(|_| !state.busy.get()) else {
                return false;
            };
            let owner = Rc::downgrade(&state);
            let offered = offered.clone();
            let finished = Rc::new(Cell::new(false));
            let cancelled = gio::Cancellable::new();
            let timeout_drop = offered.clone();
            let timeout_finished = finished.clone();
            let timeout_cancel = cancelled.clone();
            let timeout =
                glib::timeout_add_local_once(std::time::Duration::from_secs(5), move || {
                    if !timeout_finished.replace(true) {
                        timeout_cancel.cancel();
                        timeout_drop.finish(gtk::gdk::DragAction::empty());
                    }
                });
            let receipt = offered.clone();
            offered.read_value_async(
                gtk::gdk::FileList::static_type(),
                glib::Priority::DEFAULT,
                Some(&cancelled),
                move |result| {
                    if finished.replace(true) {
                        return;
                    }
                    timeout.remove();
                    let path = result
                        .ok()
                        .and_then(|value| value.get::<gtk::gdk::FileList>().ok())
                        .and_then(|files| files.files().into_iter().next())
                        .and_then(|file| file.path());
                    let accepted = owner
                        .upgrade()
                        .filter(|state| state.picker.window.is_visible() && !state.busy.get())
                        .zip(path)
                        .map(|(state, path)| {
                            state.choose(side, sources::Choice::File(path));
                            true
                        })
                        .unwrap_or(false);
                    receipt.finish(if accepted {
                        gtk::gdk::DragAction::COPY
                    } else {
                        gtk::gdk::DragAction::empty()
                    });
                },
            );
            true
        });
        state.picker.window.add_controller(drop);
        let owner = Rc::downgrade(state);
        glib::timeout_add_local(std::time::Duration::from_millis(150), move || {
            let Some(state) = owner.upgrade().filter(|s| s.picker.window.is_visible()) else {
                return glib::ControlFlow::Break;
            };
            state.picker.update(&state);
            glib::ControlFlow::Continue
        });
        for index in 0..4 {
            let owner = Rc::downgrade(state);
            state.picker.options[index].connect_toggled(move |option| {
                let Some(state) = owner.upgrade() else { return };
                let p = &state.picker;
                p.options[0].set_sensitive(!p.options[1].is_active());
                if p.updating.get() {
                    return;
                }
                if let Some(ui) = state.ui.upgrade() {
                    let owner = Rc::downgrade(&state);
                    preferences::submit(
                        &ui,
                        Some(Change::Option {
                            index,
                            value: option.is_active(),
                        }),
                        move |result| {
                            if let Some(state) = owner.upgrade() {
                                if let Err(error) = result {
                                    state.error(&preferences::message(state.lang, &error));
                                }
                            }
                        },
                    );
                }
            });
        }
        let owner = Rc::downgrade(state);
        state.picker.compare.connect_clicked(move |_| {
            if let Some(state) = owner.upgrade() {
                state.start();
            }
        });
        if let Some(ui) = state.ui.upgrade() {
            let owner = Rc::downgrade(state);
            preferences::submit(&ui, None, move |result| {
                if let Some(state) = owner.upgrade() {
                    match result {
                        Ok(settings) => {
                            let p = &state.picker;
                            p.updating.set(true);
                            for (option, value) in p.options.iter().zip(settings.options) {
                                option.set_active(value);
                            }
                            p.updating.set(false);
                            *p.settings.borrow_mut() = settings;
                            p.loaded.set(true);
                            p.update(&state);
                            if state.automatic.replace(false) {
                                state.start();
                            }
                        }
                        Err(error) => state.error(&preferences::message(state.lang, &error)),
                    }
                }
            });
        }
    }
    fn side_at(&self, x: f64, y: f64) -> Option<usize> {
        let point = gtk::graphene::Point::new(x as f32, y as f32);
        (0..2).find(|side| {
            self.fields[*side]
                .parent()
                .and_then(|panel| panel.compute_bounds(&self.window))
                .is_some_and(|bounds| bounds.contains_point(&point))
        })
    }
    fn highlight(&self, side: Option<usize>) {
        for index in 0..2 {
            if let Some(panel) = self.fields[index].parent() {
                if side == Some(index) {
                    panel.add_css_class("drop-active");
                } else {
                    panel.remove_css_class("drop-active");
                }
            }
        }
    }
    fn populate(&self, state: &Rc<State>, side: usize) {
        let Some(ui) = state.ui.upgrade() else { return };
        let body = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let documents = ui
            .documents
            .borrow()
            .iter()
            .filter(|doc| sources::eligible(doc))
            .map(sources::Choice::from_doc)
            .collect::<Vec<_>>();
        let recent = self
            .settings
            .borrow()
            .recent_files()
            .into_iter()
            .map(sources::Choice::File)
            .collect::<Vec<_>>();
        for (title, choices) in [
            (ui.lang.text("Offene Tabs", "Open tabs"), documents),
            (ui.lang.text("Zuletzt geöffnet", "Recent files"), recent),
        ] {
            if choices.is_empty() {
                continue;
            }
            let heading = support::label(title);
            heading.add_css_class("dim-label");
            heading.set_margin_top(6);
            body.append(&heading);
            for choice in choices {
                let button = gtk::Button::with_label(&choice.name(ui.lang));
                button.set_tooltip_text(
                    choice
                        .path()
                        .as_deref()
                        .map(crate::project_view::display)
                        .as_deref(),
                );
                button.set_has_frame(false);
                let owner = Rc::downgrade(state);
                button.connect_clicked(move |_| {
                    if let Some(state) = owner.upgrade() {
                        state.picker.menus[side].popdown();
                        state.choose(side, choice.clone());
                    }
                });
                body.append(&button);
            }
        }
        if body.first_child().is_none() {
            let empty = support::label(ui.lang.text(
                "Keine offenen Tabs oder zuletzt geöffneten Dateien",
                "No open tabs or recent files",
            ));
            empty.set_sensitive(false);
            body.append(&empty);
        }
        let scroll = gtk::ScrolledWindow::builder()
            .max_content_height(300)
            .propagate_natural_height(true)
            .min_content_width(250)
            .child(&body)
            .build();
        let popover = gtk::Popover::new();
        popover.set_child(Some(&scroll));
        self.menus[side].set_popover(Some(&popover));
    }
    pub fn ready(&self) -> bool {
        self.loaded.get()
    }
    #[cfg(debug_assertions)]
    pub fn test_problem(&self, side: usize) -> String {
        self.errors[side].text().to_string()
    }
    #[cfg(debug_assertions)]
    pub fn test_panel(&self, side: usize) -> gtk::Widget {
        self.fields[side].parent().unwrap()
    }
    pub fn error(&self, text: &str) {
        self.status.set_text(text);
        self.status.set_visible(!text.is_empty());
    }
    pub fn update(&self, state: &State) {
        let choices = state.choices.borrow();
        let Some(ui) = state.ui.upgrade() else { return };
        for side in 0..2 {
            self.fields[side].set_text(
                &choices[side]
                    .as_ref()
                    .map(|c| c.name(ui.lang))
                    .unwrap_or_else(|| {
                        ui.lang
                            .text("Datei hierher ziehen", "Drop a file here")
                            .into()
                    }),
            );
            self.details[side].set_text(
                &choices[side]
                    .as_ref()
                    .map(|c| c.description(ui.lang))
                    .unwrap_or_default(),
            );
            self.details[side].set_visible(choices[side].is_some());
            self.fields[side].set_tooltip_text(
                choices[side]
                    .as_ref()
                    .and_then(|choice| choice.path())
                    .as_deref()
                    .map(crate::project_view::display)
                    .as_deref(),
            );
            self.icons[side].set_icon_name(Some(match &choices[side] {
                Some(sources::Choice::Document(_)) => "fastra-window-symbolic",
                Some(sources::Choice::File(_)) => "text-x-generic-symbolic",
                None => "document-new-symbolic",
            }));
            let problem = self.problems.borrow()[side]
                .clone()
                .or_else(|| {
                    choices[side]
                        .as_ref()
                        .filter(|choice| {
                            matches!(choice, sources::Choice::Document(_))
                                && choice.document(&ui).is_none()
                        })
                        .map(|_| {
                            ui.lang
                                .text("Tab nicht mehr verfügbar", "Tab no longer available")
                                .into()
                        })
                })
                .unwrap_or_default();
            self.errors[side].set_text(&problem);
            self.errors[side].set_visible(!problem.is_empty());
            self.choose[side].set_sensitive(!state.busy.get());
            self.menus[side].set_sensitive(!state.busy.get());
        }
        for (index, option) in self.options.iter().enumerate() {
            option.set_sensitive(!state.busy.get() && (index != 0 || !self.options[1].is_active()));
        }
        self.compare.set_sensitive(
            self.loaded.get()
                && !state.busy.get()
                && choices.iter().all(Option::is_some)
                && self.problems.borrow().iter().all(Option::is_none)
                && choices.iter().flatten().all(|choice| {
                    !matches!(choice, sources::Choice::Document(_))
                        || choice.document(&ui).is_some()
                }),
        );
    }
    pub fn probe(state: &Rc<State>, side: usize) {
        let p = &state.picker;
        let epoch = p.probes[side].get().wrapping_add(1);
        p.probes[side].set(epoch);
        let choice = state.choices.borrow()[side].clone();
        let Some(choice) = choice else {
            p.update(state);
            return;
        };
        if let sources::Choice::File(path) = choice {
            p.problems.borrow_mut()[side] = Some(
                state
                    .lang
                    .text("Datei wird geprüft …", "Checking file …")
                    .into(),
            );
            p.update(state);
            let owner = Rc::downgrade(state);
            let lang = state.lang;
            support::background(
                move || Ok(sources::problem(&path, lang)),
                move |result| {
                    if let Some(state) = owner
                        .upgrade()
                        .filter(|s| s.picker.probes[side].get() == epoch)
                    {
                        state.picker.problems.borrow_mut()[side] = result.unwrap_or_else(Some);
                        state.picker.update(&state);
                    }
                },
            );
        } else {
            p.problems.borrow_mut()[side] = state
                .ui
                .upgrade()
                .filter(|ui| choice.document(ui).is_none())
                .map(|_| {
                    state
                        .lang
                        .text("Tab nicht mehr verfügbar", "Tab no longer available")
                        .into()
                });
            p.update(state);
        }
    }
}
