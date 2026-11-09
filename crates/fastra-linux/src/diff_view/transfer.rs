use super::*;
use result::Model;
pub(super) struct Preview {
    pub(super) window: gtk::Window,
    pub(super) view: Rc<view::View>,
    owner: Weak<State>,
    model: Model,
    pub(super) plan: Arc<fastra_diff::TransferPlan>,
    side: usize,
    request: u64,
    pub(super) apply: gtk::Button,
    cancel: Cancel,
    pub(super) busy: Cell<bool>,
    rich: RefCell<Option<crate::rich_editor::source_replacement::Prepared>>,
    committing: Cell<bool>,
    progress: gtk::Spinner,
    close: gtk::Button,
}
#[cfg(debug_assertions)]
thread_local! {static LAST:RefCell<Weak<Preview>>=const {RefCell::new(Weak::new())};}
#[cfg(debug_assertions)]
pub(super) fn test_preview() -> Option<Rc<Preview>> {
    LAST.with(|last| last.borrow().upgrade())
        .filter(|p| p.window.is_visible())
}
impl Preview {
    fn working(&self, working: bool, committing: bool) {
        self.progress.set_visible(working);
        if working {
            self.progress.start();
        } else {
            self.progress.stop();
        }
        self.close.set_sensitive(!committing);
        let lang = self
            .owner
            .upgrade()
            .map_or(Language(false), |state| state.lang);
        self.close.set_label(if working && !committing {
            lang.text("Abbrechen", "Cancel")
        } else {
            lang.text("Schließen", "Close")
        });
    }
    fn current(&self) -> Option<Rc<State>> {
        self.owner.upgrade().filter(|state| {
            state.request.get() == self.request
                && state.current()
                && state.active()
                && state
                    .model
                    .borrow()
                    .as_ref()
                    .is_some_and(|model| model.generation == self.model.generation)
        })
    }
    fn apply(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(state) = self.current() else {
            self.view.error(
                self.owner
                    .upgrade()
                    .map(|state| state.lang)
                    .unwrap_or(Language(false))
                    .text(
                        "Vergleich geändert. Übernahmevorschau erneut öffnen.",
                        "Comparison changed; reopen the transfer preview.",
                    ),
            );
            self.apply.set_sensitive(false);
            return;
        };
        let Some(ui) = state.live() else { return };
        let Some(target) = state.origins.borrow()[self.side]
            .as_ref()
            .and_then(|origin| origin.current(&ui))
        else {
            return;
        };
        if !sources::destination_ready(&target) {
            self.apply.set_sensitive(false);
            return;
        }
        self.busy.set(true);
        self.working(true, false);
        self.apply.set_sensitive(false);
        state.busy.set(true);
        state.controls();
        let model = self.model.clone();
        let plan = self.plan.clone();
        let cancel = self.cancel.clone();
        let lang = state.lang;
        let owner = Rc::downgrade(self);
        support::background(
            move || {
                for input in &model.inputs {
                    input.verify_file(&cancel.io)?;
                }
                let output = plan
                    .apply(
                        &model.inputs[0].snapshot,
                        &model.inputs[1].snapshot,
                        model.generation,
                        &cancel.diff,
                    )
                    .map_err(|e| diff_error(lang, e))?;
                crate::text_limits::validate(&output.text, lang)?;
                #[cfg(debug_assertions)]
                if std::env::var_os("FASTRA_DIFF_GUARDS_SELFTEST").is_some() {
                    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
                    let pause = root.join("pause-apply");
                    if pause.exists() {
                        std::fs::write(root.join("apply-worker-ready"), b"complete byte verification finished").map_err(|error| error.to_string())?;
                        while pause.exists() {
                            cancel.io.check().map_err(|error| error.to_string())?;
                            std::thread::sleep(std::time::Duration::from_millis(10));
                        }
                    }
                }
                Ok(output)
            },
            move |result| {
                let Some(preview) = owner
                    .upgrade()
                    .filter(|preview| preview.window.is_visible())
                else {
                    return;
                };
                preview.busy.set(false);
                preview.working(false, false);
                if let Some(state) = preview
                    .owner
                    .upgrade()
                    .filter(|state| state.request.get() == preview.request)
                {
                    state.busy.set(false);
                    state.controls();
                }
                let Some(state) = preview.current() else {
                    preview.view.error(lang.text(
                        "Vergleichsquelle oder Zieldokument geändert. Nichts übernommen.",
                        "Comparison source or destination changed. Nothing applied.",
                    ));
                    return;
                };
                state.busy.set(false);
                state.controls();
                let Some(ui) = state.live() else { return };
                let Some(target) = state.origins.borrow()[preview.side]
                    .as_ref()
                    .and_then(|origin| origin.current(&ui))
                    .filter(|doc| sources::destination_ready(doc))
                else {
                    return;
                };
                let result = result.and_then(|output| {
                    // Der Worker prüft die vollständige Basis; unmittelbar vor der
                    // Speicheränderung müssen auch die kurzen Dateibindungen noch stimmen.
                    for input in &preview.model.inputs {
                        input.verify_identity(&preview.cancel.io)?;
                    }
                    Ok(output)
                });
                match result {
                    Ok(output) => {
                        let editor = target
                            .rich
                            .borrow()
                            .clone()
                            .filter(|editor| editor.active.get());
                        if let Some(editor) = editor {
                            let Some(prepared) = preview.rich.borrow_mut().take() else {
                                return;
                            };
                            state.busy.set(true);
                            state.controls();
                            preview.committing.set(true);
                            preview.busy.set(true);
                            preview.working(true, true);
                            let expected = preview.model.inputs[preview.side].snapshot.text.clone();
                            let held = preview.clone();
                            editor.replace_source(
                                prepared,
                                &expected,
                                Box::new(move |result| {
                                    held.committing.set(false);
                                    held.busy.set(false);
                                    held.working(false, false);
                                    state.busy.set(false);
                                    state.controls();
                                    match result {
                                        Ok(()) => {
                                            held.window.close();
                                            state.start();
                                        }
                                        Err(error) => held.view.error(&error),
                                    }
                                }),
                            );
                            return;
                        }
                        crate::source_panes::replace_result(&target.buffer, &output.text);
                        ui.status.set_text(lang.text("Vergleichsblock im Dokument übernommen; Datei separat speichern. Einmal Rückgängig stellt den Ausgangstext wieder her.","Comparison block applied to the document; save separately. One Undo restores the original text."));
                        preview.window.close();
                        state.start();
                    }
                    Err(error) => {
                        state.model.borrow_mut().take();
                        state.controls();
                        preview.view.error(&error);
                    }
                }
            },
        );
    }
}
pub(super) fn prepare(state: &Rc<State>, side: usize) {
    if state.busy.get() || !state.current() || !state.active() {
        return;
    }
    let Some(ui) = state.live() else { return };
    let Some(target) = state.origins.borrow()[side]
        .as_ref()
        .and_then(|origin| origin.current(&ui))
    else {
        return;
    };
    if !sources::destination_ready(&target) {
        return;
    }
    let Some(model) = state.model.borrow().clone() else {
        return;
    };
    let index = state.view.selection.selected() as usize;
    let Some(block) = model.comparison.blocks().get(index) else {
        return;
    };
    let id = block.id;
    let cancel = Cancel::default();
    *state.cancel.borrow_mut() = cancel.clone();
    state.busy.set(true);
    state.preparing.set(true);
    state.controls();
    state.view.status.set_text(state.lang.text(
        "Übernahmevorschau wird berechnet …",
        "Calculating transfer preview …",
    ));
    let owner = Rc::downgrade(state);
    let request = state.request.get();
    let lang = state.lang;
    let expected = model.clone();
    let rich_target = target.is_rich_active().then(|| target.disk_path());
    support::background(
        move || {
            for input in &model.inputs {
                input.verify_file(&cancel.io)?;
            }
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_DIFF_GUARDS_SELFTEST").is_some() {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
                let pause = root.join("pause-transfer");
                if pause.exists() {
                    std::fs::write(
                        root.join("transfer-worker-ready"),
                        b"native preparation cancellation gate",
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
            let plan = Arc::new(
                model
                    .comparison
                    .prepare_transfer(
                        &model.inputs[0].snapshot,
                        &model.inputs[1].snapshot,
                        model.generation,
                        &[id],
                        if side == 0 {
                            fastra_diff::Direction::ToLeft
                        } else {
                            fastra_diff::Direction::ToRight
                        },
                        &cancel.diff,
                    )
                    .map_err(|e| diff_error(lang, e))?,
            );
            crate::text_limits::validate(plan.output(), lang)?;
            let rich = rich_target
                .map(|path| {
                    crate::rich_editor::source_replacement::prepare(
                        plan.output(),
                        path.as_deref(),
                        lang,
                        &cancel.viewer,
                    )
                })
                .transpose()?;
            let comparison = fastra_diff::Comparison::compare(
                model.inputs[side].snapshot.clone(),
                fastra_diff::TextSnapshot {
                    document_id: "transfer-output".into(),
                    revision: 0,
                    text: plan.output().into(),
                },
                0,
                fastra_diff::Options::default(),
                fastra_diff::Limits::default(),
                &cancel.diff,
            )
            .map_err(|e| diff_error(lang, e))?;
            let display = presentation::Presentation::build_exact(&comparison, [&model.inputs[side].snapshot.text, plan.output()], &cancel.diff).map_err(|error| {
                if error.contains("limit") || error.contains("32 MiB") { lang.text("Die vollständige exakte Vorschau überschreitet 32 MiB je Spalte. Nichts übernommen.", "The complete exact preview exceeds 32 MiB per column. Nothing applied.").to_owned() } else { error }
            })?;
            let labels = display.labels(lang);
            for input in &model.inputs {
                input.verify_file(&cancel.io)?;
            }
            Ok((plan, display, labels, cancel, rich))
        },
        move |result| {
            let Some(state) = owner
                .upgrade()
                .filter(|state| state.request.get() == request)
            else {
                return;
            };
            state.busy.set(false);
            state.preparing.set(false);
            state.controls();
            if !state.current() || !state.active() {
                state.error(lang.text(
                    "Vergleichsquelle geändert. Keine Übernahmevorschau geöffnet.",
                    "Comparison source changed. No transfer preview opened.",
                ));
                return;
            }
            let (plan, display, labels, cancel, rich) = match result {
                Ok(value) => value,
                Err(error) => {
                    state.error(&error);
                    return;
                }
            };
            let Some(ui) = state.live() else { return };
            state.view.status.set_text(lang.text("Übernehmen ist nur in zugeordnete offene editierbare Dokumente möglich. Dateien werden dabei nicht gespeichert.", "Transfers require an associated open editable document. Files are not saved."));
            let window = support::window(
                &ui,
                lang.text("Vergleichsblock übernehmen", "Transfer comparison block"),
                true,
            );
            window.set_default_size(900, 650);
            window.set_size_request(620, 440);
            window.set_titlebar(None::<&gtk::Widget>);
            window.set_decorated(false);
            window.add_css_class("fastra-tool");
            let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
            let heading = gtk::Box::new(gtk::Orientation::Vertical, 8);
            heading.set_margin_top(12);
            heading.set_margin_bottom(12);
            heading.set_margin_start(12);
            heading.set_margin_end(12);
            let title = support::label(lang.text("Blockübernahme prüfen", "Review block transfer"));
            title.add_css_class("heading");
            heading.append(&title);
            let name = support::label(&state.choices.borrow()[side].as_ref().unwrap().name(lang));
            heading.append(&name);
            let explanation = support::label(lang.text("Anwenden ändert nur das Zieldokument im Speicher und besitzt natives Undo. Speichere das Dokument anschließend wie gewohnt.", "Apply changes only the destination document in memory, with native Undo. Save the document afterward as usual."));
            explanation.add_css_class("dim-label");
            heading.append(&explanation);
            if display.annotated {
                let note = support::label(lang.text("Markierungen in ⟦…⟧ zeigen Zeilenenden und exakte Unicode-Zeichen; sie werden nicht eingefügt.", "Markers in ⟦…⟧ show line endings and exact Unicode characters; they are not inserted."));
                note.add_css_class("dim-label");
                heading.append(&note);
            }
            root.append(&heading);
            root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
            let view = view::View::new(lang, &window);
            view.show_transfer_controls(false);
            view.export.set_visible(false);
            view.names[0].set_text(lang.text("Vorher", "Before"));
            view.names[1].set_text(lang.text("Nachher", "After"));
            view.status.set_text(lang.text("Vollständiges Zieldokument prüfen. Übernehmen ändert nur dieses offene Dokument im Speicher und ist ein nativer Undo-Schritt. Die Datei wird nicht gespeichert.","Review the complete destination document. Apply changes only this open document in memory, with one native Undo. The file is not saved."));
            root.append(&view.root);
            let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            footer.set_margin_top(8);
            footer.set_margin_bottom(8);
            footer.set_margin_start(12);
            footer.set_margin_end(12);
            let cancel_button = gtk::Button::with_label(lang.text("Schließen", "Close"));
            let close = window.downgrade();
            cancel_button.connect_clicked(move |_| {
                if let Some(window) = close.upgrade() {
                    window.close();
                }
            });
            footer.append(&cancel_button);
            let space = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            space.set_hexpand(true);
            footer.append(&space);
            let apply = gtk::Button::with_label(lang.text("Block übernehmen", "Apply block"));
            let progress = gtk::Spinner::new();
            progress.set_visible(false);
            progress.update_property(&[gtk::accessible::Property::Label(
                lang.text("Übernahme läuft", "Applying"),
            )]);
            footer.append(&progress);
            apply.add_css_class("suggested-action");
            apply.set_sensitive(false);
            footer.append(&apply);
            root.append(&footer);
            window.set_child(Some(&root));
            let preview = Rc::new(Preview {
                window: window.clone(),
                view,
                owner: Rc::downgrade(&state),
                model: expected,
                plan,
                side,
                request,
                apply,
                cancel,
                busy: Cell::new(false),
                rich: RefCell::new(rich),
                committing: Cell::new(false),
                progress,
                close: cancel_button,
            });
            window.set_default_widget(Some(&preview.apply));
            let owner = Rc::downgrade(&preview);
            window.connect_close_request(move |_| {
                if owner.upgrade().is_some_and(|p| p.committing.get()) {
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            });
            let keys = gtk::EventControllerKey::new();
            let close = window.downgrade();
            keys.connect_key_pressed(move |_, key, _, _| {
                if key == gtk::gdk::Key::Escape {
                    if let Some(window) = close.upgrade() {
                        window.close();
                    }
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            });
            window.add_controller(keys);
            *state.preview.borrow_mut() = Rc::downgrade(&preview);
            #[cfg(debug_assertions)]
            LAST.with(|last| *last.borrow_mut() = Rc::downgrade(&preview));
            let owner = Rc::downgrade(&preview);
            preview.apply.connect_clicked(move |_| {
                if let Some(preview) = owner.upgrade() {
                    preview.apply();
                }
            });
            let owner = Rc::downgrade(&preview);
            preview.view.install(display, labels, lang, move || {
                if let Some(preview) = owner.upgrade() {
                    preview.apply.set_sensitive(preview.current().is_some());
                }
            });
            support::hold(&window, preview, |preview| {
                preview.cancel.cancel();
                preview.view.cancel_render();
                if let Some(state) = preview.owner.upgrade() {
                    state.busy.set(false);
                    state.controls();
                }
            });
            window.present();
        },
    );
}
