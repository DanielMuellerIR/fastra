use super::*;
impl Controls {
    pub(super) fn project_layout(self: &Rc<Self>, ui: &Rc<Ui>) {
        let rows = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .min_children_per_line(1)
            .max_children_per_line(2)
            .column_spacing(16)
            .row_spacing(8)
            .build();
        let sets = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        sets.append(&label(ui.lang, "Datei-Set", "File set"));
        sets.append(&self.sets);
        let add = chrome::icon(
            "fastra-plus-circle-symbolic",
            ui.lang
                .text("Gespeichertes Datei-Set anlegen", "Create saved file set"),
        );
        sets.append(&add);
        sets.append(&self.remove_set);
        rows.insert(&sets, -1);
        let types = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        types.append(&label(ui.lang, "Dateitypen", "File types"));
        types.append(&self.filter);
        rows.insert(&types, -1);
        for child in chrome::children(&rows) {
            child.set_focusable(false);
        }
        self.root.append(&rows);
        let excludes = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        excludes.append(&label(ui.lang, "Ausschlüsse", "Exclusions"));
        self.excludes.set_hexpand(true);
        self.excludes.set_tooltip_text(Some(ui.lang.text(
            "Projekt-relative Ausschlüsse; DerivedData wird immer ausgeschlossen.",
            "Project-relative exclusions; DerivedData is always excluded.",
        )));
        self.excludes.set_placeholder_text(Some(ui.lang.text(
            "z.B. .git, build, *.generated.swift",
            "e.g. .git, build, *.generated.swift",
        )));
        excludes.append(&self.excludes);
        self.root.append(&excludes);
        let weak = Rc::downgrade(self);
        add.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.edit_set();
            }
        });
        let weak = Rc::downgrade(self);
        self.remove_set.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                let root = s.project.clone().unwrap();
                let active = s.settings.borrow().project(&root).active;
                s.enqueue(Some(Change::Project(root, ProjectChange::Remove(active))));
            }
        });
        let weak = Rc::downgrade(self);
        self.sets.connect_selected_notify(move |sets| {
            if let Some(s) = weak.upgrade() {
                if !s.changing.get() {
                    let root = s.project.clone().unwrap();
                    let p = s.settings.borrow().project(&root);
                    if let Some(set) = p.sets.get(sets.selected() as usize) {
                        s.enqueue(Some(Change::Project(
                            root,
                            ProjectChange::Select(set.id.clone()),
                        )));
                    }
                }
            }
        });
    }
}
