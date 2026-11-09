//! Native, explizite 4D-Navigation mit unveränderlicher Quell- und Projektbindung.
use super::*;
use fastra_core::four_d::{Analysis, Signature};
use std::{rc::Weak, sync::Arc};
struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    window: gtk::Window,
    status: gtk::Label,
    filter: gtk::Entry,
    list: gtk::ListBox,
    details: gtk::TextView,
    revision: Cell<u64>,
    generation: Cell<u64>,
    running: Cell<bool>,
    cancel: RefCell<Cancellation>,
    analysis: RefCell<Option<Arc<Analysis>>>,
    index: RefCell<Option<Arc<four_d_index::Index>>>,
    project: RefCell<Option<project_view::Binding>>,
    project_work: RefCell<Option<project_view::WorkBinding>>,
    show_project: Cell<bool>,
    selected_method: Cell<Option<usize>>,
}
fn signature(name: &str, s: &Signature, active: Option<usize>) -> String {
    let params = s
        .parameters
        .iter()
        .enumerate()
        .map(|(i, p)| {
            format!(
                "{}{}{}",
                if active == Some(i) { "▶ " } else { "" },
                p.name,
                p.type_name
                    .as_ref()
                    .map_or(String::new(), |t| format!(" : {t}"))
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    let returns = s.returns.as_ref().map_or(String::new(), |p| {
        format!(
            " → {}{}",
            p.name,
            p.type_name
                .as_ref()
                .map_or(String::new(), |t| format!(" : {t}"))
        )
    });
    let text = format!("{name}({params}){returns}\n\n{}", s.header);
    let mut out: String = text.chars().take(16000).collect();
    if text.chars().count() > 16000 {
        out.push_str("\n[… 16000 characters …]");
    }
    out
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn owner(&self) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        if !self.window.is_visible()
            || !ui.window.is_visible()
            || doc.source_edits_locked()
            || !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
        {
            return None;
        }
        Some((ui, doc))
    }
    fn current(&self) -> bool {
        self.owner()
            .is_some_and(|(_, doc)| doc.revision.get() == self.revision.get())
    }
    fn stop(&self) {
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.analysis.borrow_mut().take();
        self.index.borrow_mut().take();
        self.project.borrow_mut().take();
        self.details.buffer().set_text("");
        self.selected_method.set(None);
    }
    fn build(self: &Rc<Self>, project: bool) {
        if self.running.get() {
            return;
        }
        let Some((ui, doc)) = self.owner() else {
            self.status.set_text(self.lang().text(
                "Zum gebundenen Quelltab wechseln und Rich-Modus beenden.",
                "Return to the bound source tab and leave Rich mode.",
            ));
            return;
        };
        if doc.buffer.char_count() as usize > fastra_core::four_d::MAX_SOURCE_BYTES {
            self.status.set_text(
                self.lang()
                    .text("Quellgrenze: 4 MiB UTF-8.", "Source limit: 4 MiB UTF-8."),
            );
            return;
        }
        let source = buffer_text(&doc.buffer);
        if source.len() > fastra_core::four_d::MAX_SOURCE_BYTES {
            self.status.set_text(
                self.lang()
                    .text("Quellgrenze: 4 MiB UTF-8.", "Source limit: 4 MiB UTF-8."),
            );
            return;
        }
        self.stop();
        self.show_project.set(project);
        self.revision.set(doc.revision.get());
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let binding = if project {
            let Some(binding) = project_view::current_binding(&ui) else {
                self.status.set_text(self.lang().text(
                    "Zuerst einen vollständigen Projektbaum wählen.",
                    "Choose a complete project tree first.",
                ));
                self.render();
                return;
            };
            Some(binding)
        } else {
            None
        };
        let work = match binding.as_ref().map(|b| b.work(&cancel)).transpose() {
            Ok(w) => w,
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        *self.project.borrow_mut() = binding.clone();
        *self.project_work.borrow_mut() = work.clone();
        let root = binding.as_ref().map(|b| b.root.path.clone());
        self.running.set(true);
        self.render();
        self.status.set_text(self.lang().text(
            "4D-Quellen werden im Hintergrund gelesen …",
            "Reading 4D sources in background …",
        ));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                if let Some(work) = &work {
                    work.validate()?;
                }
                let analysis = Analysis::build(&source, &cancel).map_err(|e| format!("{e:?}"))?;
                let index = root
                    .map(|root| four_d_index::scan(&root, &cancel).map(Arc::new))
                    .transpose()?;
                if let Some(work) = &work {
                    work.validate()?;
                }
                Ok((Arc::new(analysis), index))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                s.running.set(false);
                s.project_work.borrow_mut().take();
                if s.generation.get() != generation {
                    return;
                }
                if !s.current() || binding.as_ref().is_some_and(|b| !b.is_current()) {
                    s.status.set_text(s.lang().text(
                        "Quelle oder Projekt geändert; Ergebnis verworfen.",
                        "Source or project changed; result discarded.",
                    ));
                    return;
                }
                match result {
                    Ok((analysis, index)) => {
                        *s.analysis.borrow_mut() = Some(analysis);
                        *s.index.borrow_mut() = index;
                        s.render();
                    }
                    Err(e) => {
                        s.status.set_text(&format!(
                            "{}: {e}",
                            s.lang()
                                .text("4D-Navigation fehlgeschlagen", "4D navigation failed")
                        ));
                    }
                }
            },
        );
    }
    fn render(self: &Rc<Self>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let filter = self.filter.text().to_lowercase();
        let generation = self.generation.get();
        let mut total = 0;
        if self.show_project.get() {
            if let Some(index) = self.index.borrow().as_ref() {
                for (i, entry) in index
                    .entries
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| e.name.to_lowercase().contains(&filter))
                {
                    total += 1;
                    if total > 200 {
                        continue;
                    }
                    let label = format!(
                        "{} · {}",
                        project_view::display(std::path::Path::new(&entry.name)),
                        project_view::display(&entry.path)
                    );
                    let weak = Rc::downgrade(self);
                    self.row(&label, move || {
                        if let Some(s) = weak.upgrade() {
                            s.method(i, generation);
                        }
                    });
                }
            }
        } else if let Some(analysis) = self.analysis.borrow().as_ref() {
            for (i, d) in analysis
                .definitions
                .iter()
                .enumerate()
                .filter(|(_, d)| d.name.to_lowercase().contains(&filter))
            {
                total += 1;
                if total > 200 {
                    continue;
                }
                let label = format!(
                    "{}:{} · {:?} · {}",
                    d.span.line, d.span.column, d.kind, d.name
                );
                let weak = Rc::downgrade(self);
                self.row(&label, move || {
                    if let Some(s) = weak.upgrade() {
                        s.definition(i, generation);
                    }
                });
            }
        }
        let warnings = self
            .index
            .borrow()
            .as_ref()
            .map_or(String::new(), |i| i.warnings.join("\n"));
        self.status.set_text(&format!("{} {total} · {}\n{warnings}",self.lang().text("Einträge:","Entries:"),self.lang().text("Maximal 200 sichtbar; Filter eingrenzen. Nur statische Navigation, keine Compilerprüfung.","At most 200 visible; narrow the filter. Static navigation only; no compiler check.")));
    }
    fn row(&self, text: &str, action: impl Fn() + 'static) {
        let label = gtk::Label::new(Some(text));
        label.set_xalign(0.);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.set_max_width_chars(90);
        let button = gtk::Button::new();
        button.set_child(Some(&label));
        button.set_tooltip_text(Some(text));
        button.connect_clicked(move |_| action());
        self.list.append(&button);
    }
    fn definition(&self, i: usize, generation: u64) {
        if generation != self.generation.get() || !self.current() {
            self.stale();
            return;
        }
        let Some((_, doc)) = self.owner() else {
            return;
        };
        let span = self
            .analysis
            .borrow()
            .as_ref()
            .and_then(|a| a.definitions.get(i))
            .map(|d| d.span.clone());
        let Some(span) = span else {
            return;
        };
        if doc.folded.borrow().is_some() {
            self.status.set_text(
                self.lang()
                    .text("Zuerst alle Zeilen entfalten.", "Unfold all lines first."),
            );
            return;
        }
        let Some(target)=source_panes::capture(&doc).filter(|target|target.valid(&doc)) else{return};
        let start=target.buffer.iter_at_offset(span.characters.start as i32);
        let end=target.buffer.iter_at_offset(span.characters.end as i32);
        target.buffer.select_range(&start,&end);
        let mut start=start;target.view.scroll_to_iter(&mut start,0.15,true,0.,0.3);target.view.grab_focus();
    }
    fn stale(&self) {
        self.status.set_text(self.lang().text(
            "Tab, Revision, Rich-Sperre oder Projekt geändert. Neu lesen; keine Aktion ausgeführt.",
            "Tab, revision, Rich lock or project changed. Refresh; no action performed.",
        ));
    }
    fn method(self: &Rc<Self>, i: usize, generation: u64) {
        if generation != self.generation.get()
            || !self.current()
            || !self
                .project
                .borrow()
                .as_ref()
                .is_some_and(|b| b.is_current())
        {
            self.stale();
            return;
        }
        let Some(index) = self.index.borrow().clone() else {
            return;
        };
        let Some(entry) = index.entries.get(i) else {
            return;
        };
        self.selected_method.set(Some(i));
        self.details
            .buffer()
            .set_text(&signature(&entry.name, &entry.signature, None));
    }
    fn help(self: &Rc<Self>) {
        if self.running.get() {
            return;
        }
        if !self.current() {
            self.stale();
            return;
        }
        let Some((_, doc)) = self.owner() else {
            return;
        };
        let Some(analysis) = self.analysis.borrow().clone() else {
            self.stale();
            return;
        };
        let Some(target)=source_panes::capture(&doc) else{return};
        let cursor=target.buffer.cursor_position() as usize;
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.running.set(true);
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                let byte = analysis
                    .source()
                    .char_indices()
                    .nth(cursor)
                    .map_or(analysis.source().len(), |(i, _)| i);
                analysis
                    .call_context(byte, &cancel)
                    .map_err(|e| e.to_string())
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                s.running.set(false);
                if generation != s.generation.get() {
                    return;
                }
                if !s.current()
                    || s.doc
                        .upgrade()
                        .is_none_or(|d|!target.valid(&d)||target.buffer.cursor_position() as usize != cursor)
                {
                    s.stale();
                    return;
                }
                match result {
                    Ok(Some(call)) => {
                        let index = s.index.borrow();
                        let call_key = fastra_core::four_d::method_key(&call.method);
                        let entries: Vec<_> = index
                            .as_ref()
                            .map(|i| i.entries.iter().filter(|e| e.key == call_key).collect())
                            .unwrap_or_default();
                        if entries.len() == 1
                            && s.project.borrow().as_ref().is_some_and(|b| b.is_current())
                        {
                            s.details.buffer().set_text(&signature(
                                &entries[0].name,
                                &entries[0].signature,
                                Some(call.active_parameter),
                            ));
                        } else {
                            s.details.buffer().set_text(&format!(
                                "{} · {} {}\n{}",
                                call.method,
                                s.lang().text("Parameter", "parameter"),
                                call.active_parameter + 1,
                                s.lang().text(
                                    "Keine eindeutige Projektmethode. Projektindex neu lesen.",
                                    "No unique project method. Refresh the project index."
                                )
                            ));
                        }
                    }
                    Ok(None) => s.status.set_text(s.lang().text(
                        "Kein offener Methodenaufruf am Cursor.",
                        "No open method call at the cursor.",
                    )),
                    Err(e) => s.status.set_text(&e),
                }
            },
        );
    }
    fn open_method(self: &Rc<Self>) {
        if self.running.get() || !self.current() {
            self.stale();
            return;
        }
        let Some(i) = self.selected_method.get() else {
            self.status.set_text(self.lang().text(
                "Zuerst eine Projektmethode anklicken.",
                "Click a project method first.",
            ));
            return;
        };
        let Some(binding) = self.project.borrow().clone().filter(|b| b.is_current()) else {
            self.stale();
            return;
        };
        let Some(index) = self.index.borrow().clone() else {
            return;
        };
        let Some(entry) = index.entries.get(i) else {
            return;
        };
        let path = entry.path.clone();
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let work = match binding.work(&cancel) {
            Ok(w) => w,
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        *self.project_work.borrow_mut() = Some(work.clone());
        self.running.set(true);
        let loaded_index = index.clone();
        let loaded_work = work.clone();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                work.validate()?;
                four_d_index::unchanged(&index.entries[i], &cancel)?;
                work.validate()?;
                Ok(path)
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                s.running.set(false);
                s.project_work.borrow_mut().take();
                if generation != s.generation.get() {
                    return;
                }
                if !s.current() || !binding.is_current() {
                    s.stale();
                    return;
                }
                match result {
                    Ok(path) => {
                        let Some(ui) = s.ui.upgrade() else {
                            return;
                        };
                        let weak = Rc::downgrade(&s);
                        ui.load_path_validated(
                            path,
                            None,
                            Rc::new(move || {
                                weak.upgrade().is_some_and(|s| {
                                    s.generation.get() == generation
                                        && s.current()
                                        && s.project
                                            .borrow()
                                            .as_ref()
                                            .is_some_and(|b| b.is_current())
                                })
                            }),
                            Some(Box::new(move |loaded| {
                                loaded_work.validate().is_ok()
                                    && four_d_index::matches_loaded(
                                        &loaded_index.entries[i],
                                        loaded,
                                    )
                            })),
                        );
                    }
                    Err(e) => s.status.set_text(&e),
                }
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>) {
    let Some(doc) = ui.active() else {
        return;
    };
    if ui.source_edit_allowed(&doc) {
        open_for(ui, &doc);
    }
}
fn open_for(ui: &Rc<Ui>, doc: &Rc<Document>) -> Rc<State> {
    let window = git_view::window(
        ui,
        ui.lang
            .text("4D · Methoden und Parameter", "4D · Methods and parameters"),
        false,
    );
    window.set_default_size(860, 720);
    let root = git_view::column();
    root.append(&git_view::label(&format!(
        "{} · {}",
        doc.name,
        ui.lang.text(
            "Gebundener Quelltab. Lokale statische Analyse; keine 4D-Runtime.",
            "Bound source tab. Local static analysis; no 4D runtime."
        )
    )));
    root.append(&git_view::label(ui.lang.text("Auf Anforderung: bekannte Methods-/Classes-Ordner, höchstens 2000 Dateien und 16 MiB gesamt, 1 MiB je Datei. Symlinks ausgeschlossen. Quelltab: 4 MiB und 10.000 Definitionen. Kein Liveindex; nach Dateiänderungen neu lesen.","On request: known Methods/Classes folders, at most 2000 files and 16 MiB total, 1 MiB per file. Symlinks excluded. Source tab: 4 MiB and 10,000 definitions. No live index; refresh after file changes.")));
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .column_spacing(6)
        .row_spacing(6)
        .build();
    let definitions = gtk::Button::with_label(
        ui.lang
            .text("Definitionen neu lesen", "Refresh definitions"),
    );
    let project = gtk::Button::with_label(
        ui.lang
            .text("Projektmethoden lesen", "Read project methods"),
    );
    let help = gtk::Button::with_label(ui.lang.text("Parameter am Cursor", "Parameters at cursor"));
    let open_method = gtk::Button::with_label(
        ui.lang
            .text("Gewählte Methode öffnen", "Open selected method"),
    );
    let cancel = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    for b in [&definitions, &project, &help, &open_method, &cancel] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let filter = gtk::Entry::builder()
        .max_length(200)
        .placeholder_text(ui.lang.text("Namen filtern …", "Filter names …"))
        .build();
    root.append(&filter);
    let status = git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_max_width_chars(90);
    root.append(&status);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    root.append(&git_view::scroll(&list));
    let details = git_view::output();
    details.set_wrap_mode(gtk::WrapMode::WordChar);
    let scroll = git_view::scroll(&details);
    scroll.set_min_content_height(130);
    root.append(&scroll);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        window: window.clone(),
        status,
        filter: filter.clone(),
        list,
        details,
        revision: Cell::new(doc.revision.get()),
        generation: Cell::new(0),
        running: Cell::new(false),
        cancel: RefCell::new(Cancellation::default()),
        analysis: RefCell::new(None),
        index: RefCell::new(None),
        project: RefCell::new(None),
        project_work: RefCell::new(None),
        show_project: Cell::new(false),
        selected_method: Cell::new(None),
    });
    for (button, project) in [(definitions, false), (project, true)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.build(project);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    open_method.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.open_method();
        }
    });
    let weak = Rc::downgrade(&state);
    help.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.help();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.render();
            s.status.set_text(s.lang().text(
                "Abgebrochen. Keine Teilergebnisse.",
                "Cancelled. No partial results.",
            ));
        }
    });
    let weak = Rc::downgrade(&state);
    filter.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.selected_method.set(None);
            s.details.buffer().set_text("");
            s.render();
        }
    });
    let holder = Rc::new(RefCell::new(Some(state.clone())));
    let close = holder.clone();
    window.connect_close_request(move |_| {
        if let Some(s) = close.borrow_mut().take() {
            s.stop();
        }
        glib::Propagation::Proceed
    });
    window.connect_visible_notify(move |w| {
        if !w.is_visible() {
            if let Some(s) = holder.borrow_mut().take() {
                s.stop();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    ui.window.connect_visible_notify(move |w| {
        if !w.is_visible() {
            if let Some(s) = weak.upgrade() {
                s.stop();
                s.window.close();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    doc.buffer.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.render();
            s.stale();
        }
    });
    let weak = Rc::downgrade(&state);
    glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !s.window.is_visible() {
            return glib::ControlFlow::Break;
        }
        if s.project.borrow().as_ref().is_some_and(|b| !b.is_current()) {
            s.stop();
            s.render();
            s.stale();
        }
        glib::ControlFlow::Continue
    });
    window.present();
    state.build(false);
    state
}

#[cfg(debug_assertions)]
fn widgets(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(w) = child {
        widgets(&w, all);
        child = w.next_sibling();
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
