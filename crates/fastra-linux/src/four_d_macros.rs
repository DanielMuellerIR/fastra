//! Native Textmakros mit vollständiger, an Dokument/Pfad/Projekt/Auswahl gebundener Vorschau.
use super::*;
use fastra_core::four_d_macros::{self as core, Capability, Macro};
use std::{collections::HashMap, path::PathBuf, rc::Weak, sync::Arc};
mod discovery;
mod runtime;
#[derive(Clone, PartialEq, Eq)]
struct Owner {
    document: usize,
    path: PathBuf,
    revision: u64,
    generation: u64,
    project: Option<String>,
    selection: (i32, i32),
    pane:(usize,u64,u64,u64),
}
fn source(ui: &Rc<Ui>) -> Option<(Rc<Document>, Owner, String)> {
    let doc = ui.active()?;
    let path = doc.disk_path()?;
    if doc.source_edits_locked()
        || !ui.window.is_visible()
        || path
            .extension()
            .is_none_or(|e| !e.eq_ignore_ascii_case("4dm"))
    {
        return None;
    }
    if doc.buffer.char_count() as usize > core::Limits::default().output_bytes {
        return None;
    }
    let text = buffer_text(&doc.buffer);
    if text_limits::validate(&text, ui.lang).is_err() {
        return None;
    }
    if text.len() > 4 * 1024 * 1024 {
        return None;
    }
    let binding = project_view::current_binding(ui);
    if ui.project.borrow().is_some() && binding.as_ref().is_none_or(|b| !b.is_current()) {
        return None;
    }
    let pane=source_panes::stamp(&doc)?;
    let buffer=source_panes::buffer(&doc);
    let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
        let at = buffer.iter_at_mark(&buffer.get_insert());
        (at, at)
    });
    let owner = Owner {
        document: Rc::as_ptr(&doc) as usize,
        path,
        revision: doc.revision.get(),
        generation: ui.generation.get(),
        project: binding.map(|b| b.owner_id()),
        selection: (a.offset(), b.offset()),
        pane,
    };
    Some((doc, owner, text))
}
fn current(ui: &Rc<Ui>, expected: &Owner) -> bool {
    let Some(doc) = ui.active() else { return false };
    if !ui.window.is_visible()
        || doc.source_edits_locked()
        || Rc::as_ptr(&doc) as usize != expected.document
        || doc.disk_path().as_ref() != Some(&expected.path)
        || doc.revision.get() != expected.revision
        || ui.generation.get() != expected.generation
    {
        return false;
    }
    let binding = project_view::current_binding(ui);
    if ui.project.borrow().is_some() && binding.as_ref().is_none_or(|b| !b.is_current()) {
        return false;
    }
    if source_panes::stamp(&doc)!=Some(expected.pane){return false;}
    let buffer=source_panes::buffer(&doc);
    let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
        let at = buffer.iter_at_mark(&buffer.get_insert());
        (at, at)
    });
    binding.map(|b| b.owner_id()) == expected.project
        && (a.offset(), b.offset()) == expected.selection
}
fn byte_offset(text: &str, chars: i32) -> Option<usize> {
    if chars < 0 {
        return None;
    }
    text.char_indices()
        .map(|(i, _)| i)
        .chain(std::iter::once(text.len()))
        .nth(chars as usize)
}
fn capability_text(m: &Macro, lang: Language) -> String {
    match core::capability(m){
        Capability::NativeText=>lang.text("Textmakro – ohne Tool4D","Text macro – no Tool4D required").into(),
        Capability::Runtime(_)=>lang.text("Runtime-Makro: Tool4D und ein MacroRun-Engine-Projekt wählen, dann ausdrücklich die Vorschau starten. Der Lauf arbeitet ohne Netzwerk auf einer privaten Projektkopie.","Runtime macro: choose Tool4D and a MacroRun engine project, then explicitly start the preview. Execution uses a private project copy without network access.").into(),
        Capability::Unsupported(reason)=>{
            let detail=if let Some(tag)=reason.strip_prefix("unknown-placeholder:"){format!("{} <{tag}/>",lang.text("Unbekannter Platzhalter:","Unknown placeholder:"))}
                else if let Some(n)=reason.strip_prefix("date-format:"){format!("{} {n} (0–8)",lang.text("Ungültiges Datumsformat:","Invalid date format:"))}
                else if let Some(n)=reason.strip_prefix("time-format:"){format!("{} {n} (0–6)",lang.text("Ungültiges Zeitformat:","Invalid time format:"))}
                else if let Some(method)=reason.strip_prefix("method:"){format!("{} {method}",lang.text("Benötigt den 4D-Methodeneditor:","Requires the 4D method editor:"))}
                else{match reason.as_str(){"multiple-method-calls"=>lang.text("Mehrere Methodenaufrufe in einem Makro benötigen den 4D-Methodeneditor.","Multiple method calls in one macro require the 4D method editor.").into(),"runtime-arguments"=>lang.text("Die Argumente passen zu keiner unterstützten Komplettieren-Variante.","The arguments do not match a supported completion-macro variant.").into(),"clipboard"=>lang.text("Zwischenablage-Makros laufen nur im 4D-Methodeneditor.","Clipboard macros require the 4D method editor.").into(),"separator"=>lang.text("Trennlinie; kein ausführbares Makro.","Separator; no executable macro.").into(),"display-only"=>lang.text("Reiner Anzeigeeintrag ohne einzufügenden Text.","Display entry without insertable text.").into(),_=>lang.text("Der Methodenaufruf ist nicht lesbar oder wird nicht unterstützt.","The method call is unreadable or unsupported.").into()}};
            format!("{}\n{detail}",lang.text("Nicht unterstützt. Das Makro wird nicht unvollständig eingesetzt.","Unsupported. An incomplete macro is never inserted."))
        }
    }
}
fn macro_details(m: &Macro, lang: Language) -> String {
    let mut text = format!(
        "{}\n{}\n\n{}\n\n",
        m.display_name,
        m.source_label,
        capability_text(m, lang)
    );
    for part in &m.parts {
        let value = match part {
            core::Part::Literal(s) => s.clone(),
            core::Part::Caret => "<caret/>".into(),
            core::Part::Selection => "<selection/>".into(),
            core::Part::FullText => "<text/>".into(),
            core::Part::MethodName => "<method_name/>".into(),
            core::Part::UserOS => "<user_os/>".into(),
            core::Part::Clipboard => "<clipboard/>".into(),
            core::Part::Date(n) => format!("<date format=\"{n}\"/>"),
            core::Part::Time(n) => format!("<time format=\"{n}\"/>"),
        };
        if text.len() + value.len() > 65536 {
            text.push_str(lang.text("\n[Beschreibung begrenzt. Für den vollständigen Ergebnistext Vorschau vorbereiten.]","\n[Description limited. Prepare a preview for the complete result text.]"));
            break;
        }
        text.push_str(&value);
    }
    if let Some(call) = &m.method_call {
        text.push_str("\n<method>");
        text.extend(call.chars().take(16000));
        text.push_str("</method>");
    }
    text
}
struct Hub {
    ui: Weak<Ui>,
    config: RefCell<discovery::Config>,
    catalog: RefCell<Option<Arc<discovery::Catalog>>>,
    key: RefCell<Option<(PathBuf, Option<String>)>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    busy: Cell<bool>,
    settings_loaded: Cell<bool>,
    dialog: RefCell<Weak<State>>,
    problem: RefCell<Option<String>>,
}
thread_local! {static HUBS:RefCell<HashMap<usize,Weak<Hub>>>=RefCell::new(HashMap::new());}
fn hub(ui: &Rc<Ui>) -> Rc<Hub> {
    let key = Rc::as_ptr(ui) as usize;
    HUBS.with(|all| {
        let mut all = all.borrow_mut();
        all.retain(|_, h| h.strong_count() > 0);
        if let Some(h) = all.get(&key).and_then(Weak::upgrade) {
            return h;
        }
        let h = Rc::new(Hub {
            ui: Rc::downgrade(ui),
            config: RefCell::new(Default::default()),
            catalog: RefCell::new(None),
            key: RefCell::new(None),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            busy: Cell::new(false),
            settings_loaded: Cell::new(false),
            dialog: RefCell::new(Weak::new()),
            problem: RefCell::new(None),
        });
        all.insert(key, Rc::downgrade(&h));
        h
    })
}
impl Hub {
    fn refresh(self: &Rc<Self>, force: bool, read_settings: bool) {
        let Some(ui) = self.ui.upgrade() else { return };
        let Some((_, owner, _)) = source(&ui) else {
            self.cancel.borrow().cancel();
            self.key.borrow_mut().take();
            self.catalog.borrow_mut().take();
            return;
        };
        let key = (owner.path.clone(), owner.project.clone());
        if !force && self.key.borrow().as_ref() == Some(&key) {
            return;
        }
        self.cancel.borrow().cancel();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.generation.set(self.generation.get() + 1);
        let generation = self.generation.get();
        *self.key.borrow_mut() = Some(key);
        if let Some(dialog) = self.dialog.borrow().upgrade() {
            dialog.invalidate();
        }
        self.busy.set(true);
        let path = owner.path.clone();
        let selected_root = project_view::current_binding(&ui).map(|b| b.root.path.clone());
        let configured = self.config.borrow().clone();
        let read_settings = read_settings || !self.settings_loaded.get();
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                let config = if read_settings {
                    discovery::load_config()?
                } else {
                    configured
                };
                let catalog = discovery::load(
                    &path,
                    selected_root.as_deref(),
                    &config,
                    force,
                    &cancel,
                    lang,
                )?;
                Ok((config, catalog))
            },
            move |result| {
                let Some(h) = weak.upgrade() else { return };
                if h.generation.get() != generation {
                    return;
                }
                h.busy.set(false);
                let Some(ui) = h.ui.upgrade() else { return };
                if !source(&ui).is_some_and(|(_, now, _)| {
                    now.path == owner.path && now.project == owner.project
                }) {
                    return;
                }
                match result {
                    Ok((config, catalog)) => {
                        h.settings_loaded.set(true);
                        *h.config.borrow_mut() = config;
                        *h.catalog.borrow_mut() = Some(catalog);
                        h.problem.borrow_mut().take();
                    }
                    Err(e) => {
                        h.catalog.borrow_mut().take();
                        *h.problem.borrow_mut() = Some(e);
                    }
                }
                if let Some(dialog) = h.dialog.borrow().upgrade() {
                    dialog.render();
                };
            },
        );
        if let Some(dialog) = self.dialog.borrow().upgrade() {
            dialog.render();
        }
    }
}
pub(super) fn install(ui: &Rc<Ui>) {
    let h = hub(ui);
    let switch = h.clone();
    ui.tabs.connect_switch_page(move |_, _, _| {
        let h = switch.clone();
        glib::idle_add_local_once(move || h.refresh(false, false));
    });
    let initial = h.clone();
    glib::idle_add_local_once(move || initial.refresh(false, true));
    let hold = h.clone();
    ui.window.connect_destroy(move |_| {
        hold.cancel.borrow().cancel();
    });
}
pub(super) fn shortcut(ui: &Rc<Ui>, key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> bool {
    if !modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
        || modifiers.intersects(
            gtk::gdk::ModifierType::ALT_MASK
                | gtk::gdk::ModifierType::SUPER_MASK
                | gtk::gdk::ModifierType::META_MASK,
        )
    {
        return false;
    }
    let Some(c) = key.to_unicode() else {
        return false;
    };
    let key = c.to_lowercase().collect::<String>();
    if editor_shortcuts::reserved_macro_keys().contains(&key) {
        return false;
    }
    let h = hub(ui);
    if h.busy.get() {
        return false;
    }
    if !source(ui)
        .is_some_and(|(_, owner, _)| h.key.borrow().as_ref() == Some(&(owner.path, owner.project)))
    {
        return false;
    }
    let Some(catalog) = h.catalog.borrow().clone() else {
        return false;
    };
    let Some(m) = catalog
        .macros
        .iter()
        .find(|m| m.shortcut.as_ref() == Some(&key))
    else {
        return false;
    };
    let Some(state) = create(ui) else {
        return false;
    };
    state.filter.set_text("");
    state.sources.set_selected(0);
    state.selected.borrow_mut().replace(m.id.clone());
    state.render();
    state.prepare();
    true
}
struct Preview {
    owner: Owner,
    original: String,
    result: String,
    caret: i32,
    before: String,
    after: String,
}
struct RenderGuard<'a>(&'a Cell<bool>);
impl Drop for RenderGuard<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}
struct State {
    hub: Rc<Hub>,
    window: gtk::Window,
    list: gtk::ListBox,
    filter: gtk::Entry,
    sources: gtk::DropDown,
    source_ids: RefCell<Vec<Option<String>>>,
    selection_rows: RefCell<Vec<String>>,
    selected: RefCell<Option<String>>,
    details: gtk::TextView,
    before: gtk::TextView,
    after: gtk::TextView,
    status: gtk::Label,
    prepare: gtk::Button,
    apply: gtk::Button,
    notebook: gtk::Notebook,
    preview: RefCell<Option<Preview>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    diff_cancel: RefCell<fastra_diff::Cancellation>,
    process_cancel: RefCell<fastra_process::Cancellation>,
    runtime_label: gtk::Label,
    engine_label: gtk::Label,
    running: Cell<bool>,
    rendering: Cell<bool>,
}
impl State {
    fn lang(&self) -> Language {
        self.hub.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn invalidate(&self) {
        self.running.set(false);
        self.cancel.borrow().cancel();
        self.diff_cancel.borrow().cancel();
        self.process_cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.preview.borrow_mut().take();
        self.apply.set_sensitive(false);
    }
    fn selected_macro(&self) -> Option<Macro> {
        let id = self.selected.borrow().clone()?;
        self.hub
            .catalog
            .borrow()
            .as_ref()?
            .macros
            .iter()
            .find(|m| m.id == id)
            .cloned()
    }
    fn render(&self) {
        if self.rendering.replace(true) {
            return;
        }
        let _render = RenderGuard(&self.rendering);
        let lang = self.lang();
        runtime::render_settings(self);
        let previous = self.selected.borrow().clone();
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        self.selection_rows.borrow_mut().clear();
        let Some(catalog) = self.hub.catalog.borrow().clone() else {
            self.status.set_text(if self.hub.busy.get() {
                lang.text(
                    "Makroquellen werden im Hintergrund gelesen …",
                    "Reading macro sources in background …",
                )
            } else {
                lang.text(
                    "Keine Makros geladen. Quellen wählen oder erneut suchen.",
                    "No macros loaded. Choose sources or refresh.",
                )
            });
            if let Some(problem) = self.hub.problem.borrow().as_ref() {
                self.details.buffer().set_text(problem);
            }
            return;
        };
        let mut sources = vec![None];
        let mut labels = vec![lang.text("Alle Quellen", "All sources").to_string()];
        for source in &catalog.sources {
            let key = discovery::source_id(&source.path);
            labels.push(source.label.clone());
            sources.push(Some(key));
        }
        if *self.source_ids.borrow() != sources {
            *self.source_ids.borrow_mut() = sources;
            self.sources.set_model(Some(&gtk::StringList::new(
                &labels.iter().map(String::as_str).collect::<Vec<_>>(),
            )));
            self.sources.set_selected(0);
        }
        let selected_source = self
            .source_ids
            .borrow()
            .get(self.sources.selected() as usize)
            .cloned()
            .flatten();
        let filter = self.filter.text().to_lowercase();
        for m in &catalog.macros {
            if selected_source
                .as_ref()
                .is_some_and(|id| !m.id.starts_with(&format!("{id}#")))
                || !m.display_name.to_lowercase().contains(&filter)
            {
                continue;
            }
            let title = if m.separator {
                String::from("────────")
            } else {
                format!(
                    "{}{} · {}",
                    m.display_name,
                    m.shortcut
                        .as_ref()
                        .map_or(String::new(), |s| format!("   Ctrl+{s}")),
                    match core::capability(m) {
                        Capability::NativeText => lang.text("Text", "Text"),
                        Capability::Runtime(_) => lang.text("Tool4D", "Tool4D"),
                        Capability::Unsupported(_) => lang.text("nicht unterstützt", "unsupported"),
                    }
                )
            };
            let label = gtk::Label::new(Some(&title));
            label.set_xalign(0.);
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            label.set_max_width_chars(70);
            label.set_tooltip_text(Some(&m.source_label));
            label.set_margin_top(7);
            label.set_margin_bottom(7);
            self.list.append(&label);
            self.selection_rows.borrow_mut().push(m.id.clone());
            if previous.as_ref() == Some(&m.id) {
                if let Some(row) = self
                    .list
                    .row_at_index((self.selection_rows.borrow().len() - 1) as i32)
                {
                    self.list.select_row(Some(&row));
                }
            }
        }
        if self
            .selected
            .borrow()
            .as_ref()
            .is_some_and(|id| !self.selection_rows.borrow().contains(id))
        {
            self.invalidate();
            self.selected.borrow_mut().take();
        }
        if let Some(m) = self.selected_macro() {
            self.details.buffer().set_text(&macro_details(&m, lang));
        }
        self.prepare.set_sensitive(
            !self.running.get()
                && !self.hub.busy.get()
                && self
                    .selected_macro()
                    .is_some_and(|m| runtime::can_prepare(self, &m)),
        );
        self.status.set_text(&format!(
            "{} {} · {} {} · {} {}",
            catalog.macros.len(),
            lang.text("Makros", "macros"),
            catalog.sources.len(),
            lang.text("Quellen", "sources"),
            catalog.issues.len(),
            lang.text("Quellmeldungen", "source diagnostics")
        ));
        if self.selected_macro().is_none() {
            self.details.buffer().set_text(&format!(
                "{}\n{}\n{}",
                lang.text(
                    "Quelle und Makro wählen. Nicht lesbare Quellen:",
                    "Choose a source and macro. Unreadable sources:"
                ),
                catalog
                    .project
                    .as_ref()
                    .map_or(String::new(), |p| project_view::display(p)),
                catalog.issues.join("\n")
            ));
        }
    }
    fn prepare(self: &Rc<Self>) {
        self.invalidate();
        let Some(ui) = self.hub.ui.upgrade() else {
            return;
        };
        let Some((_, owner, text)) = source(&ui) else {
            self.status.set_text(self.lang().text(
                "Gültigen .4dm-Tab und unveränderte Projektwahl herstellen.",
                "Restore a valid .4dm tab and unchanged project selection.",
            ));
            return;
        };
        let Some(m) = self.selected_macro() else {
            return;
        };
        let lang = ui.lang;
        if self.hub.busy.get() {
            self.status.set_text(lang.text(
                "Makroquellen werden neu geladen. Bitte warten.",
                "Macro sources are being refreshed. Please wait.",
            ));
            return;
        }
        if let Capability::Runtime(variant) = core::capability(&m) {
            self.prepare_runtime(owner, text, variant);
            return;
        }
        if core::capability(&m) != Capability::NativeText {
            self.status.set_text(&capability_text(&m, lang));
            return;
        }
        let Some(start) = byte_offset(&text, owner.selection.0) else {
            return;
        };
        let Some(end) = byte_offset(&text, owner.selection.1) else {
            return;
        };
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let diff_cancel = fastra_diff::Cancellation::default();
        *self.diff_cancel.borrow_mut() = diff_cancel.clone();
        self.running.set(true);
        self.prepare.set_sensitive(false);
        self.status.set_text(lang.text(
            "Vollständige Makro-Vorschau wird berechnet …",
            "Building complete macro preview …",
        ));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                let millis = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|e| e.to_string())?
                    .as_millis() as f64;
                let locale = std::env::var("LC_ALL")
                    .or_else(|_| std::env::var("LC_TIME"))
                    .or_else(|_| std::env::var("LANG"))
                    .unwrap_or_else(|_| "en_US".into())
                    .split('.')
                    .next()
                    .unwrap_or("en_US")
                    .to_owned();
                let mut dates = std::array::from_fn(|_| String::new());
                let mut times = std::array::from_fn(|_| String::new());
                for (i, s) in dates.iter_mut().enumerate() {
                    if !m.parts.contains(&core::Part::Date(i as i64)) {
                        continue;
                    }
                    *s = core::date_time(millis, &locale, "", false, i as u8)
                        .map_err(|e| format!("{e:?}"))?;
                }
                for (i, s) in times.iter_mut().enumerate() {
                    if !m.parts.contains(&core::Part::Time(i as i64)) {
                        continue;
                    }
                    *s = core::date_time(millis, &locale, "", true, i as u8)
                        .map_err(|e| format!("{e:?}"))?;
                }
                let method = if m.parts.contains(&core::Part::MethodName) {
                    core::normalized_method_name(
                        owner
                            .path
                            .file_name()
                            .and_then(|n| n.to_str())
                            .ok_or("UTF-8 method filename required for <method_name/>")?,
                    )
                } else {
                    String::new()
                };
                let user = if m.parts.contains(&core::Part::UserOS) {
                    glib::user_name()
                        .into_string()
                        .map_err(|_| "Operating-system username is not UTF-8")?
                } else {
                    String::new()
                };
                let insertion = core::render(
                    &m,
                    &core::Context {
                        full_text: &text,
                        selection: start..end,
                        method_name: &method,
                        user_os: &user,
                        dates: &dates,
                        times: &times,
                    },
                    core::Limits::default(),
                    &cancel,
                )
                .map_err(|e| format!("{e:?}"))?;
                let total = text.len() - (end - start) + insertion.text.len();
                if total > core::Limits::default().output_bytes {
                    return Err("Macro result limit: 8 MiB".into());
                }
                let mut result = String::with_capacity(total);
                result.push_str(&text[..start]);
                result.push_str(&insertion.text);
                result.push_str(&text[end..]);
                let caret_units = insertion
                    .caret_utf16
                    .unwrap_or_else(|| insertion.text.encode_utf16().count());
                let mut consumed = 0;
                let mut caret_chars = 0;
                for c in insertion.text.chars() {
                    if consumed == caret_units {
                        break;
                    }
                    consumed += c.len_utf16();
                    caret_chars += 1;
                }
                if consumed != caret_units {
                    return Err("Invalid macro caret boundary".into());
                }
                let caret = owner
                    .selection
                    .0
                    .checked_add(caret_chars)
                    .ok_or("Macro caret overflow")?;
                runtime::build_preview(
                    owner,
                    text,
                    result,
                    caret,
                    generation,
                    &cancel,
                    &diff_cancel,
                    lang,
                )
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if state.generation.get() != generation {
                    return;
                }
                state.running.set(false);
                state.prepare.set_sensitive(true);
                match result {
                    Ok(preview) => {
                        let valid = state
                            .hub
                            .ui
                            .upgrade()
                            .is_some_and(|ui| current(&ui, &preview.owner));
                        if !valid {
                            state.status.set_text(lang.text(
                                "Dokument, Auswahl oder Projekt geändert. Vorschau verworfen.",
                                "Document, selection or project changed. Preview discarded.",
                            ));
                            return;
                        }
                        state.before.buffer().set_text(&preview.before);
                        state.after.buffer().set_text(&preview.after);
                        *state.preview.borrow_mut() = Some(preview);
                        state.apply.set_sensitive(true);
                        state.notebook.set_current_page(Some(1));
                        state.status.set_text(lang.text("Vollständigen Diff prüfen. Erst Übernehmen ändert den gebundenen Editor.","Review the complete diff. Only Apply changes the bound editor."));
                    }
                    Err(e) => state.status.set_text(&format!(
                        "{}: {e}",
                        lang.text("Keine Änderung", "No change")
                    )),
                }
            },
        );
    }
    fn apply(&self) {
        if self.before.width() < 180
            || self.after.width() < 180
            || !self.before.is_mapped()
            || !self.after.is_mapped()
        {
            self.status.set_text(self.lang().text(
                "Auf die vollständige Vorschau warten.",
                "Wait for the complete preview.",
            ));
            return;
        }
        let Some(ui) = self.hub.ui.upgrade() else {
            return;
        };
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        self.apply.set_sensitive(false);
        let Some((doc, now, text)) = source(&ui) else {
            self.status.set_text(self.lang().text(
                "Vorschau veraltet. Erneut vorbereiten.",
                "Preview is stale. Prepare again.",
            ));
            return;
        };
        if now != preview.owner || text != preview.original {
            self.status.set_text(self.lang().text(
                "Vorschau veraltet. Erneut vorbereiten.",
                "Preview is stale. Prepare again.",
            ));
            return;
        }
        let selected_buffer=source_panes::buffer(&doc);
        source_panes::replace_result(&selected_buffer,&preview.result);
        let buffer=source_panes::buffer(&doc);
        let caret=buffer.iter_at_offset(preview.caret);
        buffer.select_range(&caret,&caret);
        doc.update_saved_baseline_status(&preview.result);
        self.status.set_text(self.lang().text(
            "Makro als ein Undo-Schritt übernommen. Datei noch nicht gespeichert.",
            "Macro applied as one undo step. File has not been saved.",
        ));
    }
}
fn create(ui: &Rc<Ui>) -> Option<Rc<State>> {
    if source(ui).is_none() {
        ui.status.set_text(ui.lang.text(
            "Textmakros brauchen eine editierbare .4dm-Datei bis 4 MiB.",
            "Text macros require an editable .4dm file up to 4 MiB.",
        ));
        return None;
    }
    let h = hub(ui);
    if let Some(state) = h.dialog.borrow().upgrade() {
        state.window.present();
        return Some(state);
    }
    let lang = ui.lang;
    let window = git_view::window(ui, lang.text("4D-Textmakros", "4D text macros"), true);
    window.set_default_size(980, 780);
    window.set_size_request(680, 660);
    let root = git_view::column();
    root.append(&git_view::label(lang.text("Lokale Macros-v2-XML. Textmakros funktionieren ohne Tool4D. Jede Änderung erhält eine vollständige Vorschau.","Local Macros v2 XML. Text macros work without Tool4D. Every change receives a complete preview.")));
    let sources = git_view::file_dropdown();
    sources.set_model(Some(&gtk::StringList::new(&[
        lang.text("Alle Quellen", "All sources")
    ])));
    root.append(&sources);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let refresh = gtk::Button::with_label(lang.text("Neu laden", "Refresh"));
    let user = gtk::Button::with_label(lang.text("Eigene Makros …", "User macros …"));
    let installation = gtk::Button::with_label(lang.text("4D-Ordner …", "4D directory …"));
    let reset = gtk::Button::with_label(lang.text("XDG-Vorgaben", "XDG defaults"));
    for button in [&refresh, &user, &installation, &reset] {
        actions.append(button);
    }
    root.append(&actions);
    let (runtime_label, engine_label, runtime_button, engine_button) =
        runtime::settings_controls(&root, lang);
    let notebook = gtk::Notebook::new();
    notebook.set_vexpand(true);
    let catalog_pane = gtk::Paned::new(gtk::Orientation::Horizontal);
    let left = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let filter = gtk::Entry::builder()
        .placeholder_text(lang.text("Makros filtern", "Filter macros"))
        .build();
    left.append(&filter);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    left.append(&git_view::scroll(&list));
    let details = git_view::output();
    details.set_wrap_mode(gtk::WrapMode::WordChar);
    catalog_pane.set_start_child(Some(&left));
    catalog_pane.set_end_child(Some(&git_view::scroll(&details)));
    catalog_pane.set_position(360);
    notebook.append_page(
        &catalog_pane,
        Some(&gtk::Label::new(Some(lang.text(
            "Katalog und Fähigkeiten",
            "Catalog and capabilities",
        )))),
    );
    let diff = gtk::Paned::new(gtk::Orientation::Horizontal);
    let before = git_view::output();
    let after = git_view::output();
    for (view, title, start) in [
        (&before, lang.text("Vorher", "Before"), true),
        (&after, lang.text("Nachher", "After"), false),
    ] {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
        column.set_size_request(200, -1);
        column.append(&gtk::Label::new(Some(title)));
        column.append(&git_view::scroll(view));
        if start {
            diff.set_start_child(Some(&column));
        } else {
            diff.set_end_child(Some(&column));
        }
    }
    git_view::balance_panes(&diff);
    notebook.append_page(
        &diff,
        Some(&gtk::Label::new(Some(lang.text(
            "Vollständige Diff-Vorschau",
            "Complete diff preview",
        )))),
    );
    root.append(&notebook);
    let status = git_view::label("");
    root.append(&status);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let prepare = gtk::Button::with_label(lang.text("Vorschau vorbereiten", "Prepare preview"));
    let apply = gtk::Button::with_label(lang.text("Übernehmen", "Apply"));
    apply.set_sensitive(false);
    let cancel_job = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let close = gtk::Button::with_label(lang.text("Schließen", "Close"));
    for b in [&prepare, &apply, &cancel_job, &close] {
        buttons.append(b);
    }
    root.append(&buttons);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        hub: h.clone(),
        window: window.clone(),
        list,
        filter,
        sources,
        source_ids: RefCell::new(vec![]),
        selection_rows: RefCell::new(vec![]),
        selected: RefCell::new(None),
        details,
        before,
        after,
        status,
        prepare,
        apply,
        notebook,
        preview: RefCell::new(None),
        generation: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        diff_cancel: RefCell::new(fastra_diff::Cancellation::default()),
        process_cancel: RefCell::new(fastra_process::Cancellation::default()),
        runtime_label,
        engine_label,
        running: Cell::new(false),
        rendering: Cell::new(false),
    });
    *h.dialog.borrow_mut() = Rc::downgrade(&state);
    runtime::connect_settings(&state, runtime_button, engine_button);
    let weak = Rc::downgrade(&state);
    cancel_job.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.invalidate();
            s.prepare.set_sensitive(
                s.selected_macro()
                    .is_some_and(|m| runtime::can_prepare(&s, &m)),
            );
            s.status.set_text(s.lang().text(
                "Makroauftrag abgebrochen. Keine Änderung übernommen.",
                "Macro request cancelled. No changes applied.",
            ));
        }
    });
    let weak = Rc::downgrade(&state);
    state.list.connect_row_selected(move |_, row| {
        if let Some(s) = weak.upgrade() {
            if let Some(row) = row {
                let id = s.selection_rows.borrow().get(row.index() as usize).cloned();
                if *s.selected.borrow() != id {
                    s.invalidate();
                }
                *s.selected.borrow_mut() = id;
                if let Some(m) = s.selected_macro() {
                    s.details.buffer().set_text(&macro_details(&m, s.lang()));
                    s.prepare.set_sensitive(
                        runtime::can_prepare(&s, &m) && !s.running.get() && !s.hub.busy.get(),
                    );
                }
            }
        }
    });
    let weak = Rc::downgrade(&state);
    state.filter.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.render();
        }
    });
    let weak = Rc::downgrade(&state);
    state.sources.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.render();
        }
    });
    let weak = Rc::downgrade(&state);
    state.prepare.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.prepare();
        }
    });
    let weak = Rc::downgrade(&state);
    state.apply.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.apply();
        }
    });
    let hub = h.clone();
    refresh.connect_clicked(move |_| hub.refresh(true, true));
    let weak = window.downgrade();
    close.connect_clicked(move |_| {
        if let Some(w) = weak.upgrade() {
            w.close();
        }
    });
    for (button, field) in [
        (user, discovery::Field::User),
        (installation, discovery::Field::Installation),
    ] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                runtime::choose_setting(&s, field, true);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    reset.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            runtime::save_setting(&s, discovery::Change::Reset);
        }
    });
    let weak = Rc::downgrade(&state);
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(move |_, key, _, mods| {
        if key == gtk::gdk::Key::Return && mods.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
            if let Some(s) = weak.upgrade() {
                s.prepare();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
    git_view::hold(&window, state.clone(), State::invalidate);
    window.present();
    state.render();
    h.refresh(false, false);
    Some(state)
}
pub(super) fn open(ui: &Rc<Ui>) {
    let _ = create(ui);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>, menu: gtk::MenuButton, entry: gtk::Button) {
    gui_test::run(ui, menu, entry);
}

#[cfg(debug_assertions)]
mod runtime_gui_test;
#[cfg(debug_assertions)]
pub(super) fn runtime_selftest(ui: Rc<Ui>) {
    runtime_gui_test::run(ui);
}

#[cfg(debug_assertions)]
mod shell_gui_test;
#[cfg(debug_assertions)]
pub(super) fn shell_selftest(ui: Rc<Ui>) {
    shell_gui_test::run(ui);
}
