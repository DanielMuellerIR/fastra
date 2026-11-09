//! Unveränderlicher Textablauf auf gebundenen Tabs; Apply/Undo bleiben im gemeinsamen Batchkern.
use super::super::*;
use fastra_core::batch::{BatchLimits, BatchPlan, BatchPreview, DocumentSnapshot, Restoration};
use fastra_core::text_operations::TitlecaseLocale;
use fastra_workflow::{Definition, Workflow};
use std::{
    rc::Weak,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Instant,
};
const SOURCE_BYTES: usize = 16 * 1024 * 1024;
const RETAINED_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq)]
struct Member {
    id: usize,
    revision: u64,
    read_only: bool,
    rich: bool,
    saving: bool,
    dirty: bool,
    hex_dirty: bool,
    saved: Option<[u8; 32]>,
}
fn members(ui: &Ui) -> Result<Vec<Member>, String> {
    let docs = ui.documents.borrow();
    if docs.len() > 128 {
        return Err(limit(ui.lang));
    }
    docs.iter()
        .map(|doc| {
            Ok(Member {
                id: Rc::as_ptr(doc) as usize,
                revision: doc.revision.get(),
                read_only: doc.is_read_only(),
                rich: doc.is_rich_active(),
                saving: doc.saving.get(),
                dirty: doc.buffer.is_modified(),
                hex_dirty: doc.hex_editor.borrow().as_ref().is_some_and(|h| h.dirty()),
                saved: doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .map(|s| s.binding_digest())
                    .transpose()
                    .map_err(|e| e.to_string())?,
            })
        })
        .collect()
}
struct Capture {
    // Starke Referenzen verhindern die Wiederverwendung einer entfernten Dokumentadresse.
    _members: Vec<Rc<Document>>,
    binding: Vec<Member>,
    docs: Vec<Rc<Document>>,
    snapshots: Vec<DocumentSnapshot>,
    labels: Vec<String>,
}
fn capture(ui: &Ui) -> Result<Capture, String> {
    let binding = members(ui)?;
    let all = ui.documents.borrow().clone();
    let mut docs = Vec::new();
    let mut snapshots = Vec::new();
    let mut labels = Vec::new();
    let mut bytes = 0usize;
    for (doc, member) in all.iter().zip(&binding) {
        if member.read_only || member.rich || member.saving {
            continue;
        }
        if docs.len() >= 32 || doc.buffer.char_count() > 4 * 1024 * 1024 {
            return Err(limit(ui.lang));
        }
        let text = buffer_text(&doc.buffer);
        bytes = bytes
            .checked_add(text.len())
            .ok_or_else(|| limit(ui.lang))?;
        if text.len() > 4 * 1024 * 1024 || bytes > SOURCE_BYTES {
            return Err(limit(ui.lang));
        }
        let path = doc
            .snapshot
            .borrow()
            .as_ref()
            .map(|s| crate::project_view::display(&s.path()))
            .unwrap_or_else(|| {
                ui.lang
                    .text("Ungespeichertes Dokument", "Unsaved document")
                    .into()
            });
        labels.push(format!(
            "{} · {} · {}",
            docs.len() + 1,
            doc.label.text(),
            path
        ));
        snapshots.push(DocumentSnapshot {
            id: format!("document-{:x}", member.id),
            revision: member.revision,
            text,
        });
        docs.push(doc.clone());
    }
    Ok(Capture {
        _members: all,
        binding,
        docs,
        snapshots,
        labels,
    })
}
fn limit(lang: Language) -> String {
    lang.text("Grenze erreicht: 32 editierbare Tabs, 4 MiB je Text, 16 MiB Eingaben, 32 MiB Zwischenstufen und 15 Sekunden insgesamt. Nichts übernommen.","Limit reached: 32 editable tabs, 4 MiB per text, 16 MiB sources, 32 MiB intermediate stages and 15 seconds total. Nothing applied.").into()
}
struct Computed {
    batch: Arc<BatchPreview>,
    flows: Vec<fastra_workflow::Preview>,
}
impl Computed {
    fn locale(&self) -> Option<&TitlecaseLocale> {
        self.flows.first().and_then(|flow| flow.locale())
    }
}
fn calculate(
    definition: &Workflow,
    inputs: Vec<DocumentSnapshot>,
    generation: u64,
    lang: Language,
    locale: Option<&TitlecaseLocale>,
    cancel: &Cancellation,
) -> Result<Computed, String> {
    if inputs.is_empty()
        || inputs.len() > 32
        || inputs.iter().any(|d| d.text.len() > 4 * 1024 * 1024)
        || inputs
            .iter()
            .try_fold(0usize, |n, d| n.checked_add(d.text.len()))
            .is_none_or(|n| n > SOURCE_BYTES)
    {
        return Err(limit(lang));
    }
    let done = AtomicBool::new(false);
    let started = Instant::now();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !done.load(Ordering::Relaxed) {
                if started.elapsed() > Duration::from_secs(15) {
                    cancel.cancel();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
        let result = (|| {
            definition
                .validate()
                .map_err(|e| super::message(&e, lang))?;
            let mut retained = 0usize;
            let mut output_bytes = 0usize;
            let mut flows = Vec::new();
            let mut outputs = Vec::new();
            for input in &inputs {
                cancel.check().map_err(|e| error_text(lang, &e))?;
                let preview = fastra_workflow::preview_with_locale(
                    definition,
                    &input.text,
                    None,
                    input.revision,
                    generation,
                    locale,
                    cancel,
                )
                .map_err(|e| super::message(&e, lang))?;
                crate::text_limits::validate(preview.source(), lang)?;
                crate::text_limits::validate(preview.output(), lang)?;
                if preview.output().len() > 4 * 1024 * 1024 {
                    return Err(limit(lang));
                }
                let mut seen = std::collections::HashSet::new();
                for step in &preview.steps {
                    for text in [&step.before, &step.after] {
                        cancel.check().map_err(|e| error_text(lang, &e))?;
                        crate::text_limits::validate(text, lang)?;
                        if seen.insert((text.as_ptr() as usize, text.len())) {
                            retained = retained
                                .checked_add(text.len())
                                .ok_or_else(|| limit(lang))?;
                        }
                        if retained > RETAINED_BYTES {
                            return Err(limit(lang));
                        }
                    }
                }
                output_bytes = output_bytes
                    .checked_add(preview.output().len())
                    .ok_or_else(|| limit(lang))?;
                if output_bytes > SOURCE_BYTES {
                    return Err(limit(lang));
                }
                outputs.push(preview.output().to_string());
                flows.push(preview);
            }
            let limits = BatchLimits {
                max_documents: 32,
                max_source_bytes: SOURCE_BYTES,
                max_preview_bytes: 2 * SOURCE_BYTES,
                max_plan_bytes: SOURCE_BYTES,
                max_matches: 32,
            };
            let batch =
                BatchPreview::from_replacements(inputs, outputs, generation, limits, cancel)
                    .map_err(|e| error_text(lang, &e))?;
            Ok(Computed { batch, flows })
        })();
        done.store(true, Ordering::Relaxed);
        if started.elapsed() > Duration::from_secs(15) {
            Err(limit(lang))
        } else {
            result
        }
    })
}
struct Receipt {
    restoration: Arc<Restoration>,
    binding: Vec<Member>,
    _members: Vec<Rc<Document>>,
}
pub(super) struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    definition: Workflow,
    pane: Rc<approval::ApprovalPane>,
    status: gtk::Label,
    search: gtk::Button,
    apply: gtk::Button,
    undo: gtk::Button,
    forget: gtk::Button,
    cancel_button: gtk::Button,
    stage_docs: gtk::DropDown,
    stages: gtk::DropDown,
    stage_exact: gtk::CheckButton,
    stage_before: gtk::TextView,
    stage_after: gtk::TextView,
    stage_status: gtk::Label,
    busy: Cell<bool>,
    changing: Cell<bool>,
    generation: Cell<u64>,
    stage_generation: Cell<u64>,
    stage_cancel: RefCell<Cancellation>,
    cancel: RefCell<Cancellation>,
    pending: RefCell<Option<Arc<Computed>>>,
    captured: RefCell<Option<Capture>>,
    restoration: RefCell<Option<Receipt>>,
    watched: RefCell<Vec<(Weak<Document>, glib::SignalHandlerId)>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        self.stage_cancel.get_mut().cancel();
        for (doc, id) in self.watched.get_mut().drain(..) {
            if let Some(doc) = doc.upgrade() {
                doc.buffer.disconnect(id);
            }
        }
    }
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn current_locale(&self) -> Result<Option<TitlecaseLocale>, String> {
        if self
            .definition
            .steps
            .iter()
            .any(|step| step.enabled && step.uses_text_locale())
        {
            crate::operations::titlecase_locale()
                .map(Some)
                .map_err(|_| {
                    self.lang().text(
                "Die Text-Systemlocale konnte nicht bestimmt werden. Nichts übernommen.",
                "The system text locale could not be determined. Nothing applied.").to_string()
                })
        } else {
            Ok(None)
        }
    }
    fn locale_matches(&self, expected: Option<&TitlecaseLocale>) -> bool {
        self.current_locale()
            .is_ok_and(|locale| locale.as_ref() == expected)
    }
    fn invalidate_locale(&self) {
        self.invalidate();
        self.status.set_text(self.lang().text(
            "Die Text-Systemlocale hat sich geändert. Vorschau neu berechnen. Nichts übernommen.",
            "The system text locale changed. Recalculate the preview. Nothing applied.",
        ));
    }
    fn alive(&self) -> bool {
        self.window.is_visible() && self.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
    }
    fn controls(&self) {
        let busy = self.busy.get();
        self.search
            .set_sensitive(!busy && self.restoration.borrow().is_none());
        self.apply.set_sensitive(false);
        self.undo
            .set_sensitive(!busy && self.restoration.borrow().is_some());
        self.forget
            .set_sensitive(!busy && self.restoration.borrow().is_some());
        self.cancel_button.set_sensitive(busy);
        self.pane
            .freeze(busy || self.pending.borrow().is_none() || self.restoration.borrow().is_some());
    }
    fn clear_stages(&self) {
        self.stage_cancel.borrow().cancel();
        self.stage_generation
            .set(self.stage_generation.get().wrapping_add(1));
        self.stage_docs.set_model(None::<&gtk::StringList>);
        self.stages.set_model(None::<&gtk::StringList>);
        self.stage_before.buffer().set_text("");
        self.stage_after.buffer().set_text("");
        self.stage_status.set_text("");
    }
    fn invalidate(&self) {
        if self.changing.get() {
            return;
        }
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.pending.borrow_mut().take();
        self.captured.borrow_mut().take();
        self.pane.clear();
        self.clear_stages();
        self.busy.set(false);
        self.controls();
        self.status.set_text(self.lang().text("Tabbestand oder Dokumentbasis geändert. Vorschau neu berechnen; gemeinsames Undo prüft weiterhin den vollständigen Stand.","Tab membership or document basis changed. Recalculate; joint Undo still checks the complete state."));
    }
    fn watch(self: &Rc<Self>, docs: &[Rc<Document>]) {
        for doc in docs {
            if self
                .watched
                .borrow()
                .iter()
                .any(|(d, _)| d.upgrade().is_some_and(|d| Rc::ptr_eq(&d, doc)))
            {
                continue;
            }
            let weak = Rc::downgrade(self);
            let id = doc.buffer.connect_changed(move |_| {
                if let Some(state) = weak.upgrade() {
                    state.invalidate();
                }
            });
            self.watched.borrow_mut().push((Rc::downgrade(doc), id));
        }
    }
    fn search(self: &Rc<Self>) {
        if self.busy.get() || self.restoration.borrow().is_some() {
            return;
        }
        self.invalidate();
        let Some(ui) = self.ui.upgrade() else { return };
        let captured = match capture(&ui) {
            Ok(c) if !c.docs.is_empty() => c,
            Ok(_) => {
                self.status.set_text(self.lang().text(
                    "Keine editierbaren Quelltexttabs verfügbar.",
                    "No editable source tabs available.",
                ));
                return;
            }
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        let locale = match self.current_locale() {
            Ok(locale) => locale,
            Err(error) => {
                self.status.set_text(&error);
                return;
            }
        };
        let completion_locale = locale.clone();
        self.watch(&captured._members);
        let inputs = captured.snapshots.clone();
        *self.captured.borrow_mut() = Some(captured);
        let generation = self.generation.get();
        let definition = self.definition.clone();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let lang = self.lang();
        self.busy.set(true);
        self.controls();
        self.status.set_text(lang.text(
            "Alle Texte und Zwischenstufen werden vollständig berechnet …",
            "Calculating every text and intermediate stage completely …",
        ));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                calculate(
                    &definition,
                    inputs,
                    generation,
                    lang,
                    locale.as_ref(),
                    &cancel,
                )
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.alive() && s.generation.get() == generation)
                else {
                    return;
                };
                state.busy.set(false);
                if !state.locale_matches(completion_locale.as_ref()) {
                    state.invalidate_locale();
                    return;
                }
                let Some(ui) = state.ui.upgrade() else { return };
                let current = capture(&ui);
                let valid = state.captured.borrow().as_ref().is_some_and(|c| {
                    current
                        .as_ref()
                        .is_ok_and(|now| now.binding == c.binding && now.snapshots == c.snapshots)
                });
                if !valid {
                    state.invalidate();
                    return;
                }
                match result {
                    Ok(computed) => {
                        let c = state.captured.borrow();
                        let c = c.as_ref().unwrap();
                        let labels = c.labels.clone();
                        let items = computed
                            .batch
                            .documents()
                            .iter()
                            .zip(&labels)
                            .zip(&computed.flows)
                            .map(|((doc, label), flow)| approval::Item {
                                label: format!(
                                    "{}{} · {}",
                                    label,
                                    locale_detail(flow.locale(), lang),
                                    if flow.source() == flow.output() {
                                        lang.text("unverändert", "unchanged")
                                    } else {
                                        lang.text("geändert", "changed")
                                    }
                                ),
                                preview: doc.preview(),
                            })
                            .collect();
                        let locale_text = locale_detail(computed.locale(), lang);
                        *state.pending.borrow_mut() = Some(Arc::new(computed));
                        state.stage_docs.set_model(Some(&gtk::StringList::new(
                            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
                        )));
                        state.stage_docs.set_selected(0);
                        state.pane.set_items(items);
                        state.status.set_text(&format!(
                            "{} {} · {} {}{}",
                            c.docs.len(),
                            lang.text("vollständige Tabs", "complete tabs"),
                            c._members.len() - c.docs.len(),
                            lang.text(
                                "gesperrte Ansichten ausgelassen und gebunden",
                                "locked views skipped and bound"
                            ),
                            locale_text
                        ));
                    }
                    Err(e) => {
                        state.pending.borrow_mut().take();
                        state.status.set_text(&e);
                    }
                }
                state.controls();
                state.update_stages();
            },
        );
    }
    fn apply(self: &Rc<Self>) {
        if self.busy.get() || !self.pane.root.is_mapped() {
            return;
        }
        let Some(computed) = self.pending.borrow().clone() else {
            return;
        };
        if !self.locale_matches(computed.locale()) {
            self.invalidate_locale();
            return;
        }
        let locale = computed.locale().cloned();
        let completion_locale = locale.clone();
        let Some(ui) = self.ui.upgrade() else { return };
        let now = match capture(&ui) {
            Ok(c) => c,
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        if self
            .captured
            .borrow()
            .as_ref()
            .is_none_or(|c| c.binding != now.binding)
        {
            self.invalidate();
            return;
        }
        let Some(approved) = self.pane.approvals() else {
            return;
        };
        let generation = self.generation.get();
        let inputs = now.snapshots;
        let definition = self.definition.clone();
        let lang = self.lang();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                for (flow, input) in computed.flows.iter().zip(&inputs) {
                    flow.apply_with_locale(
                        &input.text,
                        input.revision,
                        generation,
                        &definition,
                        None,
                        locale.as_ref(),
                        &cancel,
                    )
                    .map_err(|e| super::message(&e, lang))?;
                }
                let plan = computed
                    .batch
                    .plan(&inputs, generation, &approved, &cancel)
                    .map_err(|e| error_text(lang, &e))?;
                if plan
                    .outputs()
                    .iter()
                    .zip(&inputs)
                    .all(|(text, input)| text == &input.text)
                {
                    return Err(lang
                        .text(
                            "Keine wirksamen Änderungen freigegeben.",
                            "No effective changes approved.",
                        )
                        .into());
                }
                for text in plan.outputs() {
                    crate::text_limits::validate(text, lang)?;
                }
                Ok(plan)
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.alive() && s.generation.get() == generation)
                else {
                    return;
                };
                state.busy.set(false);
                match result {
                    Ok(plan) => state.apply_plan(plan, completion_locale.as_ref()),
                    Err(e) => {
                        state.invalidate();
                        state.status.set_text(&e);
                    }
                }
            },
        );
    }
    fn apply_plan(&self, plan: BatchPlan, locale: Option<&TitlecaseLocale>) {
        if !self.locale_matches(locale) {
            self.invalidate_locale();
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let now = match capture(&ui) {
            Ok(c) => c,
            Err(e) => {
                self.controls();
                self.status.set_text(&e);
                return;
            }
        };
        if self
            .captured
            .borrow()
            .as_ref()
            .is_none_or(|c| c.binding != now.binding)
            || plan
                .validate(&now.snapshots, self.generation.get(), &self.cancel.borrow())
                .is_err()
        {
            self.invalidate();
            return;
        }
        self.changing.set(true);
        for (doc, text) in now.docs.iter().zip(plan.outputs()) {
            replace(doc, text);
        }
        let after = capture(&ui);
        self.changing.set(false);
        match after.and_then(|after| {
            plan.bind_restoration(after.snapshots.clone(), &Cancellation::default())
                .map(|restoration| Receipt {
                    restoration: Arc::new(restoration),
                    binding: after.binding,
                    _members: after._members,
                })
                .map_err(|e| error_text(self.lang(), &e))
        }) {
            Ok(receipt) => {
                *self.restoration.borrow_mut() = Some(receipt);
            }
            Err(e) => {
                self.status.set_text(&e);
                self.pending.borrow_mut().take();
                self.captured.borrow_mut().take();
                self.pane.clear();
                self.clear_stages();
                self.controls();
                return;
            }
        }
        self.pending.borrow_mut().take();
        self.captured.borrow_mut().take();
        self.pane.clear();
        self.clear_stages();
        self.controls();
        self.status.set_text(self.lang().text("Freigegebene Tabs im Editor übernommen. Dateien nicht geschrieben. Gemeinsames Undo bindet auch unveränderte und nicht freigegebene Tabs.","Approved tabs applied in the editor. No files written. Joint Undo also binds unchanged and unapproved tabs."));
    }
    fn undo(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let now = match capture(&ui) {
            Ok(c) => c,
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        let receipt = self.restoration.borrow();
        let Some(receipt) = receipt.as_ref() else {
            return;
        };
        if receipt.binding != now.binding {
            self.status
                .set_text(&error_text(self.lang(), &fastra_core::Error::Stale));
            return;
        }
        let restoration = receipt.restoration.clone();
        let inputs = now.snapshots.clone();
        let binding = now.binding;
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                restoration
                    .restore(&inputs, &cancel)
                    .map(|texts| (texts, inputs, binding))
                    .map_err(|e| error_text(lang, &e))
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.alive() && s.generation.get() == generation)
                else {
                    return;
                };
                state.busy.set(false);
                let Some(ui) = state.ui.upgrade() else { return };
                match (result, capture(&ui)) {
                    (Ok((texts, expected, binding)), Ok(now))
                        if expected == now.snapshots
                            && binding == now.binding
                            && state.cancel.borrow().check().is_ok() =>
                    {
                        state.changing.set(true);
                        for (doc, text) in now.docs.iter().zip(texts) {
                            replace(doc, &text);
                        }
                        state.changing.set(false);
                        state.restoration.borrow_mut().take();
                        state.status.set_text(lang.text(
                            "Gemeinsame Übernahme zurückgesetzt. Dateien unverändert.",
                            "Joint application restored. Files unchanged.",
                        ));
                    }
                    (Err(e), _) => state.status.set_text(&e),
                    _ => state
                        .status
                        .set_text(&error_text(lang, &fastra_core::Error::Stale)),
                }
                state.controls();
            },
        );
    }
    fn update_stages(self: &Rc<Self>) {
        let selected = self.stage_docs.selected() as usize;
        let pending = self.pending.borrow();
        let Some(computed) = pending.as_ref() else {
            return;
        };
        let Some(flow) = computed.flows.get(selected) else {
            return;
        };
        let names: Vec<_> = flow
            .steps
            .iter()
            .map(|step| {
                format!(
                    "{}. {}",
                    step.index + 1,
                    super::title(&step.kind, self.lang())
                )
            })
            .collect();
        self.stages.set_model(Some(&gtk::StringList::new(
            &names.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        self.stages.set_selected(0);
        drop(pending);
        self.show_stage();
    }
    fn show_stage(self: &Rc<Self>) {
        self.stage_cancel.borrow().cancel();
        let generation = self.stage_generation.get().wrapping_add(1);
        self.stage_generation.set(generation);
        self.stage_before.buffer().set_text("");
        self.stage_after.buffer().set_text("");
        let pair = self.pending.borrow().as_ref().and_then(|p| {
            p.flows
                .get(self.stage_docs.selected() as usize)
                .and_then(|flow| {
                    flow.steps.get(self.stages.selected() as usize).map(|step| {
                        (
                            step.before.clone(),
                            step.after.clone(),
                            flow.locale().cloned(),
                        )
                    })
                })
        });
        let Some((before, after, locale)) = pair else {
            return;
        };
        let exact = self.stage_exact.is_active();
        let cancel = Cancellation::default();
        *self.stage_cancel.borrow_mut() = cancel.clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        self.stage_status.set_text(lang.text(
            "Vollständige Zwischenstufe wird dargestellt …",
            "Rendering complete intermediate stage …",
        ));
        git_view::background(
            move || {
                let render = |text: Arc<str>| -> Result<Arc<str>, String> {
                    let text = if exact {
                        Arc::from(
                            fastra_core::display::escaped_text(&text, &cancel, 16 * 1024 * 1024)
                                .map_err(|e| error_text(lang, &e))?,
                        )
                    } else {
                        text
                    };
                    crate::text_limits::validate(&text, lang)?;
                    Ok(text)
                };
                Ok((render(before)?, render(after)?))
            },
            move |result| {
                let Some(state) = weak.upgrade().filter(|s| {
                    s.alive()
                        && s.stage_generation.get() == generation
                        && s.pending.borrow().is_some()
                }) else {
                    return;
                };
                if !state.locale_matches(locale.as_ref()) {
                    state.invalidate_locale();
                    return;
                }
                match result {
                    Ok((before, after)) => {
                        state.stage_before.buffer().set_text(&before);
                        state.stage_after.buffer().set_text(&after);
                        state.stage_status.set_text(&format!("{}{}", lang.text("Vollständige Stufe; Freigaben gelten ausschließlich dem Endergebnis im ersten Reiter.","Complete stage; approvals refer only to the final result on the first tab."), locale_detail(locale.as_ref(), lang)));
                    }
                    Err(e) => state.stage_status.set_text(&e),
                }
            },
        );
    }
}
fn locale_detail(locale: Option<&TitlecaseLocale>, lang: Language) -> String {
    locale.map_or_else(String::new, |locale| {
        format!(
            " · {}: {}",
            lang.text("Text-Systemlocale", "System text locale"),
            locale.as_str()
        )
    })
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
fn safe(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if c.is_control() {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}
pub(super) fn open(ui: &Rc<Ui>, definition: Workflow) -> Rc<State> {
    let lang = ui.lang;
    let window = git_view::window(
        ui,
        lang.text(
            "Textablauf · alle editierbaren Tabs",
            "Text workflow · all editable tabs",
        ),
        false,
    );
    window.set_default_size(1100, 850);
    window.set_size_request(620, 660);
    let root = git_view::column();
    root.append(&git_view::label(&format!(
        "{}: {}",
        lang.text("Unveränderliche Ablaufkopie", "Immutable workflow copy"),
        safe(&definition.name)
    )));
    root.append(&git_view::label(lang.text("Nur Editorinhalte; Dateien separat speichern. Änderungen im Definitionsfenster ändern diesen Auftrag nicht. Für einen anderen Ablauf ein neues Fenster öffnen.","Editor contents only; save files separately. Definition-window changes do not change this job. Open a new window for another workflow.")));
    root.append(&git_view::label(lang.text("Grenzen: 32 editierbare Tabs, 4 MiB je Text, 16 MiB Eingaben/Ausgaben, 32 MiB Zwischenstufen, 15 Sekunden insgesamt.","Limits: 32 editable tabs, 4 MiB per text, 16 MiB sources/outputs, 32 MiB intermediate stages, 15 seconds total.")));
    let definition_details = gtk::Expander::new(Some(
        lang.text("Verwendete Definition prüfen", "Review the definition used"),
    ));
    let details = git_view::output();
    let yes = |value| {
        if value {
            lang.text("ja", "yes")
        } else {
            lang.text("nein", "no")
        }
    };
    let text=definition.steps.iter().enumerate().map(|(i,s)|format!(
        "{}. {} · {}\n{}: {:?} → {:?}\n{}: {:?}\nRegex: {} · {}: {} · {}: {} · {}: {}\n{}: {} · {}: {} · {}: {} · {}: {}\n\n",
        i+1,super::title(&s.kind,lang),if s.enabled{lang.text("aktiv","enabled")}else{lang.text("ausgelassen","disabled")},
        lang.text("Ersetzen","Replace"),s.find,s.replacement,lang.text("Argument","Argument"),s.argument,
        yes(s.regex),lang.text("Groß-/Kleinschreibung","Case-sensitive"),yes(s.case_sensitive),lang.text("Ganze Wörter","Whole words"),yes(s.whole_word),lang.text("Wörtliche Platzhalterersetzung","Literal wildcard replacement"),yes(s.literal_wildcard),
        lang.text("Tabulatorbreite","Tab width"),s.tab_width,lang.text("Einrückungsbreite","Indent width"),s.indent_width,lang.text("Tabs verwenden","Use tabs"),yes(s.uses_tabs),lang.text("Umbruchspalte","Wrap column"),s.wrap_column)).collect::<String>();
    details.buffer().set_text(&text);
    let scroll = git_view::scroll(&details);
    scroll.set_min_content_height(110);
    scroll.set_max_content_height(160);
    scroll.set_vexpand(false);
    definition_details.set_child(Some(&scroll));
    root.append(&definition_details);
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(6)
        .row_spacing(6)
        .build();
    let search =
        gtk::Button::with_label(lang.text("Vorschau neu berechnen", "Recalculate preview"));
    let apply =
        gtk::Button::with_label(lang.text("Freigegebene Tabs übernehmen", "Apply approved tabs"));
    let undo = gtk::Button::with_label(lang.text("Gemeinsam rückgängig", "Undo jointly"));
    let forget = gtk::Button::with_label(lang.text(
        "Gemeinsame Rücknahme verwerfen",
        "Discard joint restoration",
    ));
    let cancel_button =
        gtk::Button::with_label(lang.text("Berechnung abbrechen", "Cancel calculation"));
    for button in [&search, &apply, &undo, &forget, &cancel_button] {
        actions.insert(button, -1);
    }
    root.append(&actions);
    let status = git_view::label("");
    root.append(&status);
    let pane = approval::ApprovalPane::new(lang);
    let notebook = gtk::Notebook::new();
    notebook.set_vexpand(true);
    notebook.append_page(
        &pane.root,
        Some(&gtk::Label::new(Some(lang.text(
            "Endergebnisse und Freigaben",
            "Final results and approvals",
        )))),
    );
    let stages_root = git_view::column();
    let stage_docs = git_view::file_dropdown();
    let stages = gtk::DropDown::from_strings(&[]);
    let stage_exact = gtk::CheckButton::with_label(lang.text("Exakte Zeichen", "Exact characters"));
    stages_root.append(&stage_docs);
    stages_root.append(&stages);
    stages_root.append(&stage_exact);
    let stage_status = git_view::label("");
    stages_root.append(&stage_status);
    let stage_before = git_view::output();
    let stage_after = git_view::output();
    let pair = gtk::Paned::new(gtk::Orientation::Horizontal);
    for (start, title, view) in [
        (
            true,
            lang.text("Vorher · vollständig", "Before · complete"),
            &stage_before,
        ),
        (
            false,
            lang.text("Nachher · vollständig", "After · complete"),
            &stage_after,
        ),
    ] {
        let col = git_view::column();
        col.append(&git_view::label(title));
        col.append(&git_view::scroll(view));
        if start {
            pair.set_start_child(Some(&col));
        } else {
            pair.set_end_child(Some(&col));
        }
    }
    git_view::balance_panes(&pair);
    pair.set_vexpand(true);
    stages_root.append(&pair);
    notebook.append_page(
        &stages_root,
        Some(&gtk::Label::new(Some(
            lang.text("Zwischenstufen", "Intermediate stages"),
        ))),
    );
    root.append(&notebook);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        definition,
        pane,
        status,
        search,
        apply,
        undo,
        forget,
        cancel_button,
        stage_docs,
        stages,
        stage_exact,
        stage_before,
        stage_after,
        stage_status,
        busy: Cell::new(false),
        changing: Cell::new(false),
        generation: Cell::new(1),
        stage_generation: Cell::new(1),
        stage_cancel: RefCell::new(Cancellation::default()),
        cancel: RefCell::new(Cancellation::default()),
        pending: RefCell::new(None),
        captured: RefCell::new(None),
        restoration: RefCell::new(None),
        watched: RefCell::new(Vec::new()),
    });
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
            s.invalidate();
            s.status.set_text(s.lang().text(
                "Abgebrochen. Editorinhalte unverändert.",
                "Cancelled. Editor contents unchanged.",
            ));
        }
    });
    let weak = Rc::downgrade(&state);
    state.forget.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.busy.get() {
                s.restoration.borrow_mut().take();
                s.controls();
                s.status.set_text(s.lang().text(
                    "Rücknahmebindung verworfen; Texte unverändert.",
                    "Restoration binding discarded; texts unchanged.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    state.pane.on_changed(Rc::new(move |valid| {
        if let Some(s) = weak.upgrade() {
            s.apply.set_sensitive(
                valid
                    && s.pane.root.is_mapped()
                    && !s.busy.get()
                    && s.pending
                        .borrow()
                        .as_ref()
                        .is_some_and(|computed| s.locale_matches(computed.locale()))
                    && s.restoration.borrow().is_none(),
            );
        }
    }));
    let weak = Rc::downgrade(&state);
    state.pane.root.connect_map(move |_| {
        if let Some(state) = weak.upgrade() {
            if state.alive() {
                state.controls();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    state.stage_docs.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.update_stages();
        }
    });
    let weak = Rc::downgrade(&state);
    state.stages.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.show_stage();
        }
    });
    let weak = Rc::downgrade(&state);
    state.stage_exact.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.show_stage();
        }
    });
    let weak = Rc::downgrade(&state);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !s.alive() {
            return glib::ControlFlow::Continue;
        }
        let locale_changed = s
            .pending
            .borrow()
            .as_ref()
            .is_some_and(|computed| !s.locale_matches(computed.locale()));
        if locale_changed {
            s.invalidate_locale();
            return glib::ControlFlow::Continue;
        }
        if let Some(ui) = s.ui.upgrade() {
            let changed = s
                .captured
                .borrow()
                .as_ref()
                .is_some_and(|c| members(&ui).is_ok_and(|m| m != c.binding));
            if changed {
                s.invalidate();
            }
        }
        glib::ControlFlow::Continue
    });
    git_view::hold(&window, state.clone(), |s| s.invalidate());
    #[cfg(debug_assertions)]
    TEST_STATE.with(|slot| *slot.borrow_mut() = Some(Rc::downgrade(&state)));
    window.present();
    state.search();
    state
}

