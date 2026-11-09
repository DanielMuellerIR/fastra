use super::*;

impl View {
    pub(super) fn capture(&self) -> Result<Target, Error> {
        let ui = self.ui.upgrade().ok_or(Error::Stale)?;
        let doc = self.doc.upgrade().ok_or(Error::Stale)?;
        capture_source(
            &ui,
            &doc,
            self.scope.selected() == 1,
            false,
            4 * 1024 * 1024,
            self.lang,
        )
    }
    pub(super) fn calculate_preview(self: &Rc<Self>) {
        if self.snippet {
            snippet::update_preview(self);
            return;
        }
        self.invalidate();
        let issues: Vec<String> = self
            .snapshot
            .borrow()
            .as_ref()
            .map(|snapshot| {
                let extra = if self.snippet {
                    &snapshot.library.snippets.extra
                } else {
                    &snapshot.library.workflows.extra
                };
                extra
                    .keys()
                    .map(|key| format!("archive.{}", key.escape_debug()))
                    .collect()
            })
            .unwrap_or_default();
        if !issues.is_empty() {
            self.error(Error::Unsupported(issues));
            return;
        }
        if let Some(Draft::Snippet(snippet)) = self.draft.borrow().as_ref() {
            if !snippet.extra.is_empty() {
                self.error(Error::Unsupported(
                    snippet
                        .extra
                        .keys()
                        .map(|key| format!("snippet.{}", key.escape_debug()))
                        .collect(),
                ));
                return;
            }
        }
        let target = match self.capture() {
            Ok(target) => target,
            Err(e) => {
                self.error(e);
                return;
            }
        };
        let Some(Draft::Flow(draft)) = self.draft.borrow().clone() else {
            return;
        };
        let locale = if draft
            .steps
            .iter()
            .any(|step| step.enabled && step.uses_text_locale())
        {
            match crate::operations::titlecase_locale() {
                Ok(locale) => Some(locale),
                Err(_) => {
                    self.error(Error::Invalid("text locale required".into()));
                    return;
                }
            }
        } else {
            None
        };
        let completion_locale = locale.clone();
        let source = target.source.clone();
        let range = target.range;
        let revision = target.revision;
        let generation = self.generation.get();
        let exact = self.exact.is_active();
        let lang = self.lang;
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.status.set_text(self.lang.text(
            "Vollständige Vorschau wird berechnet …",
            "Calculating a complete preview …",
        ));
        self.preview_job.set(true);
        self.run(
            move || {
                let started=std::time::Instant::now();
                let result=workflow::preview_with_locale(&draft,&source,range,revision,generation,locale.as_ref(),&cancel)?;
                display::validate(&result, &source, lang, &cancel)?;
                let display=if exact {Some(display::prepare(&result,lang,&cancel)?)}else{None};
                cancel.check()?;
                if started.elapsed()>Duration::from_secs(5){return Err(Error::Limit);}
                Ok(Calculation{result,display})
            },
            move |view, calculation| {
                let Calculation{result,display}=calculation;
                let current = view.capture();
                let current = current.is_ok_and(|current| {
                    target.pane.valid(&current.doc) && current.revision == target.revision && current.source == target.source
                        && current.range == target.range && Rc::ptr_eq(&current.doc, &target.doc)
                });
                if view.generation.get() != generation || !current || completion_locale.as_ref().is_some_and(|expected| crate::operations::titlecase_locale().as_ref() != Ok(expected)) { view.error(Error::Stale); return; }
                let mut names = vec![view.lang.text("Endergebnis (ganzes Dokument)", "Final result (whole document)").to_string()];
                { let preview=&result;
                    if let Some(locale) = preview.locale() {
                        names[0].push_str(&format!(" · {}: {}", view.lang.text("Text-Systemlocale", "System text locale"), locale.as_str()));
                    }
                    for step in &preview.steps {
                        let state = if step.before == step.after { view.lang.text("unverändert", "unchanged") } else { view.lang.text("geändert", "changed") };
                        names.push(format!("{}. {} · {state}", step.index + 1, title(&step.kind, view.lang)));
                    }
                }
                *view.pending.borrow_mut() = Some(Pending { target, result, display, generation });
                view.updating.set(true);
                let names: Vec<_> = names.iter().map(String::as_str).collect();
                view.stages.set_model(Some(&gtk::StringList::new(&names)));
                view.stages.set_selected(0);
                view.updating.set(false);
                view.show_stage();
                view.status.set_text(view.lang.text(
                    "Vollständige Vorschau bereit. Schritte und Endergebnis vor der Übernahme prüfen.",
                    "Complete preview ready. Review the steps and final result before applying.",
                ));
            },
        );
    }
    pub(super) fn show_stage(&self) {
        let pending = self.pending.borrow();
        let Some(pending) = pending.as_ref() else {
            return;
        };
        let preview = &pending.result;
        let (before, after, detail) = if self.stages.selected() == 0 {
            (preview.source(),preview.output(),self.lang.text("Endergebnis enthält den vollständigen Dokumenttext einschließlich unveränderter Bereiche.","The final result includes the full document, including unchanged areas.").to_string())
        } else if let Some(step) = preview.steps.get(self.stages.selected() as usize - 1) {
            (
                &*step.before,
                &*step.after,
                format!(
                    "{}. {} · {}{}",
                    step.index + 1,
                    title(&step.kind, self.lang),
                    if step.before == step.after {
                        if matches!(
                            step.kind.as_str(),
                            "keepLinesMatching" | "deleteLinesMatching"
                        ) {
                            self.lang.text("Keine wirksame Änderung. Filter lassen den gesamten Inhalt erhalten, wenn sonst alles entfiele.","No effective change. Filters preserve the contents if all lines would be removed.")
                        } else {
                            self.lang
                                .text("Keine wirksame Änderung.", "No effective change.")
                        }
                    } else {
                        self.lang.text("Vollständiger bearbeiteter Bereich; weitere Schritte bauen hierauf auf.","Full processed range; subsequent steps build on this result.")
                    },
                    step.matches
                        .map(|n| format!(" · {} {n}", self.lang.text("Treffer:", "Matches:")))
                        .unwrap_or_default()
                ),
            )
        } else {
            return;
        };
        let detail = if let Some(locale) = preview.locale() {
            format!(
                "{detail} · {}: {}",
                self.lang.text("Text-Systemlocale", "System text locale"),
                locale.as_str()
            )
        } else {
            detail
        };
        if let Some(display) = pending.display.as_ref() {
            let Some((left, right)) = display.pairs.get(self.stages.selected() as usize) else {
                return;
            };
            self.before.buffer().set_text(left);
            self.after.buffer().set_text(right);
        } else {
            self.before.buffer().set_text(before);
            self.after.buffer().set_text(after);
        }
        self.summary.set_text(&format!(
            "{} {detail} · UTF-8: {} → {} {}",
            if pending.display.is_some() {
                self.lang.text(
                    "Exakte Zeichen (Escapes, keine Dokumentänderung).",
                    "Exact characters (escapes, no document change).",
                )
            } else {
                ""
            },
            before.len(),
            after.len(),
            self.lang.text("Bytes", "bytes")
        ));
    }
    pub(super) fn apply_preview(self: &Rc<Self>) {
        if self.snippet {
            snippet::insert(self);
            return;
        }
        let Some(pending) = self.pending.borrow_mut().take() else {
            return;
        };
        let result = (|| {
            let current = self.capture()?;
            if pending.generation != self.generation.get()
                || !pending.target.pane.valid(&current.doc)
                || current.revision != pending.target.revision
                || current.source != pending.target.source
                || current.range != pending.target.range
                || !Rc::ptr_eq(&current.doc, &pending.target.doc)
            {
                return Err(Error::Stale);
            }
            let preview = &pending.result;
            let output = {
                let draft = self.draft.borrow();
                let Some(Draft::Flow(flow)) = draft.as_ref() else {
                    return Err(Error::Stale);
                };
                let locale = if preview.locale().is_some() {
                    Some(
                        crate::operations::titlecase_locale()
                            .map_err(|_| Error::Invalid("text locale required".into()))?,
                    )
                } else {
                    None
                };
                preview
                    .apply_with_locale(
                        &current.source,
                        current.revision,
                        self.generation.get(),
                        flow,
                        current.range,
                        locale.as_ref(),
                        &self.cancel.borrow(),
                    )?
                    .to_string()
            };
            if output.contains('\0') {
                return Err(Error::Unsupported(vec!["output: U+0000".into()]));
            }
            crate::text_limits::validate(&output, self.lang).map_err(Error::Invalid)?;
            if output == current.source {
                return Ok(false);
            }
            source_panes::replace_result(&current.pane.buffer, &output);
            Ok(true)
        })();
        match result{Ok(changed)=>self.status.set_text(if changed{self.lang.text("Im Dokument übernommen. Ein Rückgängig-Schritt stellt den vorherigen Text wieder her. Noch nicht auf Platte gespeichert.","Applied to the document. One Undo restores the previous text. Not saved to disk yet.")}else{self.lang.text("Keine wirksame Änderung.","No effective change.")}),Err(e)=>self.error(e)}
        self.refresh();
    }
}

