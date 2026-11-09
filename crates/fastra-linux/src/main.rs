use fastra_core::{Cancellation, Limits, Preview, SearchMode, SearchRequest};
use gtk::{gio, glib, prelude::*};
use sourceview5::prelude::*;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::mpsc,
    time::Duration,
};

#[derive(Clone, Copy)]
struct Language(bool);
impl Language {
    fn text(self, de: &'static str, en: &'static str) -> &'static str {
        if self.0 {
            de
        } else {
            en
        }
    }
}

struct Document {
    chrome: RefCell<Option<Rc<chrome::DocumentChrome>>>,
    source_panes: RefCell<Option<Rc<source_panes::Panes>>>,
    syntax_folds: RefCell<Option<Rc<folding::Folds>>>,
    outline: RefCell<Option<Rc<markdown_navigation::View>>>,
    buffer: sourceview5::Buffer,
    revision: Cell<u64>,
    label: gtk::Label,
    original: RefCell<String>,
    line_endings: line_endings::State,
    snapshot: RefCell<Option<fastra_io::Snapshot>>,
    read_source: RefCell<Option<std::sync::Arc<fastra_document::ReadOnlyTextDocument>>>,
    saving: Cell<bool>,
    close_pending: Cell<bool>,
    name: String,
    rectangles: RefCell<Vec<Rc<rectangle::Rectangle>>>,
    folded: RefCell<Option<gtk::TextTag>>,
    markdown: RefCell<Option<Rc<markdown::MarkdownView>>>,
    markdown_toggle: RefCell<Option<gtk::CheckButton>>,
    rich_toggle: RefCell<Option<gtk::CheckButton>>,
    markdown_visual_override: Cell<Option<bool>>,
    markdown_visual_programmatic: Cell<bool>,
    format: RefCell<std::sync::Arc<fastra_core::encoding::Decoded>>,
    format_label: gtk::Label,
    reopen: gtk::Button,
    charset: gtk::DropDown,
    container: gtk::Box,
    section_view: RefCell<Option<Rc<document_view::DocumentView>>>,
    watch: RefCell<Option<Rc<watch::State>>>,
    rich: RefCell<Option<Rc<rich_editor::RichEditor>>>,
    visual_view: RefCell<Option<Rc<viewer::Viewer>>>,
    comparison: RefCell<Option<Rc<diff_view::State>>>,
    editor_options: RefCell<Option<Rc<editor_options::Options>>>,
    hex_editor: RefCell<Option<Rc<hex_editor::Editor>>>,
}
impl Document {
    fn has_source_text(&self) -> bool {
        self.section_view.borrow().is_none()
            && self.visual_view.borrow().is_none()
            && self.comparison.borrow().is_none()
    }
    fn is_read_only(&self) -> bool {
        !self.has_source_text() || self.read_source.borrow().is_some()
    }
    fn is_rich_active(&self) -> bool {
        self.rich.borrow().as_ref().is_some_and(|e| e.active.get())
    }
    fn source_edits_locked(&self) -> bool {
        self.is_read_only() || self.is_rich_active()
    }
    fn disk_path(&self) -> Option<std::path::PathBuf> {
        if let Some(source) = self.read_source.borrow().as_ref() {
            return Some(source.path().to_owned());
        }
        if let Some(view) = self.section_view.borrow().as_ref() {
            return Some(view.source().path().to_owned());
        }
        if let Some(view) = self.visual_view.borrow().as_ref() {
            return Some(view.disk_path());
        }
        self.snapshot
            .borrow()
            .as_ref()
            .map(|snapshot| snapshot.path())
    }
    fn source_identity(&self) -> Option<fastra_io::FileIdentity> {
        self.snapshot.borrow().as_ref().map(fastra_io::Snapshot::file_identity).or_else(|| {
            self.read_source.borrow().as_ref().map(|source| source.snapshot().file_identity())
        })
    }
    fn update_saved_baseline_status(&self, current_text: &str) {
        let dirty = current_text != self.original.borrow().as_str()
            || self.line_endings.pending().is_some();
        self.buffer.set_modified(dirty);
    }
    fn update_label(&self) {
        let dirty = self.buffer.is_modified()
            || self
                .hex_editor
                .borrow()
                .as_ref()
                .is_some_and(|editor| editor.dirty());
        let title = self
            .snapshot
            .borrow()
            .as_ref()
            .and_then(|snapshot| {
                snapshot
                    .path()
                    .file_name()
                    .map(|name| project_view::display(std::path::Path::new(name)))
            })
            .unwrap_or_else(|| self.name.clone());
        self.label
            .set_text(&format!("{title}{}", if dirty { " •" } else { "" }));
        self.label.set_tooltip_text(Some(
            &self
                .disk_path()
                .map(|path| project_view::display(&path))
                .unwrap_or(title),
        ));
    }
}

enum SaveTarget {
    Existing(fastra_io::Snapshot),
    New(std::path::PathBuf),
}

type LoadValidator = Box<dyn FnOnce(&viewer::Loaded) -> bool + Send>;
type LoadCompletion = Box<dyn FnOnce(Rc<Document>)>;

