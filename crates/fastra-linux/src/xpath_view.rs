//! XPath navigiert ausschließlich in den gebundenen Quelltab; kein Dateizugriff und keine Textänderung.
use super::*;
use fastra_core::xpath::{self, Index, Match};
use std::{rc::Weak, sync::Arc};
const PAGE: usize = 100;
struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    window: gtk::Window,
    query: gtk::Entry,
    list: gtk::ListBox,
    suggestions: gtk::FlowBox,
    status: gtk::Label,
    build: gtk::Button,
    evaluate_button: gtk::Button,
    cancel_button: gtk::Button,
    previous: gtk::Button,
    next: gtk::Button,
    previous_page: gtk::Button,
    next_page: gtk::Button,
    index: RefCell<Option<Arc<Index>>>,
    matches: RefCell<Vec<Match>>,
    selected: Cell<Option<usize>>,
    page: Cell<usize>,
    revision: Cell<u64>,
    generation: Cell<u64>,
    query_generation: Cell<u64>,
    parse_running: Cell<bool>,
    query_running: Cell<bool>,
    query_pending: Cell<bool>,
    parse_cancel: RefCell<Cancellation>,
    query_cancel: RefCell<Cancellation>,
}
fn error_text(lang: Language, error: &xpath::Error) -> String {
    match error {
        xpath::Error::Cancelled => lang
            .text(
                "Abgebrochen. Keine Teiltreffer angezeigt.",
                "Cancelled. No partial results displayed.",
            )
            .into(),
        xpath::Error::DtdForbidden => lang
            .text(
                "DTD ist gesperrt; externe Entitäten und Netzauflösung sind nicht erlaubt.",
                "DTD is blocked; external entities and network resolution are not allowed.",
            )
            .into(),
        xpath::Error::Limit(kind) => {
            let name = match *kind {
                "source bytes" => lang.text("Quellgröße", "source bytes"),
                "start tag bytes" => lang.text("Starttaggröße", "start tag bytes"),
                "attributes per element" => {
                    lang.text("Attribute je Starttag", "attributes per start tag")
                }
                "depth" => lang.text("Verschachtelungstiefe", "depth"),
                "attributes" => lang.text("Attributzahl", "attributes"),
                "parser nodes/attributes" => {
                    lang.text("XML-Knoten oder Attribute", "XML nodes or attributes")
                }
                "results" => lang.text("Trefferzahl", "results"),
                "query bytes" => lang.text("XPath-Länge", "query bytes"),
                "query work" => lang.text("Komplexität der Auswertung", "query complexity"),
                "steps" => lang.text("XPath-Schritte", "XPath steps"),
                "predicates" => lang.text("XPath-Prädikate", "XPath predicates"),
                _ => lang.text("Konfiguration", "configuration"),
            };
            let detail = if kind.starts_with("query") || matches!(*kind, "steps" | "predicates") {
                lang.text("XPath:4 KiB,128 Schritte/Prädikate und begrenzte Auswertungsarbeit. Keine Teiltreffer.","XPath:4 KiB,128 steps/predicates and bounded evaluation work. No partial results.")
            } else {
                lang.text("XML:4 MiB UTF-8,100.000 Knoten/Attribute,Tiefe32,128 Attribute/Starttag,8 KiB Starttag,10.000 Treffer. Keine Teilergebnisse.","XML:4 MiB UTF-8,100,000 nodes/attributes,depth32,128 attributes/start tag,8 KiB start tag,10,000 results. No partial results.")
            };
            format!(
                "{} {name}. {detail}",
                lang.text("XPath-Grenze erreicht:", "XPath limit reached:")
            )
        }
        xpath::Error::Xml {
            message,
            line,
            column,
        } => format!(
            "{} {line}:{column}: {message}",
            lang.text("XML ungültig bei", "Invalid XML at")
        ),
        xpath::Error::Empty => lang
            .text(
                "XPath eingeben, z. B. //buch[@id='42']/titel.",
                "Enter XPath, e.g. //book[@id='42']/title.",
            )
            .into(),
        xpath::Error::Unsupported(part) => format!(
            "{} {part}",
            lang.text(
                "Nicht unterstützte XPath-Syntax:",
                "Unsupported XPath subset:"
            )
        ),
        xpath::Error::Malformed(part) => format!(
            "{} {part}",
            lang.text(
                "XPath unvollständig oder ungültig:",
                "XPath incomplete or invalid:"
            )
        ),
        xpath::Error::InvalidOffset => lang
            .text(
                "Quellposition ungültig; XML neu prüfen. Kein Sprung ausgeführt.",
                "Invalid source position; validate XML again. Navigation was not performed.",
            )
            .into(),
    }
}
fn widgets(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(item) = child {
        widgets(&item, all);
        child = item.next_sibling();
    }
}
impl State {
    fn stop(&self) {
        self.query_pending.set(false);
        self.parse_cancel.borrow().cancel();
        self.query_cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
    }
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn owner(&self) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        if !self.window.is_visible()
            || !ui.window.is_visible()
            || doc.source_edits_locked()
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
        {
            return None;
        }
        Some((ui, doc))
    }
    fn current(&self) -> bool {
        self.owner()
            .is_some_and(|(_, doc)| doc.revision.get() == self.revision.get())
    }
    fn actions(&self) {
        let current = self.current();
        self.build.set_sensitive(!self.parse_running.get());
        self.evaluate_button
            .set_sensitive(current && self.index.borrow().is_some() && !self.query_running.get());
        self.cancel_button
            .set_sensitive(self.parse_running.get() || self.query_running.get());
        let matches = self.matches.borrow();
        self.previous.set_sensitive(current && !matches.is_empty());
        self.next.set_sensitive(current && !matches.is_empty());
        self.previous_page.set_sensitive(self.page.get() > 0);
        self.next_page
            .set_sensitive((self.page.get() + 1) * PAGE < matches.len());
    }
    fn clear(&self) {
        self.matches.borrow_mut().clear();
        self.selected.set(None);
        self.page.set(0);
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        while let Some(child) = self.suggestions.first_child() {
            self.suggestions.remove(&child);
        }
        self.actions();
    }
    fn invalidate(&self) {
        self.query_pending.set(false);
        self.parse_cancel.borrow().cancel();
        self.query_cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.query_generation.set(self.query_generation.get() + 1);
        self.index.borrow_mut().take();
        self.clear();
        self.status.set_text(self.lang().text(
            "Quelle geändert oder gesperrt. XML neu prüfen; alte Quellpositionen sind ungültig.",
            "Source changed or locked. Validate XML again; old source positions are invalid.",
        ));
    }
    fn build(self: &Rc<Self>) {
        if self.parse_running.get() {
            return;
        }
        let Some((_, doc)) = self.owner() else {
            self.status.set_text(self.lang().text("Zum gebundenen Quelltab wechseln und Rich-Modus beenden. Kein fremder Tab wird geöffnet.","Return to the bound source tab and leave Rich mode. No other tab will be opened."));
            return;
        };
        self.invalidate();
        let limits = xpath::Limits::default();
        if doc.buffer.char_count() as usize > limits.source_bytes {
            self.status.set_text(&error_text(
                self.lang(),
                &xpath::Error::Limit("source bytes"),
            ));
            return;
        }
        let source = buffer_text(&doc.buffer);
        if source.len() > limits.source_bytes {
            self.status.set_text(&error_text(
                self.lang(),
                &xpath::Error::Limit("source bytes"),
            ));
            return;
        }
        self.revision.set(doc.revision.get());
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.parse_cancel.borrow_mut() = cancel.clone();
        self.parse_running.set(true);
        self.actions();
        self.status.set_text(self.lang().text("XML wird im Hintergrund geprüft. Parserphase ist hart begrenzt; Abbruch wirkt davor/danach.","Validating XML in background. Parser phase is strictly bounded; cancellation applies before/after it."));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || Ok(Index::build(&source, limits, &cancel).map(Arc::new)),
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                state.parse_running.set(false);
                state.actions();
                if !state.current() || state.generation.get() != generation {
                    return;
                }
                match result {
                    Ok(Ok(index)) => {
                        let count = index.element_count();
                        *state.index.borrow_mut() = Some(index);
                        state.status.set_text(&format!(
                            "{count} {}",
                            state.lang().text(
                                "Elemente geprüft. Nur Quellnavigation, keine Änderungen.",
                                "elements validated. Source navigation only, no changes."
                            )
                        ));
                        state.evaluate();
                    }
                    Ok(Err(error)) => state.status.set_text(&error_text(state.lang(), &error)),
                    Err(error) => state.status.set_text(&error),
                }
                state.actions();
            },
        );
    }
    fn evaluate(self: &Rc<Self>) {
        self.query_pending.set(true);
        self.query_cancel.borrow().cancel();
        self.query_generation.set(self.query_generation.get() + 1);
        self.clear();
        if self.query_running.get() {
            self.status.set_text(self.lang().text(
                "Auswertung wird abgebrochen; danach aktuelle Eingabe prüfen.",
                "Cancelling evaluation; the current input will be checked afterwards.",
            ));
            return;
        }
        if !self.current() {
            self.status.set_text(self.lang().text(
                "Quelle oder aktiver Tab geändert. XML neu prüfen; kein Sprung.",
                "Source or active tab changed. Validate XML again; no navigation.",
            ));
            return;
        }
        let Some(index) = self.index.borrow().clone() else {
            return;
        };
        let input = self.query.text().to_string();
        let generation = self.query_generation.get();
        let source_generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.query_cancel.borrow_mut() = cancel.clone();
        self.query_pending.set(false);
        self.query_running.set(true);
        self.status.set_text(self.lang().text(
            "XPath wird im Hintergrund ausgewertet …",
            "Evaluating XPath in background …",
        ));
        self.actions();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                let suggestions = index.completions(&input, 8, &cancel).unwrap_or_default();
                let matches = index.query(&input, &cancel);
                Ok((matches, suggestions))
            },
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                state.query_running.set(false);
                state.actions();
                if !state.current() {
                    return;
                }
                if state.generation.get() != source_generation {
                    if state.query_pending.get()
                        && state.index.borrow().is_some()
                        && !state.parse_running.get()
                    {
                        state.evaluate();
                    }
                    return;
                }
                if state.query_generation.get() != generation {
                    state.evaluate();
                    return;
                }
                match result {
                    Ok((matches, suggestions)) => {
                        state.suggestions(suggestions);
                        match matches {
                            Ok(matches) => {
                                let count = matches.len();
                                *state.matches.borrow_mut() = matches;
                                state.status.set_text(&format!("{count} {}",state.lang().text("Treffer · Quellrevision gebunden · Klick markiert nur im Editor","results · bound source revision · click only selects in the editor")));
                                state.render();
                            }
                            Err(error) => state.status.set_text(&error_text(state.lang(), &error)),
                        }
                    }
                    Err(error) => state.status.set_text(&error),
                }
                state.actions();
            },
        );
    }
    fn suggestions(self: &Rc<Self>, suggestions: Vec<String>) {
        for suggestion in suggestions {
            let button = gtk::Button::new();
            let label = gtk::Label::new(Some(&suggestion));
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            label.set_max_width_chars(24);
            button.set_child(Some(&label));
            button.set_tooltip_text(Some(&suggestion));
            let expected_input = self.query.text().to_string();
            let expected_generation = self.query_generation.get();
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(state) = weak.upgrade() {
                    if !state.current()
                        || state.query_generation.get() != expected_generation
                        || state.query.text().as_str() != expected_input
                    {
                        return;
                    }
                    let input = state.query.text();
                    let (prefix, _) = xpath::split_completion(&input);
                    let text = if prefix.is_empty() {
                        suggestion.clone()
                    } else if prefix.ends_with('/') {
                        format!("{prefix}{suggestion}")
                    } else {
                        format!("{prefix}/{suggestion}")
                    };
                    if text.len() > 4096 {
                        state.status.set_text(&error_text(
                            state.lang(),
                            &xpath::Error::Limit("query bytes"),
                        ));
                        return;
                    }
                    state.query.set_text(&text);
                    state.query.grab_focus();
                    state.query.set_position(-1);
                }
            });
            self.suggestions.insert(&button, -1);
        }
    }
    fn render(self: &Rc<Self>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let matches = self.matches.borrow();
        let source = self.index.borrow();
        let Some(source) = source.as_ref() else {
            return;
        };
        for (index, found) in matches
            .iter()
            .enumerate()
            .skip(self.page.get() * PAGE)
            .take(PAGE)
        {
            let excerpt: String = source.source()[found.span.bytes.clone()]
                .chars()
                .take(120)
                .flat_map(|c| {
                    if c.is_control() {
                        c.escape_default().collect::<Vec<_>>()
                    } else {
                        vec![c]
                    }
                })
                .collect();
            let label = gtk::Label::new(Some(&format!(
                "{}:{} · {} · {excerpt}",
                found.span.line, found.span.column, found.name
            )));
            label.set_xalign(0.);
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            label.set_max_width_chars(90);
            label.set_tooltip_text(Some(&excerpt));
            let button = gtk::Button::new();
            button.set_child(Some(&label));
            let generation = self.generation.get();
            let query_generation = self.query_generation.get();
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(state) = weak.upgrade() {
                    state.navigate_bound(index, generation, query_generation);
                }
            });
            self.list.append(&button);
        }
        drop(matches);
        self.actions();
    }
    fn navigate_bound(&self, index: usize, generation: u64, query_generation: u64) {
        if self.generation.get() != generation || self.query_generation.get() != query_generation {
            self.status.set_text(self.lang().text(
                "Trefferbasis geändert. Kein Sprung; aktuelle Treffer verwenden.",
                "Result basis changed. No navigation; use the current results.",
            ));
            return;
        }
        self.navigate(index);
    }
    fn navigate(&self, index: usize) {
        if !self.current() {
            self.status.set_text(self.lang().text(
                "Tab, Revision oder Rich-Sperre geändert. Kein Sprung; Quelle erneut prüfen.",
                "Tab, revision or Rich lock changed. No navigation; validate the source again.",
            ));
            return;
        }
        let Some((_, doc)) = self.owner() else {
            return;
        };
        let (found, count) = {
            let matches = self.matches.borrow();
            let Some(found) = matches.get(index) else {
                return;
            };
            (found.clone(), matches.len())
        };
        let generation = self.generation.get();
        let query_generation = self.query_generation.get();
        let a = found.span.characters.start;
        let b = found.span.characters.end;
        if b > doc.buffer.char_count() as usize || a > b {
            return;
        }
        let mut all = Vec::new();
        widgets(doc.container.upcast_ref(), &mut all);
        let folded = doc.folded.borrow().is_some();
        if folded {
            if let Some(button) = all
                .iter()
                .filter_map(|w| w.downcast_ref::<gtk::Button>())
                .find(|b| {
                    b.label().as_deref() == Some(self.lang().text("Alles entfalten", "Unfold all"))
                })
            {
                button.emit_clicked();
            }
        }
        if !self.current()
            || self.generation.get() != generation
            || self.query_generation.get() != query_generation
        {
            return;
        }
        let Some(target)=source_panes::capture(&doc).filter(|target|target.valid(&doc)) else{return};
        let start=target.buffer.iter_at_offset(a as i32);let end=target.buffer.iter_at_offset(b as i32);
        target.buffer.select_range(&start,&end);let mut start=start;target.view.scroll_to_iter(&mut start,0.15,true,0.,0.3);target.view.grab_focus();
        self.selected.set(Some(index));
        self.status.set_text(&format!(
            "{} {}/{} · {}:{}",
            self.lang().text("Markiert", "Selected"),
            index + 1,
            count,
            found.span.line,
            found.span.column
        ));
    }
    fn step(&self, forward: bool) {
        let count = self.matches.borrow().len();
        if count == 0 {
            return;
        }
        let at = match self.selected.get() {
            None => 0,
            Some(at) if forward => (at + 1) % count,
            Some(at) => (at + count - 1) % count,
        };
        self.navigate(at);
    }
}
pub(super) fn open(ui: &Rc<Ui>) {
    let Some(doc) = ui.active() else {
        return;
    };
    if !ui.source_edit_allowed(&doc) {
        return;
    }
    open_for(ui, &doc);
}
fn open_for(ui: &Rc<Ui>, doc: &Rc<Document>) -> Rc<State> {
    let window = git_view::window(
        ui,
        ui.lang.text(
            "XML · XPath-Quellnavigation",
            "XML · XPath source navigation",
        ),
        false,
    );
    window.set_default_size(900, 680);
    let root = git_view::column();
    root.append(&git_view::label(&format!(
        "{} · {}",
        doc.name,
        ui.lang.text(
            "Dieser Quelltab bleibt gebunden. Nur Markierung; keine Textänderung.",
            "This source tab remains bound. Selection only; no text changes."
        )
    )));
    let subset=git_view::label(ui.lang.text("Teilset: /, //, *, [n], [@attr], [@attr='wert'], @attr, text(). Relative Pfade suchen in jeder Tiefe; Positionen zählen je Elternknoten. DTD gesperrt.","Subset: /, //, *, [n], [@attr], [@attr='value'], @attr, text(). Relative paths search every depth; positions count per parent. DTD blocked."));
    subset.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    root.append(&subset);
    let query = gtk::Entry::builder()
        .hexpand(true)
        .max_length(4096)
        .placeholder_text(
            ui.lang
                .text("//buch[@id='42']/titel", "//book[@id='42']/title"),
        )
        .build();
    query.set_text("//*");
    root.append(&query);
    let controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(2)
        .max_children_per_line(4)
        .column_spacing(8)
        .row_spacing(4)
        .build();
    let build = gtk::Button::with_label(ui.lang.text("XML neu prüfen", "Validate XML again"));
    let evaluate_button =
        gtk::Button::with_label(ui.lang.text("XPath auswerten", "Evaluate XPath"));
    let cancel_button = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    let previous = gtk::Button::with_label(ui.lang.text("Voriger Treffer", "Previous result"));
    let next = gtk::Button::with_label(ui.lang.text("Nächster Treffer", "Next result"));
    for b in [&build, &evaluate_button, &cancel_button] {
        controls.insert(b, -1);
    }
    let navigation = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    navigation.append(&previous);
    navigation.append(&next);
    controls.insert(&navigation, -1);
    root.append(&controls);
    let suggestions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(8)
        .column_spacing(6)
        .row_spacing(4)
        .build();
    root.append(&suggestions);
    let status = git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_max_width_chars(90);
    status.set_selectable(true);
    status.set_yalign(0.);
    let status_scroll = gtk::ScrolledWindow::builder()
        .min_content_height(60)
        .max_content_height(110)
        .propagate_natural_height(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&status)
        .build();
    root.append(&status_scroll);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    root.append(&git_view::scroll(&list));
    let pages = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let previous_page = gtk::Button::with_label(ui.lang.text("Vorige 100", "Previous 100"));
    let next_page = gtk::Button::with_label(ui.lang.text("Nächste 100", "Next 100"));
    pages.append(&previous_page);
    pages.append(&next_page);
    root.append(&pages);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        window: window.clone(),
        query: query.clone(),
        list,
        suggestions,
        status,
        build: build.clone(),
        evaluate_button: evaluate_button.clone(),
        cancel_button: cancel_button.clone(),
        previous: previous.clone(),
        next: next.clone(),
        previous_page: previous_page.clone(),
        next_page: next_page.clone(),
        index: RefCell::new(None),
        matches: RefCell::new(Vec::new()),
        selected: Cell::new(None),
        page: Cell::new(0),
        revision: Cell::new(doc.revision.get()),
        generation: Cell::new(0),
        query_generation: Cell::new(0),
        parse_running: Cell::new(false),
        query_running: Cell::new(false),
        query_pending: Cell::new(false),
        parse_cancel: RefCell::new(Cancellation::default()),
        query_cancel: RefCell::new(Cancellation::default()),
    });
    let weak = Rc::downgrade(&state);
    build.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.build();
        }
    });
    let weak = Rc::downgrade(&state);
    evaluate_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.evaluate();
        }
    });
    let weak = Rc::downgrade(&state);
    query.connect_activate(move |_| {
        if let Some(s) = weak.upgrade() {
            s.evaluate();
        }
    });
    let weak = Rc::downgrade(&state);
    query.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.evaluate();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel_button.connect_clicked(move |_| {
        if let Some(s)=weak.upgrade(){
            s.query_pending.set(false);
            s.parse_cancel.borrow().cancel();
            s.query_cancel.borrow().cancel();
            s.generation.set(s.generation.get()+1);
            s.query_generation.set(s.query_generation.get()+1);
            s.clear();
            s.status.set_text(s.lang().text(
                "Abbruch angefordert. Die begrenzte Parserphase endet zuerst; keine Teiltreffer.",
                "Cancellation requested. The bounded parser phase finishes first; no partial results."));
        }
    });
    let weak = Rc::downgrade(&state);
    previous.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.step(false);
        }
    });
    let weak = Rc::downgrade(&state);
    next.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.step(true);
        }
    });
    for (forward, button) in [(false, previous_page), (true, next_page)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.page.set(if forward {
                    s.page.get() + 1
                } else {
                    s.page.get().saturating_sub(1)
                });
                s.render();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    doc.buffer.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.invalidate();
        }
    });
    let holder = Rc::new(RefCell::new(Some(state.clone())));
    let close_holder = holder.clone();
    window.connect_close_request(move |_| {
        let state = close_holder.borrow_mut().take();
        if let Some(state) = state {
            state.stop();
        }
        glib::Propagation::Proceed
    });
    window.connect_visible_notify(move |window| {
        if !window.is_visible() {
            let state = holder.borrow_mut().take();
            if let Some(state) = state {
                state.stop();
            }
        }
    });
    let child = window.downgrade();
    ui.window.connect_visible_notify(move |parent| {
        if !parent.is_visible() {
            if let Some(child) = child.upgrade() {
                child.close();
            }
        }
    });
    window.present();
    state.build();
    state
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
