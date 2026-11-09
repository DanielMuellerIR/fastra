use super::*;
use crate::Document;
use sources::{Choice, Loaded, Origin};
#[cfg(debug_assertions)]
thread_local! { static LAST: RefCell<Weak<State>> = const { RefCell::new(Weak::new()) }; }
#[cfg(debug_assertions)]
pub(super) fn test_last() -> Option<Rc<State>> {
    LAST.with(|last| last.borrow().upgrade())
}
#[derive(Clone)]
pub(super) struct Model {
    pub comparison: Arc<fastra_diff::Comparison>,
    pub inputs: [Arc<Loaded>; 2],
    pub generation: u64,
    pub paths: [Option<PathBuf>; 2],
}
struct SourceBinding {
    document: Weak<Document>,
    buffer: glib::SignalHandlerId,
    label: glib::SignalHandlerId,
}
pub(crate) struct State {
    pub(super) ui: Weak<Ui>,
    pub(super) lang: Language,
    pub(super) picker: picker::Picker,
    pub(super) view: Rc<view::View>,
    pub(super) choices: RefCell<[Option<Choice>; 2]>,
    pub(super) origins: RefCell<[Option<Origin>; 2]>,
    pub(super) document: RefCell<Weak<Document>>,
    pub(super) model: RefCell<Option<Model>>,
    pub(super) cancel: RefCell<Cancel>,
    pub(super) request: Cell<u64>,
    pub(super) busy: Cell<bool>,
    pub(super) preparing: Cell<bool>,
    pub(super) automatic: Cell<bool>,
    saved: Cell<bool>,
    pub(super) preview: RefCell<Weak<transfer::Preview>>,
    bindings: RefCell<Vec<SourceBinding>>,
    page_removed: RefCell<Option<glib::SignalHandlerId>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.clear_bindings();
        if let (Some(ui), Some(handler)) = (self.ui.upgrade(), self.page_removed.get_mut().take()) {
            ui.tabs.disconnect(handler);
        }
        self.cancel.get_mut().cancel();
        if let Some(preview) = self.preview.get_mut().upgrade() {
            preview.window.close();
        }
    }
}
impl State {
    fn new(ui: &Rc<Ui>) -> Rc<Self> {
        let state = Rc::new(Self {
            ui: Rc::downgrade(ui),
            lang: ui.lang,
            picker: picker::Picker::new(ui),
            view: view::View::new(ui.lang, &ui.window),
            choices: RefCell::new([None, None]),
            origins: RefCell::new([None, None]),
            document: RefCell::new(Weak::new()),
            model: RefCell::new(None),
            cancel: RefCell::new(Cancel::default()),
            request: Cell::new(0),
            busy: Cell::new(false),
            preparing: Cell::new(false),
            automatic: Cell::new(false),
            saved: Cell::new(false),
            preview: RefCell::new(Weak::new()),
            bindings: RefCell::new(Vec::new()),
            page_removed: RefCell::new(None),
        });
        #[cfg(debug_assertions)]
        LAST.with(|last| *last.borrow_mut() = Rc::downgrade(&state));
        picker::Picker::connect(&state);
        let owner = Rc::downgrade(&state);
        state.view.refresh.connect_clicked(move |_| {
            if let Some(state) = owner.upgrade() {
                if state.busy.get() {
                    state.abort();
                } else {
                    state.start();
                }
            }
        });
        for side in 0..2 {
            let owner = Rc::downgrade(&state);
            state.view.transfer[side].connect_clicked(move |_| {
                if let Some(state) = owner.upgrade() {
                    transfer::prepare(&state, side);
                }
            });
        }
        let owner = Rc::downgrade(&state);
        state.view.export.connect_clicked(move |_| {
            if let Some(state) = owner.upgrade() {
                export::open(&state);
            }
        });
        let owner = Rc::downgrade(&state);
        state.view.selection.connect_selected_notify(move |_| {
            if let Some(state) = owner.upgrade() {
                state.controls();
            }
        });
        let owner = Rc::downgrade(&state);
        state.view.root.connect_map(move |_| {
            let owner = owner.clone();
            glib::idle_add_local_once(move || {
                if let Some(state) = owner
                    .upgrade()
                    .filter(|state| !state.busy.get() && state.active())
                {
                    state.check_return();
                }
            });
        });
        let owner = Rc::downgrade(&state);
        *state.page_removed.borrow_mut() = Some(ui.tabs.connect_page_removed(move |_, _, _| {
            let owner = owner.clone();
            glib::idle_add_local_once(move || {
                if let Some(state) = owner.upgrade() {
                    state.source_changed();
                }
            });
        }));
        state.controls();
        state
    }
    pub(crate) fn set_wrap(&self, enabled: bool) {
        self.view.set_wrap(enabled);
    }
    fn clear_bindings(&self) {
        for binding in self.bindings.borrow_mut().drain(..) {
            if let Some(doc) = binding.document.upgrade() {
                doc.buffer.disconnect(binding.buffer);
                doc.label.disconnect(binding.label);
            }
        }
    }
    fn source_changed(&self) {
        self.controls();
        if !self.busy.get()
            && self.model.borrow().is_some()
            && self.live().is_some()
            && !self.current()
        {
            self.error(self.lang.text("Eine Vergleichsquelle wurde geändert oder geschlossen. Neu berechnen oder Quellen neu wählen.", "A comparison source changed or closed. Recalculate or choose the sources again."));
        }
    }
    fn bind_sources(self: &Rc<Self>, ui: &Ui) {
        self.clear_bindings();
        let mut seen = Vec::new();
        for doc in self
            .choices
            .borrow()
            .iter()
            .flatten()
            .filter_map(|choice| choice.document(ui))
        {
            if seen.iter().any(|old| Rc::ptr_eq(old, &doc)) {
                continue;
            }
            let owner = Rc::downgrade(self);
            let buffer = doc.buffer.connect_changed(move |_| {
                if let Some(state) = owner.upgrade() {
                    state.source_changed();
                }
            });
            let owner = Rc::downgrade(self);
            let label = doc.label.connect_label_notify(move |_| {
                if let Some(state) = owner.upgrade() {
                    state.source_changed();
                }
            });
            self.bindings.borrow_mut().push(SourceBinding {
                document: Rc::downgrade(&doc),
                buffer,
                label,
            });
            seen.push(doc);
        }
    }
    fn check_return(self: &Rc<Self>) {
        let Some(model) = self.model.borrow().clone() else {
            return;
        };
        if !self.current() {
            self.start();
            return;
        }
        let owner = Rc::downgrade(self);
        let generation = model.generation;
        support::background(
            move || {
                for input in &model.inputs {
                    input.verify_file(&fastra_core::Cancellation::default())?;
                }
                Ok(())
            },
            move |result| {
                if let Some(state) = owner.upgrade().filter(|s| {
                    !s.busy.get()
                        && s.active()
                        && s.model
                            .borrow()
                            .as_ref()
                            .is_some_and(|m| m.generation == generation)
                }) {
                    if result.is_err() {
                        state.start();
                    }
                }
            },
        );
    }
    pub(super) fn choose(self: &Rc<Self>, side: usize, choice: Choice) {
        if self.busy.get() {
            return;
        }
        self.choices.borrow_mut()[side] = Some(choice);
        picker::Picker::probe(self, side);
    }
    pub(super) fn live(&self) -> Option<Rc<Ui>> {
        let ui = self.ui.upgrade().filter(|ui| {
            ui.window.is_visible()
                && !ui.close_committed.get()
                && !ui.window_close_dialog.get()
                && !crate::close_protocol::active(ui)
        })?;
        let doc = self.document.borrow().upgrade()?;
        let member = ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc));
        member.then_some(ui)
    }
    pub(super) fn current(&self) -> bool {
        self.live().is_some_and(|ui| {
            self.origins
                .borrow()
                .iter()
                .flatten()
                .all(|origin| origin.current(&ui).is_some())
        })
    }
    pub(super) fn active(&self) -> bool {
        self.live().is_some_and(|ui| {
            self.document
                .borrow()
                .upgrade()
                .zip(ui.active())
                .is_some_and(|(a, b)| Rc::ptr_eq(&a, &b))
        })
    }
    fn side_name(&self, side: usize) -> String {
        let name = self.choices.borrow()[side]
            .as_ref()
            .map(|choice| choice.result_name(self.lang))
            .unwrap_or_default();
        if self.saved.get() && side == 0 {
            format!("{name} ({})", self.lang.text("gespeichert", "saved"))
        } else {
            name
        }
    }
    fn attach(self: &Rc<Self>) -> Option<Rc<Ui>> {
        if let Some(ui) = self.live() {
            return Some(ui);
        }
        let ui = self.ui.upgrade().filter(|ui| ui.window.is_visible())?;
        {
            let choices = self.choices.borrow();
            choices[0].as_ref()?;
            choices[1].as_ref()?;
        }
        let name = format!("Diff: {} ⇄ {}", self.side_name(0), self.side_name(1));
        ui.add_document(&name, "");
        let doc = ui.active()?;
        *doc.comparison.borrow_mut() = Some(self.clone());
        *self.document.borrow_mut() = Rc::downgrade(&doc);
        crate::editor_options::comparison_attached(&doc);
        while let Some(child) = doc.container.first_child() {
            doc.container.remove(&child);
        }
        doc.container.set_spacing(0);
        doc.container.append(&self.view.root);
        doc.buffer.set_modified(false);
        if let Some(chrome) = doc.chrome.borrow().as_ref() {
            (chrome.refresh_context)();
        }
        chrome::refresh(&ui);
        Some(ui)
    }
    pub(super) fn error(&self, text: &str) {
        if self.document.borrow().upgrade().is_some() {
            self.view.error(text);
        } else {
            self.picker.error(text);
        }
    }
    pub(super) fn abort(&self) {
        self.cancel.borrow().cancel();
        self.request.set(self.request.get().wrapping_add(1));
        if self.preparing.replace(false) {
            self.busy.set(false);
            self.controls();
            self.view.status.set_text(self.lang.text(
                "Übernahmevorschau abgebrochen. Der Vergleich bleibt erhalten.",
                "Transfer preview cancelled. The comparison is retained.",
            ));
            return;
        }
        self.view.cancel_render();
        self.model.borrow_mut().take();
        self.busy.set(false);
        self.controls();
        self.view.error(self.lang.text(
            "Vergleich abgebrochen. Keine Übernahme möglich; neu berechnen.",
            "Comparison cancelled. Transfers are unavailable; recalculate.",
        ));
    }
    pub(super) fn controls(&self) {
        let ready = !self.busy.get() && self.model.borrow().is_some() && self.current();
        for side in 0..2 {
            let target = self.live().and_then(|ui| {
                self.origins.borrow()[side]
                    .as_ref()
                    .and_then(|origin| origin.current(&ui))
            });
            self.view.transfer[side].set_sensitive(
                ready
                    && target.is_some_and(|doc| sources::destination_ready(&doc))
                    && self.view.selection.selected() != gtk::INVALID_LIST_POSITION,
            );
        }
        self.view
            .export
            .set_sensitive(!self.busy.get() && self.model.borrow().is_some());
        self.view.refresh.set_label(if self.busy.get() {
            self.lang.text("Abbrechen", "Cancel")
        } else {
            self.lang.text("Neu berechnen", "Recalculate")
        });
        self.view.interactive(!self.busy.get());
        self.picker.update(self);
    }
    pub(super) fn start(self: &Rc<Self>) {
        if self.busy.get() || !self.picker.ready() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        if self.choices.borrow().iter().any(Option::is_none) {
            return;
        }
        self.busy.set(true);
        self.preparing.set(false);
        self.controls();
        let documents = self
            .choices
            .borrow()
            .iter()
            .flatten()
            .filter_map(|choice| choice.document(&ui))
            .filter(|doc| doc.is_rich_active())
            .collect::<Vec<_>>();
        if !documents.is_empty() {
            let owner = Rc::downgrade(self);
            let request = self.request.get().wrapping_add(1);
            self.request.set(request);
            crate::rich_editor::flush_documents_owned(
                &documents,
                Box::new(move |ok| {
                    if let Some(state) = owner
                        .upgrade()
                        .filter(|state| state.busy.get() && state.request.get() == request)
                    {
                        if ok {
                            state.calculate();
                        } else {
                            state.busy.set(false);
                            state.controls();
                            state.error(state.lang.text(
                                "Rich-Quelle konnte nicht sicher synchronisiert werden.",
                                "The Rich source could not be synchronized safely.",
                            ));
                        }
                    }
                }),
            );
        } else {
            self.calculate();
        }
    }
    fn calculate(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade() else { return };
        let requests = {
            let choices = self.choices.borrow();
            let capture = || -> Result<_, String> {
                Ok([
                    choices[0]
                        .as_ref()
                        .ok_or("Missing left source")?
                        .capture(&ui)?,
                    choices[1]
                        .as_ref()
                        .ok_or("Missing right source")?
                        .capture(&ui)?,
                ])
            };
            match capture() {
                Ok(value) => value,
                Err(error) => {
                    self.busy.set(false);
                    self.controls();
                    self.error(&error);
                    return;
                }
            }
        };
        let [(left, left_origin), (right, right_origin)] = requests;
        *self.origins.borrow_mut() = [left_origin, right_origin];
        self.bind_sources(&ui);
        self.cancel.borrow().cancel();
        let cancel = Cancel::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let request = self.request.get().wrapping_add(1);
        self.request.set(request);
        self.model.borrow_mut().take();
        self.view.cancel_render();
        self.view.loading(self.lang);
        let options = if self.saved.get() {
            fastra_diff::Options::default()
        } else {
            fastra_diff::Options {
                ignore_trailing_whitespace: self.picker.options[0].is_active(),
                ignore_all_whitespace: self.picker.options[1].is_active(),
                ignore_blank_lines: self.picker.options[2].is_active(),
                ignore_case: self.picker.options[3].is_active(),
            }
        };
        if self.attach().is_none() {
            self.busy.set(false);
            return;
        }
        self.picker.window.close();
        for side in 0..2 {
            if let Some(choice) = self.choices.borrow()[side].as_ref() {
                self.view.names[side].set_text(&self.side_name(side));
                self.view.names[side].set_tooltip_text(Some(&choice.description(self.lang)));
            }
        }
        self.view.status.set_text(
            self.lang
                .text("Vergleich wird berechnet …", "Calculating comparison …"),
        );
        self.controls();
        let owner = Rc::downgrade(self);
        let lang = self.lang;
        let paths = self
            .choices
            .borrow()
            .each_ref()
            .map(|choice| choice.as_ref().and_then(Choice::path));
        support::background(
            move || {
                let inputs = [
                    Arc::new(left.load(&cancel.io, lang)?),
                    Arc::new(right.load(&cancel.io, lang)?),
                ];
                #[cfg(debug_assertions)]
                if std::env::var_os("FASTRA_DIFF_LARGE_SELFTEST").is_some() {
                    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
                    let pause = root.join("pause-comparison");
                    if pause.exists() {
                        std::fs::write(
                            root.join("comparison-worker-ready"),
                            b"native cancellation gate",
                        )
                        .map_err(|error| error.to_string())?;
                        while pause.exists() {
                            cancel
                                .diff
                                .check()
                                .map_err(|error| diff_error(lang, error))?;
                            std::thread::sleep(std::time::Duration::from_millis(10));
                        }
                    }
                }
                let comparison = Arc::new(
                    fastra_diff::Comparison::compare(
                        inputs[0].snapshot.clone(),
                        inputs[1].snapshot.clone(),
                        request,
                        options,
                        fastra_diff::Limits::default(),
                        &cancel.diff,
                    )
                    .map_err(|e| diff_error(lang, e))?,
                );
                let display = presentation::Presentation::build(&comparison, &cancel.diff)?;
                let labels = block_labels(&comparison, lang);
                for input in &inputs {
                    input.verify_file(&cancel.io)?;
                }
                Ok((
                    Model {
                        comparison,
                        inputs,
                        generation: request,
                        paths,
                    },
                    display,
                    labels,
                ))
            },
            move |result| {
                let Some(state) = owner
                    .upgrade()
                    .filter(|state| state.request.get() == request)
                else {
                    return;
                };
                if !state.current() {
                    state.busy.set(false);
                    state.controls();
                    state.error(lang.text(
                        "Eine Vergleichsquelle wurde geändert oder geschlossen. Neu berechnen.",
                        "A comparison source changed or closed. Recalculate.",
                    ));
                    return;
                }
                match result {
                    Ok((model, display, labels)) => {
                        *state.model.borrow_mut() = Some(model);
                        let owner = Rc::downgrade(&state);
                        state.view.install(display,labels,lang,move ||{if let Some(state)=owner.upgrade().filter(|state|state.request.get()==request){state.busy.set(false);state.view.status.set_text(lang.text("Übernehmen ist nur in zugeordnete offene editierbare Dokumente möglich. Dateien werden dabei nicht gespeichert.","Transfers require an associated open editable document. Files are not saved."));state.controls();}});
                    }
                    Err(error) => {
                        state.busy.set(false);
                        state.controls();
                        state.error(&error);
                    }
                }
            },
        );
    }
    #[cfg(debug_assertions)]
    pub(crate) fn test_pair_sources(&self) -> Option<[(PathBuf, String); 2]> {
        if self.busy.get() {
            return None;
        }
        self.model.borrow().as_ref().and_then(|model| {
            let [left, right] = model.inputs.each_ref().map(|input| {
                input.file.as_ref().map(|file| (file.path().to_path_buf(), input.snapshot.text.clone()))
            });
            Some([left?, right?])
        })
    }
}
pub(super) fn block_label(
    left: Option<(usize, usize)>,
    right: Option<(usize, usize)>,
    lang: Language,
) -> String {
    let span = |(a, b): (usize, usize)| {
        if a == b {
            a.to_string()
        } else {
            format!("{a}–{b}")
        }
    };
    let plural = |range: Option<(usize, usize)>| range.is_some_and(|(a, b)| a != b);
    let noun = |multiple| {
        if multiple {
            lang.text("Zeilen", "Lines")
        } else {
            lang.text("Zeile", "Line")
        }
    };
    match (left, right) {
        (None, Some(range)) => format!(
            "+ {} {} {}",
            noun(plural(right)),
            span(range),
            lang.text("nur rechts", "only on right")
        ),
        (Some(range), None) => format!(
            "− {} {} {}",
            noun(plural(left)),
            span(range),
            lang.text("nur links", "only on left")
        ),
        (Some(a), Some(b)) if a != b => format!(
            "✎ {} {} ↔ {} {}",
            noun(true),
            span(a),
            span(b),
            lang.text("geändert", "changed")
        ),
        (Some(range), _) => format!(
            "✎ {} {} {}",
            noun(plural(left)),
            span(range),
            lang.text("geändert", "changed")
        ),
        _ => String::new(),
    }
}
pub(super) fn block_labels(comparison: &fastra_diff::Comparison, lang: Language) -> Vec<String> {
    comparison
        .blocks()
        .iter()
        .map(|block| {
            let rows = &comparison.rows()[block.rows.clone()];
            let range = |side| {
                let mut numbers =
                    rows.iter()
                        .filter_map(|row| if side { row.left_line } else { row.right_line });
                numbers
                    .next()
                    .map(|first| (first, numbers.next_back().unwrap_or(first)))
            };
            block_label(range(true), range(false), lang)
        })
        .collect()
}
pub(super) fn open(ui: &Rc<Ui>) -> Rc<State> {
    let state = State::new(ui);
    if let Some(doc) = ui.active().filter(|doc| sources::eligible(doc)) {
        state.choose(0, Choice::from_doc(&doc));
    }
    support::hold(&state.picker.window, state.clone(), |state| {
        if state.document.borrow().upgrade().is_none() {
            state.cancel.borrow().cancel();
        }
    });
    state.picker.window.present();
    state
}
pub(super) fn open_documents(ui: &Rc<Ui>, documents: [Rc<Document>; 2]) -> Rc<State> {
    let state = open(ui);
    for (side, doc) in documents.into_iter().enumerate() {
        state.choose(side, Choice::from_doc(&doc));
    }
    state
}
pub(super) fn open_saved(ui: &Rc<Ui>) -> Option<Rc<State>> {
    if !crate::tab_comparison::can_saved(ui) {
        return None;
    }
    let doc = ui.active()?;
    let path = doc.disk_path()?;
    let state = State::new(ui);
    state.saved.set(true);
    *state.choices.borrow_mut() = [Some(Choice::File(path)), Some(Choice::from_doc(&doc))];
    state.automatic.set(true);
    state.attach();
    state
        .picker
        .window
        .set_application(None::<&gtk::Application>);
    if state.picker.ready() {
        state.automatic.set(false);
        state.start();
    }
    Some(state)
}
pub(super) fn open_pair(
    ui: &Rc<Ui>,
    left: PathBuf,
    right: PathBuf,
) -> Rc<State> {
    let state = State::new(ui);
    *state.choices.borrow_mut() = [
        Some(Choice::File(left)),
        Some(Choice::File(right)),
    ];
    state.automatic.set(true);
    state.attach();
    state
        .picker
        .window
        .set_application(None::<&gtk::Application>);
    if state.picker.ready() {
        state.automatic.set(false);
        state.start();
    }
    state
}