struct Pending {
    preview: std::sync::Arc<Preview>,
    selection: Option<(i32, i32)>,
    target: Option<source_panes::Target>,
}
struct Ui {
    chrome: RefCell<Option<Rc<chrome::Shell>>>,
    search_history: RefCell<Option<Rc<search_history::Menu>>>,
    search_pattern: RefCell<Option<Rc<search_pattern::Model>>>,
    outline_history: RefCell<Option<Rc<markdown_navigation::History>>>,
    template_choice: RefCell<Option<(String, String)>>,
    template_menus: RefCell<Vec<Rc<template_menu::Menu>>>,
    lang: Language,
    window: gtk::ApplicationWindow,
    documents: RefCell<Vec<Rc<Document>>>,
    saved_diff_tool: gtk::Button,
    tab_mru: RefCell<Vec<std::rc::Weak<Document>>>,
    comparison_pair: RefCell<Option<tab_comparison::Pair>>,
    tabs: gtk::Notebook,
    find: gtk::Entry,
    replace: gtk::Entry,
    mode: gtk::DropDown,
    scope: gtk::DropDown,
    case: gtk::CheckButton,
    whole_word: gtk::CheckButton,
    search_section: gtk::Expander,
    approval: Rc<approval::ApprovalPane>,
    captures: gtk::ListView,
    capture_scroll: gtk::ScrolledWindow,
    status: gtk::Label,
    apply: gtk::Button,
    save: gtk::Button,
    generation: Cell<u64>,
    pending: RefCell<Option<Pending>>,
    search_emphasis: RefCell<Option<search_navigation::Emphasis>>,
    search_selection: RefCell<Option<search_selection::Frozen>>,
    selection_control: glib::WeakRef<gtk::CheckButton>,
    folder_configuration: RefCell<Option<folder::SearchConfiguration>>,
    project_configuration: RefCell<Option<(String, folder::SearchConfiguration)>>,
    cancellation: RefCell<Cancellation>,
    discard_confirmed: Cell<bool>,
    window_close_dialog: Cell<bool>,
    session: RefCell<Option<Rc<session::State>>>,
    close_ticket: RefCell<Option<std::rc::Weak<close_protocol::Ticket>>>,
    close_committed: Cell<bool>,
    startup_restore_epoch: Cell<u64>,
    project: RefCell<Option<Rc<project_view::State>>>,
}
impl Ui {
    fn refresh_clean_documents(&self, snapshots: Vec<fastra_io::Snapshot>) {
        for snapshot in snapshots {
            for doc in self.documents.borrow().iter() {
                if doc.disk_path().as_ref() == Some(&snapshot.path())
                    && !doc.is_read_only()
                    && !doc.buffer.is_modified()
                    && !doc.saving.get()
                    && !doc.is_rich_active()
                {
                    let encoding = doc.format.borrow().encoding();
                    if let Ok(decoded) =
                        fastra_core::encoding::decode(snapshot.bytes(), Some(encoding))
                    {
                        if let Err(error) = text_limits::validate(decoded.text(), self.lang) {
                            self.status.set_text(&format!("{} {error}", self.lang.text("Neue Dateifassung nicht in den Texteditor geladen; bisheriger Editorstand bleibt erhalten.", "New file contents were not loaded into the text editor; the previous editor contents are retained.")));
                            continue;
                        }
                        source_panes::reset(doc, true);
                        doc.buffer.begin_irreversible_action();
                        doc.buffer.set_text(decoded.text());
                        doc.buffer.end_irreversible_action();
                        source_panes::reset(doc, false);
                        doc.line_endings.reset(decoded.text());
                        *doc.original.borrow_mut() = decoded.text().to_owned();
                        doc.format_label.set_text(&document_view::format_text(
                            &decoded,
                            decoded.text(),
                            self.lang,
                        ));
                        *doc.format.borrow_mut() = std::sync::Arc::new(decoded);
                        *doc.snapshot.borrow_mut() = Some(snapshot.clone());
                        doc.buffer.set_modified(false);
                        doc.update_label();
                    }
                }
            }
        }
        self.refresh_save();
    }
    fn source_edit_allowed(&self, doc: &Document) -> bool {
        if doc.is_rich_active() {
            self.status.set_text(self.lang.text(
                "Für diese Aktion zuerst zum Quelltext wechseln. Die formatierten Änderungen werden dabei synchronisiert.",
                "Return to source mode for this action. Formatted edits will be synchronized during the switch.",
            ));
            false
        } else if doc.is_read_only() {
            self.status.set_text(if doc.read_source.borrow().is_some() { self.lang.text(
                "Diese Datei bleibt schreibgeschützt. Mit »Als Kopie bearbeiten« eine neue Datei anlegen.",
                "This file remains read-only. Use “Edit a copy” to create a new file.",
            ) } else { self.lang.text(
                "Diese Ansicht ist schreibgeschützt. Bearbeiten ist im vollständig geladenen Text möglich.",
                "This view is read-only. Editing is available in fully loaded text.",
            ) });
            false
        } else {
            true
        }
    }
    fn source_read_allowed(&self, doc: &Document) -> bool {
        if doc.has_source_text() && !doc.is_rich_active() {
            true
        } else {
            self.source_edit_allowed(doc)
        }
    }
    fn active(&self) -> Option<Rc<Document>> {
        self.documents
            .borrow()
            .get(self.tabs.current_page()? as usize)
            .cloned()
    }
    fn invalidate(&self) {
        git_fetch::invalidate_owner(self);
        git_push::invalidate_owner(self);
        git_branches::invalidate_owner(self);
        git_switch::invalidate_owner(self);
        git_pull::invalidate_owner(self);
        git_commit::invalidate_owner(self);
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.search_emphasis.borrow_mut().take();
        self.pending.borrow_mut().take();
        self.apply.set_sensitive(false);
        self.approval.clear();
        self.refresh_save();
        self.status.set_text(self.lang.text(
            "Vorschau neu berechnen, bevor Änderungen übernommen werden.",
            "Calculate a preview before applying changes.",
        ));
        self.status.set_visible(false);
    }
    fn new_document(self: &Rc<Self>) {
        self.add_document(self.lang.text("Unbenannt", "Untitled"), "");
        if let Some(doc) = self.active() { tab_close::focus(self, &doc); }
    }
    fn add_document(self: &Rc<Self>, name: &str, text: &str) {
        self.add_document_with_source(name, text, None);
    }
    fn add_document_with_source(
        self: &Rc<Self>,
        name: &str,
        text: &str,
        read_source: Option<std::sync::Arc<fastra_document::ReadOnlyTextDocument>>,
    ) {
        editor_options::startup::interrupt(self);
        let initial_format = read_source.as_ref().map(|source| source.shared_decoded())
            .unwrap_or_else(|| std::sync::Arc::new(fastra_core::encoding::decode(&[], None).unwrap()));
        let buffer = source_panes::new_buffer(None::<&gtk::TextTagTable>);
        buffer.set_enable_undo(false);
        buffer.set_text(text);
        buffer.place_cursor(&buffer.start_iter());
        buffer.set_enable_undo(true);
        buffer.set_modified(false);
        let manager = sourceview5::LanguageManager::default();
        if let Some(language) = manager.guess_language(Some(name), None) {
            buffer.set_language(Some(&language));
        }
        let doc = Rc::new(Document {
            chrome: RefCell::new(None),
            source_panes: RefCell::new(None),
            syntax_folds: RefCell::new(None),
            outline: RefCell::new(None),
            buffer: buffer.clone(),
            revision: Cell::new(0),
            label: gtk::Label::new(Some(name)),
            original: RefCell::new(text.to_owned()),
            line_endings: line_endings::State::new(text),
            snapshot: RefCell::new(None),
            read_source: RefCell::new(read_source),
            saving: Cell::new(false),
            close_pending: Cell::new(false),
            name: name.to_owned(),
            rectangles: RefCell::new(Vec::new()),
            folded: RefCell::new(None),
            markdown: RefCell::new(None),
            markdown_toggle: RefCell::new(None),
            rich_toggle: RefCell::new(None),
            markdown_visual_override: Cell::new(None),
            markdown_visual_programmatic: Cell::new(false),
            format: RefCell::new(initial_format),
            format_label: gtk::Label::new(None),
            reopen: gtk::Button::with_label(self.lang.text("Neu öffnen in Tab", "Reopen in tab")),
            charset: gtk::DropDown::from_strings(&[
                self.lang.text("Automatisch", "Automatic"),
                "UTF-8",
                "UTF-16 LE",
                "UTF-16 BE",
                "UTF-32 LE",
                "UTF-32 BE",
                "Windows-1252",
                "Latin-1",
                "MacRoman",
            ]),
            container: gtk::Box::new(gtk::Orientation::Vertical, 6),
            section_view: RefCell::new(None),
            watch: RefCell::new(None),
            rich: RefCell::new(None),
            visual_view: RefCell::new(None),
            comparison: RefCell::new(None),
            editor_options: RefCell::new(None),
            hex_editor: RefCell::new(None),
        });
        let first = source_editor(&buffer);
        let secondary = source_panes::Panes::secondary(&buffer);
        let second = source_editor(&secondary);
        if doc.is_read_only() {
            first.set_editable(false);
            second.set_editable(false);
        }
        first.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Label(self.lang.text("Quelltext, Ansicht A", "Source text, pane A"))]);
        second.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Label(self.lang.text("Quelltext, Ansicht B", "Source text, pane B"))]);
        source_panes::guard(self,&doc,&second);
        four_d_completion_view::install(self, &doc, &first);
        four_d_completion_view::install(self, &doc, &second);
        let peers = Rc::new(RefCell::new(Vec::new()));
        let weak = Rc::downgrade(self);
        let report: Rc<dyn Fn(rectangle::Error)> = Rc::new(move |error| {
            if let Some(ui) = weak.upgrade() {
                ui.status.set_text(match error {rectangle::Error::Limit=>ui.lang.text("Rechteckgrenze erreicht: höchstens 2001 Zeilen, 4 MiB Gesamttext und 64 KiB je Ergebniszeile.","Rectangle limit reached: at most 2001 rows, 4 MiB total text and 64 KiB per resulting line."),rectangle::Error::Rows=>ui.lang.text("Spaltenpaste braucht eine Zeile oder genau eine Zeile je ausgewählter Zeile.","Column paste requires one line or exactly one line per selected row."),rectangle::Error::Selection=>ui.lang.text("Rechteckerweiterung benötigt eine Auswahl innerhalb einer logischen Zeile.","Rectangle extension needs a selection within one logical line."),rectangle::Error::Clipboard=>ui.lang.text("Die Zwischenablage konnte nicht übernommen werden. Der Quelltext bleibt unverändert.","The clipboard could not be transferred. Source text is unchanged.")});
            }
        });
        let document = Rc::downgrade(&doc);
        let owner = Rc::downgrade(self);
        let ending: Rc<dyn Fn() -> Option<fastra_core::encoding::LineEnding>> = Rc::new(move || {
            let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
                return None;
            };
            if !ui.window.is_visible()
                || !ui.window.is_active()
                || ui.window_close_dialog.get()
                || ui.close_committed.get()
                || doc.close_pending.get()
                || doc.source_edits_locked()
                || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            {
                return None;
            }
            let ending = doc.line_endings.editor_ending(&doc.original.borrow());
            Some(ending)
        });
        let first_rectangle = rectangle::Rectangle::attach(&first, peers.clone(), report.clone(), ending.clone());
        let second_rectangle = rectangle::Rectangle::attach(&second, peers, report, ending);
        *doc.source_panes.borrow_mut() = Some(source_panes::Panes::install(self,&doc, [&first, &second]));
        linear_paste::install(self, &doc, [&first, &second]);
        doc.rectangles
            .borrow_mut()
            .extend([first_rectangle.clone(), second_rectangle]);
        go_to_target::install(self, &doc, &first);
        go_to_target::install(self, &doc, &second);
        let split = gtk::Paned::new(gtk::Orientation::Horizontal);
        split.set_start_child(Some(&scroll(&first)));
        let right = scroll(&second);
        right.set_visible(false);
        split.set_end_child(Some(&right));
        split.set_resize_start_child(true);
        split.set_resize_end_child(true);
        let pane = doc.container.clone();
        let format_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        doc.format_label.set_xalign(0.);
        doc.format_label.set_hexpand(true);
        doc.format_label.set_wrap(true);
        doc.format_label.set_text(&document_view::format_text(
            &doc.format.borrow(),
            text,
            self.lang,
        ));
        format_row.append(&doc.format_label);
        let charset = doc.charset.clone();
        format_row.append(&charset);
        doc.reopen.set_sensitive(false);
        doc.reopen.set_tooltip_text(Some(self.lang.text("Öffnet die Datei mit gewählter Kodierung in einem neuen Tab. Ungesicherte Änderungen im alten Tab bleiben erhalten.", "Opens the file with the selected encoding in a new tab. Unsaved changes in the old tab are retained.")));
        format_row.append(&doc.reopen);
        let weak = Rc::downgrade(self);
        let document = Rc::downgrade(&doc);
        doc.reopen.connect_clicked(move |_| {
            let (Some(ui), Some(document)) = (weak.upgrade(), document.upgrade()) else {
                return;
            };
            if document.saving.get() {
                return;
            }
            let path = document.disk_path();
            if let Some(path) = path {
                use fastra_core::encoding::Encoding::*;
                let encoding = [
                    None,
                    Some(Utf8),
                    Some(Utf16Le),
                    Some(Utf16Be),
                    Some(Utf32Le),
                    Some(Utf32Be),
                    Some(Windows1252),
                    Some(Latin1),
                    Some(MacRoman),
                ][charset.selected() as usize];
                ui.load_path_as(path, encoding);
            }
        });
        line_endings::install(self, &doc, &format_row);
        pane.append(&format_row);
        let options = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .min_children_per_line(3)
            .max_children_per_line(6)
            .column_spacing(8)
            .row_spacing(4)
            .build();
        editor_options::install(self, &doc, [&first, &second], &options);
        let split_toggle =
            gtk::CheckButton::with_label(self.lang.text("Geteilte Ansicht", "Split view"));
        let split_doc=Rc::downgrade(&doc);
        split_toggle.connect_toggled(move |b| {right.set_visible(b.is_active());if let Some(doc)=split_doc.upgrade(){source_panes::split(&doc,b.is_active());}});
        let fold_views = [first.downgrade(), second.downgrade()];
        markdown::positions::install(self, &doc, &first);
        markdown::positions::install(self, &doc, &second);
        let wrap = gtk::CheckButton::with_label(self.lang.text("Zeilenumbruch", "Wrap lines"));
        let navigation_view = first.clone();
        editor_options::install_wrap(&doc, &wrap);
        let rectangle_mode =
            gtk::CheckButton::with_label(self.lang.text("Rechteckmodus", "Rectangle mode"));
        rectangle_mode.set_sensitive(!doc.is_read_only());
        rectangle_mode.set_tooltip_text(Some(self.lang.text(
            "Aktivieren und im Editor ziehen. Mehrcursor bleiben beim Tippen und Einfügen erhalten. Esc oder ein normaler Klick beendet die Auswahl.",
            "Enable and drag in the editor. Cursors persist while typing and pasting. Escape or a normal click clears the selection.",
        )));
        let rectangles = doc.rectangles.borrow().clone();
        rectangle_mode.connect_toggled(move |button| {
            for rect in &rectangles {
                rect.set_enabled(button.is_active());
            }
        });
        let column_paste = gtk::Button::with_label(self.lang.text("Spaltenpaste", "Column paste"));
        column_paste.set_sensitive(!doc.is_read_only());
        column_paste.set_tooltip_text(Some(self.lang.text(
            "Fügt ab der Einfügemarke oder dem Rechteck ein und füllt kurze Zeilen gemäß dem Einrückungsprofil auf.",
            "Insert at the caret or rectangle, padding short lines according to the indentation profile.",
        )));
        let rectangles = doc.rectangles.borrow().clone();
        column_paste.connect_clicked(move |button| {
            // Den Menü-Grab vor der Clipboard-Anfrage lösen; sonst gilt die
            // eigene Fokus-Rückgabe als Abbruch der ausstehenden Paste.
            if let Some(popover) = button.ancestor(gtk::Popover::static_type()).and_downcast::<gtk::Popover>() {
                popover.popdown();
            }
            if let Some(rect) = rectangle::target(&rectangles) { rect.paste(); }
        });
        let fold = gtk::Button::with_label(self.lang.text("Auswahl falten", "Fold selection"));
        let document = Rc::downgrade(&doc);
        let weak = Rc::downgrade(self);
        fold.connect_clicked(move |button| {
            if let (Some(doc), Some(ui)) = (document.upgrade(), weak.upgrade()) {
                if !ui.source_read_allowed(&doc) {
                    return;
                }
                let previous_fold = doc.folded.borrow_mut().take();
                if let Some(tag) = previous_fold {
                    if let Some(panes)=doc.source_panes.borrow().as_ref(){for buffer in &panes.buffers {let (a,b)=buffer.bounds();buffer.remove_tag(&tag,&a,&b);}}
                    doc.buffer.tag_table().remove(&tag);
                    for view in fold_views.iter().filter_map(|view| view.upgrade()) {
                        view.set_show_line_numbers(editor_options::line_numbers(&doc));
                    }
                    button.set_label(ui.lang.text("Auswahl falten", "Fold selection"));
                    folding::refresh(&doc);
                    return;
                }
                folding::expand_all(&doc);
                let selected=source_panes::buffer(&doc);
                let Some((mut a, mut b)) = selected.selection_bounds() else {
                    ui.status.set_text(ui.lang.text(
                        "Zum Falten zuerst ganze Zeilen auswählen.",
                        "Select lines before folding.",
                    ));
                    return;
                };
                a.set_line_offset(0);
                if b.line_offset() != 0 {
                    b.forward_line();
                }
                if a.line() == b.line() {
                    return;
                }
                let tag = doc
                    .buffer
                    .create_tag(None, &[("invisible", &true)])
                    .unwrap();
                if let Some(panes)=doc.source_panes.borrow().as_ref(){for buffer in &panes.buffers {buffer.apply_tag(&tag,&buffer.iter_at_offset(a.offset()),&buffer.iter_at_offset(b.offset()));}}
                // GtkSource zeichnet sonst Nummern unsichtbarer Zeilen an derselben Gutterposition.
                for view in fold_views.iter().filter_map(|view| view.upgrade()) {
                    view.set_show_line_numbers(false);
                }
                *doc.folded.borrow_mut() = Some(tag);
                folding::refresh(&doc);
                button.set_label(ui.lang.text("Alles entfalten", "Unfold all"));
            }
        });
        options.insert(&fold, -1);
        folding::install(self, &doc, [&first, &second], &options);
        options.insert(&rectangle_mode, -1);
        options.insert(&column_paste, -1);
        options.insert(&split_toggle, -1);
        options.insert(&wrap, -1);
        markdown_navigation::install(self, &doc, &navigation_view, &fold, &options);
        let markdown_holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
        markdown_holder.set_visible(false);
        let content = gtk::Paned::new(gtk::Orientation::Horizontal);
        content.set_start_child(Some(&split));
        content.set_end_child(Some(&markdown_holder));
        content.set_position(560);
        content.set_resize_start_child(true);
        content.set_resize_end_child(true);
        content.set_shrink_start_child(true);
        content.set_shrink_end_child(true);
        content.set_vexpand(true);
        let markdown_toggle =
            gtk::CheckButton::with_label(self.lang.text("Markdown-Vorschau", "Markdown preview"));
        let document = Rc::downgrade(&doc);
        let weak = Rc::downgrade(self);
        let markdown_split = content.clone();
        let navigation_target = navigation_view.downgrade();
        let unfold_target = fold.downgrade();
        markdown_toggle.connect_toggled(move |toggle| {
            if let (Some(doc), Some(ui)) = (document.upgrade(), weak.upgrade()) {
                if toggle.is_active() && (!editor_options::markdown_preview::eligible(&doc) || doc.is_rich_active()) {
                    toggle.set_active(false);
                    return;
                }
                editor_options::markdown_preview::record_toggle(&ui, &doc);
                if toggle.is_active() && doc.markdown.borrow().is_none() {
                    let preview = markdown::MarkdownView::new();
                    markdown::positions::bind(&preview, &ui, &doc, &navigation_target, &unfold_target);
                    markdown_holder.append(&preview.widget);
                    *doc.markdown.borrow_mut() = Some(preview);
                }
                markdown_holder.set_visible(toggle.is_active());
                if toggle.is_active() {
                    let split = markdown_split.downgrade();
                    glib::idle_add_local_once(move || {
                        if let Some(split) = split.upgrade() {
                            split.set_position((split.width() / 2).max(200));
                        }
                    });
                    ui.search_section.set_expanded(false);
                }
                if let Some(preview) = doc.markdown.borrow().as_ref() {
                    preview.visible.set(toggle.is_active());
                    preview.schedule(&doc, ui.lang);
                }
            }
        });
        *doc.markdown_toggle.borrow_mut() = Some(markdown_toggle.clone());
        options.insert(&markdown_toggle, -1);
        let refresh = gtk::Button::builder()
            .icon_name("view-refresh-symbolic")
            .tooltip_text(self.lang.text(
                "Markdown-Vorschau aktualisieren",
                "Refresh Markdown preview",
            ))
            .build();
        let document = Rc::downgrade(&doc);
        let weak = Rc::downgrade(self);
        refresh.connect_clicked(move |_| {
            if let (Some(doc), Some(ui)) = (document.upgrade(), weak.upgrade()) {
                if let Some(preview) = doc.markdown.borrow().as_ref() {
                    preview.schedule(&doc, ui.lang);
                }
            }
        });
        options.insert(&refresh, -1);
        pane.append(&options);
        let editing_modes = rich_editor::install(self, &doc, &content, &options);
        markdown_inline::install(self, &doc, &pane, [&first, &second]);
        pane.append(&editing_modes);
        let ui = Rc::downgrade(self);
        let document = Rc::downgrade(&doc);
        buffer.connect_changed(move |_| {
            let Some(document) = document.upgrade() else {
                return;
            };
            document.revision.set(document.revision.get() + 1);
            document.update_label();
            if let Some(ui) = ui.upgrade() {
                editor_options::startup::interrupt(&ui);
                search_live::changed(&ui);
                if let Some(preview) = document.markdown.borrow().as_ref() {
                    preview.schedule(&document, ui.lang);
                }
            }
        });
        for observed in [&buffer, &secondary] {
            let owner = Rc::downgrade(self);
            observed.connect_mark_set(move |_,_,mark| {
                if matches!(mark.name().as_deref(), Some("insert"|"selection_bound")) {
                    if let Some(ui) = owner.upgrade() { search_selection::refresh(&ui); }
                }
            });
        }
        let document = Rc::downgrade(&doc);
        buffer.connect_modified_changed(move |_| {
            if let Some(document) = document.upgrade() {
                if document.line_endings.pending().is_some() && !document.buffer.is_modified() {
                    document.buffer.set_modified(true);
                }
                document.update_label();
            }
        });
        chrome::document(self, &doc, chrome::DocumentControls { pane: &pane, format: &format_row, options: &options, editor: &editing_modes, split: &split_toggle, wrap: &wrap });
        let header = tab_close::header(self, &doc);
        let index = self.tabs.append_page(&pane, Some(&header));
        editor_options::markdown_preview::register(self, &doc);
        self.documents.borrow_mut().push(doc);
        self.tabs.set_current_page(Some(index));
        tab_close::remember_active(self);
        chrome::refresh(self);
    }
    fn add_loaded_text(
        self: &Rc<Self>,
        name: &str,
        decoded: std::sync::Arc<fastra_core::encoding::Decoded>,
        snapshot: fastra_io::Snapshot,
    ) -> Rc<Document> {
        let pristine = self
            .active()
            .filter(|doc| chrome::is_pristine(doc) && !doc.source_edits_locked());
        self.add_document(name, decoded.text());
        let document = self.active().unwrap();
        if let Some(pristine) = pristine {
            let index = self.documents.borrow().iter().position(|doc| Rc::ptr_eq(doc, &pristine));
            if let Some(index) = index { self.documents.borrow_mut().remove(index); self.tabs.remove_page(Some(index as u32)); }
        }
        document.format_label.set_text(&document_view::format_text(
            &decoded,
            decoded.text(),
            self.lang,
        ));
        *document.format.borrow_mut() = decoded;
        *document.snapshot.borrow_mut() = Some(snapshot);
        editor_options::restore(self, &document);
        *document.watch.borrow_mut() = Some(watch::attach(self, &document));
        document.reopen.set_sensitive(true);
        document.update_label();
        if let Some(path) = document.disk_path() { diff_view::remember_opened(self,path); }
        document
    }
    fn add_section(
        self: &Rc<Self>,
        name: &str,
        source: fastra_document::SectionDocument,
        hex: bool,
        reopen_path: std::path::PathBuf,
        encoding: Option<fastra_core::encoding::Encoding>,
    ) -> Rc<Document> {
        let recent_path = reopen_path.clone();
        self.add_document(name, "");
        let document = self.active().unwrap();
        while let Some(child) = document.container.first_child() {
            document.container.remove(&child);
        }
        let weak = Rc::downgrade(self);
        let reopen: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(ui) = weak.upgrade() {
                ui.load_path_as(reopen_path.clone(), encoding);
            }
        });
        let view = document_view::DocumentView::new(source, hex, self.lang, reopen);
        document.container.append(&view.root);
        hex_editor::install(self, &document, &view);
        *document.section_view.borrow_mut() = Some(view);
        document.update_label();
        if let Some(toggle) = document.markdown_toggle.borrow().as_ref() {
            toggle.set_sensitive(false);
        }
        diff_view::remember_opened(self,recent_path);
        self.search_section.set_expanded(false);
        self.invalidate();
        document
    }
    fn search(self: &Rc<Self>) {
        search_history::remember(self);
        self.invalidate();
        match self.scope.selected() {
            1 => {
                tabs_search::open(self);
                return;
            }
            2 => {
                folder::open(self);
                return;
            }
            3 => {
                project_view::search(self);
                return;
            }
            _ => {}
        }
        let Some(doc) = self.active() else { return };
        if !self.source_read_allowed(&doc) {
            return;
        }
        let Some(target)=source_panes::capture(&doc) else { return };
        // GTK liefert Zeichenpositionen; UTF-16 wird auf dem Such-Worker berechnet.
        let selection = if self.scope.selected() == 4 {
            let Some(selection) = search_selection::range(self, &doc) else {
                self.status.set_text(self.lang.text("Bitte eine nichtleere zusammenhängende Textauswahl markieren. Eine Rechteckauswahl zuerst mit Esc beenden. Es wird nicht im ganzen Dokument gesucht.", "Select a nonempty continuous text range. End rectangle selection with Escape first. The whole document will not be searched."));
                return;
            };
            Some(selection)
        } else {
            None
        };
        let text = buffer_text(&doc.buffer);
        let generation = self.generation.get();
        let revision = doc.revision.get();
        let mut request = SearchRequest {
            pattern: self.find.text().into(),
            replacement: self.replace.text().into(),
            mode: match self.mode.selected() {
                1 => SearchMode::Wildcard,
                2 => SearchMode::Regex,
                _ => SearchMode::Literal,
            },
            case_sensitive: self.case.is_active(),
            range: None,
        };
        let flags = fastra_core::SearchFlags {
            whole_word: self.whole_word.is_active(),
        };
        let cancel = Cancellation::default();
        *self.cancellation.borrow_mut() = cancel.clone();
        self.status
            .set_text(self.lang.text("Suche läuft …", "Searching …"));
        self.status.set_visible(false);
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            #[cfg(debug_assertions)] source_panes::delay_reply();
            let result = selection
                .map(|selection| utf16_selection(&text, selection, &cancel))
                .transpose()
                .and_then(|range| {
                    request.range = range;
                    fastra_core::PreparedSearch::new(
                        &request,
                        flags,
                        Limits {
                            max_matches: 2000,
                            max_text_bytes: 4 * 1024 * 1024,
                            ..Limits::default()
                        },
                        &cancel,
                    )
                    .and_then(|search| search.preview(&text, revision, generation))
                });
            let _ = tx.send(result);
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(ui) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if ui.generation.get() != generation || !target.valid_document_for_reading(&doc) {
                return glib::ControlFlow::Break;
            }
            match rx.try_recv() {
                Ok(Ok(preview)) => {
                    if !search_selection::valid(&ui, &doc, selection)
                    {
                        ui.invalidate();
                        return glib::ControlFlow::Break;
                    }
                    ui.show_preview_target(preview, selection, Some(target.clone()));
                    glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    ui.status.set_text(&error_text(ui.lang, &error));
                    glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => {
                    ui.status.set_text(ui.lang.text(
                        "Suche wurde unerwartet beendet.",
                        "Search ended unexpectedly.",
                    ));
                    glib::ControlFlow::Break
                }
            }
        });
    }
    fn show_preview_target(self: &Rc<Self>, preview: Preview, selection: Option<(i32,i32)>, target:Option<source_panes::Target>) {
        self.status.set_text(&format!(
            "{} {}",
            preview.matches().len(),
            self.lang.text(
                "Treffer · Freigaben prüfen; Übernehmen ändert nur den Editor.",
                "matches · Review approvals; Apply changes the editor only."
            )
        ));
        let preview = std::sync::Arc::new(preview);
        self.status.set_visible(false);
        *self.pending.borrow_mut() = Some(Pending {
            preview: preview.clone(),
            selection,
            target,
        });
        self.approval.set_items(vec![approval::Item {
            label: self
                .active()
                .map_or_else(String::new, |doc| doc.name.clone()),
            preview,
        }]);
    }
    fn apply(&self) {
        let Some(doc) = self.active() else { return };
        if !self.source_edit_allowed(&doc) {
            return;
        }
        if self.pending.borrow().as_ref().and_then(|p|p.target.as_ref()).is_none_or(|target|!target.valid_document(&doc)) {self.invalidate();return;}
        let expected_selection = self
            .pending
            .borrow()
            .as_ref()
            .and_then(|pending| pending.selection);
        if self.scope.selected() == 4
            && (expected_selection.is_none() || !search_selection::valid(self, &doc, expected_selection))
        {
            self.invalidate();
            self.status.set_text(self.lang.text(
                "Die Textauswahl wurde geändert. Vorschau neu berechnen; nichts übernommen.",
                "The text selection changed. Calculate a new preview; nothing was adopted.",
            ));
            return;
        }
        let result = {
            let pending = self.pending.borrow();
            let Some(pending) = pending.as_ref() else {
                return;
            };
            let Some(approvals) = self.approval.approvals() else {
                return;
            };
            let Some(approved) = approvals.first().filter(|row| !row.is_empty()) else {
                return;
            };
            pending.preview.apply(
                &buffer_text(&doc.buffer),
                doc.revision.get(),
                self.generation.get(),
                approved,
                &Cancellation::default(),
            )
        };
        match result {
            Ok(text) => {
                if let Err(error) = text_limits::validate(&text, self.lang) {
                    self.invalidate();
                    self.status.set_text(&error);
                    return;
                }

                let target_buffer=source_panes::buffer(&doc);
                source_panes::replace_result(&target_buffer,&text);
                self.status.set_text(self.lang.text("Im Editor übernommen. Einmal Rückgängig stellt den Ausgangstext wieder her. Datei bleibt unverändert.", "Applied to editor. One Undo restores the original text. File remains unchanged."));
            }
            Err(error) => {
                self.invalidate();
                self.status.set_text(&error_text(self.lang, &error));
            }
        }
    }
    fn open(self: &Rc<Self>) {
        let chooser = gtk::FileDialog::builder()
            .title(self.lang.text("Datei öffnen", "Open file"))
            .build();
        let weak = Rc::downgrade(self);
        chooser.open(
            Some(&self.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(ui) = weak.upgrade() else { return };
                let Ok(file) = result else { return };
                let Some(path) = file.path() else { return };
                ui.load_path(path);
            },
        );
    }
    fn load_path(self: &Rc<Self>, path: std::path::PathBuf) {
        self.load_path_owned(path, Rc::new(|| true));
    }
    fn load_path_owned(self: &Rc<Self>, path: std::path::PathBuf, owner: Rc<dyn Fn() -> bool>) {
        self.load_path_as_owned(path, None, owner);
    }
    fn load_path_as(
        self: &Rc<Self>,
        path: std::path::PathBuf,
        encoding: Option<fastra_core::encoding::Encoding>,
    ) {
        self.load_path_as_owned(path, encoding, Rc::new(|| true));
    }
    fn load_path_as_owned(
        self: &Rc<Self>,
        path: std::path::PathBuf,
        encoding: Option<fastra_core::encoding::Encoding>,
        owner: Rc<dyn Fn() -> bool>,
    ) {
        self.load_path_validated(path, encoding, owner, None);
    }
    fn load_path_validated(
        self: &Rc<Self>,
        path: std::path::PathBuf,
        encoding: Option<fastra_core::encoding::Encoding>,
        owner: Rc<dyn Fn() -> bool>,
        validate: Option<LoadValidator>,
    ) {
        editor_options::startup::interrupt(self);
        import_view::route_open(self, path, encoding, owner, validate);
    }
    fn display_loaded_path(
        self: &Rc<Self>,
        path: std::path::PathBuf,
        loaded: viewer::Loaded,
        encoding: Option<fastra_core::encoding::Encoding>,
    ) -> Option<Rc<Document>> {
        let ui = self.clone();
        let name = path
            .file_name()
            .map(|n| project_view::display(std::path::Path::new(n)))
            .unwrap_or_default();
        let result = match loaded {
            viewer::Loaded::Editor(loaded) => match loaded {
                loader::Loaded::Text { decoded, snapshot } => {
                    Some(ui.add_loaded_text(&name, decoded, snapshot))
                }
                loader::Loaded::ReadOnlyText(source) => {
                    Some(readonly_source::add(&ui, &name, source))
                }
                loader::Loaded::Sections(source) | loader::Loaded::Hex(source) => {
                    let hex = source.encoding().is_none();
                    ui.add_section(&name, source, hex, path.clone(), encoding);
                    None
                }
            },
            viewer::Loaded::Visual(source) => {
                ui.add_document(&name, "");
                let document = ui.active().unwrap();
                while let Some(child) = document.container.first_child() {
                    document.container.remove(&child);
                }
                let weak = Rc::downgrade(&ui);
                let reopen_path = path.clone();
                let reopen: Rc<dyn Fn()> = Rc::new(move || {
                    if let Some(ui) = weak.upgrade() {
                        ui.load_path(reopen_path.clone());
                    }
                });
                let weak_ui = Rc::downgrade(&ui);
                let weak_doc = Rc::downgrade(&document);
                let owner: Rc<dyn Fn() -> bool> = Rc::new(move || {
                    let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade())
                    else {
                        return false;
                    };
                    ui.window.is_visible()
                        && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                });
                let view = viewer::Viewer::new(source, ui.lang, owner, reopen);
                document.container.append(&view.root);
                *document.visual_view.borrow_mut() = Some(view);
                document.update_label();
                if let Some(toggle) = document.markdown_toggle.borrow().as_ref() {
                    toggle.set_sensitive(false);
                }
                ui.search_section.set_expanded(false);
                ui.invalidate();
                None
            }
        };

        ui.refresh_save();
        result
    }
    fn load_path_raw_completed(
        self: &Rc<Self>,
        path: std::path::PathBuf,
        encoding: Option<fastra_core::encoding::Encoding>,
        owner: Rc<dyn Fn() -> bool>,
        validate: Option<LoadValidator>,
        mut completed: Option<LoadCompletion>,
    ) {
        let (tx, rx) = mpsc::channel();
        let cancellation = viewer::Cancellation::default();
        let worker_cancel = cancellation.clone();
        std::thread::spawn(move || {
            let loaded = viewer::load(&path, encoding, &worker_cancel);
            let loaded = loaded.and_then(|loaded| {
                if validate.is_some_and(|check| !check(&loaded)) {
                    Err(viewer::Error::Stale)
                } else {
                    Ok(loaded)
                }
            });
            let _ = tx.send(loaded.map(|loaded| (path, loaded)));
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(ui) = weak.upgrade() else {
                cancellation.cancel();
                return glib::ControlFlow::Break;
            };
            if !ui.window.is_visible() || !owner() {
                cancellation.cancel();
                return glib::ControlFlow::Break;
            }
            match rx.try_recv() {
                Ok(Ok((path, loaded))) => {
                    // Werkzeugergebnisse dürfen nach einem Tab-/Revisionswechsel keinen neuen Tab erzeugen.
                    if !owner() {
                        return glib::ControlFlow::Break;
                    }
                    if let (Some(done), Some(doc)) = (completed.take(), ui.display_loaded_path(path, loaded, encoding)) {
                        done(doc);
                    }
                    glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    if !owner() {
                        return glib::ControlFlow::Break;
                    }
                    ui.status.set_text(&format!(
                        "{}: {}",
                        ui.lang.text("Datei nicht geöffnet", "File not opened"),
                        error.message(ui.lang.0)
                    ));
                    glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => glib::ControlFlow::Break,
            }
        });
    }
    fn refresh_save(&self) {
        save_as::refresh(self);
        tab_comparison::refresh_saved(self);
        if let Some(doc) = self.active() {
            line_endings::refresh(self, &doc);
            let hex = doc.hex_editor.borrow().clone();
            if let Some(hex) = hex {
                self.save.set_sensitive(hex.can_request_save());
                self.save.set_label(
                    self.lang
                        .text("Hexänderungen prüfen …", "Review hex changes …"),
                );
                return;
            }
            self.save
                .set_sensitive(!doc.saving.get() && !doc.is_read_only());
            self.save.set_label(if doc.snapshot.borrow().is_some() {
                self.lang.text("Speichern", "Save")
            } else {
                self.lang.text("Speichern unter …", "Save as …")
            });
        } else {
            self.save.set_sensitive(false);
        }
    }
    fn save_document(self: &Rc<Self>) {
        let Some(doc) = self.active() else { return };
        if doc.saving.get() {
            self.status.set_text(self.lang.text("Speichern läuft bereits. Bitte den Abschluss abwarten.", "Saving is already in progress. Wait for completion."));
            return;
        }
        if !git_pull::write_allowed(self) { return; }
        let hex = doc.hex_editor.borrow().clone();
        if let Some(hex) = hex {
            hex.command_save();
            return;
        }
        let editor = doc.rich.borrow().clone();
        if let Some(editor) = editor {
            let weak = Rc::downgrade(self);
            let normalize = doc.line_endings.pending().is_some();
            editor.synchronize(
                normalize,
                Box::new(move |ok| {
                    if ok {
                        if let Some(ui) = weak.upgrade() {
                            ui.save_document_ready(doc);
                        }
                    }
                }),
            );
            return;
        }
        self.save_document_ready(doc);
    }
    fn save_document_ready(self: &Rc<Self>, doc: Rc<Document>) {
        self.save_document_ready_done(doc, Box::new(|_| {}));
    }
    fn save_document_ready_done(self: &Rc<Self>, doc: Rc<Document>, done: close_protocol::SaveCompletion) {
        self.save_document_ready_owned(doc,None,done);
    }
    fn save_document_ready_owned(self: &Rc<Self>, doc: Rc<Document>, ticket:Option<Rc<close_protocol::Ticket>>, done: close_protocol::SaveCompletion) {
        if doc.saving.get() { done(close_protocol::SaveOutcome::Failed); return; }
        if !git_pull::write_allowed(self) {
            if ticket.is_none() {
                if let Some(fence) = rich_editor::remember_save_fence(&doc) { fence.cancel(); }
            }
            done(close_protocol::SaveOutcome::Failed);
            return;
        }
        if doc.is_read_only() {
            self.status.set_text(self.lang.text(
                "Abschnitts- und Hex-Ansichten bleiben schreibgeschützt.",
                "Section and hex views remain read-only.",
            ));
            done(close_protocol::SaveOutcome::Failed);
            return;
        }
        if doc.saving.get() {
            done(close_protocol::SaveOutcome::Failed);
            return;
        }
        let snapshot = doc.snapshot.borrow().clone();
        if let Some(snapshot) = snapshot {
            self.save_to_done_owned(doc, SaveTarget::Existing(snapshot), ticket, done);
            return;
        }
        git_fetch::invalidate_owner(self);
        git_push::invalidate_owner(self);
        git_branches::invalidate_owner(self);
        git_switch::invalidate_owner(self);
        git_pull::invalidate_owner(self);
        git_commit::invalidate_owner(self);
        doc.saving.set(true);
        self.refresh_save();
        let chooser = gtk::FileDialog::builder()
            .title(
                self.lang
                    .text("Neues Dokument speichern", "Save new document"),
            )
            .initial_name(self.lang.text("Unbenannt.txt", "Untitled.txt"))
            .build();
        let weak = Rc::downgrade(self);
        let cancellable=ticket.as_ref().map(|ticket|ticket.begin_dialog());
        let completed=cancellable.clone();
        let chooser_fence = rich_editor::remember_save_fence(&doc);
        chooser.save(
            Some(&self.window),
            cancellable.as_ref(),
            move |result| {
                if let (Some(ticket),Some(dialog))=(&ticket,&completed){ticket.end_dialog(dialog);}
                doc.saving.set(false);
                let Some(ui) = weak.upgrade() else {
                    if let Some(fence) = &chooser_fence { fence.cancel(); }
                    done(close_protocol::SaveOutcome::Stale); return;
                };
                ui.refresh_save();
                match result {
                    Ok(file) => match file.path() {
                        Some(path) => ui.save_to_done_owned(doc, SaveTarget::New(path), ticket, done),
                        None => {
                            if let Some(fence) = &chooser_fence { fence.cancel(); }
                            done(close_protocol::SaveOutcome::Failed);
                        }
                    },
                    Err(error) if error.matches(gtk::DialogError::Dismissed) || error.matches(gtk::DialogError::Cancelled) => {
                        if let Some(fence) = &chooser_fence { fence.cancel(); }
                        done(close_protocol::SaveOutcome::Cancelled);
                    }
                    Err(_) => {
                        if let Some(fence) = &chooser_fence { fence.cancel(); }
                        done(close_protocol::SaveOutcome::Failed);
                    }
                }
            },
        );
    }
    #[cfg(debug_assertions)]
    fn save_to(self: &Rc<Self>, doc: Rc<Document>, target: SaveTarget) {
        self.save_to_done(doc,target,Box::new(|_|{}));
    }
    #[cfg(debug_assertions)]
    fn save_to_done(self: &Rc<Self>, doc: Rc<Document>, target: SaveTarget, done: close_protocol::SaveCompletion) {
        self.save_to_done_owned(doc, target, None, done);
    }
    fn save_to_done_owned(self: &Rc<Self>, doc: Rc<Document>, target: SaveTarget,
        ticket: Option<Rc<close_protocol::Ticket>>, done: close_protocol::SaveCompletion) {
        if doc.saving.get() { done(close_protocol::SaveOutcome::Failed); return; }
        if !git_pull::write_allowed(self) {
            if ticket.is_none() {
                if let Some(fence) = rich_editor::remember_save_fence(&doc) { fence.cancel(); }
            }
            done(close_protocol::SaveOutcome::Failed);
            return;
        }
        if doc.is_read_only() || doc.saving.replace(true) {
            done(close_protocol::SaveOutcome::Failed);
            return;
        }
        let held_save_fence = rich_editor::remember_save_fence(&doc);
        let save_revision = doc.revision.get();
        let mut done = Some(done);
        let text = buffer_text(&doc.buffer);
        let source_text = text.clone();
        let pending_ending = doc.line_endings.pending();
        let chosen_ending = doc.line_endings.current();
        let format = doc.format.borrow().clone();
        self.refresh_save();
        self.status.set_text(
            self.lang
                .text("Datei wird sicher gespeichert …", "Saving file safely …"),
        );
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let cancel = Cancellation::default();
            let result: Result<_, loader::SaveError> = (|| {
                let saved_text = line_endings::converted(&text, pending_ending)?;
                let bytes = format.encode(&saved_text)?;
                let snapshot = match target {
                    SaveTarget::Existing(snapshot) => {
                        let unchanged = snapshot.clone();
                        if let Some(transaction) =
                            fastra_io::Transaction::save_document(snapshot, &bytes, &cancel)?
                        {
                            let (saved, ()) =
                                loader::finish_saved_document(transaction, &cancel, |snapshot| {
                                    if snapshot.bytes() != bytes {
                                        return Err(fastra_io::Error::Stale);
                                    }
                                    Ok(())
                                })?;
                            saved
                        } else {
                            unchanged
                        }
                    }
                    SaveTarget::New(path) => {
                        let parent = path
                            .parent()
                            .ok_or(fastra_io::Error::InvalidPath)?
                            .canonicalize()?;
                        let path =
                            parent.join(path.file_name().ok_or(fastra_io::Error::InvalidPath)?);
                        fastra_io::Transaction::save_new_document(&path, &bytes, &cancel)?
                    }
                };
                if snapshot.bytes() != bytes {
                    return Err(fastra_io::Error::Stale.into());
                }
                Ok((snapshot, saved_text))
            })();
            #[cfg(debug_assertions)]
            close_protocol::test_pause("SAVE");
            let _ = tx.send(result);
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(ui) = weak.upgrade() else {
                if let Some(done) = done.take() { done(close_protocol::SaveOutcome::Stale); }
                return glib::ControlFlow::Break;
            };
            match rx.try_recv() {
                Ok(Ok((snapshot, saved_text))) => {
                    let rich = if source_text != saved_text
                        && doc.revision.get() == save_revision
                        && buffer_text(&doc.buffer) == source_text {
                        rich_editor::save_as::detach(&ui, &doc)
                    } else { None };
                    let adopted = line_endings::complete(
                        &doc, &source_text, &saved_text, save_revision,
                        chosen_ending, pending_ending,
                    );
                    // Während des Speicherns darf weiter getippt werden; nur der gespeicherte Stand wird zur Basis.
                    *doc.snapshot.borrow_mut() = Some(snapshot);
                    rich_editor::after_save(&doc);
                    editor_options::saved(&doc);
                    *doc.original.borrow_mut() = saved_text.clone();
                    doc.update_saved_baseline_status(&buffer_text(&doc.buffer));
                    doc.saving.set(false);
                    if doc.watch.borrow().is_none() {
                        *doc.watch.borrow_mut() = Some(watch::attach(&ui, &doc));
                    }
                    doc.update_label();
                    doc.reopen.set_sensitive(true);
                    doc.format_label.set_text(&document_view::format_text(
                        &doc.format.borrow(),
                        &saved_text,
                        ui.lang,
                    ));
                    ui.refresh_save();
                    session::changed(&ui);
                    if let Some(preview) = doc.markdown.borrow().as_ref() {
                        preview.schedule(&doc, ui.lang);
                    }
                    ui.status.set_text(ui.lang.text(
                        "Datei sicher gespeichert. Spätere Editoränderungen bleiben ungesichert.",
                        "File saved safely. Later editor edits remain unsaved.",
                    ));
                    let rebuilt = rich.is_some();
                    rich_editor::save_as::restore_mode(&doc, ui.lang, rich);
                    if let Some(done) = done.take() {
                        let fence = held_save_fence.clone();
                        let ticket_owned = ticket.is_some();
                        let completed = Box::new(move |outcome| {
                            done(outcome);
                            if !ticket_owned {
                                if let Some(fence) = fence { fence.cancel(); }
                            }
                        });
                        line_endings::finish_save(&ui, &doc, save_revision, adopted, rebuilt, ticket.clone(), completed);
                    }
                    glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    if let Some(fence) = &held_save_fence { fence.cancel(); }
                    doc.saving.set(false);
                    ui.refresh_save();
                    let mut message = error.message(ui.lang);
                    if let loader::SaveError::Io(fastra_io::Error::RecoveryRequired(path)) = &error
                    {
                        if let Err(index_error) = session::remember_journal(&ui, path.clone()) {
                            message.push_str(&format!(
                                "\n{} {index_error}",
                                ui.lang.text(
                                    "Der Dateitransaktionsindex konnte nicht gesichert werden.",
                                    "The file transaction index could not be saved."
                                )
                            ));
                        }
                    }
                    ui.status.set_text(&message);
                    if let Some(done) = done.take() { done(close_protocol::SaveOutcome::Failed); }
                    glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => {
                    if let Some(fence) = &held_save_fence { fence.cancel(); }
                    doc.saving.set(false);
                    ui.refresh_save();
                    ui.status.set_text(ui.lang.text(
                        "Speichern wurde unerwartet beendet.",
                        "Saving ended unexpectedly.",
                    ));
                    if let Some(done) = done.take() { done(close_protocol::SaveOutcome::Failed); }
                    glib::ControlFlow::Break
                }
            }
        });
    }
    fn confirm_close(self: &Rc<Self>) -> glib::Propagation {
        close_protocol::window_close(self)
    }

}
fn error_text(lang: Language, error: &fastra_core::Error) -> String {
    let message = match error {
        fastra_core::Error::Regex { .. } => lang.text(
            "Ungültiger regulärer Ausdruck",
            "Invalid regular expression",
        ),
        fastra_core::Error::Limit => lang.text(
            "Suchgrenze erreicht. Eingabe oder Treffermenge verkleinern.",
            "Search limit reached. Reduce input or matches.",
        ),
        fastra_core::Error::Cancelled => lang.text("Suche abgebrochen", "Search cancelled"),
        _ => lang.text(
            "Vorschau ungültig. Neu berechnen.",
            "Preview invalid. Calculate again.",
        ),
    };
    format!("{message} ({error})")
}
fn io_error_text(lang: Language, error: &fastra_io::Error) -> String {
    let message=match error {
        fastra_io::Error::Io(error) if error.kind()==std::io::ErrorKind::AlreadyExists=>lang.text("Das Ziel existiert bereits. Bitte einen anderen Dateinamen wählen; nichts überschrieben.","The target already exists. Choose another filename; nothing was overwritten."),
        fastra_io::Error::Limit=>lang.text("Editierbarer Text ist auf 32 MiB begrenzt. Große Dateien bleiben schreibgeschützt.","Editable text is limited to 32 MiB. Large files remain read-only."),
        fastra_io::Error::Stale=>lang.text("Die Datei wurde außerhalb von Fastra geändert. Editorinhalt erhalten; Datei vor erneutem Speichern prüfen.","The file changed outside Fastra. Editor contents were retained; inspect the file before saving again."),
        fastra_io::Error::RecoveryRequired(_)=>lang.text("Der Speicherzustand muss geprüft werden. Sicherung erhalten; nicht erneut überschreiben.","The save state needs inspection. Recovery data was retained; do not overwrite again."),
        fastra_io::Error::UnsupportedFilesystem=>lang.text("Dieses Dateisystem unterstützt den sicheren Austausch noch nicht.","This filesystem does not support the required safe exchange yet."),
        fastra_io::Error::UnsupportedMetadata=>lang.text("Die Dateimetadaten können nicht sicher erhalten werden.","The file metadata cannot be preserved safely."),
        _=>lang.text("Datei konnte nicht sicher gespeichert werden.","The file could not be saved safely."),
    };
    format!("{message} ({error})")
}

