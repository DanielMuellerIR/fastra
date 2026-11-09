//! Suchvorlagen füllen ausschließlich das Formular des zugehörigen Fensters.
use super::*;
use crate::git_view::{background, column, label, window};
use fastra_workflow::{
    patterns::{self, Collection, Pattern, Snapshot, Store},
    Error,
};
use std::{collections::BTreeMap, path::PathBuf};
thread_local! { static VIEWS: RefCell<Vec<std::rc::Weak<View>>> = const { RefCell::new(Vec::new()) }; }
struct View {
    ui: std::rc::Weak<Ui>,
    window: gtk::Window,
    lang: Language,
    snapshot: RefCell<Option<Snapshot>>,
    builtins: Vec<Pattern>,
    draft: RefCell<Option<Pattern>>,
    selected: Cell<u32>,
    loading: Cell<bool>,
    dirty: Cell<bool>,
    busy: Cell<bool>,
    writing: Cell<bool>,
    job: Cell<u64>,
    cancel: RefCell<Cancellation>,
    picker: gtk::DropDown,
    form: gtk::Grid,
    name: gtk::Entry,
    category: gtk::DropDown,
    regex: gtk::TextView,
    replacement: gtk::TextView,
    example: gtk::TextView,
    groups: gtk::TextView,
    has_replacement: gtk::CheckButton,
    info: gtk::Label,
    status: gtk::Label,
    new: gtk::Button,
    duplicate: gtk::Button,
    delete: gtk::Button,
    reload: gtk::Button,
    discard: gtk::Button,
    import: gtk::Button,
    export: gtk::Button,
    save: gtk::Button,
    apply: gtk::Button,
    cancel_button: gtk::Button,
    inspect: gtk::Button,
}
pub(super) fn message(error: &Error, lang: Language) -> String {
    match error {
        Error::Stale=>lang.text("Die Sammlung wurde inzwischen geändert. Entwurf behalten; verwerfen oder sichern und neu laden. Nichts überschrieben.","The collection changed elsewhere. Keep or discard the draft, then reload. Nothing was overwritten.").into(),
        Error::Limit=>lang.text("Grenze erreicht: 1 MiB JSON, 100 eigene Vorlagen, 16 KiB je Muster/Ersetzung/Beispiel und 64 Capture-Beschriftungen.","Limit reached: 1 MiB JSON, 100 user templates, 16 KiB per pattern/replacement/example and 64 capture labels.").into(),
        Error::Unsupported(fields)=> {
            let names=fields.iter().take(8).map(|name|name.chars().take(128).collect::<String>()).collect::<Vec<_>>().join(", ");
            format!("{} {} · {} {}",lang.text("Unbekannte Angaben sperren die Formularübernahme:","Unknown fields block filling the form:"),names,fields.len(),lang.text("Angaben; vollständige Definition als JSON prüfen.","fields; inspect the complete definition as JSON."))
        },
        Error::Core(error)=>error_text(lang,error),
        Error::Invalid(detail)=>format!("{} {detail}",lang.text("Vorlage oder Darstellung ist nicht verwendbar:","Template or display is unavailable:")),
        error=>format!("{} {error}",lang.text("Vorgang fehlgeschlagen; vorhandene Daten bleiben erhalten.","Operation failed; existing data was retained.")),
    }
}
pub(super) fn config() -> Result<PathBuf, Error> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")))
        .ok_or_else(|| Error::Invalid("config directory".into()))?;
    if !root.is_absolute() {
        return Err(Error::Invalid("absolute config directory".into()));
    }
    Ok(root)
}
fn text_view() -> gtk::TextView {
    gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build()
}
fn field_scroll(view: &gtk::TextView) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .height_request(27)
        .child(view)
        .hexpand(true)
        .build()
}
fn attach(grid: &gtk::Grid, row: i32, title: &str, field: &impl IsA<gtk::Widget>) {
    let caption = label(title);
    caption.set_valign(gtk::Align::Center);
    caption.set_xalign(1.);
    grid.attach(&caption, 0, row, 1, 1);
    grid.attach(field, 1, row, 1, 1);
}
pub(super) fn category_title(category: &str, lang: Language) -> &str {
    match category {
        "Identifikatoren" => lang.text("Identifikatoren", "Identifiers"),
        "Datum & Zeit" => lang.text("Datum & Zeit", "Date and time"),
        "Text-Strukturen" => lang.text("Text-Strukturen", "Text structures"),
        "Zahlen" => lang.text("Zahlen", "Numbers"),
        "Wörter & Zeilen" => lang.text("Wörter & Zeilen", "Words and lines"),
        "Leerraum & Aufräumen" => lang.text("Leerraum & Aufräumen", "Whitespace and cleanup"),
        _ => category,
    }
}
pub(super) fn builtin_title(value: &Pattern, lang: Language) -> String {
    if lang.0 {
        return value.name.clone();
    }
    let english = match value.id.as_str() {
        "email" => "Email address",
        "url" => "URL",
        "iban" => "IBAN",
        "ipv4" => "IPv4 address",
        "uuid" => "UUID",
        "iso_date" => "ISO date",
        "german_date" => "German date",
        "time" => "Time",
        "md_link" => "Markdown link",
        "md_heading" => "Markdown heading",
        "html_tag" => "HTML tag",
        "code_block" => "Code block",
        "file_path" => "File path",
        "integer" => "Integer",
        "german_decimal" => "German decimal",
        "phone_de" => "German phone number",
        "hex_color" => "Hex color",
        "semver" => "Semantic version",
        "file_name" => "File name",
        "iso_timestamp" => "ISO timestamp",
        "html_comment" => "HTML comment",
        "english_decimal" => "English decimal",
        "percentage" => "Percentage",
        "euro_amount" => "Euro amount",
        "one_word" => "One word",
        "two_words" => "Two words",
        "last_first_name" => "Last name, first name",
        "doubled_word" => "Repeated word",
        "capitalized_word" => "Capitalized word",
        "quoted_text" => "Quoted text",
        "german_quoted_text" => "German quoted text",
        "parenthesized_text" => "Parenthesized text",
        "whole_line" => "Whole line",
        "multiple_spaces" => "Multiple spaces",
        "trailing_whitespace" => "Trailing whitespace",
        "leading_whitespace" => "Leading whitespace",
        "tabs" => "Tabs",
        "empty_lines" => "Empty lines",
        _ => &value.name,
    };
    english.into()
}
pub fn show(ui: &Rc<Ui>) {
    if let Some(view) = VIEWS.with(|all| {
        all.borrow()
            .iter()
            .filter_map(std::rc::Weak::upgrade)
            .find(|v| v.ui.upgrade().is_some_and(|owner| Rc::ptr_eq(&owner, ui)))
    }) {
        view.window.present();
        return;
    }
    let lang = ui.lang;
    let builtins = match patterns::builtins() {
        Ok(v) => v,
        Err(e) => {
            ui.status.set_text(&message(&e, lang));
            return;
        }
    };
    let window = window(ui, lang.text("Suchvorlagen", "Search templates"), false);
    window.set_default_size(720, 430);
    window.set_size_request(640, 390);
    let root = column();
    root.add_css_class("pattern-library");
    root.append(&label(lang.text("Vorlagen füllen nur Suchen/Ersetzen und wählen Regex. Suchbereich und Flags bleiben erhalten; ohne Ersetzungsvorschlag bleibt der bisherige Ersetzungstext. Danach Vorschau neu berechnen und freigeben.","Templates only fill Find/Replace and select Regex. Scope and flags stay unchanged; without a replacement suggestion the existing replacement stays. Then calculate and approve a fresh preview.")));
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(3)
        .max_children_per_line(6)
        .column_spacing(8)
        .row_spacing(6)
        .build();
    let button = |de, en| gtk::Button::with_label(lang.text(de, en));
    let new = button("Neu aus Suchformular", "New from search form");
    let duplicate = button("Duplizieren", "Duplicate");
    let delete = button("Löschen", "Delete");
    let reload = button("Neu laden", "Reload");
    let discard = button("Entwurf verwerfen", "Discard draft");
    let import = button("Importieren …", "Import …");
    let export = button("Eigene Sammlung exportieren …", "Export user collection …");
    let inspect = button("Definition als JSON …", "Definition as JSON …");
    for b in [
        &new, &duplicate, &delete, &reload, &discard, &import, &export, &inspect,
    ] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let picker = git_view::file_dropdown();
    root.append(&picker);
    let info = label("");
    root.append(&info);
    let form = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(8)
        .build();
    let name = gtk::Entry::builder().hexpand(true).max_length(512).build();
    let category = git_view::file_dropdown();
    let regex = text_view();
    let replacement = text_view();
    let example = text_view();
    let groups = text_view();
    let has_replacement = gtk::CheckButton::with_label(lang.text(
        "Ersetzungsvorschlag verwenden (auch leer)",
        "Use replacement suggestion (including empty)",
    ));
    attach(&form, 0, lang.text("Name", "Name"), &name);
    attach(&form, 1, lang.text("Kategorie", "Category"), &category);
    attach(&form, 2, "Regex", &field_scroll(&regex));
    let replace_box = gtk::Box::new(gtk::Orientation::Vertical, 4);
    replace_box.append(&has_replacement);
    replace_box.append(&field_scroll(&replacement));
    attach(
        &form,
        3,
        lang.text("Ersetzung", "Replacement"),
        &replace_box,
    );
    attach(
        &form,
        4,
        lang.text("Beispieltext", "Example text"),
        &field_scroll(&example),
    );
    attach(
        &form,
        5,
        lang.text("Capture-Namen (JSON)", "Capture labels (JSON)"),
        &field_scroll(&groups),
    );
    root.append(
        &gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .min_content_height(180)
            .vexpand(true)
            .child(&form)
            .build(),
    );
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let save = button("Definition speichern", "Save definition");
    let apply = button("Suchformular füllen", "Fill search form");
    let cancel_button = button("Abbrechen", "Cancel");
    for b in [&apply, &save, &cancel_button] {
        footer.append(b);
    }
    root.append(&footer);
    footer.set_halign(gtk::Align::End);
    let status = label("");
    root.append(&status);
    // Wie die Mac-Bibliothek: Liste links, Definition rechts; Zusatzdaten
    // bleiben aufklappbar, ohne den gewöhnlichen Entwurf zu verdrängen.
    let main = gtk::Paned::new(gtk::Orientation::Horizontal);
    main.set_resize_start_child(false); main.set_shrink_start_child(false); main.set_shrink_end_child(false); main.set_position(210); main.set_vexpand(true);
    let selection = gtk::SingleSelection::new(None::<gtk::gio::ListModel>);
    selection.set_autoselect(false); selection.set_can_unselect(true);
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| { let item = item.downcast_ref::<gtk::ListItem>().unwrap(); let text = gtk::Label::new(None); text.set_xalign(0.); text.set_ellipsize(gtk::pango::EllipsizeMode::End); text.set_margin_start(10); text.set_margin_end(10); text.set_margin_top(5); text.set_margin_bottom(5); item.set_child(Some(&text)); });
    factory.connect_bind(|_, item| { let item = item.downcast_ref::<gtk::ListItem>().unwrap(); let text = item.child().unwrap().downcast::<gtk::Label>().unwrap(); if let Some(value) = item.item().and_downcast::<gtk::StringObject>() { text.set_text(&value.string()); text.set_tooltip_text(Some(&value.string())); } });
    let list = gtk::ListView::new(Some(selection.clone()), Some(factory)); list.add_css_class("tool-sidebar");
    let model = selection.downgrade(); picker.connect_model_notify(move |picker| { if let Some(model) = model.upgrade() { model.set_model(picker.model().as_ref()); } });
    picker.bind_property("selected", &selection, "selected").bidirectional().sync_create().build();
    let left = gtk::Box::new(gtk::Orientation::Vertical, 6); left.set_width_request(180); left.append(&scroll(&list));
    for item in [&new,&delete] { if let Some(parent) = item.parent().and_downcast::<gtk::FlowBoxChild>() { parent.set_child(None::<&gtk::Widget>); } }
    let local = gtk::Box::new(gtk::Orientation::Horizontal, 8); local.append(&new); local.append(&delete);
    let right = column();
    let form_scroll = form.ancestor(gtk::ScrolledWindow::static_type()).unwrap().downcast::<gtk::ScrolledWindow>().unwrap();
    for item in [form_scroll.upcast_ref::<gtk::Widget>(), info.upcast_ref(), footer.upcast_ref(), status.upcast_ref()] { root.remove(item); }
    form.set_valign(gtk::Align::Center); form_scroll.set_vexpand(true); right.append(&form_scroll);
    let advanced = gtk::Grid::builder().row_spacing(8).column_spacing(12).build();
    for old_row in [4,5] { for column in [0,1] { if let Some(child) = form.child_at(column, old_row) { form.remove(&child); advanced.attach(&child,column,old_row-4,1,1); } } }
    let extra = gtk::Expander::builder().label(lang.text("Weitere Vorlagendaten", "Additional template data")).child(&advanced).build(); form.attach(&extra,0,4,2,1);
    info.set_visible(false);
    for action in [&export,&import] { if let Some(parent) = action.parent().and_downcast::<gtk::FlowBoxChild>() { parent.set_child(None::<&gtk::Widget>); } footer.prepend(action); }
    let more = gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(lang.text("Weitere Aktionen", "More actions")).build(); let popover = gtk::Popover::new(); root.remove(&actions); popover.set_child(Some(&actions));
    for button in [&duplicate, &reload, &discard, &inspect] { let popover = popover.downgrade(); button.connect_clicked(move |_| { if let Some(popover) = popover.upgrade() { popover.popdown(); } }); }
    more.set_popover(Some(&popover)); local.append(&more);
    for (button, title) in [(&new,lang.text("Neu", "New")), (&import,lang.text("Importieren …", "Import …")), (&export,lang.text("Exportieren …", "Export …")), (&save,lang.text("Speichern", "Save")), (&apply,lang.text("Anwenden", "Apply"))] {
        button.set_tooltip_text(button.label().as_deref()); button.set_label(title);
    }
    cancel_button.set_visible(false);
    right.append(&local); right.append(&footer); right.append(&status);
    main.set_start_child(Some(&left)); main.set_end_child(Some(&right));
    for child in super::chrome::children(&root) { root.remove(&child); }
    root.set_margin_top(0); root.set_margin_bottom(0); root.set_margin_start(0); root.set_margin_end(0); root.append(&main);
    window.set_child(Some(&root));
    let view = Rc::new(View {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        lang,
        snapshot: RefCell::new(None),
        builtins,
        draft: RefCell::new(None),
        selected: Cell::new(gtk::INVALID_LIST_POSITION),
        loading: Cell::new(false),
        dirty: Cell::new(false),
        busy: Cell::new(false),
        writing: Cell::new(false),
        job: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        picker,
        form,
        name,
        category,
        regex,
        replacement,
        example,
        groups,
        has_replacement,
        info,
        status,
        new,
        duplicate,
        delete,
        reload,
        discard,
        import,
        export,
        save,
        apply,
        cancel_button,
        inspect,
    });
    connect(&view.new, &view, |v| v.new_draft(false));
    connect(&view.duplicate, &view, |v| v.new_draft(true));
    connect(&view.delete, &view, View::delete);
    connect(&view.reload, &view, View::reload);
    connect(&view.discard, &view, |v| {
        v.dirty.set(false);
        let id = v.draft.borrow().as_ref().map(|p| p.id.clone());
        v.rebuild(id.as_deref());
    });
    connect(&view.import, &view, View::import_file);
    connect(&view.export, &view, View::export_file);
    connect(&view.save, &view, View::save);
    connect(&view.apply, &view, View::fill_form);
    connect(&view.cancel_button, &view, View::cancel_job);
    connect(&view.inspect, &view, View::inspect);
    let weak = Rc::downgrade(&view);
    view.picker.connect_selected_notify(move |picker| {
        if let Some(v) = weak.upgrade() {
            if !v.loading.get() {
                v.populate(picker.selected());
            }
        }
    });
    for buffer in [
        view.regex.buffer(),
        view.replacement.buffer(),
        view.example.buffer(),
        view.groups.buffer(),
    ] {
        let weak = Rc::downgrade(&view);
        buffer.connect_changed(move |_| {
            if let Some(v) = weak.upgrade() {
                v.mark_dirty();
            }
        });
    }
    let weak = Rc::downgrade(&view);
    view.name.connect_changed(move |_| {
        if let Some(v) = weak.upgrade() {
            v.mark_dirty();
        }
    });
    let weak = Rc::downgrade(&view);
    view.category.connect_selected_notify(move |_| {
        if let Some(v) = weak.upgrade() {
            v.mark_dirty();
        }
    });
    let weak = Rc::downgrade(&view);
    view.has_replacement.connect_toggled(move |_| {
        if let Some(v) = weak.upgrade() {
            v.mark_dirty();
        }
    });
    let weak = Rc::downgrade(&view);
    window.connect_close_request(move |_| {
        let Some(v) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if v.busy.get() {
            v.status.set_text(v.lang.text(
                "Vorgang läuft. Abbrechen oder auf Abschluss warten.",
                "An operation is running. Cancel it or wait for completion.",
            ));
            return glib::Propagation::Stop;
        }
        if !v.dirty.get() {
            return glib::Propagation::Proceed;
        }
        let weak = Rc::downgrade(&v);
        gtk::AlertDialog::builder()
            .message(v.lang.text(
                "Ungesicherten Vorlagenentwurf verwerfen?",
                "Discard the unsaved template draft?",
            ))
            .buttons([
                v.lang.text("Abbrechen", "Cancel"),
                v.lang.text("Entwurf verwerfen", "Discard draft"),
            ])
            .default_button(0)
            .cancel_button(0)
            .build()
            .choose(Some(&v.window), None::<&gio::Cancellable>, move |answer| {
                if answer == Ok(1) {
                    if let Some(v) = weak.upgrade() {
                        v.dirty.set(false);
                        v.window.close();
                    }
                }
            });
        glib::Propagation::Stop
    });
    VIEWS.with(|all| {
        all.borrow_mut().retain(|v| v.strong_count() > 0);
        all.borrow_mut().push(Rc::downgrade(&view));
    });
    git_view::hold(&window, view.clone(), |v| v.cancel.borrow().cancel());
    window.present();
    view.reload();
}
fn connect(button: &gtk::Button, view: &Rc<View>, action: impl Fn(&Rc<View>) + 'static) {
    let weak = Rc::downgrade(view);
    button.connect_clicked(move |_| {
        if let Some(v) = weak.upgrade() {
            action(&v);
        }
    });
}
impl View {
    fn refresh(&self) {
        if let (Some(ui), Some(snapshot)) = (self.ui.upgrade(), self.snapshot.borrow().as_ref()) {
            template_menu::library_changed(&ui, self.builtins.iter().map(|p| (p, true)).chain(snapshot.collection.0.iter().map(|p| (p, false))));
        }
        let builtin = (self.selected.get() as usize) < self.builtins.len();
        let ready = self.snapshot.borrow().is_some();
        self.picker
            .set_sensitive(!self.busy.get() && !self.dirty.get());
        for b in [&self.new, &self.duplicate, &self.import, &self.export] {
            b.set_sensitive(ready && !self.busy.get() && !self.dirty.get());
        }
        self.reload
            .set_sensitive(!self.busy.get() && !self.dirty.get());
        self.delete.set_sensitive(
            ready
                && !builtin
                && !self.busy.get()
                && !self.dirty.get()
                && self.draft.borrow().is_some(),
        );
        self.discard
            .set_sensitive(!self.busy.get() && self.dirty.get());
        self.form.set_sensitive(!self.busy.get() && !builtin);
        self.save
            .set_sensitive(ready && !self.busy.get() && !builtin && self.dirty.get());
        self.apply.set_sensitive(
            ready
                && !self.busy.get()
                && self.draft.borrow().as_ref().is_some_and(|p| {
                    p.extra.is_empty() && patterns::CATEGORIES.contains(&p.category.as_str())
                }),
        );
        self.inspect
            .set_sensitive(ready && !self.busy.get() && self.draft.borrow().is_some());
        self.cancel_button
            .set_sensitive(self.busy.get() && !self.writing.get());
        self.replacement
            .set_sensitive(self.has_replacement.is_active());
    }
    fn mark_dirty(&self) {
        if self.loading.get() {
            return;
        }
        self.dirty.set(true);
        self.status.set_text(self.lang.text(
            "Entwurf geändert. Speichern und Formularfüllung sind getrennte Aktionen.",
            "Draft changed. Saving and filling the form are separate actions.",
        ));
        self.refresh();
    }
    fn populate(&self, index: u32) {
        let value = if (index as usize) < self.builtins.len() {
            self.builtins.get(index as usize).cloned()
        } else {
            self.snapshot
                .borrow()
                .as_ref()
                .and_then(|s| s.collection.0.get(index as usize - self.builtins.len()))
                .cloned()
        };
        let Some(value) = value else {
            return;
        };
        self.populate_value(value, index);
    }
    fn populate_value(&self, value: Pattern, index: u32) {
        self.loading.set(true);
        self.selected.set(index);
        self.name
            .set_text(&if (index as usize) < self.builtins.len() {
                builtin_title(&value, self.lang)
            } else {
                value.name.clone()
            });
        let unknown_category = serde_json::to_string(&value.category).unwrap();
        let mut categories: Vec<_> = patterns::CATEGORIES
            .iter()
            .map(|c| category_title(c, self.lang))
            .collect();
        let cat = patterns::CATEGORIES
            .iter()
            .position(|c| *c == value.category)
            .unwrap_or_else(|| {
                categories.push(&unknown_category);
                categories.len() - 1
            });
        self.category
            .set_model(Some(&gtk::StringList::new(&categories)));
        self.category.set_selected(cat as u32);
        self.regex.buffer().set_text(&value.regex);
        self.replacement
            .buffer()
            .set_text(value.default_replacement.as_deref().unwrap_or(""));
        self.has_replacement
            .set_active(value.default_replacement.is_some());
        self.example.buffer().set_text(&value.example_match);
        self.groups
            .buffer()
            .set_text(&serde_json::to_string_pretty(&value.group_labels).unwrap());
        self.info.set_text(if !value.extra.is_empty()||!patterns::CATEGORIES.contains(&value.category.as_str()){self.lang.text("Unbekannte Angaben bleiben erhalten. Formularfüllung ist gesperrt; Definition als JSON prüfen.","Unknown fields are preserved. Filling the form is blocked; inspect the definition as JSON.")}else if (index as usize)<self.builtins.len(){self.lang.text("Mitgelieferte Vorlage, unveränderlich. Für Änderungen zuerst duplizieren.","Bundled template, read-only. Duplicate it before editing.")}else{self.lang.text("Eigene Vorlage. Import ersetzt nur ausdrücklich gleiche IDs; keine automatische Suche oder Ersetzung.","User template. Imports replace only explicitly identical IDs; no automatic search or replacement.")});
        *self.draft.borrow_mut() = Some(value);
        self.dirty.set(false);
        self.loading.set(false);
        self.refresh();
    }
    fn rebuild(&self, id: Option<&str>) {
        let own = self.snapshot.borrow();
        let mut labels: Vec<_> = self
            .builtins
            .iter()
            .map(|v| {
                format!(
                    "{} · {}",
                    self.lang.text("Mitgeliefert", "Bundled"),
                    builtin_title(v, self.lang)
                )
            })
            .collect();
        if let Some(s) = own.as_ref() {
            labels.extend(s.collection.0.iter().map(|v| {
                format!(
                    "{} · {}",
                    self.lang.text("Eigene", "User"),
                    v.name.escape_debug()
                )
            }));
        }
        let index = id
            .and_then(|id| {
                self.builtins
                    .iter()
                    .chain(own.as_ref().into_iter().flat_map(|s| s.collection.0.iter()))
                    .position(|v| v.id == id)
            })
            .unwrap_or(0);
        drop(own);
        self.loading.set(true);
        self.picker.set_model(Some(&gtk::StringList::new(
            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        self.picker.set_selected(index as u32);
        self.loading.set(false);
        self.populate(index as u32);
    }
    fn read_draft(&self) -> Result<Pattern, Error> {
        let mut p = self
            .draft
            .borrow()
            .clone()
            .ok_or_else(|| Error::Invalid("template".into()))?;
        if (self.selected.get() as usize) < self.builtins.len() {
            return Ok(p);
        }
        for view in [&self.regex, &self.replacement, &self.example] {
            if view.buffer().char_count() > 16 * 1024 {
                return Err(Error::Limit);
            }
        }
        if self.groups.buffer().char_count() as usize > patterns::MAX_BYTES {
            return Err(Error::Limit);
        }
        p.name = self.name.text().into();
        p.regex = buffer_text(&self.regex.buffer());
        p.example_match = buffer_text(&self.example.buffer());
        p.default_replacement = self
            .has_replacement
            .is_active()
            .then(|| buffer_text(&self.replacement.buffer()));
        p.group_labels = serde_json::from_str(&buffer_text(&self.groups.buffer()))?;
        if let Some(category) = patterns::CATEGORIES.get(self.category.selected() as usize) {
            p.category = (*category).into();
        }
        Ok(p)
    }
    fn run<T: Send + 'static>(
        self: &Rc<Self>,
        writing: bool,
        work: impl FnOnce(Cancellation) -> Result<T, Error> + Send + 'static,
        done: impl FnOnce(&Rc<Self>, T) + 'static,
    ) {
        self.cancel.borrow().cancel();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.job.set(self.job.get() + 1);
        let job = self.job.get();
        self.busy.set(true);
        self.writing.set(writing);
        self.status
            .set_text(self.lang.text("Vorgang läuft …", "Working …"));
        self.refresh();
        let weak = Rc::downgrade(self);
        let lang = self.lang;
        background(
            move || work(cancel).map_err(|e| message(&e, lang)),
            move |result| {
                let Some(v) = weak.upgrade() else {
                    return;
                };
                if v.job.get() != job {
                    return;
                }
                v.busy.set(false);
                v.writing.set(false);
                match result {
                    Ok(value) => done(&v, value),
                    Err(error) => v.status.set_text(&error),
                }
                v.refresh();
            },
        );
    }
    fn cancel_job(self: &Rc<Self>) {
        if self.writing.get() {
            return;
        }
        self.cancel.borrow().cancel();
        self.job.set(self.job.get() + 1);
        self.busy.set(false);
        self.status.set_text(self.lang.text(
            "Abgebrochen. Keine Vorlage übernommen.",
            "Cancelled. No template was adopted.",
        ));
        self.refresh();
    }
    fn reload(self: &Rc<Self>) {
        let root = match config() {
            Ok(p) => p,
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        let id = self.draft.borrow().as_ref().map(|p| p.id.clone());
        self.run(
            false,
            move |cancel| Store::open(&root)?.load(&cancel),
            move |v, snapshot| {
                *v.snapshot.borrow_mut() = Some(snapshot);
                v.rebuild(id.as_deref());
                v.status.set_text(v.lang.text(
                    "38 mitgelieferte Vorlagen und eigene Sammlung geladen.",
                    "38 bundled templates and user collection loaded.",
                ));
            },
        );
    }
    fn new_draft(self: &Rc<Self>, duplicate: bool) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let mut p = if duplicate {
            match self.read_draft() {
                Ok(p) => p,
                Err(e) => {
                    self.status.set_text(&message(&e, self.lang));
                    return;
                }
            }
        } else {
            Pattern {
                id: String::new(),
                name: self.lang.text("Neue Vorlage", "New template").into(),
                category: patterns::CATEGORIES[2].into(),
                regex: ui.find.text().into(),
                example_match: String::new(),
                group_labels: Vec::new(),
                default_replacement: Some(ui.replace.text().into()),
                extra: BTreeMap::new(),
            }
        };
        p.id = match fastra_workflow::new_id() {
            Ok(id) => format!("user-{id}"),
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        if duplicate {
            p.name = format!("{} {}", p.name, self.lang.text("Kopie", "copy"));
        }
        self.loading.set(true);
        self.picker.set_selected(gtk::INVALID_LIST_POSITION);
        self.loading.set(false);
        self.populate_value(p, gtk::INVALID_LIST_POSITION);
        self.dirty.set(true);
        self.status.set_text(self.lang.text(
            "Neue Definition nur als Entwurf. Erst Speichern legt sie privat ab.",
            "New definition is only a draft. Save explicitly to store it privately.",
        ));
        self.refresh();
    }
    fn save_collection(
        self: &Rc<Self>,
        collection: Collection,
        id: Option<String>,
        notice: &'static str,
    ) {
        let Some(expected) = self.snapshot.borrow().clone() else {
            return;
        };
        let root = match config() {
            Ok(p) => p,
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        self.run(
            true,
            move |cancel| Store::open(&root)?.save(&expected, &collection, &cancel),
            move |v, snapshot| {
                *v.snapshot.borrow_mut() = Some(snapshot);
                v.dirty.set(false);
                v.rebuild(id.as_deref());
                v.status.set_text(notice);
            },
        );
    }
    fn save(self: &Rc<Self>) {
        let p = match self.read_draft() {
            Ok(p) => p,
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        let Some(s) = self.snapshot.borrow().clone() else {
            return;
        };
        let mut values = s.collection.0;
        values.retain(|v| v.id != p.id);
        let id = p.id.clone();
        values.push(p);
        self.save_collection(
            Collection(values),
            Some(id),
            self.lang.text(
                "Definition privat gespeichert. Formular und Dokument unverändert.",
                "Definition saved privately. Form and document unchanged.",
            ),
        );
    }
    fn delete(self: &Rc<Self>) {
        let Some(p) = self.draft.borrow().clone() else {
            return;
        };
        let Some(s) = self.snapshot.borrow().clone() else {
            return;
        };
        let mut values = s.collection.0;
        values.retain(|v| v.id != p.id);
        let weak = Rc::downgrade(self);
        gtk::AlertDialog::builder()
            .message(
                self.lang
                    .text("Eigene Vorlage löschen?", "Delete this user template?"),
            )
            .detail(&p.name)
            .buttons([
                self.lang.text("Abbrechen", "Cancel"),
                self.lang.text("Löschen", "Delete"),
            ])
            .default_button(0)
            .cancel_button(0)
            .build()
            .choose(
                Some(&self.window),
                None::<&gio::Cancellable>,
                move |answer| {
                    if answer == Ok(1) {
                        if let Some(v) = weak.upgrade() {
                            v.save_collection(
                                Collection(values),
                                None,
                                v.lang.text(
                                    "Vorlage gelöscht. Suchformular unverändert.",
                                    "Template deleted. Search form unchanged.",
                                ),
                            );
                        }
                    }
                },
            );
    }
    fn fill_form(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let generation = ui.generation.get();
        let p = match self.read_draft() {
            Ok(p) => p,
            Err(e) => {
                self.status.set_text(&message(&e, self.lang));
                return;
            }
        };
        self.run(false,move|cancel|{p.usable(&cancel)?;Ok(p)},move|v,p|{let Some(ui)=v.ui.upgrade()else{return;};if ui.generation.get()!=generation{v.status.set_text(v.lang.text("Suchformular oder Dokument inzwischen geändert. Vorlage erneut wählen; nichts übernommen.","The search form or document changed meanwhile. Choose the template again; nothing was adopted."));return;}template_menu::adopt(&ui, &p, v.builtins.iter().any(|b| b.id == p.id));ui.status.set_text(ui.lang.text("Vorlage im Suchformular. Neue Treffer und Vorschau prüfen und freigeben.","Template filled the search form. Check and approve the new matches and preview."));v.status.set_text(v.lang.text("Suchformular gefüllt; keine Ersetzung oder Dateispeicherung ausgeführt.","Search form filled; no replacement or file save was performed."));});
    }
}
pub fn prevent_close(ui: &Ui) -> bool {
    let views = VIEWS.with(|all| {
        all.borrow()
            .iter()
            .filter_map(std::rc::Weak::upgrade)
            .collect::<Vec<_>>()
    });
    for v in views {
        if v.ui
            .upgrade()
            .is_some_and(|owner| std::ptr::eq(Rc::as_ptr(&owner), ui))
            && (v.dirty.get() || v.busy.get())
        {
            v.status.set_text(v.lang.text("Vor dem Hauptfenster dieses Werkzeug fertigstellen: Entwurf speichern/verwerfen und laufenden Vorgang abschließen.","Finish this tool before closing the main window: save/discard the draft and finish the running operation."));
            v.window.present();
            return true;
        }
    }
    false
}
mod archive;
#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