pub(super) fn selection_range(doc: &Document, source: &str) -> Utf16Range {
    let buffer = source_panes::buffer(doc);
    let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
        let at = buffer.iter_at_mark(&buffer.get_insert());
        (at, at)
    });
    let start = source
        .chars()
        .take(a.offset() as usize)
        .map(char::len_utf16)
        .sum();
    let length = source
        .chars()
        .skip(a.offset() as usize)
        .take((b.offset() - a.offset()) as usize)
        .map(char::len_utf16)
        .sum();
    Utf16Range {
        location: start,
        length,
    }
}

pub(super) fn capture_source(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    selection: bool,
    allow_empty: bool,
    maximum_bytes: usize,
    lang: Language,
) -> Result<Target, Error> {
    if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, doc)) {
        return Err(Error::Invalid(lang.text(
                "Den ursprünglichen Dokumenttab aktivieren oder das Werkzeug für den anderen Tab neu öffnen.",
                "Activate the original document tab or open the tool again for the other tab.",
            ).into()));
    }
    if doc.source_edits_locked() {
        return Err(Error::Invalid(
            lang.text(
                "Zuerst zum editierbaren Quelltext wechseln und die Vorschau neu berechnen.",
                "Return to editable source mode and calculate a fresh preview.",
            )
            .into(),
        ));
    }
    if doc
        .rectangles
        .borrow()
        .iter()
        .any(|rectangle| rectangle.is_selected())
    {
        return Err(Error::Invalid(
            lang.text(
                "Rechteckauswahl zuerst mit Esc beenden; eine einzelne Auswahl wird benötigt.",
                "Clear the rectangle with Escape first; a single selection is required.",
            )
            .into(),
        ));
    }
    if doc.buffer.char_count() as usize > maximum_bytes {
        return Err(Error::Limit);
    }
    let source = buffer_text(&doc.buffer);
    if source.contains('\0') {
        return Err(Error::Unsupported(vec!["source: U+0000".into()]));
    }
    if source.len() > maximum_bytes {
        return Err(Error::Limit);
    }
    let range = if selection {
        let range = selection_range(doc, &source);
        if !allow_empty && range.length == 0 {
            return Err(Error::Invalid(
                lang.text(
                    "Zuerst Text im Dokument auswählen",
                    "Select text in the document first",
                )
                .into(),
            ));
        }
        Some(range)
    } else {
        None
    };
    let revision = doc.revision.get();
    let pane = source_panes::capture(doc).ok_or(Error::Stale)?;
    Ok(Target {
        pane,
        doc: doc.clone(),
        source,
        revision,
        range,
    })
}