fn selected_offsets(doc: &Document) -> Option<(i32, i32)> {
    if doc
        .rectangles
        .borrow()
        .iter()
        .any(|rectangle| rectangle.is_selected())
    {
        return None;
    }
    source_panes::buffer(doc)
        .selection_bounds()
        .map(|(start, end)| (start.offset(), end.offset()))
}
fn utf16_selection(
    text: &str,
    (start, end): (i32, i32),
    cancel: &Cancellation,
) -> Result<fastra_core::Utf16Range, fastra_core::Error> {
    let start = usize::try_from(start).map_err(|_| fastra_core::Error::InvalidRange)?;
    let end = usize::try_from(end).map_err(|_| fastra_core::Error::InvalidRange)?;
    if start >= end {
        return Err(fastra_core::Error::InvalidRange);
    }
    let mut units = 0;
    let mut location = None;
    // Der zusätzliche Endpunkt erlaubt eine Auswahl bis exakt ans Textende.
    for (index, ch) in text
        .chars()
        .map(Some)
        .chain(std::iter::once(None))
        .enumerate()
    {
        if index & 4095 == 0 {
            cancel.check()?;
        }
        if index == start {
            location = Some(units);
        }
        if index == end {
            let location = location.ok_or(fastra_core::Error::InvalidRange)?;
            return Ok(fastra_core::Utf16Range {
                location,
                length: units - location,
            });
        }
        if let Some(ch) = ch {
            units += ch.len_utf16();
        }
    }
    Err(fastra_core::Error::InvalidRange)
}

