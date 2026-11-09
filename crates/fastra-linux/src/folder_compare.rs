use super::{git_view as support, project_view::display, Language, Ui};
use fastra_diff::{
    folder::{ContentKind, FolderLimits, FolderResult, Status},
    Cancellation,
};
use gtk::{gio, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::Arc,
};
const PAGE: usize = 100;
pub(super) struct View {
    window: gtk::Window,
    ui: Weak<Ui>,
    lang: Language,
    roots: RefCell<[Option<PathBuf>; 2]>,
    paths: [gtk::Entry; 2],
    changing_path: Cell<bool>,
    calculate: gtk::Button,
    filters: gtk::DropDown,
    query: gtk::SearchEntry,
    list: gtk::ListBox,
    detail: gtk::Label,
    status: gtk::Label,
    pair: gtk::Button,
    open: [gtk::Button; 2],
    previous: gtk::Button,
    next: gtk::Button,
    page_label: gtk::Label,
    model: RefCell<Option<Arc<FolderResult>>>,
    visible: RefCell<Vec<usize>>,
    page: Cell<usize>,
    selected: Cell<Option<usize>>,
    generation: Cell<u64>,
    busy: Cell<bool>,
    cancel: RefCell<Cancellation>,
    pair_cancel: RefCell<fastra_core::Cancellation>,
    filter_cancel: RefCell<Cancellation>,
    filter_generation: Cell<u64>,
    #[cfg(debug_assertions)]
    last_pair: RefCell<Option<Weak<super::diff_view::State>>>,
}
fn status_text(status: Status, lang: Language) -> &'static str {
    match status {
        Status::OnlyLeft => lang.text("Nur links", "Only left"),
        Status::OnlyRight => lang.text("Nur rechts", "Only right"),
        Status::Identical => lang.text("Bytegleich", "Byte-identical"),
        Status::Different => lang.text("Unterschiedlich", "Different"),
        Status::Unavailable => lang.text("Nicht geprüft", "Unavailable"),
    }
}
impl View {
    fn cancel(&self) {
        self.cancel.borrow().cancel();
        self.pair_cancel.borrow().cancel();
        self.filter_cancel.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
    }
    fn invalidate(&self) {
        self.cancel();
        self.model.borrow_mut().take();
        self.visible.borrow_mut().clear();
        self.selected.set(None);
        self.render();
        self.busy.set(false);
        self.calculate.set_sensitive(true);
        self.status.set_text(self.lang.text(
            "Eingaben geändert. Neu vergleichen.",
            "Inputs changed. Compare again.",
        ));
    }
    fn set_root(&self, index: usize, path: PathBuf) {
        self.roots.borrow_mut()[index] = Some(path.clone());
        self.changing_path.set(true);
        self.paths[index].set_text(&display(&path));
        self.changing_path.set(false);
        self.invalidate();
    }
    fn calculate(self: &Rc<Self>) {
        self.invalidate();
        let [Some(left), Some(right)] = self.roots.borrow().clone() else {
            self.status.set_text(
                self.lang
                    .text("Zuerst zwei Ordner auswählen.", "Choose two folders first."),
            );
            return;
        };
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        self.busy.set(true);
        self.calculate.set_sensitive(false);
        self.status.set_text(self.lang.text(
            "Ordner lesen, Bytes vergleichen und Dateistände prüfen …",
            "Reading folders, comparing bytes and validating file states …",
        ));
        support::background(
            move || {
                fastra_diff::folder::compare_folders(
                    &left,
                    &right,
                    FolderLimits::default(),
                    &cancel,
                )
                .map_err(|e| e.to_string())
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.window.is_visible() && s.generation.get() == generation)
                else {
                    return;
                };
                state.busy.set(false);
                state.calculate.set_sensitive(true);
                match result {
                    Ok(result) => {
                        let title = if result.complete() {
                            state
                                .lang
                                .text("Vergleich vollständig", "Comparison complete")
                        } else {
                            state.lang.text(
                                "Unvollständig: nicht alle Einträge konnten geprüft werden",
                                "Incomplete: some entries could not be verified",
                            )
                        };
                        state.status.set_text(&format!(
                            "{title} · {} {} · {} {}",
                            result.rows.len(),
                            state.lang.text("Einträge", "entries"),
                            result.bytes_read,
                            state.lang.text("Bytes gelesen", "bytes read")
                        ));
                        *state.model.borrow_mut() = Some(Arc::new(result));
                        state.filter();
                    }
                    Err(error) => state.status.set_text(&format!(
                        "{}: {error}",
                        state.lang.text(
                            "Ordnervergleich nicht möglich; kein vollständiges Ergebnis",
                            "Folder comparison unavailable; no complete result"
                        )
                    )),
                }
            },
        );
    }
    fn filter(self: &Rc<Self>) {
        self.filter_cancel.borrow().cancel();
        self.filter_generation
            .set(self.filter_generation.get().wrapping_add(1));
        let filter_generation = self.filter_generation.get();
        self.selected.set(None);
        self.update_selection();
        let query = self.query.text().to_lowercase();
        if query.len() > 4096 {
            self.status.set_text(self.lang.text(
                "Ergebnisfilter ist auf 4096 Bytes begrenzt.",
                "The result filter is limited to 4096 bytes.",
            ));
            return;
        }
        let statuses = [
            None,
            Some(Status::Different),
            Some(Status::OnlyLeft),
            Some(Status::OnlyRight),
            Some(Status::Identical),
            Some(Status::Unavailable),
        ];
        let status = statuses
            .get(self.filters.selected() as usize)
            .copied()
            .flatten();
        let Some(model) = self.model.borrow().clone() else {
            self.visible.borrow_mut().clear();
            self.render();
            return;
        };
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        let cancel = Cancellation::default();
        *self.filter_cancel.borrow_mut() = cancel.clone();
        support::background(
            move || {
                let mut visible = Vec::new();
                for (index, row) in model.rows.iter().enumerate() {
                    cancel.check().map_err(|e| e.to_string())?;
                    if status.is_none_or(|s| s == row.status)
                        && (query.is_empty()
                            || display(&row.relative_path).to_lowercase().contains(&query))
                    {
                        visible.push(index);
                    }
                }
                Ok(visible)
            },
            move |result| {
                let Some(state) = weak.upgrade().filter(|s| {
                    s.window.is_visible()
                        && s.generation.get() == generation
                        && s.filter_generation.get() == filter_generation
                }) else {
                    return;
                };
                if let Ok(visible) = result {
                    *state.visible.borrow_mut() = visible;
                    state.page.set(0);
                    state.render();
                }
            },
        );
    }
    fn render(&self) {
        self.selected.set(None);
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let visible = self.visible.borrow();
        let pages = visible.len().div_ceil(PAGE).max(1);
        self.page.set(self.page.get().min(pages - 1));
        if let Some(model) = self.model.borrow().as_ref() {
            for &index in visible.iter().skip(self.page.get() * PAGE).take(PAGE) {
                let row = &model.rows[index];
                let label = support::label(&format!(
                    "{} · {}{}",
                    status_text(row.status, self.lang),
                    display(&row.relative_path),
                    if row.kind == ContentKind::Directory {
                        "/"
                    } else {
                        ""
                    }
                ));
                label.set_selectable(false);
                label.set_margin_top(5);
                label.set_margin_bottom(5);
                self.list.append(&label);
            }
        }
        self.previous.set_sensitive(self.page.get() > 0);
        self.next.set_sensitive(self.page.get() + 1 < pages);
        self.page_label.set_text(&format!(
            "{} / {pages} · {} {}",
            self.page.get() + 1,
            visible.len(),
            self.lang.text("sichtbar", "visible")
        ));
        drop(visible);
        self.update_selection();
    }
    fn update_selection(&self) {
        let selected = self.selected.get();
        let model = self.model.borrow();
        let row = model
            .as_ref()
            .and_then(|m| selected.and_then(|i| m.rows.get(i)));
        let available = row.is_some_and(|r| {
            r.status != Status::Unavailable
                && r.kind != ContentKind::Special
                && r.kind != ContentKind::Directory
                && r.issue.is_none()
        });
        self.pair.set_sensitive(
            !self.busy.get()
                && available
                && row.is_some_and(|r| matches!(r.status, Status::Identical | Status::Different)),
        );
        for (i, button) in self.open.iter().enumerate() {
            button.set_sensitive(
                !self.busy.get()
                    && available
                    && row.is_some_and(|r| {
                        r.status
                            != if i == 0 {
                                Status::OnlyRight
                            } else {
                                Status::OnlyLeft
                            }
                    }),
            );
        }
        let mut detail = row.map_or_else(String::new, |r| {
            format!(
                "{}\n{}",
                display(&r.relative_path),
                r.issue.as_deref().unwrap_or("")
            )
        });
        if let Some(model) = model.as_ref() {
            if !model.issues.is_empty() {
                detail.push_str(&format!(
                    "\n{}:\n{}",
                    self.lang
                        .text("Grenzen des Ergebnisses", "Result limitations"),
                    model.issues.join("\n")
                ));
            }
        }
        self.detail.set_text(&detail);
    }
    fn paths(&self) -> Option<(PathBuf, PathBuf)> {
        let model = self.model.borrow();
        let model = model.as_ref()?;
        let row = model.rows.get(self.selected.get()?)?;
        Some((
            model.left_root.join(&row.relative_path),
            model.right_root.join(&row.relative_path),
        ))
    }
    fn open_one(self: &Rc<Self>, index: usize) {
        let Some((left, right)) = self.paths() else {
            return;
        };
        let Some(ui) = self.ui.upgrade() else { return };
        let path = if index == 0 { left } else { right };
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        ui.load_path_owned(
            path,
            Rc::new(move || {
                weak.upgrade()
                    .is_some_and(|s| s.window.is_visible() && s.generation.get() == generation)
            }),
        );
    }
    fn open_pair(self: &Rc<Self>) {
        if !self.pair.is_sensitive() {
            return;
        }
        let Some((left, right)) = self.paths() else {
            return;
        };
        let Some(model) = self.model.borrow().clone() else {
            return;
        };
        let generation = self.generation.get();
        let selected = self.selected.get();
        let ui_generation = self.ui.upgrade().map(|ui| ui.generation.get());
        let weak = Rc::downgrade(self);
        let lang = self.lang;
        let cancel = fastra_core::Cancellation::default();
        self.pair_cancel.borrow().cancel();
        *self.pair_cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.calculate.set_sensitive(false);
        self.update_selection();
        self.status.set_text(lang.text(
            "Dateipaar frisch lesen. Die Ordnerliste ist nur eine Momentaufnahme.",
            "Reading the file pair afresh. The folder list is only a snapshot.",
        ));
        support::background(
            move || {
                for (path, root) in [(&left, &model.left_root), (&right, &model.right_root)] {
                    let metadata = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
                    if !metadata.is_file()
                        || !std::fs::canonicalize(path)
                            .map_err(|e| e.to_string())?
                            .starts_with(root)
                    {
                        return Err(lang
                            .text(
                                "Dateipaar ist nicht mehr regulär innerhalb der gewählten Ordner.",
                                "File pair is no longer regular and inside the selected folders.",
                            )
                            .into());
                    }
                }
                cancel.check().map_err(|e| e.to_string())?;
                let left_document = fastra_document::ReadOnlyTextDocument::open(&left, None, &cancel)
                    .map_err(|error| super::loader::document_error(lang, &error))?;
                super::text_limits::validate(left_document.text(), lang)?;
                let right_document = fastra_document::ReadOnlyTextDocument::open(&right, None, &cancel)
                    .map_err(|error| super::loader::document_error(lang, &error))?;
                super::text_limits::validate(right_document.text(), lang)?;
                if left_document.text().len() + right_document.text().len() > 4 * 1024 * 1024 {
                    return Err(lang
                        .text(
                            "Der vollständige Textpaarvergleich ist auf 4 MiB Text begrenzt.",
                            "The complete text-pair comparison is limited to 4 MiB of text.",
                        )
                        .into());
                }
                right_document
                    .verify_current(&cancel)
                    .map_err(|e| e.to_string())?;
                left_document.verify_current(&cancel).map_err(|e| e.to_string())?;
                Ok((left, right))
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.window.is_visible() && s.generation.get() == generation)
                else {
                    return;
                };
                state.busy.set(false);
                state.calculate.set_sensitive(true);
                state.update_selection();
                if state.selected.get() != selected
                    || state.ui.upgrade().map(|ui| ui.generation.get()) != ui_generation
                {
                    state.status.set_text(lang.text(
                        "Auswahl oder Zieldokument inzwischen geändert. Dateipaar nicht geöffnet.",
                        "Selection or target document changed. File pair not opened.",
                    ));
                    return;
                }
                match result {
                    Ok((left, right)) => {
                        if let Some(ui) = state.ui.upgrade().filter(|ui| ui.window.is_visible()) {
                            let _comparison = super::diff_view::open_pair(&ui, left, right);
                            #[cfg(debug_assertions)]
                            {
                                *state.last_pair.borrow_mut() = Some(Rc::downgrade(&_comparison));
                            }
                        }
                    }
                    Err(error) => state.status.set_text(&format!(
                        "{}: {error}",
                        lang.text("Dateipaar nicht geöffnet", "File pair not opened")
                    )),
                }
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>) -> Rc<View> {
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text("Ordner vergleichen", "Compare folders"),
        false,
    );
    window.set_default_size(1000, 780);
    let root = support::column();
    root.append(&support::label(lang.text("Schreibgeschützter Bytevergleich. Dateipaare werden frisch gelesen und in einem schreibgeschützten Textvergleich geöffnet. Die Quelldateien bleiben unverändert.","Read-only byte comparison. File pairs are read afresh and opened in a read-only text comparison. Source files remain unchanged.")));
    let paths =
        std::array::from_fn(|_| gtk::Entry::builder().hexpand(true).editable(false).build());
    let choosers = std::array::from_fn::<_, 2, _>(|_| {
        gtk::Button::with_label(lang.text("Ordner wählen …", "Choose folder …"))
    });
    for i in 0..2 {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.append(&gtk::Label::new(Some(if i == 0 {
            lang.text("Links", "Left")
        } else {
            lang.text("Rechts", "Right")
        })));
        row.append(&paths[i]);
        row.append(&choosers[i]);
        root.append(&row);
    }
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(2)
        .max_children_per_line(5)
        .column_spacing(8)
        .row_spacing(6)
        .build();
    let calculate = gtk::Button::with_label(lang.text("Vergleichen", "Compare"));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let pair = gtk::Button::with_label(lang.text("Textpaar vergleichen …", "Compare text pair …"));
    let open = [
        gtk::Button::with_label(lang.text("Links öffnen", "Open left")),
        gtk::Button::with_label(lang.text("Rechts öffnen", "Open right")),
    ];
    for b in [&calculate, &cancel, &pair, &open[0], &open[1]] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let status = support::label(lang.text(
        "Zwei Ordner wählen. Versteckte Einträge bleiben ausgeschlossen; Symlinks und Sonderdateien werden angezeigt, aber nicht verfolgt.",
        "Choose two folders. Hidden entries are excluded; symlinks and special files are shown but never followed.",
    ));
    root.append(&status);
    let filter_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let query = gtk::SearchEntry::builder()
        .placeholder_text(lang.text("Ergebnisse filtern", "Filter results"))
        .hexpand(true)
        .build();
    let filters = gtk::DropDown::from_strings(&[
        lang.text("Alle", "All"),
        status_text(Status::Different, lang),
        status_text(Status::OnlyLeft, lang),
        status_text(Status::OnlyRight, lang),
        status_text(Status::Identical, lang),
        status_text(Status::Unavailable, lang),
    ]);
    filter_row.append(&query);
    filter_row.append(&filters);
    root.append(&filter_row);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    root.append(&support::scroll(&list));
    let previous = gtk::Button::with_label(lang.text("Vorherige Seite", "Previous page"));
    let next = gtk::Button::with_label(lang.text("Nächste Seite", "Next page"));
    let page_label = gtk::Label::new(None);
    let pages = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    pages.append(&previous);
    pages.append(&page_label);
    pages.append(&next);
    root.append(&pages);
    let detail = support::label("");
    detail.set_selectable(true);
    let detail_scroll = gtk::ScrolledWindow::builder()
        .child(&detail)
        .min_content_height(55)
        .max_content_height(110)
        .build();
    root.append(&detail_scroll);
    root.append(&support::label(lang.text("Grenzen: 20.000 Einträge, 256 MiB je Datei, 2 GiB gelesen. Ergebnisfilter ändern nur die sichtbare Liste; Bytebudget und Vollständigkeit beziehen sich auf alle gelesenen Einträge.","Limits: 20,000 entries, 256 MiB per file, 2 GiB read. Result filters only change the visible list; the byte budget and completeness refer to all scanned entries.")));
    window.set_child(Some(&root));
    let state = Rc::new(View {
        window: window.clone(),
        ui: Rc::downgrade(ui),
        lang,
        roots: RefCell::new([None, None]),
        paths,
        changing_path: Cell::new(false),
        calculate,
        filters,
        query,
        list,
        detail,
        status,
        pair,
        open,
        previous,
        next,
        page_label,
        model: RefCell::new(None),
        visible: RefCell::new(Vec::new()),
        page: Cell::new(0),
        selected: Cell::new(None),
        generation: Cell::new(0),
        busy: Cell::new(false),
        cancel: RefCell::new(Cancellation::default()),
        pair_cancel: RefCell::new(fastra_core::Cancellation::default()),
        filter_cancel: RefCell::new(Cancellation::default()),
        filter_generation: Cell::new(0),
        #[cfg(debug_assertions)]
        last_pair: RefCell::new(None),
    });
    for (i, chooser) in choosers.into_iter().enumerate() {
        let weak = Rc::downgrade(&state);
        chooser.connect_clicked(move |_| {
            let Some(state) = weak.upgrade() else { return };
            let weak = Rc::downgrade(&state);
            gtk::FileDialog::new().select_folder(
                Some(&state.window),
                None::<&gio::Cancellable>,
                move |result| {
                    if let (Some(state), Ok(file)) = (weak.upgrade(), result) {
                        if state.window.is_visible() {
                            if let Some(path) = file.path() {
                                state.set_root(i, path);
                            }
                        }
                    }
                },
            );
        });
        let weak = Rc::downgrade(&state);
        state.paths[i].connect_changed(move |entry| {
            if let Some(state) = weak.upgrade() {
                if !state.changing_path.get() {
                    state.roots.borrow_mut()[i] = Some(PathBuf::from(entry.text().as_str()));
                    state.invalidate();
                }
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.calculate.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.calculate();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.invalidate();
            state.status.set_text(state.lang.text(
                "Abgebrochen. Kein aktuelles Ergebnis.",
                "Cancelled. No current result.",
            ));
        }
    });
    let weak = Rc::downgrade(&state);
    state.filters.connect_selected_notify(move |_| {
        if let Some(state) = weak.upgrade() {
            state.filter();
        }
    });
    let weak = Rc::downgrade(&state);
    state.query.connect_search_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            state.filter();
        }
    });
    for (i, button) in state.open.iter().enumerate() {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.open_one(i);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.pair.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.open_pair();
        }
    });
    for (next, button) in [(false, &state.previous), (true, &state.next)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.page.set(if next {
                    state.page.get() + 1
                } else {
                    state.page.get().saturating_sub(1)
                });
                state.render();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.list.connect_row_selected(move |_, row| {
        if let Some(state) = weak.upgrade() {
            state.selected.set(row.and_then(|r| {
                state
                    .visible
                    .borrow()
                    .get(state.page.get() * PAGE + r.index() as usize)
                    .copied()
            }));
            state.update_selection();
        }
    });
    state.render();
    support::hold(&window, state.clone(), |state| state.cancel());
    window.present();
    state
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn run_selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
