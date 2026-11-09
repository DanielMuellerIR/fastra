//! Alle offenen editierbaren Dokumente bilden eine gemeinsam geprüfte Editoraktion.
use super::*;
use fastra_core::batch::{BatchLimits, BatchPlan, BatchPreview, DocumentSnapshot, Restoration};
use std::{rc::Weak, sync::Arc};
struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    pane: Rc<approval::ApprovalPane>,
    status: gtk::Label,
    search: gtk::Button,
    apply: gtk::Button,
    undo: gtk::Button,
    forget: gtk::Button,
    cancel_button: gtk::Button,
    busy: Cell<bool>,
    changing: Cell<bool>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    pending: RefCell<Option<Arc<BatchPreview>>>,
    restoration: RefCell<Option<Arc<Restoration>>>,
    watched: RefCell<Vec<(Weak<Document>, glib::SignalHandlerId)>>,
    parent_handler: RefCell<Option<glib::SignalHandlerId>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        if let (Some(ui), Some(handler)) = (self.ui.upgrade(), self.parent_handler.get_mut().take())
        {
            ui.window.disconnect(handler);
        }
        for (doc, handler) in self.watched.get_mut().drain(..) {
            if let Some(doc) = doc.upgrade() {
                doc.buffer.disconnect(handler);
            }
        }
    }
}
fn collect(ui: &Ui) -> Result<(Vec<Rc<Document>>, Vec<DocumentSnapshot>), fastra_core::Error> {
    if !ui.window.is_visible() {
        return Err(fastra_core::Error::Stale);
    }
    let documents: Vec<_> = ui
        .documents
        .borrow()
        .iter()
        .filter(|doc| !doc.source_edits_locked())
        .cloned()
        .collect();
    if documents.len() > 128 {
        return Err(fastra_core::Error::Limit);
    }
    let mut bytes = 0usize;
    let mut snapshots = Vec::with_capacity(documents.len());
    for doc in &documents {
        if doc.buffer.char_count() > 8 * 1024 * 1024 {
            return Err(fastra_core::Error::Limit);
        }
        let text = buffer_text(&doc.buffer);
        bytes = bytes
            .checked_add(text.len())
            .ok_or(fastra_core::Error::Limit)?;
        if bytes > 128 * 1024 * 1024 {
            return Err(fastra_core::Error::Limit);
        }
        snapshots.push(DocumentSnapshot {
            id: format!("document-{:x}", Rc::as_ptr(doc) as usize),
            revision: doc.revision.get(),
            text,
        });
    }
    Ok((documents, snapshots))
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn busy(&self, value: bool) {
        self.busy.set(value);
        self.search
            .set_sensitive(!value && self.restoration.borrow().is_none());
        self.cancel_button.set_sensitive(value);
        self.apply.set_sensitive(false);
        self.pane.freeze(
            value || self.pending.borrow().is_none() || self.restoration.borrow().is_some(),
        );
        self.undo
            .set_sensitive(!value && self.restoration.borrow().is_some());
        self.forget
            .set_sensitive(!value && self.restoration.borrow().is_some());
    }
    fn invalidate(&self) {
        if self.changing.get() {
            return;
        }
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.pending.borrow_mut().take();
        self.pane.clear();
        self.apply.set_sensitive(false);
        self.status.set_text(self.lang().text("Dokumente geändert. Vorschau neu erstellen; gemeinsames Rückgängig prüft alle Dokumente erneut.","Documents changed. Recalculate the preview; joint Undo checks every document again."));
        self.status.set_visible(false);
    }
    fn inputs_changed(self: &Rc<Self>) {
        if self.changing.get() {
            return;
        }
        self.invalidate();
        if !self.window.is_visible() || self.restoration.borrow().is_some() {
            return;
        }
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(120), move || {
            let Some(state) = weak.upgrade().filter(|state| {
                state.generation.get() == generation
                    && state.window.is_visible()
                    && state.restoration.borrow().is_none()
            }) else {
                return glib::ControlFlow::Break;
            };
            if state.busy.get() {
                return glib::ControlFlow::Continue;
            }
            if state
                .ui
                .upgrade()
                .is_some_and(|ui| !ui.find.text().is_empty())
            {
                state.search();
            }
            glib::ControlFlow::Break
        });
    }
    fn watch(self: &Rc<Self>, docs: &[Rc<Document>]) {
        for doc in docs {
            if self
                .watched
                .borrow()
                .iter()
                .any(|(weak, _)| weak.upgrade().is_some_and(|old| Rc::ptr_eq(&old, doc)))
            {
                continue;
            }
            let weak = Rc::downgrade(self);
            let handler = doc.buffer.connect_changed(move |_| {
                if let Some(state) = weak.upgrade() {
                    state.inputs_changed();
                }
            });
            self.watched
                .borrow_mut()
                .push((Rc::downgrade(doc), handler));
        }
    }
    fn search(self: &Rc<Self>) {
        if self.busy.get() || self.restoration.borrow().is_some() {
            return;
        }
        self.invalidate();
        let Some(ui) = self.ui.upgrade() else { return };
        super::search_history::remember(&ui);
        let (docs, snapshots) = match collect(&ui) {
            Ok(value) => value,
            Err(error) => {
                self.error(&error);
                return;
            }
        };
        self.watch(&docs);
        let labels: Vec<_> = docs
            .iter()
            .map(|doc| doc.label.text().to_string())
            .collect();
        let total = docs.len();
        let skipped = ui.documents.borrow().len() - total;
        let request = SearchRequest {
            pattern: ui.find.text().into(),
            replacement: ui.replace.text().into(),
            mode: match ui.mode.selected() {
                1 => SearchMode::Wildcard,
                2 => SearchMode::Regex,
                _ => SearchMode::Literal,
            },
            case_sensitive: ui.case.is_active(),
            range: None,
        };
        let flags = fastra_core::SearchFlags {
            whole_word: ui.whole_word.is_active(),
        };
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy(true);
        let lang = ui.lang;
        self.status.set_text(lang.text(
            "Alle editierbaren Tabs werden geprüft …",
            "Checking all editable tabs …",
        ));
        self.status.set_visible(false);
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                BatchPreview::create(
                    snapshots,
                    generation,
                    &request,
                    flags,
                    BatchLimits::default(),
                    &cancel,
                )
                .map_err(|e| error_text(lang, &e))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if !state.window.is_visible() {
                    return;
                }
                if state.generation.get() != generation {
                    state.busy(false);
                    return;
                }
                state.busy(false);
                if state.cancel.borrow().check().is_err() {
                    state
                        .status
                        .set_text(lang.text("Suche abgebrochen.", "Search cancelled."));
                    return;
                }
                match result {
                    Ok(preview) => {
                        let Some(ui) = state.ui.upgrade() else { return };
                        let current = match collect(&ui) {
                            Ok((_, snapshots)) => snapshots,
                            Err(e) => {
                                state.error(&e);
                                return;
                            }
                        };
                        if let Err(error) =
                            preview.validate(&current, generation, &Cancellation::default())
                        {
                            state.error(&error);
                            return;
                        }
                        let count = preview
                            .documents()
                            .iter()
                            .map(|doc| doc.preview().matches().len())
                            .sum::<usize>();
                        let items = preview
                            .documents()
                            .iter()
                            .zip(&labels)
                            .map(|(doc, label)| approval::Item {
                                label: label.clone(),
                                preview: doc.preview(),
                            })
                            .collect();
                        *state.pending.borrow_mut() = Some(preview);
                        state.pane.set_items(items);
                        state.busy(false);
                        state.status.set_text(&format!(
                            "{count} {} · {total} {} · {skipped} {}",
                            lang.text("Treffer", "matches"),
                            lang.text("editierbare Tabs", "editable tabs"),
                            lang.text("gesperrte Ansichten ausgelassen", "locked views skipped")
                        ));
                        state.status.set_visible(skipped > 0);
                    }
                    Err(error) => state.status.set_text(&error),
                }
            },
        );
    }
    fn error(&self, error: &fastra_core::Error) {
        self.pending.borrow_mut().take();
        self.pane.clear();
        self.status.set_text(&error_text(self.lang(), error));
        self.apply.set_sensitive(false);
    }
    fn replace_active(self: &Rc<Self>, command: approval::search::Replacement) {
        if self.busy.get() || self.restoration.borrow().is_some() {
            (command.finish)();
            return;
        }
        let Some(ui) = self.ui.upgrade() else {
            (command.finish)();
            return;
        };
        let Some(pending) = self.pending.borrow().clone() else {
            (command.finish)();
            return;
        };
        let Some(item) = pending
            .documents()
            .get(command.item)
            .filter(|item| Arc::ptr_eq(&item.preview(), &command.preview))
        else {
            (command.finish)();
            return;
        };
        let doc = ui
            .documents
            .borrow()
            .iter()
            .find(|doc| format!("document-{:x}", Rc::as_ptr(doc) as usize) == item.id())
            .cloned();
        let Some(doc) = doc else {
            (command.finish)();
            return;
        };
        let generation = self.generation.get();
        let ordinal = command.ordinal;
        let weak = Rc::downgrade(self);
        let current = Rc::new(move || {
            let Some(state) = weak.upgrade() else {
                return false;
            };
            let Some(ui) = state.ui.upgrade() else {
                return false;
            };
            if !state.window.is_visible()
                || state.busy.get()
                || state.restoration.borrow().is_some()
                || state.generation.get() != generation
                || !state
                    .pending
                    .borrow()
                    .as_ref()
                    .is_some_and(|p| Arc::ptr_eq(p, &pending))
            {
                return false;
            }
            let documents = ui.documents.borrow();
            let editable = documents
                .iter()
                .filter(|doc| !doc.source_edits_locked())
                .collect::<Vec<_>>();
            editable.len() == pending.documents().len()
                && editable
                    .iter()
                    .zip(pending.documents())
                    .all(|(doc, expected)| {
                        !doc.close_pending.get()
                            && format!("document-{:x}", Rc::as_ptr(doc) as usize) == expected.id()
                            && doc.revision.get() == expected.preview().revision()
                    })
        });
        let weak = Rc::downgrade(self);
        let document = Rc::downgrade(&doc);
        let applied = Rc::new(move || {
            let (Some(state), Some(doc)) = (weak.upgrade(), document.upgrade()) else {
                return;
            };
            let expected = state.generation.get() + 1;
            let revision = doc.revision.get();
            let weak = Rc::downgrade(&state);
            let document = Rc::downgrade(&doc);
            state.pane.resume_at(
                ordinal,
                Rc::new(move || {
                    let (Some(state), Some(doc)) = (weak.upgrade(), document.upgrade()) else {
                        return false;
                    };
                    state.window.is_visible()
                        && state.generation.get() == expected
                        && doc.revision.get() == revision
                }),
            );
            state.search();
        });
        single_replace::run(
            single_replace::Context {
                owner: Rc::downgrade(&ui),
                doc: Rc::downgrade(&doc),
                buffer: doc.buffer.clone(),
                generation,
                lang: ui.lang,
                current,
                applied,
            },
            command,
        );
    }
    fn apply(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(preview) = self.pending.borrow().clone() else {
            return;
        };
        let Some(ui) = self.ui.upgrade() else { return };
        let current = match collect(&ui) {
            Ok((_, snapshots)) => snapshots,
            Err(e) => {
                self.error(&e);
                return;
            }
        };
        let Some(approved) = self.pane.approvals() else {
            return;
        };
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy(true);
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                let plan = preview
                    .plan(&current, generation, &approved, &cancel)
                    .map_err(|e| error_text(lang, &e))?;
                for output in plan.outputs() {
                    crate::text_limits::validate(output, lang)?;
                }
                Ok(plan)
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if !state.window.is_visible() {
                    return;
                }
                if state.generation.get() != generation || state.cancel.borrow().check().is_err() {
                    state.busy(false);
                    return;
                }
                match result {
                    Ok(plan) => state.apply_plan(plan),
                    Err(error) => {
                        state.pending.borrow_mut().take();
                        state.pane.clear();
                        state.busy(false);
                        state.status.set_text(&error)
                    }
                }
            },
        );
    }
    fn apply_plan(&self, plan: BatchPlan) {
        let Some(ui) = self.ui.upgrade() else { return };
        let (docs, current) = match collect(&ui) {
            Ok(value) => value,
            Err(error) => {
                self.busy(false);
                self.error(&error);
                return;
            }
        };
        if let Err(error) = plan.validate(&current, self.generation.get(), &self.cancel.borrow()) {
            self.busy(false);
            self.error(&error);
            return;
        }
        if plan.outputs().iter().any(|text| text.contains('\0')) {
            self.busy(false);
            self.status.set_text(ui.lang.text(
                "U+0000 kann nicht vollständig im Texteditor angezeigt werden. Nichts übernommen.",
                "U+0000 cannot be displayed completely in the text editor. Nothing applied.",
            ));
            return;
        }
        self.changing.set(true);
        for (doc, text) in docs.iter().zip(plan.outputs()) {
            replace(doc, text);
        }
        let after = collect(&ui)
            .map(|(_, snapshots)| snapshots)
            .and_then(|after| plan.bind_restoration(after, &Cancellation::default()));
        self.changing.set(false);
        self.pending.borrow_mut().take();
        self.pane.clear();
        match after {
            Ok(restoration) => {
                *self.restoration.borrow_mut() = Some(Arc::new(restoration));
                self.status.set_text(ui.lang.text("In allen Tabs übernommen. Dateien sind noch nicht gespeichert. Gemeinsames Rückgängig prüft den gesamten übernommenen Stand.","Applied to all tabs. Files have not been saved. Joint Undo checks the entire applied state."));
            }
            Err(error) => self.error(&error),
        }
        self.busy(false);
    }
    fn undo(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(restoration) = self.restoration.borrow().clone() else {
            return;
        };
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let current = match collect(&ui) {
            Ok((_, snapshots)) => snapshots,
            Err(error) => {
                self.error(&error);
                return;
            }
        };
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy(true);
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                let result = restoration.restore(&current, &cancel);
                Ok((result, current))
            },
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                if !state.window.is_visible() {
                    return;
                }
                let Some(ui) = state.ui.upgrade() else {
                    return;
                };
                match result {
                    Ok((result, expected)) => {
                        let live = collect(&ui);
                        let valid = state.cancel.borrow().check().is_ok()
                            && live
                                .as_ref()
                                .is_ok_and(|(_, snapshots)| snapshots == &expected);
                        match (result, live, valid) {
                            (Ok(texts), Ok((docs, _)), true) => {
                                state.changing.set(true);
                                for (doc, text) in docs.iter().zip(texts) {
                                    replace(doc, &text);
                                }
                                state.changing.set(false);
                                state.restoration.borrow_mut().take();
                                state.status.set_text(lang.text("Gemeinsame Übernahme zurückgesetzt. Dateien wurden nicht geschrieben.","Joint application restored. No files were written."));
                            }
                            (Err(error), _, _) => state.error(&error),
                            _ => state.error(&fastra_core::Error::Stale),
                        }
                    }
                    Err(error) => state.status.set_text(&error),
                }
                state.busy(false);
            },
        );
    }
}
fn replace(doc: &Document, text: &str) {
    if buffer_text(&doc.buffer) == text {
        return;
    }
    doc.buffer.begin_user_action();
    let (mut a, mut b) = doc.buffer.bounds();
    doc.buffer.delete(&mut a, &mut b);
    doc.buffer.insert(&mut a, text);
    doc.buffer.end_user_action();
    doc.update_saved_baseline_status(text);
}
pub fn open(ui: &Rc<Ui>) {
    let lang = ui.lang;
    let window = git_view::window(
        ui,
        lang.text(
            "Alle Tabs · Vorschau und Ersetzen",
            "All tabs · Preview and Replace",
        ),
        true,
    );
    let root = git_view::column();
    let notice=gtk::Label::new(Some(lang.text("Alle offenen editierbaren Tabs. Die Übernahme ändert nur den Editor; Dateien werden separat gespeichert. Grenzen: 128 Tabs, 4 MiB je Eingabe, 10.000 Treffer, 64 MiB Quelltext. Überschreitungen sperren den gesamten Plan.","All open editable tabs. Applying changes the editor only; save files separately. Limits: 128 tabs, 4 MiB per input, 10,000 matches, 64 MiB source text. Exceeding a limit blocks the entire plan.")));
    notice.set_wrap(true);
    notice.set_xalign(0.);
    root.append(&notice);
    let controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .row_spacing(4)
        .column_spacing(8)
        .build();
    let search =
        gtk::Button::with_label(lang.text("Vorschau neu erstellen", "Recalculate preview"));
    let apply = gtk::Button::with_label(
        lang.text("Freigegebene in Tabs übernehmen", "Apply approvals to tabs"),
    );
    let undo = gtk::Button::with_label(
        lang.text("Gemeinsame Übernahme rückgängig", "Undo joint application"),
    );
    let forget = gtk::Button::with_label(lang.text(
        "Gemeinsame Rücknahme verwerfen",
        "Discard joint restoration",
    ));
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&search, &apply, &undo, &forget, &cancel_button] {
        controls.insert(b, -1)
    }
    root.append(&controls);
    let status = gtk::Label::new(None);
    status.set_wrap(true);
    status.set_xalign(0.);
    root.append(&status);
    let pane = approval::ApprovalPane::new(lang);
    root.append(&pane.root);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        pane,
        status,
        search,
        apply,
        undo,
        forget,
        cancel_button,
        busy: Cell::new(false),
        changing: Cell::new(false),
        generation: Cell::new(1),
        cancel: RefCell::new(Cancellation::default()),
        pending: RefCell::new(None),
        restoration: RefCell::new(None),
        watched: RefCell::new(vec![]),
        parent_handler: RefCell::new(None),
    });
    let weak = Rc::downgrade(&state);
    *state.pane.inline_source.borrow_mut() = Some(Rc::new(move || {
        let state = weak.upgrade()?;
        let ui = state.ui.upgrade()?;
        if !state.window.is_visible()
            || state.busy.get()
            || state.restoration.borrow().is_some()
            || ui.replace.text().is_empty()
        {
            return None;
        }
        let doc = ui.active()?;
        if doc.close_pending.get() || doc.source_edits_locked() {
            return None;
        }
        let pending = state.pending.borrow();
        let item = pending
            .as_ref()?
            .documents()
            .iter()
            .find(|item| item.id() == format!("document-{:x}", Rc::as_ptr(&doc) as usize))?;
        (doc.revision.get() == item.preview().revision()).then(|| item.preview())
    }));
    let weak = Rc::downgrade(&state);
    *state.pane.on_navigate.borrow_mut() = Some(Rc::new(move |navigation| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        let Some(ui) = state.ui.upgrade() else {
            return;
        };
        let pending = state.pending.borrow().clone();
        let Some(pending) = pending else {
            return;
        };
        let Some(document) = pending
            .documents()
            .get(navigation.item)
            .filter(|doc| Arc::ptr_eq(&doc.preview(), &navigation.preview))
        else {
            return;
        };
        let doc = ui
            .documents
            .borrow()
            .iter()
            .find(|doc| format!("document-{:x}", Rc::as_ptr(doc) as usize) == document.id())
            .cloned();
        if let Some(doc) = doc {
            search_navigation::memory(&ui, &doc, navigation);
        }
    }));
    let weak = Rc::downgrade(&state);
    *state.pane.on_replace.borrow_mut() = Some(Rc::new(move |command| {
        if let Some(state) = weak.upgrade() {
            state.replace_active(command);
        } else {
            (command.finish)();
        }
    }));
    let weak = Rc::downgrade(&state);
    *state.parent_handler.borrow_mut() = Some(ui.window.connect_visible_notify(move |window| {
        if !window.is_visible() {
            if let Some(state) = weak.upgrade() {
                state.cancel.borrow().cancel();
                state.window.close();
            }
        }
    }));
    let weak = Rc::downgrade(&state);
    state.search.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.search();
        }
    });
    let weak = Rc::downgrade(&state);
    state.apply.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.apply();
        }
    });
    let weak = Rc::downgrade(&state);
    state.undo.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.undo();
        }
    });
    let weak = Rc::downgrade(&state);
    state.cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancel.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&state);
    state.pane.on_changed(Rc::new(move |valid| {
        if let Some(s) = weak.upgrade() {
            s.apply.set_sensitive(
                valid
                    && s.pane.has_approvals()
                    && !s.busy.get()
                    && s.pending.borrow().is_some()
                    && s.restoration.borrow().is_none(),
            );
        }
    }));
    let weak = Rc::downgrade(&state);
    state.forget.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            if s.busy.get() {
                return;
            }
            s.restoration.borrow_mut().take();
            s.status.set_text(s.lang().text(
                "Gemeinsame Rücknahme verworfen. Texte unverändert; neue Vorschau ist möglich.",
                "Joint restoration discarded. Texts unchanged; a new preview is available.",
            ));
            s.busy(false);
        }
    });
    git_view::hold(&window, state.clone(), |s| s.cancel.borrow().cancel());
    let weak = Rc::downgrade(&state);
    let changed = Rc::new(move || {
        if let Some(state) = weak.upgrade() {
            state.inputs_changed();
        }
    });
    state.search.set_label(lang.text("Suchen", "Find"));
    state
        .apply
        .set_label(lang.text("Freigegebene übernehmen", "Apply approved"));
    state.undo.set_label(lang.text("Rückgängig", "Undo"));
    state
        .forget
        .set_label(lang.text("Rücknahme abschließen", "Finish restoration"));
    state.busy(false);
    super::chrome::search::collection(
        ui,
        super::chrome::search::Collection {
            window: &window,
            selected: 1,
            root: &root,
            pane: &state.pane,
            status: &state.status,
            actions: &[
                &state.search,
                &state.cancel_button,
                &state.undo,
                &state.forget,
                &state.apply,
            ],
            extras: &[],
            header: None,
            changed,
        },
    );
    let weak = Rc::downgrade(&state);
    window.connect_map(move |_| {
        if let Some(state) = weak.upgrade() {
            state.inputs_changed();
        }
    });
    window.present();
    state.search();
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_TABS_SELFTEST").is_some()
        && std::env::var_os("FASTRA_APPROVAL_STRESS").is_none()
    {
        run_selftest(state.clone());
    }
}

