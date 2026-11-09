use super::*;
impl Controls {
    pub(super) fn edit_set(self: &Rc<Self>) {
        let lang = self.lang();
        let parent = self.owner.upgrade().unwrap();
        let window = gtk::Window::builder()
            .title(lang.text("Projekt-Datei-Set", "Project file set"))
            .transient_for(&parent)
            .modal(true)
            .default_width(440)
            .default_height(310)
            .build();
        chrome::dialog::decorate(
            &window,
            lang.text("Projekt-Datei-Set", "Project file set"),
            lang,
        );
        let root = git_view::column();
        root.set_spacing(12);
        root.set_margin_top(18);
        root.set_margin_bottom(18);
        root.set_margin_start(18);
        root.set_margin_end(18);
        let heading = gtk::Label::new(Some(lang.text("Projekt-Datei-Set", "Project file set")));
        heading.set_xalign(0.);
        heading.add_css_class("tool-heading");
        root.append(&heading);
        let name = gtk::Entry::builder()
            .placeholder_text(lang.text("Name", "Name"))
            .build();
        root.append(&name);
        root.append(&git_view::label(lang.text(
            "Projekt-relative Dateien oder Ordner, durch Komma oder Zeilenumbruch getrennt:",
            "Project-relative files or folders, separated by comma or line break:",
        )));
        let paths = gtk::TextView::builder()
            .monospace(true)
            .vexpand(true)
            .build();
        paths.buffer().set_text("Sources, Tests");
        let scroll = git_view::scroll(&paths);
        scroll.set_min_content_height(100);
        scroll.add_css_class("file-set-paths");
        root.append(&scroll);
        let feedback = git_view::label("");
        feedback.set_visible(false);
        feedback.connect_label_notify(|label| label.set_visible(!label.text().is_empty()));
        root.append(&feedback);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
        let save = gtk::Button::with_label(lang.text("Sichern", "Save"));
        save.add_css_class("suggested-action");
        window.set_default_widget(Some(&save));
        name.set_activates_default(true);
        actions.append(&cancel);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        actions.append(&save);
        root.append(&actions);
        window.set_child(Some(&root));
        let weak = window.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(w) = weak.upgrade() {
                w.close();
            }
        });
        let writing = Rc::new(Cell::new(false));
        let name_weak = name.downgrade();
        let paths_weak = paths.buffer().downgrade();
        let save_weak = save.downgrade();
        let busy = writing.clone();
        let validate = Rc::new(move || {
            if let (Some(name), Some(paths), Some(save)) = (
                name_weak.upgrade(),
                paths_weak.upgrade(),
                save_weak.upgrade(),
            ) {
                save.set_sensitive(
                    !busy.get()
                        && !name.text().trim().is_empty()
                        && buffer_text(&paths)
                            .split([',', '\n', '\r'])
                            .any(|s| !s.trim().is_empty()),
                );
            }
        });
        let refresh = validate.clone();
        let notice = feedback.downgrade();
        name.connect_changed(move |_| {
            if let Some(notice) = notice.upgrade() {
                notice.set_text("");
            }
            refresh();
        });
        let refresh = validate.clone();
        let notice = feedback.downgrade();
        paths.buffer().connect_changed(move |_| {
            if let Some(notice) = notice.upgrade() {
                notice.set_text("");
            }
            refresh();
        });
        validate();
        let keys = gtk::ShortcutController::new();
        let target = window.downgrade();
        keys.add_shortcut(gtk::Shortcut::new(
            gtk::ShortcutTrigger::parse_string("Escape"),
            Some(gtk::CallbackAction::new(move |_, _| {
                if let Some(window) = target.upgrade() {
                    window.close();
                }
                glib::Propagation::Stop
            })),
        ));
        window.add_controller(keys);
        let weak = Rc::downgrade(self);
        let owner = window.downgrade();
        save.connect_clicked(move |save| {
            let Some(s) = weak.upgrade() else {
                return;
            };
            let paths = buffer_text(&paths.buffer())
                .split([',', '\n', '\r'])
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>();
            if name.text().trim().is_empty()
                || paths.is_empty()
                || paths.iter().any(|p| {
                    std::path::Path::new(p).components().any(|c| {
                        !matches!(
                            c,
                            std::path::Component::Normal(_) | std::path::Component::CurDir
                        )
                    })
                })
            {
                feedback.set_text(lang.text(
                    "Name und projekt-relative Pfade angeben; keine absoluten Pfade oder „..“.",
                    "Enter a name and project-relative paths; no absolute paths or “..”.",
                ));
                return;
            }
            let id = match fastra_workflow::new_id() {
                Ok(id) => id,
                Err(error) => {
                    feedback.set_text(&error.to_string());
                    return;
                }
            };
            let set = FileSet {
                id: id.clone(),
                name: name.text().trim().into(),
                paths,
            };
            if writing.replace(true) {
                return;
            }
            save.set_sensitive(false);
            s.enqueue(Some(Change::Project(
                s.project.clone().unwrap(),
                ProjectChange::Add(set),
            )));
            if let Some(w) = owner.upgrade() {
                let weak = Rc::downgrade(&s);
                let owner = w.downgrade();
                let feedback = feedback.clone();
                let writing = writing.clone();
                let validate = validate.clone();
                glib::timeout_add_local(Duration::from_millis(40), move || {
                    let (Some(s), Some(w)) = (weak.upgrade(), owner.upgrade()) else {
                        return glib::ControlFlow::Break;
                    };
                    if s.busy() {
                        return glib::ControlFlow::Continue;
                    }
                    if s.settings
                        .borrow()
                        .project(s.project.as_ref().unwrap())
                        .sets
                        .iter()
                        .any(|set| set.id == id)
                    {
                        w.close();
                    } else {
                        feedback.set_text(&s.feedback.text());
                        writing.set(false);
                        validate();
                    }
                    glib::ControlFlow::Break
                });
            }
        });
        window.present();
    }
}