#[cfg(debug_assertions)]
#[path = "workflow_tabs/gui_test.rs"]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}

#[cfg(debug_assertions)]
thread_local! {static TEST_STATE: RefCell<Option<Weak<State>>> = const { RefCell::new(None) };}

#[cfg(test)]
mod tests {
    use super::*;
    fn flow() -> Workflow {
        Workflow {
            id: fastra_workflow::new_id().unwrap(),
            revision: fastra_workflow::new_id().unwrap(),
            name: "bounded".into(),
            steps: (0..16)
                .map(|_| {
                    let mut step = fastra_workflow::Step::new("prefixLines").unwrap();
                    step.argument = "a".into();
                    step
                })
                .collect(),
            extra: Default::default(),
        }
    }
    fn docs(count: usize, text: &str) -> Vec<DocumentSnapshot> {
        (0..count)
            .map(|n| DocumentSnapshot {
                id: n.to_string(),
                revision: 1,
                text: text.into(),
            })
            .collect()
    }
    #[test]
    fn aggregate_resource_budget_is_enforced_across_documents() {
        let definition = flow();
        let cancel = Cancellation::default();
        let text = format!("{}\n", "a".repeat(65500)).repeat(4);
        let result = calculate(
            &definition,
            docs(8, &text),
            3,
            Language(false),
            None,
            &cancel,
        );
        assert!(result.is_err());
        let result = calculate(
            &definition,
            docs(2, "a\n"),
            3,
            Language(false),
            None,
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(result.flows.len(), 2);
        assert_eq!(result.flows[0].steps.len(), 16);
        assert_eq!(result.flows[0].output(), "aaaaaaaaaaaaaaaaa\n");
    }
    #[test]
    fn source_membership_budget_and_cancel_precede_any_plan() {
        let definition = flow();
        let cancel = Cancellation::default();
        assert!(calculate(
            &definition,
            docs(33, "a"),
            3,
            Language(false),
            None,
            &cancel
        )
        .is_err());
        assert!(calculate(
            &definition,
            docs(5, &"a".repeat(4 * 1024 * 1024)),
            3,
            Language(false),
            None,
            &cancel
        )
        .is_err());
        cancel.cancel();
        assert!(calculate(&definition, docs(1, "a"), 3, Language(false), None, &cancel).is_err());
    }
}