fn buffer_text(buffer: &impl IsA<gtk::TextBuffer>) -> String {
    let (start, end) = buffer.bounds();
    buffer.text(&start, &end, true).into()
}
fn editor(buffer: &sourceview5::Buffer) -> sourceview5::View {
    configure_editor(sourceview5::View::with_buffer(buffer),buffer)
}
fn source_editor(buffer:&sourceview5::Buffer)->sourceview5::View{configure_editor(source_panes::source_view(buffer),buffer)}
fn configure_editor(view:sourceview5::View,buffer:&sourceview5::Buffer)->sourceview5::View{
    view.add_css_class("fastra-document");
    view.set_monospace(true);
    source_appearance::install(&view, buffer);
    view.set_show_line_numbers(true);
    view.set_auto_indent(true);
    view.set_highlight_current_line(true);
    view.set_left_margin(48);
    view.set_top_margin(1);
    view.set_pixels_above_lines(1);
    view.set_pixels_below_lines(2);
    view.set_tab_width(4);
    view.set_wrap_mode(gtk::WrapMode::WordChar);
    view.set_vexpand(true);
    view
}
fn scroll(widget: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .child(widget)
        .vexpand(true)
        .hexpand(true)
        .min_content_height(100)
        .build()
}
fn build(app: &gtk::Application) -> Rc<Ui> {
    let lang = Language(
        std::env::var("LANGUAGE")
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .starts_with("de"),
    );
    let default_height = gtk::gdk::Display::default()
        .and_then(|display| display.monitors().item(0))
        .and_downcast::<gtk::gdk::Monitor>()
        .map_or(850, |monitor| {
            (monitor.geometry().height() - 64).clamp(700, 950)
        });
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("Fastra")
        .default_width(1180)
        .default_height(default_height)
        .build();
    window.set_size_request(760, 700);
    let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
    root.set_margin_top(12);
    root.set_margin_bottom(12);
    root.set_margin_start(16);
    root.set_margin_end(16);
    let toolbar = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(3)
        .max_children_per_line(6)
        .column_spacing(8)
        .row_spacing(4)
        .build();
    toolbar.set_vexpand(false);
    let open = gtk::Button::with_label(lang.text("Öffnen …", "Open …"));
    let new = gtk::Button::with_label(lang.text("Neu", "New"));
    let undo = gtk::Button::with_label(lang.text("Rückgängig", "Undo"));
    let redo = gtk::Button::with_label(lang.text("Wiederholen", "Redo"));
    let save = gtk::Button::with_label(lang.text("Speichern", "Save"));
    save.set_sensitive(false);
    save.set_tooltip_text(Some(lang.text(
        "Dokument sicher speichern. Neue Dateien überschreiben niemals bestehende Ziele.",
        "Safely save this document. New files never overwrite existing targets.",
    )));
    for button in [&open, &new, &undo, &redo, &save] {
        toolbar.insert(button, -1)
    }
    let tools = gtk::MenuButton::builder()
        .label(lang.text("Werkzeuge", "Tools"))
        .build();
    let tools_popover = gtk::Popover::new();
    let tools_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    tools_box.set_margin_top(8);
    tools_box.set_margin_bottom(8);
    tools_box.set_margin_start(8);
    tools_box.set_margin_end(8);
    let git_tool = gtk::Button::with_label(lang.text("Git …", "Git …"));
    git_tool.set_visible(false);
    let diff_tool = gtk::Button::with_label(lang.text("Dateien vergleichen …", "Compare files …"));
    diff_tool.set_tooltip_text(Some(lang.text("Dateien vergleichen (Ctrl+Alt+Shift+D)", "Compare files (Ctrl+Alt+Shift+D)")));
    let saved_diff_tool = gtk::Button::with_label(lang.text("Mit gespeicherter Fassung vergleichen", "Compare Against Saved Version"));
    saved_diff_tool.set_tooltip_text(Some(lang.text("Vergleicht den ungespeicherten Editor-Inhalt mit dem gespeicherten Stand der Datei.", "Compares the unsaved editor content with the saved state of the file.")));
    saved_diff_tool.set_sensitive(false);
    let folder_compare_tool =
        gtk::Button::with_label(lang.text("Ordner vergleichen …", "Compare folders …"));
    let import_tool =
        gtk::Button::with_label(lang.text("Dokument importieren …", "Import document …"));
    let project_tool = gtk::Button::with_label(lang.text("Projektdateien …", "Project files …"));
    let recovery_tool = gtk::Button::with_label(lang.text("Dateisicherungen …", "File recovery …"));
    let workflows_tool =
        gtk::Button::with_label(lang.text("Gespeicherte Textabläufe …", "Saved text workflows …"));
    let snippets_tool = gtk::Button::with_label(lang.text("Textbausteine …", "Text snippets …"));
    let four_d_runtime_tool =
        gtk::Button::with_label(lang.text("4D-Diagnosen (tool4d) …", "4D diagnostics (tool4d) …"));
    let four_d_tool = gtk::Button::with_label(
        lang.text("4D-Methoden und Parameter …", "4D methods and parameters …"),
    );
    let completion_index_tool = gtk::Button::with_label(lang.text(
        "4D-Projekt-/Komponentenindex aktualisieren",
        "Refresh 4D project/component index",
    ));
    let completion_tool =
        gtk::Button::with_label(lang.text("4D-Vervollständigung …", "4D completion …"));
    let four_d_macros_tool = gtk::Button::with_label(lang.text("4D-Makros …", "4D macros …"));
    let references_tool=gtk::Button::with_label(lang.text("Lokale Markdown-Verweise prüfen …","Check local Markdown references …"));
    references_tool.set_widget_name("fastra-reference-check");
    let goto_tool =
        gtk::Button::with_label(lang.text("Zu Zeile/Spalte springen …", "Go to line/column …"));
    goto_tool.set_tooltip_text(Some("Ctrl+L"));
    let disk_hex_tool = gtk::Button::with_label(lang.text(
        "Dateibytes in neuem Hex-Tab …",
        "Disk bytes in new hex tab …",
    ));
    let explanation_tool = gtk::Button::with_label(lang.text(
        "Gespeicherte Codefrage öffnen …",
        "Open saved code question …",
    ));
    let example_tool = gtk::Button::with_label(lang.text(
        "Transformation per Beispiel …",
        "Transformation by example …",
    ));
    let xpath_tool = gtk::Button::with_label(lang.text("XPath-Navigation …", "XPath navigation …"));
    for button in [
        &explanation_tool,
        &example_tool,
        &completion_tool,
        &completion_index_tool,
        &four_d_macros_tool,
        &four_d_runtime_tool,
        &goto_tool,
        &references_tool,
        &disk_hex_tool,
        &four_d_tool,
        &xpath_tool,
        &project_tool,
        &git_tool,
        &diff_tool,
        &saved_diff_tool,
        &folder_compare_tool,
        &import_tool,
        &recovery_tool,
        &workflows_tool,
        &snippets_tool,
    ] {
        tools_box.append(button);
    }
    let tools_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(600)
        .propagate_natural_height(true)
        .child(&tools_box)
        .build();
    tools_popover.set_child(Some(&tools_scroll));
    let weak_scroll = tools_scroll.downgrade();
    let weak_window = window.downgrade();
    tools_popover.connect_show(move |_| {
        if let Some(window) = weak_window.upgrade() {
            let monitor = window.surface().and_then(|surface| {
                gtk::prelude::WidgetExt::display(&window).monitor_at_surface(&surface)
            });
            if let (Some(monitor), Some(scroll)) = (monitor, weak_scroll.upgrade()) {
                scroll.set_max_content_height((monitor.geometry().height() - 160).clamp(240, 760));
            }
        }
    });

    tools.set_popover(Some(&tools_popover));
    toolbar.insert(&tools, -1);
    let notice_text = lang.text(
        "Text bis 32 MiB · Große Dateien abschnittsweise; optionaler Hexentwurf bis 32 MiB.",
        "Text up to 32 MiB · Large files use sections; optional hex drafts up to 32 MiB.",
    );
    let notice = gtk::Label::new(Some(&format!(
        "Fastra {} · {notice_text}",
        env!("CARGO_PKG_VERSION")
    )));
    notice.set_wrap(true);
    notice.set_xalign(0.);
    let tabs = gtk::Notebook::new();
    tabs.set_scrollable(true);
    tabs.set_vexpand(true);
    let form = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(8)
        .build();
    let find = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text("Text oder Muster", "Text or pattern"))
        .build();
    let replace = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text("Ersetzung", "Replacement"))
        .build();
    find.update_property(&[gtk::accessible::Property::Label(lang.text("Suchen", "Find"))]);
    replace.update_property(&[gtk::accessible::Property::Label(lang.text("Ersetzen", "Replace"))]);
    form.attach(
        &gtk::Label::new(Some(lang.text("Suchen", "Find"))),
        0,
        0,
        1,
        1,
    );
    form.attach(&find, 1, 0, 1, 1);
    form.attach(
        &gtk::Label::new(Some(lang.text("Ersetzen", "Replace"))),
        0,
        1,
        1,
        1,
    );
    form.attach(&replace, 1, 1, 1, 1);
    let mode = gtk::DropDown::from_strings(&[
        lang.text("Wörtlicher Text", "Literal text"),
        lang.text("Platzhalter", "Wildcards"),
        "Regex",
    ]);
    mode.set_selected(1);
    mode.update_property(&[gtk::accessible::Property::Description(lang.text("Suchmodus", "Search mode"))]);
    form.attach(&mode, 2, 0, 1, 1);
    let case = gtk::CheckButton::with_label(lang.text("Groß-/Kleinschreibung", "Case sensitive"));
    let whole_word =
        gtk::CheckButton::with_label(lang.text("Nur ganze Wörter", "Whole words only"));
    let flags = gtk::Box::new(gtk::Orientation::Vertical, 2);
    flags.append(&case);
    flags.append(&whole_word);
    form.attach(&flags, 2, 1, 1, 1);
    let search = gtk::Button::with_label(lang.text("Vorschau berechnen", "Calculate preview"));
    form.attach(&search, 3, 0, 1, 1);
    let apply = gtk::Button::with_label(lang.text("Freigegebene übernehmen", "Apply approved"));
    apply.set_sensitive(false);
    form.attach(&apply, 3, 1, 1, 1);
    let captures = search_pattern::empty();
    let capture_scroll = gtk::ScrolledWindow::builder()
        .child(&captures)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(40)
        .build();
    let approval = approval::ApprovalPane::single_file(lang);
    approval.root.set_height_request(220);
    let status = gtk::Label::new(None);
    status.set_wrap(true);
    status.set_xalign(0.);
    let search_content = gtk::Box::new(gtk::Orientation::Vertical, 12);
    let scope = gtk::DropDown::from_strings(&[
        lang.text("Aktive Datei", "Active file"),
        lang.text("Alle editierbaren Tabs", "All editable tabs"),
        lang.text("Ordner", "Folder"),
        lang.text("Projekt", "Project"),
        lang.text("Aktuelle Auswahl", "Current selection"),
    ]);
    let scope_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    scope.update_property(&[gtk::accessible::Property::Description(lang.text("Suchbereich", "Search scope"))]);
    scope_row.append(&gtk::Label::new(Some(lang.text("Bereich", "Scope"))));
    scope_row.append(&scope);
    let patterns_button =
        gtk::Button::with_label(lang.text("Suchvorlagen …", "Search templates …"));
    scope_row.append(&patterns_button);
    search_content.append(&scope_row);
    for widget in [
        form.upcast_ref::<gtk::Widget>(),
        capture_scroll.upcast_ref(),
        approval.root.upcast_ref(),
    ] {
        search_content.append(widget)
    }
    let search_section = gtk::Expander::builder()
        .label(lang.text("Suchen und Ersetzen", "Search and replace"))
        .expanded(true)
        .child(
            &gtk::ScrolledWindow::builder()
                .hscrollbar_policy(gtk::PolicyType::Never)
                .min_content_height(180)
                .child(&search_content)
                .build(),
        )
        .build();
    search_section.set_vexpand(true);
    let document_search = gtk::Paned::new(gtk::Orientation::Vertical);
    // Die unsichtbare Hitzone des dünnen Griffs würde den kompakten Suchkopf abfangen.
    document_search.set_wide_handle(true);
    document_search.set_start_child(Some(&tabs));
    document_search.set_end_child(Some(&search_section));
    document_search.set_resize_start_child(true);
    document_search.set_resize_end_child(true);
    document_search.set_shrink_start_child(false);
    document_search.set_shrink_end_child(false);
    document_search.set_position(300);
    document_search.set_vexpand(true);
    let expanded_position = Rc::new(Cell::new(300));
    let weak_pane = document_search.downgrade();
    search_section.connect_expanded_notify(move |section| {
        let Some(pane) = weak_pane.upgrade() else {
            return;
        };
        if section.is_expanded() {
            section.set_vexpand(true);
            pane.set_resize_end_child(true);
            pane.set_position(expanded_position.get());
        } else {
            expanded_position.set(pane.position().max(100));
            section.set_vexpand(false);
            pane.set_resize_end_child(false);
            pane.set_position(pane.max_position());
        }
    });

    // GTK bestimmt die Grenze erst bei der Allokation und ändert sie beim Dokumentwechsel.
    let weak_section = search_section.downgrade();
    document_search.connect_max_position_notify(move |pane| {
        if weak_section
            .upgrade()
            .is_some_and(|section| !section.is_expanded())
            && pane.position() != pane.max_position()
        {
            pane.set_position(pane.max_position());
        }
    });

    for widget in [
        toolbar.upcast_ref::<gtk::Widget>(),
        notice.upcast_ref(),
        document_search.upcast_ref(),
        status.upcast_ref(),
    ] {
        root.append(widget)
    }
    window.set_child(Some(&root));
    let ui = Rc::new(Ui {
        chrome: RefCell::new(None),
        search_history: RefCell::new(None),
        search_pattern: RefCell::new(None),
        outline_history: RefCell::new(None),
        template_choice: RefCell::new(None),
        template_menus: RefCell::new(Vec::new()),
        lang,
        window,
        documents: RefCell::new(Vec::new()),
        saved_diff_tool: saved_diff_tool.clone(),
        tab_mru: RefCell::new(Vec::new()),
        comparison_pair: RefCell::new(None),
        tabs,
        find,
        replace,
        mode,
        scope,
        case,
        whole_word,
        search_section,
        approval,
        captures,
        capture_scroll,
        status,
        apply,
        save,
        generation: Cell::new(0),
        pending: RefCell::new(None),
        search_emphasis: RefCell::new(None),
        search_selection: RefCell::new(None),
        selection_control: glib::WeakRef::new(),
        folder_configuration: RefCell::new(None),
        project_configuration: RefCell::new(None),
        cancellation: RefCell::new(Cancellation::default()),
        discard_confirmed: Cell::new(false),
        window_close_dialog: Cell::new(false),
        session: RefCell::new(None),
        close_ticket: RefCell::new(None),
        close_committed: Cell::new(false),
        startup_restore_epoch: Cell::new(0),
        project: RefCell::new(None),
    });
    search_navigation::file(&ui);
    single_replace::install(&ui);
    search_pattern::install(&ui);
    desktop_open::install(&ui);
    let history = search_history::Menu::new(&ui);
    scope_row.append(&history.button);
    *ui.search_history.borrow_mut() = Some(history);
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_HISTORY_SELFTEST").is_some() {
        search_history::selftest(ui.clone());
    }
    let weak = Rc::downgrade(&ui);
    ui.approval.on_changed(Rc::new(move |valid| {
        if let Some(ui) = weak.upgrade() {
            let selected = ui
                .approval
                .approvals()
                .is_some_and(|rows| rows.iter().any(|row| !row.is_empty()));
            ui.apply
                .set_sensitive(valid && selected && ui.pending.borrow().is_some() && ui.active().is_some_and(|doc| !doc.source_edits_locked()));
        }
    }));
    let weak = Rc::downgrade(&ui);
    patterns_button.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            pattern_view::show(&ui);
        }
    });
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_PATTERN_SELFTEST").is_some() {
        pattern_view::run_selftest(ui.clone());
    }
    let weak=Rc::downgrade(&ui);let popover=tools_popover.clone();
    references_tool.connect_clicked(move |_| {popover.popdown();if let Some(ui)=weak.upgrade(){markdown::references::show(&ui);}});
    let weak=Rc::downgrade(&ui);let button=references_tool.downgrade();
    glib::timeout_add_local(Duration::from_millis(200),move||{let (Some(ui),Some(button))=(weak.upgrade(),button.upgrade())else{return glib::ControlFlow::Break;};button.set_sensitive(ui.active().is_some_and(|doc|markdown::references::view::supported(&doc)));glib::ControlFlow::Continue});
    toolbar.insert(&operations::menu(&ui), -1);
    toolbar.insert(&print_view::menu(&ui), -1);
    let folder_button =
        gtk::Button::with_label(lang.text("Ordner durchsuchen …", "Search folder …"));
    let weak = Rc::downgrade(&ui);
    folder_button.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            folder::open(&ui);
        }
    });
    toolbar.insert(&folder_button, -1);
    let help = gtk::Button::with_label(ui.lang.text("Hilfe", "Help"));
    let weak = Rc::downgrade(&ui);
    help.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            operations::help(&ui);
        }
    });
    toolbar.insert(&help, -1);
    toolbar.insert(&updates::button(&ui), -1);
    application_lifecycle::quit_button(&ui, &toolbar);
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    completion_index_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            four_d_completion_view::refresh_index(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    completion_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            four_d_completion_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    four_d_macros_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            four_d_macros::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    explanation_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            code_explanation::choose(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    example_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            example_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    goto_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            editor_navigation::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    disk_hex_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            hex_routes::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    four_d_runtime_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            four_d_runtime_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    four_d_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            four_d_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    xpath_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            xpath_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    diff_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            let _ = diff_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    saved_diff_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() { let _ = diff_view::open_saved(&ui); }
    });
    let weak = Rc::downgrade(&ui);
    tools_popover.connect_show(move |_| {
        if let Some(ui) = weak.upgrade() { tab_comparison::refresh_saved(&ui); }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    folder_compare_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            folder_compare::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    import_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            let _ = import_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    recovery_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            recovery::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    project_tool.connect_clicked(move |_| {
        popover.popdown();
        if let Some(ui) = weak.upgrade() {
            project_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    let popover = tools_popover.clone();
    let git_button = git_tool.clone();
    git_view::background(
        || Ok(git_view::find_program("git")),
        move |result| {
            if let Ok(Some(program)) = result {
                git_button.set_visible(true);
                git_button.connect_clicked(move |_| {
                    popover.popdown();
                    if let Some(ui) = weak.upgrade() {
                        git_view::open(&ui, program.clone());
                    }
                });
            }
        },
    );
    let weak = Rc::downgrade(&ui);
    open.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.open()
        }
    });
    save_as::install(&ui,&toolbar);
    let weak = Rc::downgrade(&ui);
    ui.save.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.save_document();
        }
    });
    let weak = Rc::downgrade(&ui);
    new.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.new_document()
        }
    });
    let weak = Rc::downgrade(&ui);
    undo.connect_clicked(move |_| {
        if let Some(doc) = weak.upgrade().and_then(|ui| ui.active()) {
            if let Some(editor) = doc.rich.borrow().as_ref() {
                if print_view::is_busy() {
                    return;
                }
                editor.command("undo");
                return;
            }
            if doc.buffer.can_undo() {
                doc.buffer.undo()
            }
        }
    });
    let weak = Rc::downgrade(&ui);
    redo.connect_clicked(move |_| {
        if let Some(doc) = weak.upgrade().and_then(|ui| ui.active()) {
            if let Some(editor) = doc.rich.borrow().as_ref() {
                if print_view::is_busy() {
                    return;
                }
                editor.command("redo");
                return;
            }
            if doc.buffer.can_redo() {
                doc.buffer.redo()
            }
        }
    });
    let weak = Rc::downgrade(&ui);
    search.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.search()
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.apply.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.apply()
        }
    });
    for entry in [&ui.find, &ui.replace] {
        let weak = Rc::downgrade(&ui);
        entry.connect_changed(move |_| {
            if let Some(ui) = weak.upgrade() {
                search_live::changed(&ui)
            }
        });
    }
    let weak = Rc::downgrade(&ui);
    ui.case.connect_toggled(move |_| {
        if let Some(ui) = weak.upgrade() {
            search_live::changed(&ui)
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.whole_word.connect_toggled(move |_| {
        if let Some(ui) = weak.upgrade() {
            search_live::changed(&ui)
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.scope.connect_selected_notify(move |scope| {
        if let Some(ui) = weak.upgrade() {
            if scope.selected() == 4 { if !search_selection::available(&ui) { search_selection::capture(&ui); } } else if scope.selected() == 0 { ui.search_selection.borrow_mut().take(); }
            search_selection::refresh(&ui);
            search_live::changed(&ui);
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.mode.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            search_live::changed(&ui)
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.tabs.connect_switch_page(move |_, page, _| {
        if let Some(ui) = weak.upgrade() {
            editor_options::startup::interrupt(&ui);
            tab_comparison::page_changing(&ui, page);
            search_live::changed(&ui);
            let weak = Rc::downgrade(&ui);
            // current_page wird erst im GTK-Standardhandler auf den neuen Tab gesetzt.
            glib::idle_add_local_once(move || {
                if let Some(ui) = weak.upgrade() {
                    tab_close::remember_active(&ui);
                    ui.refresh_save();
                    search_selection::refresh(&ui);
                }
            });
        }
    });

    ui.add_document(lang.text("Unbenannt", "Untitled"), "");
    ui.invalidate();
    chrome::mount(&ui, &toolbar, &document_search, &form, &search);
    go_to_target::install_window(&ui);
    tab_comparison::install_keys(&ui, &ui.window);
    ui.window.present();
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FOLDING_SELFTEST").is_some() { folding::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_REFERENCES_SELFTEST").is_some() { markdown::references::selftest::run(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FONTS_SELFTEST").is_some() { fonts::selftest::run(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_SELECTION_SELFTEST").is_some(){search_selection::selftest::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FOLDER_READONLY_SELFTEST").is_some() { folder::readonly_test::start(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TEMPLATE_MENU_SELFTEST").is_some() { template_menu::selftest::run(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_SOURCES_SELFTEST").is_some(){search_sources::selftest::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_INLINE_PREVIEW_SELFTEST").is_some(){approval::search::inline_test::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_GROUPS_SELFTEST").is_some(){approval::search::group_test::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SINGLE_REPLACE_SELFTEST").is_some() {single_replace::selftest::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_DETAIL_SELFTEST").is_some() {search_live::detail_test::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_LIVE_SELFTEST").is_some() {
        search_live::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SETTINGS_FORM_SELFTEST").is_some() { editor_options::settings_form::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_CHROME_SELFTEST").is_some() {
        chrome::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_HOME_SELFTEST").is_some() {
        chrome::home::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_COLLECTION_NAVIGATION_SELFTEST").is_some() {
        search_navigation::collection_test::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_NAVIGATION_SELFTEST").is_some() {
        search_navigation::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SEARCH_PARITY_SELFTEST").is_some() {
        approval::search::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_MARKDOWN_INLINE_SELFTEST").is_some() {
        markdown_inline::selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_DISPLAY_SELFTEST").is_some()
        || std::env::var_os("FASTRA_DESKTOP_SMOKE").is_some()
    {
        display_smoke::run(
            ui.clone(),
            std::env::var_os("FASTRA_DESKTOP_SMOKE").is_some(),
        );
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FOLDER_COMPARE_SELFTEST").is_some() {
        folder_compare::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SOURCE_APPEARANCE_SELFTEST").is_some() { source_appearance::selftest::run(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SPLIT_GATE_SELFTEST").is_some() { source_panes::run(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SOURCE_SIZE_PROBE").is_some(){source_size_probe::run(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_LINEAR_PASTE_SELFTEST").is_some() { if std::env::var("FASTRA_LINEAR_PASTE_CASE").unwrap_or_default().starts_with("primary-") { primary_paste_gui_test::run(ui.clone()); } else { linear_paste_gui_test::run(ui.clone()); } }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_EOL_SELFTEST").is_some() {
        line_endings::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_READING_FONT_SELFTEST").is_some() { editor_options::reading_font::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SOURCE_FONT_SELFTEST").is_some() { editor_options::font::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_OPTIONS_SELFTEST").is_some() {
        editor_options::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_PRINT_SELFTEST").is_some() {
        print_view::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_RICH_SELFTEST").is_some() {
        rich_editor::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SAVE_AS_SELFTEST").is_some(){rich_editor::save_as::run_selftest(ui.clone());}
    four_d_macros::install(&ui);
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FILE_MANAGER_SELFTEST").is_some() { file_manager::selftest(ui.clone()); }
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&ui);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if !modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
            return glib::Propagation::Proceed;
        }
        let Some(ui) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if matches!(key,gtk::gdk::Key::m|gtk::gdk::Key::M) && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK|gtk::gdk::ModifierType::SHIFT_MASK|gtk::gdk::ModifierType::ALT_MASK) && !modifiers.intersects(gtk::gdk::ModifierType::SUPER_MASK|gtk::gdk::ModifierType::META_MASK|gtk::gdk::ModifierType::HYPER_MASK) {
            return if editor_options::markdown_mode::toggle_document(&ui){glib::Propagation::Stop}else{glib::Propagation::Proceed};
        }
        if application_lifecycle::quit_shortcut(key, modifiers) {
            application_lifecycle::request_quit();
            return glib::Propagation::Stop;
        }
        if matches!(key,gtk::gdk::Key::s|gtk::gdk::Key::S) && modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK) && !modifiers.intersects(gtk::gdk::ModifierType::ALT_MASK|gtk::gdk::ModifierType::SUPER_MASK) {
            save_as::request(&ui,Box::new(|_|{}));return glib::Propagation::Stop;
        }
        if matches!(key, gtk::gdk::Key::g | gtk::gdk::Key::G) {
            if let Some(editor) = ui.active().and_then(|doc| doc.rich.borrow().clone()) { editor.find_next(modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK)); return glib::Propagation::Stop; }
        }
        if matches!(key, gtk::gdk::Key::o | gtk::gdk::Key::O)
            && modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK)
        {
            chrome::choose_project(&ui);
            return glib::Propagation::Stop;
        }
        match editor_shortcuts::command(key) {
            Some(editor_shortcuts::Command::Open) => ui.open(),
            Some(editor_shortcuts::Command::Goto) => editor_navigation::open(&ui),
            Some(editor_shortcuts::Command::Save) => ui.save_document(),
            Some(editor_shortcuts::Command::Print) => print_view::print_visible(&ui),
            Some(editor_shortcuts::Command::CloseWindow) => ui.window.close(),
            Some(editor_shortcuts::Command::CloseTab) => tab_close::active(&ui),
            Some(editor_shortcuts::Command::NewTab) => {
                ui.new_document()
            }
            Some(editor_shortcuts::Command::Find) => {
                if let Some(editor) = ui.active().and_then(|doc| doc.rich.borrow().clone()) { editor.show_find(); }
                else { chrome::find(&ui); ui.find.grab_focus(); }
            }
            Some(editor_shortcuts::Command::Search) => {
                chrome::show_search(&ui);
                ui.search()
            }
            None => {
                return if four_d_macros::shortcut(&ui, key, modifiers) {
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            }
        }
        glib::Propagation::Stop
    });
    ui.window.add_controller(keys);
    let weak = Rc::downgrade(&ui);
    ui.window.connect_close_request(move |_| {
        weak.upgrade()
            .map_or(glib::Propagation::Proceed, |ui| ui.confirm_close())
    });
    *ui.session.borrow_mut() = Some(session::attach(&ui));
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TAB_CLOSE_SELFTEST").is_some() {
        tab_close::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_COMMIT_SELFTEST").is_some() {git_commit::selftest(ui.clone());}
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_PULL_SELFTEST").is_some() { git_pull::selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_SWITCH_SELFTEST").is_some() { git_switch::selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_BRANCHES_SELFTEST").is_some() {
        git_branches::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_PUSH_SELFTEST").is_some() {
        git_push::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_FETCH_SELFTEST").is_some() {
        git_fetch::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_HISTORY_SELFTEST").is_some() {
        git_history_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_EXPLANATION_SELFTEST").is_some() {
        code_explanation::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_EXAMPLE_SELFTEST").is_some() {
        example_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TARGET_SELFTEST").is_some() {
        go_to_target::selftest::start(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GOTO_SELFTEST").is_some() {
        editor_navigation::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_HEX_ROUTES_SELFTEST").is_some() {
        hex_editor::routes_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_RECENT_PROJECTS_SELFTEST").is_some() {
        project_view::recent_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_HEX_SELFTEST").is_some() {
        hex_editor::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_RUNTIME_SELFTEST").is_some() {
        four_d_runtime_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_COMPLETION_SELFTEST").is_some() {
        four_d_completion_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_MACRO_SHELL_SELFTEST").is_some() {
        four_d_macros::shell_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_MACRO_RUNTIME_SELFTEST").is_some() {
        four_d_macros::runtime_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_MACROS_SELFTEST").is_some() {
        four_d_macros::selftest(ui.clone(), tools.clone(), four_d_macros_tool.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_SELFTEST").is_some() {
        four_d_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_XPATH_SELFTEST").is_some() {
        xpath_view::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_PROJECT_SCOPE_SELFTEST").is_some() {
        project_view::scope_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if let Ok(mode) = std::env::var("FASTRA_SESSION_SELFTEST") {
        session::selftest(ui.clone(), &mode);
    }
    #[cfg(debug_assertions)]
    if let Ok(tool) = std::env::var("FASTRA_TOOL_SELFTEST") {
        if tool == "menu" {
            git_view::menu_test(
                ui.clone(),
                tools.clone(),
                vec![git_tool.clone(), diff_tool.clone(), import_tool.clone()],
            );
        } else {
            git_view::selftest(ui.clone(), &tool);
        }
    }
    #[cfg(debug_assertions)]
    if let Ok(mode) = std::env::var("FASTRA_PROJECT_SELFTEST") {
        if mode == "project" {
            project_view::selftest(ui.clone());
        } else if mode == "watch-metadata" {
            watch::metadata_selftest(ui.clone());
        } else if mode == "watch-lifetime" {
            watch::lifetime_selftest(ui.clone());
        } else {
            watch::selftest(ui.clone());
        }
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_RECTANGLE_SELFTEST").is_some() {
        rectangle_selftest::run(ui.clone());
    }
    for (button, snippet) in [(&workflows_tool, false), (&snippets_tool, true)] {
        let weak = Rc::downgrade(&ui);
        let popover = tools_popover.downgrade();
        button.connect_clicked(move |_| {
            if let Some(popover) = popover.upgrade() {
                popover.popdown();
            }
            if let Some(ui) = weak.upgrade() {
                workflow_view::show(&ui, snippet);
            }
        });
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_EXTENDED_TEXT_SELFTEST").is_some() {
        workflow_view::run_extended_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TITLECASE_SELFTEST").is_some() {
        workflow_view::run_titlecase_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_4D_TRANSFORM_SELFTEST").is_some() {
        workflow_view::run_four_d_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_WORKFLOW_SELFTEST").is_some() {
        workflow_view::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_SELECTION_SELFTEST").is_some() {
        selection_selftest::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_UI_SELFTEST").is_some() {
        selftest::run(ui.clone(), search);
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_PREVIEW_LINKS_SELFTEST").is_some() { markdown::external_links_gui_test::start(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_CODE_COPY_SELFTEST").is_some() { markdown::code_copy::selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_NAVIGATION_SELFTEST").is_some() {
        markdown_navigation::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_RECOVERY_SELFTEST").is_some() {
        recovery::open(&ui);
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TABS_SELFTEST").is_some() {
        ui.active().unwrap().buffer.set_text("cat cat");
        ui.add_document("second", "cat🙂");
        ui.add_document("untouched", "none");
        ui.find.set_text("cat");
        ui.replace.set_text("dog");
        ui.mode.set_selected(0);
        ui.case.set_active(true);
        ui.scope.set_selected(1);
        ui.search();
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FOLDER_SELFTEST").is_some() {
        ui.find.set_text("cat");
        ui.replace.set_text("dog");
        ui.mode.set_selected(0);
        ui.case.set_active(true);
        folder::open(&ui);
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_DESKTOP_OPEN_SELFTEST").is_some() {
        desktop_open::run(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_DOCUMENT_SELFTEST").is_some() {
        document_view::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_APPEARANCE_SELFTEST").is_some() { editor_options::appearance::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_MARKDOWN_PREVIEW_SELFTEST").is_some() { editor_options::markdown_preview::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_MARKDOWN_MODE_SELFTEST").is_some() { editor_options::markdown_mode::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_ZOOM_SELFTEST").is_some() { editor_options::zoom::run_selftest(ui.clone()); }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_LOCAL_CONTROL_SELFTEST").is_some() {
        local_control::selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_VIEWER_SELFTEST").is_some() {
        viewer::run_selftest(ui.clone());
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_READONLY_SOURCE_SELFTEST").is_some() {
        readonly_source::run_selftest(ui.clone());
    }
    ui
}
fn main() {
    if let Some(code) = folding::worker_entry() { std::process::exit(code); }
    if let Err(error) = fastra_io::initialize_runtime_policy() {
        eprintln!("Fastra: {error}");
        std::process::exit(2);
    }
    if std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some()
        && !matches!(fastra_process::host::is_active(), Ok(true))
    {
        eprintln!("Fastra: Die optionale Laufzeit benötigt ihren gültigen Hostkanal. / The optional runtime requires its valid host channel.");
        std::process::exit(2);
    }
    if let Some(code)=fastra_git::commit_hook_entry(){std::process::exit(code);}
    if let Some(code) = four_d_macro_runtime::worker_entry() {
        std::process::exit(code);
    }
    if let Some(code) = four_d_runtime::worker_entry() {
        std::process::exit(code);
    }
    if std::env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "--version")
    {
        println!("Fastra {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let app = gtk::Application::builder()
        .application_id(if std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some() {
            fastra_io::local_control::transport::NATIVE_APPLICATION_ID
        } else {
            fastra_io::local_control::transport::SYSTEM_APPLICATION_ID
        })
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE | gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    app.connect_startup(|app| {
        sourceview5::init();
        fonts::register();
        if std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some()
            && !source_panes::native_preflight_ready()
        {
            eprintln!("Fastra: Die optionale Laufzeit besitzt nicht die benötigte Eingabevorprüfung. / The optional runtime does not provide the required input preflight.");
            std::process::exit(2);
        }
        four_d_language::install();
        local_control::start(app);
        external_diff::start(app);
    });
    app.connect_shutdown(|_| { source_appearance::cleanup_schemes(); fonts::cleanup(); });
    application_lifecycle::install(&app);
    std::process::exit(app.run().get().into());
}
mod application_lifecycle;
mod fonts;
mod close_protocol;
mod asset_io;
mod desktop_open;
mod document_view;
mod line_endings;
mod loader;
mod readonly_source;
mod rectangle;
#[cfg(debug_assertions)]
mod rectangle_selftest;
#[cfg(debug_assertions)]
mod selftest;

mod example_view;
mod operations;
mod chrome;
mod updates;

mod markdown;
mod rich_editor;

mod folder;

mod diff_view;
mod external_diff;
mod git_branches;
mod git_commit;
mod git_fetch;
mod git_pull;
mod git_push;
mod git_switch;
mod git_view;
mod import_view;

mod file_manager;
mod project_view;
mod watch;

mod approval;
mod search_live;
mod search_navigation;
mod search_pattern;
mod search_selection;
mod search_sources;
mod single_replace;

mod tabs_search;

mod viewer;

mod recovery;

mod session;

mod markdown_navigation;
mod go_to_target;

mod workflow_view;

mod text_limits;

mod print_view;

mod pattern_view;
mod template_menu;

mod editor_options;

mod folder_compare;

#[cfg(debug_assertions)]
mod display_smoke;

#[cfg(debug_assertions)]
mod selection_selftest;

mod xpath_view;

mod hex_editor;

mod four_d_index;
mod four_d_language;
mod four_d_view;

mod hex_routes;

mod editor_navigation;

mod four_d_macro_runtime;
mod four_d_runtime;
mod four_d_runtime_view;

mod git_history_view;

mod search_history;

mod tab_close;
mod tab_comparison;
mod tab_close_others;

mod save_as;

mod code_explanation;

mod editor_shortcuts;
mod four_d_completion_view;
mod four_d_components;
mod four_d_macros;

mod local_control;

#[cfg(debug_assertions)]
mod linear_paste_gui_test;

mod linear_paste;

#[cfg(debug_assertions)]
mod primary_paste_gui_test;

mod source_panes;
mod source_appearance;

#[cfg(debug_assertions)] mod source_size_probe;

#[cfg(test)]
mod native_runtime_paths;

mod markdown_inline;

mod folding;
