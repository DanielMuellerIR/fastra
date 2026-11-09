use super::*;
use std::rc::Weak;

pub(super) enum Target {
    Source {
        target: super::Target,
        path: Option<PathBuf>,
        offsets: (i32, i32),
    },
    Rich(Rc<crate::rich_editor::snippet::Bookmark>),
}
impl Target {
    fn current(&self, ui: &Ui) -> bool {
        match self {
            Self::Source {
                target,
                path,
                offsets,
            } => {
                ui.documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, &target.doc))
                    && target.doc.disk_path() == *path
                    && target.pane.valid_document(&target.doc)
                    && !target
                        .doc
                        .rectangles
                        .borrow()
                        .iter()
                        .any(|r| r.is_selected())
                    && target.doc.revision.get() == target.revision
                    && target.pane.offsets() == *offsets
            }
            Self::Rich(bookmark) => bookmark.current(),
        }
    }
}
pub(super) fn open(ui: &Rc<Ui>) {
    if let Some(existing) = VIEWS.with(|views| {
        views.borrow().iter().filter_map(Weak::upgrade).find(|v| {
            v.snippet
                && !v.closed.get()
                && v.ui.upgrade().is_some_and(|owner| Rc::ptr_eq(&owner, ui))
        })
    }) {
        existing.window.present();
        return;
    }
    if !crate::git_pull::write_allowed(ui) {
        return;
    }
    let Some(doc) = ui.active() else {
        return;
    };
    let rich = doc.rich.borrow().clone().filter(|e| e.active.get());
    if let Some(editor) = rich {
        let weak = Rc::downgrade(ui);
        crate::rich_editor::snippet::capture(&editor, move |bookmark| {
            let Some(ui) = weak.upgrade() else {
                return;
            };
            if let Some(bookmark) = bookmark.filter(|b| b.current()) {
                show_bound(&ui, Some(Target::Rich(bookmark)));
            } else {
                ui.status.set_text(&message(&Error::Stale, ui.lang));
            }
        });
    } else {
        if !ui.source_edit_allowed(&doc) {
            return;
        }
        match super::preview::capture_source(
            ui,
            &doc,
            true,
            true,
            fastra_document::EDITABLE_BYTES,
            ui.lang,
        ) {
            Ok(target) => show_bound(
                ui,
                Some(Target::Source {
                    path: doc.disk_path(),
                    offsets: target.pane.offsets(),
                    target,
                }),
            ),
            Err(error) => ui.status.set_text(&message(&error, ui.lang)),
        }
    }
}
pub(super) fn hint(text: &str) -> gtk::Label {
    let label = label(text);
    label.add_css_class("fastra-secondary");
    label.add_css_class("fastra-small");
    label
}
const PADDING: i32 = 12;
const LIBRARY_MIN: i32 = 180;
const LIBRARY_MAX: i32 = 260;
const EDITOR_MIN: i32 = 530;
fn padded() -> gtk::Box {
    gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_start(PADDING)
        .margin_end(PADDING)
        .margin_top(PADDING)
        .margin_bottom(PADDING)
        .build()
}
type Action = Box<dyn FnOnce(&Rc<View>)>;
pub(super) struct Layout {
    pub root: gtk::Box,
    filter: gtk::SearchEntry,
    library: gtk::Box,
    dirty: gtk::Label,
    stale: gtk::Label,
    fields_title: gtk::Label,
    close: gtk::Button,
    pub after_save: RefCell<Option<Action>>,
}
impl Layout {
    pub fn new(
        lang: Language,
        editor: &gtk::Box,
        preview: &gtk::TextView,
        status: &gtk::ScrolledWindow,
        insert: &gtk::Button,
        buttons: [&gtk::Button; 6],
    ) -> Self {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("fastra-snippets");
        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .margin_start(PADDING)
            .margin_end(PADDING)
            .margin_top(PADDING)
            .margin_bottom(PADDING)
            .build();
        header.append(&gtk::Image::from_icon_name("fastra-snippets-symbolic"));
        let title = label(lang.text("Textbausteine", "Text snippets"));
        title.add_css_class("heading");
        header.append(&title);
        let local = hint(lang.text(
            "Lokal gespeichert · keine Skripte",
            "Stored locally · no scripts",
        ));
        local.set_hexpand(true);
        local.set_halign(gtk::Align::End);
        header.append(&local);
        root.append(&header);
        root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let split = gtk::Paned::new(gtk::Orientation::Horizontal);
        split.set_position(LIBRARY_MAX);
        split.connect_position_notify(|split| {
            let position = split.position().clamp(LIBRARY_MIN, LIBRARY_MAX);
            if position != split.position() {
                split.set_position(position);
            }
        });
        split.set_resize_start_child(false);
        split.set_shrink_start_child(false);
        split.set_shrink_end_child(false);
        split.set_vexpand(true);
        let left = padded();
        left.set_size_request(LIBRARY_MIN - 2 * PADDING, -1);
        let filter = gtk::SearchEntry::new();
        filter.set_placeholder_text(Some(
            lang.text("Textbausteine durchsuchen", "Search text snippets"),
        ));
        left.append(&filter);
        let library = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let saved = scroll(&library);
        saved.set_min_content_height(80);
        saved.set_vexpand(true);
        left.append(&saved);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.append(buttons[0]);
        row.append(buttons[1]);
        left.append(&row);
        for button in &buttons[2..] {
            button.set_halign(gtk::Align::Start);
            left.append(*button);
        }
        buttons[5].set_label(lang.text("Löschen…", "Delete…"));
        buttons[3].set_label(lang.text("Importieren…", "Import…"));
        buttons[4].set_label(lang.text("Sammlung exportieren…", "Export collection…"));
        left.append(&hint(lang.text("Bis zu 50 Textbausteine. Import: höchstens 1 MiB; Namenskonflikte werden durch Nummern aufgelöst.","Up to 50 text snippets. Import: at most 1 MiB; name conflicts receive a number.")));
        split.set_start_child(Some(&left));
        let right = padded();
        right.set_size_request(EDITOR_MIN - 2 * PADDING, -1);
        editor.set_spacing(8);
        let dirty = hint(lang.text(
            "Speichere die Vorlage vor dem Einfügen.",
            "Save the template before inserting.",
        ));
        editor.insert_child_after(&dirty, editor.first_child().as_ref());
        // Derselbe Editor und dieselbe Ablage bedienen Bausteine und Abläufe; nur ihre Ansichten unterscheiden sich.
        right.append(editor);
        let fields_title = label(lang.text("Platzhalter ausfüllen", "Fill placeholders"));
        fields_title.add_css_class("heading");
        let fields = editor.last_child().unwrap();
        editor.insert_child_after(&fields_title, fields.prev_sibling().as_ref());
        right.append(&hint(lang.text(
            "Tab: nächstes Feld · Umschalt-Tab: vorheriges Feld · Leere Werte sind erlaubt.",
            "Tab: next field · Shift+Tab: previous field · Empty values are allowed.",
        )));
        let preview_title = label(lang.text("Einfügevorschau", "Insertion preview"));
        preview_title.add_css_class("heading");
        right.append(&preview_title);
        let preview_scroll = scroll(preview);
        preview_scroll.set_min_content_height(70);
        preview_scroll.set_max_content_height(150);
        preview_scroll.set_has_frame(true);
        preview_scroll.set_vexpand(true);
        right.append(&preview_scroll);
        right.append(&hint(lang.text("Grenzen: 16 KiB pro Vorlage und Feldwert, 32 verschiedene Platzhalter, 256 KiB Ergebnis.","Limits: 16 KiB per template and field value, 32 distinct placeholders, 256 KiB result.")));
        split.set_end_child(Some(&right));
        root.append(&split);
        root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let footer = padded();
        footer.set_spacing(6);
        footer.append(status);
        let stale = label("");
        stale.add_css_class("error");
        footer.append(&stale);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let note=hint(lang.text("Ersetzt die beim Öffnen festgehaltene Auswahl als einen Undo-Schritt. Die Datei wird erst beim Speichern geändert.","Replaces the selection captured when opening as one Undo step. The file changes only when saved."));
        note.set_hexpand(true);
        actions.append(&note);
        let close = gtk::Button::with_label(lang.text("Schließen", "Close"));
        close.set_valign(gtk::Align::Center);
        actions.append(&close);
        insert.set_valign(gtk::Align::Center);
        insert.set_label(lang.text("Baustein einfügen", "Insert snippet"));
        insert.add_css_class("suggested-action");
        actions.append(insert);
        footer.append(&actions);
        root.append(&footer);
        Self {
            root,
            filter,
            library,
            dirty,
            stale,
            fields_title,
            close,
            after_save: RefCell::new(None),
        }
    }
}
pub(super) fn connect(view: &Rc<View>) {
    let layout = view.snippet_layout.as_ref().unwrap();
    view.window.set_modal(true);
    view.window.set_titlebar(None::<&gtk::Widget>);
    view.window.set_decorated(false);
    view.window.add_css_class("fastra-snippet-window");
    view.window.set_default_size(960, 740);
    view.window.set_size_request(760, 650);
    view.window.set_default_widget(Some(&view.apply));
    clicked(&layout.close, view, |v| v.window.close());
    let weak = Rc::downgrade(view);
    layout.filter.connect_search_changed(move |_| {
        if let Some(v) = weak.upgrade() {
            refresh_library(&v);
        }
    });
    let weak = Rc::downgrade(view);
    glib::timeout_add_local(Duration::from_millis(150), move || {
        let Some(view) = weak.upgrade().filter(|v| !v.closed.get()) else {
            return glib::ControlFlow::Break;
        };
        refresh(&view);
        glib::ControlFlow::Continue
    });
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(view);
    keys.connect_key_pressed(move |_, key, _, mods| {
        if mods.is_empty() && key == gtk::gdk::Key::Escape {
            if let Some(v) = weak.upgrade() {
                v.window.close();
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    view.window.add_controller(keys);
}
pub(super) fn refresh_library(view: &Rc<View>) {
    let Some(layout) = &view.snippet_layout else {
        return;
    };
    while let Some(c) = layout.library.first_child() {
        layout.library.remove(&c);
    }
    let filter = layout.filter.text().to_lowercase();
    let saved = view.snapshot.borrow();
    let snippets = saved
        .as_ref()
        .map(|s| s.library.snippets.snippets.as_slice())
        .unwrap_or(&[]);
    let mut count = 0;
    for (index, item) in snippets.iter().enumerate() {
        match name_matches(&item.name, &filter, false) {
            Ok(true) => {}
            Ok(false) => continue,
            Err(error) => {
                view.error(error);
                return;
            }
        }
        count += 1;
        let button = gtk::Button::new();
        button.set_has_frame(false);
        button.add_css_class("snippet-library-item");
        button.set_hexpand(true);
        let text = label(&item.name);
        text.set_lines(2);
        text.set_ellipsize(gtk::pango::EllipsizeMode::End);
        button.set_child(Some(&text));
        button.set_tooltip_text(Some(&item.name));
        if view.selected.get() == Some(index) {
            button.add_css_class("snippet-selected");
        }
        clicked(&button, view, move |v| {
            protect(v, move |v| v.choose(Some(index)))
        });
        layout.library.append(&button);
    }
    if count == 0 {
        layout.library.append(&hint(if snippets.is_empty() {
            view.lang.text(
                "Noch keine Textbausteine. Erstelle eine Vorlage mit Neu.",
                "No text snippets yet. Create a template with New.",
            )
        } else {
            view.lang.text(
                "Keine passenden Textbausteine.",
                "No matching text snippets.",
            )
        }));
    }
}
fn rendered(view: &View) -> Result<String, Error> {
    let draft = view.draft.borrow();
    let Some(Draft::Snippet(snippet)) = draft.as_ref() else {
        return Err(Error::Stale);
    };
    snippet.validate()?;
    if !snippet.extra.is_empty() {
        return Err(Error::Unsupported(
            snippet
                .extra
                .keys()
                .map(|s| format!("snippet.{s}"))
                .collect(),
        ));
    }
    if let Some(snapshot) = view.snapshot.borrow().as_ref() {
        if !snapshot.library.snippets.extra.is_empty() {
            return Err(Error::Unsupported(
                snapshot
                    .library
                    .snippets
                    .extra
                    .keys()
                    .map(|s| format!("archive.{s}"))
                    .collect(),
            ));
        }
    }
    let values = view
        .values
        .borrow()
        .iter()
        .map(|(name, field)| {
            (
                name.clone(),
                field
                    .buffer()
                    .text(
                        &field.buffer().start_iter(),
                        &field.buffer().end_iter(),
                        true,
                    )
                    .to_string(),
            )
        })
        .collect();
    Template::parse(&snippet.template)?.render(&values)
}
pub(super) fn refresh(view: &View) {
    let Some(layout) = &view.snippet_layout else {
        return;
    };
    let ready = view.snapshot.borrow().is_some() && !view.busy.get();
    let dirty = view.dirty.get();
    view.editor
        .set_sensitive(ready && view.draft.borrow().is_some());
    for button in [
        &view.new,
        &view.duplicate,
        &view.reload,
        &view.import,
        &view.export,
        &view.remove,
    ] {
        button.set_sensitive(ready);
    }
    view.duplicate
        .set_sensitive(ready && view.draft.borrow().is_some());
    view.remove
        .set_sensitive(ready && view.selected.get().is_some());
    view.export.set_sensitive(
        ready
            && view
                .snapshot
                .borrow()
                .as_ref()
                .is_some_and(|s| !s.library.snippets.snippets.is_empty()),
    );
    view.save.set_sensitive(
        ready
            && dirty
            && view
                .draft
                .borrow()
                .as_ref()
                .is_some_and(|d| matches!(d,Draft::Snippet(s) if s.validate().is_ok())),
    );
    layout.filter.set_sensitive(ready);
    layout.library.set_sensitive(ready);
    layout.close.set_sensitive(!view.busy.get());
    layout.dirty.set_visible(dirty);
    layout
        .fields_title
        .set_visible(!view.values.borrow().is_empty());
    let current = view
        .ui
        .upgrade()
        .is_some_and(|ui| view.snippet_target.as_ref().is_some_and(|t| t.current(&ui)));
    layout.stale.set_text(if current{""}else{view.lang.text("Dokument oder festgehaltene Auswahl wurde geändert. Textbausteine für das gewünschte Ziel erneut öffnen.","The document or captured selection changed. Reopen text snippets for the intended target.")});
    layout.stale.set_visible(!current);
    let output = rendered(view);
    let content = output.as_ref().map(String::as_str).unwrap_or("");
    if view.after.buffer().text(
        &view.after.buffer().start_iter(),
        &view.after.buffer().end_iter(),
        true,
    ) != content
    {
        view.after.buffer().set_text(content);
    }
    view.apply
        .set_sensitive(ready && !dirty && current && output.is_ok());
}
pub(super) fn update_preview(view: &View) {
    refresh(view);
    if let Err(error) = rendered(view) {
        view.error(error);
    }
}
pub(super) fn protect(view: &Rc<View>, action: impl FnOnce(&Rc<View>) + 'static) {
    if !view.snippet || !view.dirty.get() {
        action(view);
        return;
    }
    if view.busy.get() {
        return;
    }
    let prompt = gtk::AlertDialog::builder()
        .message(view.lang.text(
            "Ungespeicherte Änderungen am Textbaustein",
            "Unsaved changes to the text snippet",
        ))
        .detail(view.lang.text(
            "Die Vorlage wurde geändert. Der Dokumentinhalt bleibt bis zum Einfügen unverändert.",
            "The template changed. The document stays unchanged until insertion.",
        ))
        .buttons([
            view.lang.text("Speichern", "Save"),
            view.lang.text("Verwerfen", "Discard"),
            view.lang.text("Zurück", "Back"),
        ])
        .cancel_button(2)
        .default_button(0)
        .build();
    let weak = Rc::downgrade(view);
    prompt.choose(
        Some(&view.window),
        None::<&gio::Cancellable>,
        move |result| {
            let Some(view) = weak.upgrade().filter(|v| !v.closed.get()) else {
                return;
            };
            // GTK löst die Rückfrage erst nach ihrem Callback vom Elternfenster.
            // Das Ziel darf vorher weder geschlossen noch durch einen neuen Dialog ersetzt werden.
            glib::idle_add_local_once(move || {
                if view.closed.get() {
                    return;
                }
                match result {
                    Ok(0) => {
                        *view
                            .snippet_layout
                            .as_ref()
                            .unwrap()
                            .after_save
                            .borrow_mut() = Some(Box::new(action));
                        view.save_definition();
                    }
                    Ok(1) => {
                        view.dirty.set(false);
                        action(&view);
                    }
                    _ => {}
                }
            });
        },
    );
}
pub(super) fn insert(view: &Rc<View>) {
    if view.busy.get() || view.dirty.get() || view.closed.get() {
        return;
    }
    let Some(ui) = view.ui.upgrade() else {
        return;
    };
    if !crate::git_pull::write_allowed(&ui) {
        view.status.set_text(&ui.status.text());
        return;
    }
    let Some(target) = view.snippet_target.as_ref().filter(|t| t.current(&ui)) else {
        view.error(Error::Stale);
        return;
    };
    let output = match rendered(view) {
        Ok(s) => s,
        Err(e) => {
            view.error(e);
            return;
        }
    };
    match target {
        Target::Source { target, .. } => {
            let source = target.source.clone();
            let range = target.range.unwrap();
            let lang = view.lang;
            view.run(
                move || {
                    let bytes = range.byte_range(&source)?;
                    let mut result = source;
                    result.replace_range(bytes, &output);
                    crate::text_limits::validate(&result, lang).map_err(Error::Invalid)?;
                    Ok(output)
                },
                |view, output| {
                    let Some(ui) = view.ui.upgrade() else {
                        return;
                    };
                    if !crate::git_pull::write_allowed(&ui) {
                        view.status.set_text(&ui.status.text());
                        return;
                    }
                    let Some(Target::Source {
                        target, offsets, ..
                    }) = view.snippet_target.as_ref().filter(|t| t.current(&ui))
                    else {
                        view.error(Error::Stale);
                        return;
                    };
                    let buffer = &target.pane.buffer;
                    let (a, b) = *offsets;
                    buffer.begin_user_action();
                    buffer.delete(&mut buffer.iter_at_offset(a), &mut buffer.iter_at_offset(b));
                    buffer.insert(&mut buffer.iter_at_offset(a), &output);
                    buffer.end_user_action();
                    view.window.close();
                    target.pane.view.grab_focus();
                },
            );
        }
        Target::Rich(bookmark) => {
            view.busy.set(true);
            refresh(view);
            let weak = Rc::downgrade(view);
            bookmark.insert(output, move |result| {
                if let Some(v) = weak.upgrade().filter(|v| !v.closed.get()) {
                    v.busy.set(false);
                    match result {
                        Ok(()) => v.window.close(),
                        Err(error) => {
                            v.status.set_text(&error);
                            refresh(&v);
                        }
                    }
                }
            });
        }
    }
}

#[cfg(debug_assertions)]
pub(super) mod selftest;

pub(super) fn name_matches(name: &str, query: &str, whole: bool) -> Result<bool, Error> {
    if query.is_empty() {
        return Ok(!whole || name.is_empty());
    }
    let request = fastra_core::SearchRequest {
        pattern: query.into(),
        replacement: String::new(),
        mode: fastra_core::SearchMode::Literal,
        case_sensitive: false,
        range: None,
    };
    let cancel = Cancellation::default();
    let search = fastra_core::PreparedSearch::new(
        &request,
        fastra_core::SearchFlags::default(),
        fastra_core::Limits::default(),
        &cancel,
    )?;
    let result = search.preview(name, 0, 0)?;
    Ok(result.matches().iter().any(|m| {
        !whole || (m.range.location == 0 && m.range.length == name.encode_utf16().count())
    }))
}
pub(super) fn available_name(view: &View, name: &str) -> Result<String, Error> {
    use unicode_segmentation::UnicodeSegmentation;
    let base = name.trim().graphemes(true).take(80).collect::<String>();
    let mut candidate = base.clone();
    let mut suffix = 2;
    let snapshot = view.snapshot.borrow();
    let saved = snapshot.as_ref().ok_or(Error::Stale)?;
    loop {
        let mut conflict = false;
        for item in &saved.library.snippets.snippets {
            if name_matches(&item.name, &candidate, true)? {
                conflict = true;
                break;
            }
        }
        if !conflict {
            return Ok(candidate);
        }
        let ending = format!(" ({suffix})");
        candidate = base
            .graphemes(true)
            .take(80 - ending.len())
            .collect::<String>()
            + &ending;
        suffix += 1;
    }
}
