use super::*;
use sourceview5::prelude::*;
pub(super) struct View {
    pub window: gtk::Window,
    pub source: sourceview5::View,
    pub buffer: sourceview5::Buffer,
    status: Option<gtk::Label>,
    setting: Rc<Cell<bool>>,
    primary_suspended: Rc<Cell<bool>>,
}
fn primary_policy(source: &sourceview5::View) -> Rc<Cell<bool>> {
    let suspended = Rc::new(Cell::new(false));
    let state = suspended.clone();
    // Vor GTKs unrealize-Handler die von der View gehaltene Registrierung ausgleichen.
    source.connect_unrealize(move |source| {
        if state.replace(false) {
            source
                .buffer()
                .add_selection_clipboard(&source.primary_clipboard());
        }
    });
    suspended
}
fn offset(text: &str, units: i64) -> i32 {
    let mut count = 0i64;
    for (index, c) in text.chars().enumerate() {
        if count == units {
            return index as i32;
        }
        count += c.len_utf16() as i64;
    }
    text.chars().count() as i32
}
impl View {
    pub fn new(
        application: &gtk::Application,
        lang: Language,
        name: &str,
        provenance: Option<&Provenance>,
    ) -> Self {
        let window = gtk::Window::builder()
            .application(application)
            .title(lang.text("Schreibgeschützter Snapshot", "Read-only snapshot"))
            .default_width(900)
            .default_height(650)
            .build();
        window.set_size_request(400, if provenance.is_some() { 420 } else { 240 });
        crate::chrome::snapshot::decorate(
            &window,
            lang.text("Schreibgeschützter Snapshot", "Read-only snapshot"),
            lang,
        );
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let filename = support::label(&super::super::project_view::display(Path::new(name)));
        filename.set_single_line_mode(true);
        filename.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        filename.set_tooltip_text(Some(&format!("{name:?}")));

        let status = support::label(lang.text("Snapshot wird geladen …", "Loading snapshot …"));
        status.set_wrap(true);
        root.append(&crate::chrome::snapshot::header(&filename, &status));
        if let Some(p) = provenance {
            let text = provenance_text(p, lang);
            let label = gtk::TextView::builder()
                .editable(false)
                .cursor_visible(false)
                .wrap_mode(gtk::WrapMode::WordChar)
                .build();
            label.buffer().set_text(&text);
            let origin = gtk::ScrolledWindow::builder()
                .min_content_height(110)
                .max_content_height(140)
                .hscrollbar_policy(gtk::PolicyType::Never)
                .child(&label)
                .build();
            origin.add_css_class("snapshot-provenance");
            origin.set_margin_start(12);
            origin.set_margin_end(12);
            origin.set_margin_bottom(8);
            root.append(&origin);
        }
        let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
        buffer.set_enable_undo(false);
        let source = sourceview5::View::with_buffer(&buffer);
        crate::source_appearance::install(&source, &buffer);
        crate::chrome::snapshot::source(&source);
        source.set_editable(false);
        source.set_monospace(true);

        source.set_wrap_mode(gtk::WrapMode::WordChar);
        root.append(
            &gtk::ScrolledWindow::builder()
                .vexpand(true)
                .child(&source)
                .build(),
        );
        window.set_child(Some(&root));
        let keys = gtk::EventControllerKey::new();
        let weak = window.downgrade();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if key == gtk::gdk::Key::w && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
                if let Some(window) = weak.upgrade() {
                    window.close();
                }
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(keys);
        let primary_suspended = primary_policy(&source);
        Self {
            window,
            source,
            buffer,
            status: Some(status),
            setting: Rc::new(Cell::new(false)),
            primary_suspended,
        }
    }
    pub fn from_player(player: &code_explanation::Player) -> Self {
        let (window, source, buffer, setting) = player.control_view();
        let primary_suspended = primary_policy(&source);
        Self {
            window,
            source,
            buffer,
            setting,
            primary_suspended,
            status: None,
        }
    }
    pub fn install(&self, l: &Loaded) {
        self.setting.set(true);
        self.window
            .set_title(Some(&format!("Snapshot: {}", l.name.replace('\0', "\\0"))));
        self.buffer.set_text(&l.text);
        let manager = sourceview5::LanguageManager::default();
        self.buffer
            .set_language(manager.guess_language(Some(&l.name), None).as_ref());
        self.buffer.set_modified(false);
        self.setting.set(false);
    }
    pub fn selection(&self) -> Selection {
        let (start, end) = self.buffer.selection_bounds().unwrap_or_else(|| {
            let i = self.buffer.iter_at_mark(&self.buffer.get_insert());
            (i, i)
        });
        let units = |iter: &gtk::TextIter| {
            self.buffer
                .text(&self.buffer.start_iter(), iter, true)
                .encode_utf16()
                .count() as i64
        };
        Selection {
            location: units(&start),
            length: units(&end) - units(&start),
        }
    }
    pub fn select(&self, s: &Selection) {
        let text = self
            .buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true);
        let a = self.buffer.iter_at_offset(offset(&text, s.location));
        let b = self
            .buffer
            .iter_at_offset(offset(&text, s.location + s.length));
        self.setting.set(true);
        // Ein automatischer Sprung darf PRIMARY nicht übernehmen. Unter Wayland
        // kann deren abgewiesene Übernahme sonst die Zielauswahl wieder löschen.
        if self.source.is_realized() && !self.primary_suspended.replace(true) {
            self.buffer
                .remove_selection_clipboard(&self.source.primary_clipboard());
        }
        self.source.grab_focus();
        self.buffer.select_range(&a, &b);
        self.setting.set(false);
        self.scroll(s);
    }
    pub fn resume_primary(&self) {
        if self.primary_suspended.replace(false) && self.source.is_realized() {
            self.buffer
                .add_selection_clipboard(&self.source.primary_clipboard());
        }
    }
    pub fn scroll(&self, s: &Selection) {
        let text = self
            .buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true);
        let mut iter = self.buffer.iter_at_offset(offset(&text, s.location));
        self.source.scroll_to_iter(&mut iter, 0.15, true, 0., 0.2);
    }
    pub fn content_matches(&self, l: &Loaded, s: &Selection) -> bool {
        self.buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true)
            .as_str()
            == l.text.as_ref()
            && self.selection() == *s
    }
    pub fn selection_visible(&self, s: &Selection) -> bool {
        let text = self
            .buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true);
        let a = self.buffer.iter_at_offset(offset(&text, s.location));
        let b = self
            .buffer
            .iter_at_offset(offset(&text, s.location + s.length));
        let mut rect = self
            .source
            .iter_location(&a)
            .union(&self.source.iter_location(&b));
        rect.set_width(rect.width().max(1));
        rect.set_height(rect.height().max(1));
        rect.intersect(&self.source.visible_rect()).is_some()
    }
    #[cfg(debug_assertions)]
    pub fn confirms(&self, l: &Loaded, s: &Selection) -> bool {
        self.content_matches(l, s) && self.selection_visible(s)
    }
    pub fn ready(&self) {
        if let Some(s) = &self.status {
            s.set_text(language().text("Schreibgeschützter Snapshot", "Read-only snapshot"));
        }
    }
    pub fn failure(&self, error: Option<&Failure>) {
        if let Some(status) = &self.status {
            status.set_text(failure_text(error, language()));
        }
    }
}
pub(super) fn failure_text(error: Option<&Failure>, lang: Language) -> &'static str {
    if error.is_some_and(|e| e.message == io::NUL_MESSAGE) {
        return lang.text("Die Quelle enthält U+0000. Die Linux-Textansicht kann diesen Inhalt nicht unverändert anzeigen.","The source contains U+0000. The Linux text view cannot display this content unchanged.");
    }
    match error.map(|e| e.code.as_str()) {
        Some("invalidRequest") => lang.text(
            "Das Erklärungspaket oder der Steuerungsauftrag hat ein ungültiges Format.",
            "The explanation package or control request has an invalid format.",
        ),
        Some("unsupported") => lang.text(
            "Diese Steuerungsoperation oder Protokollversion wird nicht unterstützt.",
            "This control operation or protocol version is not supported.",
        ),
        Some("invalidID") => lang.text(
            "Die Sitzung oder Dokumentbindung ist nicht mehr gültig.",
            "The session or document binding is no longer valid.",
        ),
        Some("stale") => lang.text(
            "Quellstand stimmt nicht überein.",
            "The source binding does not match.",
        ),
        Some("sourceUnavailable") => lang.text(
            "Quelle nicht verfügbar oder kein begrenzter Text.",
            "The source is unavailable or is not bounded text.",
        ),
        Some("capacity") => lang.text(
            "Das Sitzungs-, Auftrags- oder Quellbudget ist ausgeschöpft.",
            "The session, job or source budget has been reached.",
        ),
        Some("invalidRange") => lang.text(
            "Auswahl liegt nicht auf vollständigen Zeichen.",
            "Selection is not on complete character boundaries.",
        ),
        Some("expired") => lang.text(
            "Zeitgrenze des Auftrags überschritten.",
            "The job deadline has elapsed.",
        ),
        Some("delivery") => lang.text(
            "Die Anwendung hat den Auftrag nicht rechtzeitig bestätigt.",
            "The application did not confirm the request before the deadline.",
        ),
        _ => lang.text(
            "Snapshot-Navigation wurde abgebrochen.",
            "Snapshot navigation was interrupted.",
        ),
    }
}