#[cfg(debug_assertions)]
fn run_selftest(state: Rc<State>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let ui = state.ui.upgrade().unwrap();
    let docs = ui.documents.borrow().clone();
    assert_eq!(docs.len(), 3);
    git_view::test_size(&state.window);
    let painted = Cell::new(None);
    let stage = Cell::new(0);
    let hidden_before = RefCell::new(Vec::<String>::new());
    let hidden_since = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "Tabs test timed out at {}: {}",
            stage.get(),
            state.status.text()
        );
        if stage.get() != 91 && state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        if stage.get() != 91
            && state.pending.borrow().is_some()
            && !state.pane.test_approve_initial()
            && state.restoration.borrow().is_none()
        {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                assert!(state.pending.borrow().is_some(), "{}", state.status.text());
                if std::env::var_os("FASTRA_TOOL_SCREENSHOTS").is_some() {
                    let since = painted.get().unwrap_or_else(|| {
                        let now = std::time::Instant::now();
                        painted.set(Some(now));
                        now
                    });
                    if since.elapsed() < Duration::from_millis(300) {
                        return glib::ControlFlow::Continue;
                    }
                    if !git_view::try_capture(&state.window, "all-tabs") {
                        return glib::ControlFlow::Continue;
                    }
                }

                state.pane.test_approve_hit(0, 0, false);
                if !state.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.pane.test_display(1), "cat dog");
                state.pane.files.set_selected(1);
                state.pane.exact.set_active(true);
                assert!(!state.pane.is_ready());
                state.apply.emit_clicked();
                assert!(!state.busy.get());
                assert_eq!(buffer_text(&docs[0].buffer), "cat cat");
                stage.set(10);
            }
            10 => {
                assert_eq!(state.pane.test_display(0), "cat\\u{1F642}");
                assert_eq!(state.pane.test_display(1), "dog\\u{1F642}");
                state.pane.exact.set_active(false);
                state.pane.exact.set_active(true);
                state.pane.exact.set_active(false);
                state.pane.files.set_selected(0);
                assert!(!state.pane.is_ready());
                stage.set(11);
            }
            11 => {
                assert_eq!(state.pane.test_display(0), "cat cat");
                assert_eq!(state.pane.test_display(1), "cat dog");
                state.apply.emit_clicked();
                assert!(!state.pane.checks.is_sensitive());
                stage.set(1);
            }
            1 => {
                assert_eq!(buffer_text(&docs[0].buffer), "cat dog");
                assert_eq!(buffer_text(&docs[1].buffer), "dog🙂");
                assert_eq!(buffer_text(&docs[2].buffer), "none");
                assert!(state.restoration.borrow().is_some());
                docs[1].buffer.undo();
                assert_eq!(buffer_text(&docs[1].buffer), "cat🙂");
                state.undo.emit_clicked();
                stage.set(2);
            }
            2 => {
                assert_eq!(buffer_text(&docs[0].buffer), "cat dog");
                assert!(state.restoration.borrow().is_some());
                assert!(state.forget.is_sensitive());
                state.forget.emit_clicked();
                assert!(state.search.is_sensitive());
                state.search.emit_clicked();
                stage.set(3);
            }
            3 => {
                assert!(state.pending.borrow().is_some(), "{}", state.status.text());
                state.apply.emit_clicked();
                stage.set(4);
            }
            4 => {
                assert_eq!(buffer_text(&docs[0].buffer), "dog dog");
                assert_eq!(buffer_text(&docs[1].buffer), "dog🙂");
                state.undo.emit_clicked();
                stage.set(5);
            }
            5 => {
                assert!(
                    state.restoration.borrow().is_none(),
                    "{}",
                    state.status.text()
                );
                assert_eq!(buffer_text(&docs[0].buffer), "cat dog");
                assert_eq!(buffer_text(&docs[1].buffer), "cat🙂");
                assert!(docs[0].buffer.is_modified());
                assert!(!docs[1].buffer.is_modified());
                assert!(!docs[2].buffer.is_modified());
                state.search.emit_clicked();
                stage.set(6);
            }
            6 => {
                assert!(state.pending.borrow().is_some());
                docs[2].buffer.set_text("cat");
                assert!(state.pending.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                state.search.emit_clicked();
                stage.set(7);
            }
            7 => {
                assert!(state.pending.borrow().is_some());
                ui.add_document("late", "new");
                state.apply.emit_clicked();
                stage.set(8);
            }
            8 => {
                assert!(state.pending.borrow().is_none(), "{}", state.status.text());
                assert_eq!(buffer_text(&docs[0].buffer), "cat dog");
                assert_eq!(buffer_text(&docs[2].buffer), "cat");
                state.search.emit_clicked();
                state.cancel_button.emit_clicked();
                stage.set(9);
            }
            9 => {
                assert!(state.pending.borrow().is_none());
                state.search.emit_clicked();
                stage.set(90);
            }
            90 => {
                assert!(state.pending.borrow().is_some());
                *hidden_before.borrow_mut() = ui
                    .documents
                    .borrow()
                    .iter()
                    .map(|doc| buffer_text(&doc.buffer))
                    .collect();
                state.apply.emit_clicked();
                ui.window.set_visible(false);
                hidden_since.set(std::time::Instant::now());
                stage.set(91);
            }
            _ => {
                if hidden_since.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.window.is_visible());
                assert!(state.cancel.borrow().check().is_err());
                assert_eq!(
                    ui.documents
                        .borrow()
                        .iter()
                        .map(|doc| buffer_text(&doc.buffer))
                        .collect::<Vec<_>>(),
                    *hidden_before.borrow()
                );
                eprintln!(
                    "FASTRA_TABS_SELFTEST_OK selective-multitab/noop-bound/one-native-undo/stale-restoration/discard-restoration/joint-restore/dirty-baseline/stale-nonmatch/membership/cancel/exact-unicode/async-preview-binding/parent-hide-no-apply"
                );
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
