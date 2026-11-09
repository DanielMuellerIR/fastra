use super::*;

impl View {
    pub(super) fn reload_collection(self: &Rc<Self>) {
        self.invalidate();
        let config = self.config.clone();
        self.status.set_text(
            self.lang
                .text("Sammlung wird geladen …", "Loading collection …"),
        );
        self.run(
            move || Store::open(&config)?.load(),
            |v, snapshot| {
                *v.snapshot.borrow_mut() = Some(snapshot);
                v.selected.set(None);
                v.refresh_saved();
                v.choose(
                    if v.saved.model().is_some_and(|model| model.n_items() > 0) {
                        Some(0)
                    } else {
                        None
                    },
                );
                if v.snippet && v.draft.borrow().is_none() {
                    v.new_draft(false);
                }
                v.status.set_text(if v.snippet {
                    ""
                } else {
                    v.lang.text(
                        "Sammlung geladen. Wähle eine Definition oder lege eine neue an.",
                        "Collection loaded. Choose a definition or create a new one.",
                    )
                });
            },
        );
    }
    pub(super) fn refresh_saved(self: &Rc<Self>) {
        self.updating.set(true);
        let names: Vec<String> = self
            .snapshot
            .borrow()
            .as_ref()
            .map(|s| {
                if self.snippet {
                    s.library
                        .snippets
                        .snippets
                        .iter()
                        .map(|d| d.name.clone())
                        .collect()
                } else {
                    s.library
                        .workflows
                        .workflows
                        .iter()
                        .map(|d| d.name.clone())
                        .collect()
                }
            })
            .unwrap_or_default();
        let names: Vec<_> = names.iter().map(String::as_str).collect();
        self.saved.set_model(Some(&gtk::StringList::new(&names)));
        self.saved.set_selected(
            self.selected
                .get()
                .map_or(gtk::INVALID_LIST_POSITION, |i| i as u32),
        );
        self.updating.set(false);
        if self.snippet {
            snippet::refresh_library(self);
        }
    }
    pub(super) fn choose(self: &Rc<Self>, index: Option<usize>) {
        self.invalidate();
        self.selected.set(index);
        let draft = self.snapshot.borrow().as_ref().and_then(|s| {
            if self.snippet {
                index
                    .and_then(|i| s.library.snippets.snippets.get(i).cloned())
                    .map(Draft::Snippet)
            } else {
                index
                    .and_then(|i| s.library.workflows.workflows.get(i).cloned())
                    .map(Draft::Flow)
            }
        });
        if self.snippet {
            self.values.borrow_mut().clear();
        }
        *self.draft.borrow_mut() = draft;
        self.dirty.set(false);
        if self.snippet {
            self.status.set_text("");
        }
        self.selected_step.set(Some(0));
        self.refresh_saved();
        self.render_draft();
        self.refresh();
    }
    pub(super) fn new_draft(self: &Rc<Self>, copy: bool) {
        let result = (|| {
            let mut draft = if copy {
                let mut draft = self
                    .draft
                    .borrow()
                    .clone()
                    .ok_or_else(|| Error::Invalid("definition".into()))?;
                match &mut draft {
                    Draft::Flow(flow) => {
                        flow.id = workflow::new_id()?;
                        flow.revision = workflow::new_id()?;
                        flow.name = format!("{} {}", flow.name, self.lang.text("Kopie", "copy"));
                        for step in &mut flow.steps {
                            step.id = workflow::new_id()?;
                        }
                    }
                    Draft::Snippet(snippet) => {
                        snippet.id = workflow::new_id()?;
                        snippet.revision = workflow::new_id()?;
                        snippet.name =
                            format!("{} {}", snippet.name, self.lang.text("Kopie", "copy"));
                    }
                }
                draft
            } else if self.snippet {
                Draft::Snippet(Snippet {
                    id: workflow::new_id()?,
                    revision: workflow::new_id()?,
                    name: self
                        .lang
                        .text("Neuer Textbaustein", "New text snippet")
                        .into(),
                    template: "{{Text}}".into(),
                    extra: Default::default(),
                })
            } else {
                Draft::Flow(Workflow {
                    id: workflow::new_id()?,
                    revision: workflow::new_id()?,
                    name: self.lang.text("Neuer Ablauf", "New workflow").into(),
                    steps: vec![Step::new("uppercase")?],
                    extra: Default::default(),
                })
            };
            if let Draft::Snippet(snippet) = &mut draft {
                snippet.name = snippet::available_name(self, &snippet.name)?;
            }
            Ok::<_, Error>(draft)
        })();
        match result {
            Ok(draft) => {
                self.selected.set(None);
                if self.snippet {
                    self.values.borrow_mut().clear();
                }
                *self.draft.borrow_mut() = Some(draft);
                self.selected_step.set(Some(0));
                self.dirty.set(true);
                self.refresh_saved();
                self.render_draft();
                self.invalidate();
                self.refresh();
                self.status.set_text(self.lang.text(
                    "Neue Definition. Benennen, bearbeiten und speichern.",
                    "New definition. Name, edit and save it.",
                ));
            }
            Err(e) => self.error(e),
        }
    }
    pub(super) fn render_draft(self: &Rc<Self>) {
        self.updating.set(true);
        match self.draft.borrow().as_ref() {
            Some(Draft::Flow(flow)) => {
                self.name.set_text(&flow.name);
                if flow.steps.iter().any(|step| {
                    step.enabled
                        && matches!(
                            step.kind.as_str(),
                            "precomposeUnicode"
                                | "decomposeUnicode"
                                | "addEmojiPresentation"
                                | "removeEmojiPresentation"
                        )
                }) {
                    self.exact.set_active(true);
                }
            }
            Some(Draft::Snippet(snippet)) => {
                self.name.set_text(&snippet.name);
                self.template.buffer().set_text(&snippet.template);
            }
            None => {
                self.name.set_text("");
                self.template.buffer().set_text("");
            }
        }
        self.updating.set(false);
        if self.snippet {
            self.render_fields();
        } else {
            self.render_steps();
        }
    }
    pub(super) fn render_steps(self: &Rc<Self>) {
        self.updating.set(true);
        while let Some(child) = self.steps.first_child() {
            self.steps.remove(&child);
        }
        if let Some(Draft::Flow(flow)) = self.draft.borrow().as_ref() {
            for (index, step) in flow.steps.iter().enumerate() {
                let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
                let enabled = gtk::CheckButton::new();
                enabled.set_active(step.enabled);
                enabled.set_tooltip_text(Some(self.lang.text("Schritt aktiv", "Enable step")));
                let text = label(&format!("{}. {}", index + 1, title(&step.kind, self.lang)));
                row.append(&enabled);
                row.append(&text);
                self.steps.append(&row);
                let weak = Rc::downgrade(self);
                enabled.connect_toggled(move |button| {
                    if let Some(v) = weak.upgrade() {
                        if v.updating.get() {
                            return;
                        }
                        if let Some(Draft::Flow(flow)) = v.draft.borrow_mut().as_mut() {
                            if let Some(step) = flow.steps.get_mut(index) {
                                step.enabled = button.is_active();
                            }
                        }
                        v.dirty();
                    }
                });
            }
        }
        if let Some(row) = self
            .selected_step
            .get()
            .and_then(|i| self.steps.row_at_index(i as i32))
        {
            self.steps.select_row(Some(&row));
        }
        self.updating.set(false);
        self.render_step();
    }
    pub(super) fn render_step(&self) {
        self.updating.set(true);
        let draft = self.draft.borrow();
        let step = match draft.as_ref() {
            Some(Draft::Flow(flow)) => self.selected_step.get().and_then(|i| flow.steps.get(i)),
            _ => None,
        };
        self.step_editor.set_sensitive(step.is_some());
        if let Some(step) = step {
            let mut kinds: Vec<String> = KINDS
                .iter()
                .map(|v| self.lang.text(v.1, v.2).into())
                .collect();
            let index = KINDS
                .iter()
                .position(|kind| kind.0 == step.kind)
                .unwrap_or_else(|| {
                    kinds.push(title(&step.kind, self.lang));
                    kinds.len() - 1
                });
            let names: Vec<_> = kinds.iter().map(String::as_str).collect();
            self.kind.set_model(Some(&gtk::StringList::new(&names)));
            self.kind.set_selected(index as u32);
            self.tab_width.set_value(step.tab_width as f64);
            self.indent_width.set_value(step.indent_width as f64);
            self.wrap_column.set_value(step.wrap_column as f64);
            self.uses_tabs.set_active(step.uses_tabs);
            let indent = matches!(step.kind.as_str(), "shiftRight" | "shiftLeft");
            let tabs = indent || matches!(step.kind.as_str(), "detab" | "entab");
            self.profile.set_visible(tabs || step.kind == "hardWrap");
            self.tab_width.set_sensitive(tabs);
            self.indent_width.set_sensitive(indent);
            self.uses_tabs.set_sensitive(indent);
            self.wrap_column.set_sensitive(step.kind == "hardWrap");
            self.argument.set_text(&step.argument);
            self.find.set_text(&step.find);
            self.replacement.set_text(&step.replacement);
            let replace = step.kind == "replace";
            let filter = matches!(
                step.kind.as_str(),
                "keepLinesMatching" | "deleteLinesMatching"
            );
            let argument = filter || matches!(step.kind.as_str(), "prefixLines" | "suffixLines");
            for (row, visible) in [
                (1, argument),
                (2, replace),
                (3, replace),
                (4, replace || filter),
            ] {
                for column in 0..2 {
                    if let Some(widget) = self.step_editor.child_at(column, row) {
                        widget.set_visible(visible);
                    }
                }
            }
            self.argument.set_sensitive(argument);
            self.find.set_sensitive(replace);
            self.replacement.set_sensitive(replace);
            self.regex.set_sensitive(replace);
            self.case_sensitive.set_sensitive(replace || filter);
            self.whole_word.set_sensitive(replace);
            self.literal.set_sensitive(replace && !step.regex);
            self.regex.set_active(step.regex || filter);
            self.case_sensitive.set_active(step.case_sensitive);
            self.whole_word.set_active(step.whole_word);
            self.literal.set_active(step.literal_wildcard);
        }
        self.updating.set(false);
    }
    pub(super) fn render_fields(self: &Rc<Self>) {
        let names = match self.draft.borrow().as_ref() {
            Some(Draft::Snippet(snippet)) => Template::parse(&snippet.template).map(|t| t.names),
            _ => Ok(Vec::new()),
        };
        let names = match names {
            Ok(names) => names,
            Err(e) => {
                self.error(e);
                return;
            }
        };
        let old: BTreeMap<_, _> = self
            .values
            .borrow()
            .iter()
            .map(|(name, entry)| {
                (
                    name.clone(),
                    entry
                        .buffer()
                        .text(
                            &entry.buffer().start_iter(),
                            &entry.buffer().end_iter(),
                            true,
                        )
                        .to_string(),
                )
            })
            .collect();
        while let Some(child) = self.fields.first_child() {
            self.fields.remove(&child);
        }
        self.values.borrow_mut().clear();
        self.fields_scroll.set_visible(!names.is_empty());
        self.fields_scroll.set_min_content_height(80);
        self.fields_scroll
            .set_vscrollbar_policy(if names.len() > 2 {
                gtk::PolicyType::Always
            } else {
                gtk::PolicyType::Automatic
            });
        for (index, name) in names.into_iter().enumerate() {
            let field = gtk::TextView::builder()
                .wrap_mode(gtk::WrapMode::WordChar)
                .hexpand(true)
                .build();
            field.set_accepts_tab(false);
            field.set_top_margin(4);
            field.set_bottom_margin(4);
            field.set_left_margin(6);
            field.set_right_margin(6);
            field
                .buffer()
                .set_text(old.get(&name).map(String::as_str).unwrap_or(""));
            let field_scroll = scroll(&field);
            field_scroll.set_has_frame(true);
            field_scroll.set_vexpand(false);
            field_scroll.set_min_content_height(58);
            field_scroll.set_max_content_height(58);
            let name_label = label(&name);
            name_label.set_max_width_chars(24);
            self.fields.attach(&name_label, 0, index as i32 * 2, 1, 1);
            self.fields
                .attach(&field_scroll, 0, index as i32 * 2 + 1, 1, 1);
            let weak = Rc::downgrade(self);
            field.buffer().connect_changed(move |_| {
                if let Some(v) = weak.upgrade() {
                    v.invalidate();
                    v.refresh();
                }
            });
            let weak = Rc::downgrade(self);
            field.buffer().connect_insert_text(move |buffer, _, text| {
                if let Some(view) = weak.upgrade() {
                    if text.len() > 16 * 1024
                        || buffer
                            .text(&buffer.start_iter(), &buffer.end_iter(), true)
                            .len()
                            + text.len()
                            > 16 * 1024
                    {
                        buffer.stop_signal_emission_by_name("insert-text");
                        view.status.set_text(view.lang.text(
                            "Feldwert zu groß: höchstens 16 KiB.",
                            "Field value too large: at most 16 KiB.",
                        ));
                    }
                }
            });
            self.values.borrow_mut().push((name, field));
        }
        if self.snippet {
            snippet::update_preview(self);
        }
    }
    pub(super) fn change_steps(self: &Rc<Self>, action: i32) {
        let result = (|| {
            let mut draft = self.draft.borrow_mut();
            let Some(Draft::Flow(flow)) = draft.as_mut() else {
                return Ok(());
            };
            match action {
                0 => {
                    if flow.steps.len() >= 32 {
                        return Err(Error::Limit);
                    }
                    flow.steps.push(Step::new("replace")?);
                    self.selected_step.set(Some(flow.steps.len() - 1));
                }
                2 => {
                    if let Some(i) = self.selected_step.get().filter(|i| *i < flow.steps.len()) {
                        flow.steps.remove(i);
                        self.selected_step
                            .set(i.checked_sub(1).or((!flow.steps.is_empty()).then_some(0)));
                    }
                }
                direction => {
                    if let Some(i) = self.selected_step.get().filter(|i| *i < flow.steps.len()) {
                        let next = i as i32 + direction;
                        if next >= 0 && (next as usize) < flow.steps.len() {
                            flow.steps.swap(i, next as usize);
                            self.selected_step.set(Some(next as usize));
                        }
                    }
                }
            }
            Ok::<_, Error>(())
        })();
        match result {
            Ok(()) => {
                self.dirty();
                self.render_steps();
            }
            Err(e) => self.error(e),
        }
    }
    pub(super) fn save_library(
        self: &Rc<Self>,
        library: Library,
        selected: Option<usize>,
        notice: &'static str,
    ) {
        let Some(snapshot) = self.snapshot.borrow().clone() else {
            return;
        };
        let values = (self.snippet && self.dirty.get() && selected.is_some_and(|i|
            matches!(self.draft.borrow().as_ref(),Some(Draft::Snippet(draft)) if library.snippets.snippets.get(i).is_some_and(|s|s.id==draft.id))))
            .then(|| self.values.borrow().iter().map(|(name,field)|(name.clone(),field.buffer().text(&field.buffer().start_iter(),&field.buffer().end_iter(),true).to_string())).collect::<BTreeMap<_,_>>());
        let config = self.config.clone();
        self.run(
            move || Store::open(&config)?.save(&snapshot, &library),
            move |v, snapshot| {
                *v.snapshot.borrow_mut() = Some(snapshot);
                v.choose(selected);
                if let Some(values) = values {
                    for (name, field) in v.values.borrow().iter() {
                        if let Some(text) = values.get(name) {
                            field.buffer().set_text(text);
                        }
                    }
                }
                if v.snippet && v.draft.borrow().is_none() {
                    v.new_draft(false);
                }
                v.status.set_text(notice);
                let action = v
                    .snippet_layout
                    .as_ref()
                    .and_then(|l| l.after_save.borrow_mut().take());
                if let Some(action) = action {
                    action(v);
                }
            },
        );
    }
    pub(super) fn save_definition(self: &Rc<Self>) {
        let result = (|| {
            let mut draft = self
                .draft
                .borrow()
                .clone()
                .ok_or_else(|| Error::Invalid("definition".into()))?;
            let mut library = self
                .snapshot
                .borrow()
                .as_ref()
                .ok_or(Error::Stale)?
                .library
                .clone();
            let index = match &mut draft {
                Draft::Flow(flow) => {
                    flow.name = flow.name.trim().into();
                    flow.validate()?;
                    if library.workflows.workflows.iter().any(|other| {
                        other.id != flow.id && other.name.to_lowercase() == flow.name.to_lowercase()
                    }) {
                        return Err(Error::Invalid(
                            self.lang
                                .text("Name bereits vorhanden", "Name already exists")
                                .into(),
                        ));
                    }
                    flow.revision = workflow::new_id()?;
                    let index = library
                        .workflows
                        .workflows
                        .iter()
                        .position(|v| v.id == flow.id)
                        .unwrap_or(library.workflows.workflows.len());
                    if index == library.workflows.workflows.len() {
                        library.workflows.workflows.push(flow.clone());
                    } else {
                        library.workflows.workflows[index] = flow.clone();
                    }
                    index
                }
                Draft::Snippet(snippet) => {
                    snippet.name = snippet.name.trim().into();
                    snippet.validate()?;
                    for other in &library.snippets.snippets {
                        if other.id != snippet.id
                            && snippet::name_matches(&other.name, &snippet.name, true)?
                        {
                            return Err(Error::Invalid(
                                self.lang
                                    .text("Name bereits vorhanden", "Name already exists")
                                    .into(),
                            ));
                        }
                    }
                    snippet.revision = workflow::new_id()?;
                    let index = library
                        .snippets
                        .snippets
                        .iter()
                        .position(|v| v.id == snippet.id)
                        .unwrap_or(library.snippets.snippets.len());
                    if index == library.snippets.snippets.len() {
                        library.snippets.snippets.push(snippet.clone());
                    } else {
                        library.snippets.snippets[index] = snippet.clone();
                    }
                    index
                }
            };
            library.validate()?;
            Ok::<_, Error>((library, index))
        })();
        match result {
            Ok((library, index)) => self.save_library(
                library,
                Some(index),
                self.lang.text(
                    if self.snippet {
                        "Textbaustein gespeichert."
                    } else {
                        "Definition privat gespeichert. Jetzt die Vorschau berechnen."
                    },
                    if self.snippet {
                        "Text snippet saved."
                    } else {
                        "Definition saved privately. Now calculate a preview."
                    },
                ),
            ),
            Err(e) => {
                if let Some(layout) = &self.snippet_layout {
                    layout.after_save.borrow_mut().take();
                }
                self.error(e);
            }
        }
    }
    pub(super) fn remove_definition(self: &Rc<Self>) {
        let Some(index) = self.selected.get() else {
            return;
        };
        let Some(snapshot) = self.snapshot.borrow().clone() else {
            return;
        };
        let mut library = snapshot.library;
        let dialog = gtk::AlertDialog::builder()
            .message(self.lang.text(
                "Gespeicherte Definition löschen?",
                "Delete the saved definition?",
            ))
            .detail(self.lang.text(
                "Dokumenttexte bleiben erhalten.",
                "Document contents are preserved.",
            ))
            .buttons([
                self.lang.text("Abbrechen", "Cancel"),
                self.lang.text("Löschen", "Delete"),
            ])
            .cancel_button(0)
            .default_button(0)
            .build();
        self.busy.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        dialog.choose(
            Some(&self.window),
            None::<&gio::Cancellable>,
            move |result| {
                if let Some(v) = weak.upgrade() {
                    v.busy.set(false);
                    if result == Ok(1) {
                        if v.snippet {
                            if index < library.snippets.snippets.len() {
                                library.snippets.snippets.remove(index);
                            }
                        } else if index < library.workflows.workflows.len() {
                            library.workflows.workflows.remove(index);
                        }
                        v.save_library(
                            library,
                            None,
                            v.lang.text("Definition gelöscht.", "Definition deleted."),
                        );
                    }
                    v.refresh();
                }
            },
        );
    }
}