pub(super) fn bind(s: &Rc<Session>) {
    let v = s.view.borrow();
    let weak = Rc::downgrade(s);
    let setting = v.setting.clone();
    let marks = Cell::new((
        v.buffer.cursor_position(),
        v.buffer.iter_at_mark(&v.buffer.selection_bound()).offset(),
    ));
    v.buffer.connect_mark_set(move |buffer, _, mark| {
        if !matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
            return;
        }
        let current = (
            buffer.cursor_position(),
            buffer.iter_at_mark(&buffer.selection_bound()).offset(),
        );
        // GTK meldet Marken beim Öffnen auch ohne Bewegung. Eigene gesetzte
        // Auswahlen mitmerken, damit nur eine spätere Änderung als Erkunden zählt.
        let previous = marks.replace(current);
        if !setting.get() && current != previous {
            if let Some(s) = weak.upgrade() {
                s.view.borrow().resume_primary();
                s.interrupt();
            }
        }
    });
    let weak = Rc::downgrade(s);
    let setting = v.setting.clone();
    v.buffer.connect_changed(move |_| {
        if !setting.get() {
            if let Some(s) = weak.upgrade() {
                s.view.borrow().resume_primary();
                s.interrupt();
            }
        }
    });
    // Auch Herkunft und Scrollleisten gehören zur eigenen Fenstereingabe.
    let target: gtk::Widget = s.window.clone().upcast();
    let key = gtk::EventControllerKey::new();
    key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(s);
    key.connect_key_pressed(move |_, _, _, _| {
        if let Some(s) = weak.upgrade() {
            s.view.borrow().resume_primary();
            s.interrupt()
        }
        glib::Propagation::Proceed
    });
    target.add_controller(key);
    let click = gtk::GestureClick::new();
    click.set_button(0);
    click.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(s);
    click.connect_pressed(move |_, _, _, _| {
        if let Some(s) = weak.upgrade() {
            s.view.borrow().resume_primary();
            s.interrupt()
        }
    });
    target.add_controller(click);
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
    scroll.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(s);
    scroll.connect_scroll(move |_, _, _| {
        if let Some(s) = weak.upgrade() {
            s.view.borrow().resume_primary();
            s.interrupt()
        }
        glib::Propagation::Proceed
    });
    target.add_controller(scroll);
}
fn provenance_text(p: &Provenance, lang: Language) -> String {
    let mut lines = vec![lang
        .text(
            if p.kind == "original" {
                "Originaldatei als schreibgeschützter Sitzungssnapshot"
            } else {
                "Materialisiertes Archivmitglied — schreibgeschützte Sitzungskopie"
            },
            if p.kind == "original" {
                "Original file as a read-only session snapshot"
            } else {
                "Materialized archive member — read-only session copy"
            },
        )
        .to_string()];
    if p.kind == "archiveMaterialization" {
        lines.push(lang.text(if p.archive_binding=="sha256"{"Äußerer Archivinhalt und Generation geprüft; Mitgliedszuordnung vom Sender angegeben."}else{"Schwächere Herkunftsbindung: Nur die Archivgeneration ist geprüft, nicht der äußere Inhaltsstand."},if p.archive_binding=="sha256"{"Outer archive content and generation checked; member mapping supplied by sender."}else{"Weaker provenance: only archive generation checked, not outer content."}).into())
    }
    if p.position_binding == "unboundHit" {
        lines.push(
            lang.text(
                "Keine bestätigte Trefferposition; Ansicht beginnt am Dateianfang.",
                "No confirmed hit position; the view starts at the beginning.",
            )
            .into(),
        )
    }
    lines.push(format!(
        "{}: {:?}",
        lang.text("Quelle", "Source"),
        p.hit_identity.filesystem_path
    ));
    for (i, (name, raw)) in p
        .hit_identity
        .archive_members
        .iter()
        .zip(&p.hit_identity.archive_member_bytes)
        .enumerate()
    {
        lines.push(format!(
            "{} {}: {name:?}\nBase64: {raw}",
            lang.text("Archivmitglied", "Archive member"),
            i + 1
        ));
    }
    lines.push(format!(
        "{}: {}",
        lang.text("Suchlauf", "Search run"),
        p.run_id.as_str()
    ));
    if let Some(e) = &p.search_evidence {
        lines.push(format!(
            "{}: {e:?}",
            lang.text("Suchbeleg des Senders", "Sender search evidence")
        ));
    }
    lines.join("\n")
}
