use super::*;
impl Controls {
    fn folder_types(&self, ui: &Ui) -> gtk::MenuButton {
        let menu = gtk::MenuButton::new();
        menu.set_widget_name("fastra-folder-file-types");
        menu.add_css_class("search-file-types");
        menu.update_property(&[gtk::accessible::Property::Label(
            ui.lang
                .text("Dateitypen und Ausschlüsse", "File types and exclusions"),
        )]);
        let options = git_view::column();
        let mut previous = None;
        for (index, title) in [
            ui.lang.text("Bekannte Textformate", "Known text formats"),
            ui.lang.text("Alle Dateien", "All files"),
        ]
        .into_iter()
        .enumerate()
        {
            let check = gtk::CheckButton::with_label(title);
            check.set_group(previous.as_ref());
            check.set_active(self.filter.selected() == index as u32);
            let filter = self.filter.clone();
            check.connect_toggled(move |check| {
                if check.is_active() {
                    filter.set_selected(index as u32);
                }
            });
            let weak = check.downgrade();
            self.filter.connect_selected_notify(move |filter| {
                if let Some(check) = weak.upgrade() {
                    check.set_active(filter.selected() == index as u32);
                }
            });
            options.append(&check);
            previous = Some(check);
        }
        options.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        options.append(&label(ui.lang, "Ausschlüsse", "Exclusions"));
        options.append(&self.excludes);
        let popover = gtk::Popover::new();
        popover.set_child(Some(&options));
        menu.set_popover(Some(&popover));
        self.filter
            .bind_property("sensitive", &menu, "sensitive")
            .sync_create()
            .build();
        let weak = menu.downgrade();
        let lang = ui.lang;
        let update = move |filter: &gtk::DropDown| {
            if let Some(menu) = weak.upgrade() {
                menu.set_label(if filter.selected() == 0 {
                    lang.text("Bekannte Textformate", "Known text formats")
                } else {
                    lang.text("Alle Dateien", "All files")
                });
            }
        };
        update(&self.filter);
        self.filter.connect_selected_notify(update);
        menu
    }
    pub(super) fn folder_layout(
        self: &Rc<Self>,
        ui: &Rc<Ui>,
        factory: &gtk::SignalListItemFactory,
    ) {
        let heading = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        heading.append(&label(ui.lang, "Ordner", "Folders"));
        let notice = git_view::label(ui.lang.text(
            "Zuletzt verwendete Ordner (Auswahl zum Durchsuchen ankreuzen):",
            "Recent folders (check to include in search):",
        ));
        notice.add_css_class("muted");
        heading.append(&notice);
        self.root.append(&heading);
        self.root.append(&self.scroll);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let indent = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        indent.set_width_request(80);
        actions.append(&indent);
        let add = gtk::Button::with_label(ui.lang.text("Ordner hinzufügen…", "Add folders…"));
        add.add_css_class("search-folder-add");
        actions.append(&add);
        let types = gtk::Label::new(Some(ui.lang.text("Dateitypen", "File types")));
        types.add_css_class("search-field-label");
        actions.append(&types);
        actions.append(&self.folder_types(ui));
        self.root.append(&actions);
        let weak = Rc::downgrade(self);
        add.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.choose();
            }
        });
        let weak = Rc::downgrade(self);
        factory.connect_setup(move |_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let check = gtk::CheckButton::new();
            let title = gtk::Label::new(None);
            title.set_hexpand(true);
            title.set_xalign(0.);
            title.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            title.add_css_class("search-folder-path");
            let lang = weak.upgrade().map_or(Language(false), |s| s.lang());
            let remove = chrome::icon(
                "list-remove-symbolic",
                lang.text("Ordner entfernen", "Remove folder"),
            );
            row.append(&check);
            row.append(&title);
            row.append(&remove);
            item.set_child(Some(&row));
            let target = item.downgrade();
            let weak = weak.clone();
            let owner = weak.clone();
            check.connect_toggled(move |check| {
                if let (Some(s), Some(item)) = (owner.upgrade(), target.upgrade()) {
                    if !s.changing.get() {
                        let path = s
                            .settings
                            .borrow()
                            .folders
                            .get(item.position() as usize)
                            .map(|f| f.path());
                        if let Some(path) = path {
                            s.enqueue(Some(Change::EnableFolder(path, check.is_active())));
                        }
                    }
                }
            });
            let target = item.downgrade();
            remove.connect_clicked(move |_| {
                if let (Some(s), Some(item)) = (weak.upgrade(), target.upgrade()) {
                    let path = s
                        .settings
                        .borrow()
                        .folders
                        .get(item.position() as usize)
                        .map(|f| f.path());
                    if let Some(path) = path {
                        s.enqueue(Some(Change::RemoveFolder(path)));
                    }
                }
            });
        });
        let weak = Rc::downgrade(self);
        factory.connect_bind(move |_, item| {
            let Some(s) = weak.upgrade() else {
                return;
            };
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let folder = s.settings.borrow().folders[item.position() as usize].clone();
            let row = item.child().unwrap();
            let children = chrome::children(&row);
            let previous = s.changing.replace(true);
            children[0]
                .downcast_ref::<gtk::CheckButton>()
                .unwrap()
                .set_active(folder.enabled);
            let text = project_view::display(&folder.path());
            children[1]
                .downcast_ref::<gtk::Label>()
                .unwrap()
                .set_text(&text);
            children[1].set_tooltip_text(Some(&text));
            children[0].update_property(&[gtk::accessible::Property::Label(&text)]);
            children[2].update_property(&[gtk::accessible::Property::Label(&format!(
                "{}: {text}",
                s.lang().text("Ordner entfernen", "Remove folder")
            ))]);
            children[2].set_tooltip_text(Some(s.lang().text(
                "Diesen Ordner aus der Liste entfernen",
                "Remove this folder from the list",
            )));
            s.changing.set(previous);
        });
    }
}
