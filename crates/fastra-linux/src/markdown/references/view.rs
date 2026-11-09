#[cfg(debug_assertions)]
#[path = "selftest.rs"]
pub(crate) mod selftest;
#[cfg(debug_assertions)]
thread_local! {static LAST:RefCell<Weak<State>>=const {RefCell::new(Weak::new())};}
#[cfg(debug_assertions)]
static WORK_DELAY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
use super::{
    check::{self, Notice, Options, Report, Source, Status},
    parser,
};
use crate::{project_view, *};
use std::{
    collections::HashMap,
    rc::Weak,
    sync::{Arc, Mutex},
    time::Instant,
};

pub(super) struct State {
    pub ui: Weak<Ui>,
    pub doc: Weak<Document>,
    pub window: gtk::Window,
    pub lang: Language,
    pub report: RefCell<Option<Arc<Report>>>,
    pub documents: RefCell<HashMap<usize, Weak<Document>>>,
    pub job: Cell<u64>,
    pub busy: Cell<bool>,
    pub cancel: RefCell<Cancellation>,
    pub selected: gtk::SingleSelection,
    pub visible: RefCell<Vec<usize>>,
    model: gtk::StringList,
    scope: gtk::Box,
    project: gtk::ToggleButton,
    problems: gtk::CheckButton,
    start: gtk::Button,
    jump: gtk::Button,
    status: gtk::Label,
    status_row: gtk::Box,
    status_icon: gtk::Image,
    timestamp: gtk::Label,
    spinner: gtk::Spinner,
    summary: gtk::Label,
    detail: gtk::Label,
    issues: gtk::Label,
    issues_scroll: gtk::ScrolledWindow,
    notice: gtk::Label,
    empty: gtk::Label,
    freshness: RefCell<HashMap<(usize, u64), bool>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
    }
}
pub(crate) fn show(ui: &Rc<Ui>) {
    let Some(doc) = ui.active().filter(|d| supported(d)) else {
        return;
    };
    let owner = Rc::downgrade(ui);
    let original = Rc::downgrade(&doc);
    crate::rich_editor::flush_documents_owned(
        &[doc],
        Box::new(move |ok| {
            let (Some(ui), Some(doc)) = (owner.upgrade(), original.upgrade()) else {
                return;
            };
            if ok && supported(&doc) && ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc)) {
                State::new(&ui, &doc).window.present();
            }
        }),
    );
}
pub(crate) fn supported(doc: &Document) -> bool {
    doc.has_source_text()
        && doc.buffer.language().is_some_and(|l| l.id() == "markdown")
        && !doc.saving.get()
        && !doc.close_pending.get()
}
fn label(text: &str, small: bool) -> gtk::Label {
    let label = git_view::label(text);
    if small {
        label.add_css_class("muted");
        label.add_css_class("caption");
    }
    label
}
fn button(lang: Language, de: &'static str, en: &'static str, id: &str) -> gtk::Button {
    let b = gtk::Button::with_label(lang.text(de, en));
    b.set_widget_name(id);
    b
}
impl State {
    pub(super) fn new(ui: &Rc<Ui>, doc: &Rc<Document>) -> Rc<Self> {
        let lang = ui.lang;
        let title = lang.text("Lokale Markdown-Verweise", "Local Markdown References");
        let window = git_view::window(ui, title, true);
        window.set_widget_name("fastra-markdown-references");
        window.add_css_class("fastra-references");
        // Die Mac-Vorlage ist ein Sheet: Titel und Schließen liegen bereits
        // im Inhalt. Eine zweite Fensterleiste würde das Raster verschieben.
        window.set_titlebar(None::<&gtk::Widget>);
        window.set_decorated(false);
        window.set_default_size(900, 700);
        window.set_size_request(640, 600);
        let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
        root.set_margin_top(20);
        root.set_margin_bottom(20);
        root.set_margin_start(20);
        root.set_margin_end(20);
        let heading = label(title, false);
        heading.add_css_class("title");
        root.append(&heading);
        let explanation=label(lang.text("Prüft Datei- und Bildziele sowie Markdown- und HTML-Anker ausschließlich lokal. Netzadressen werden nicht geöffnet. Die Liste ist eine Momentaufnahme; Dateien werden nicht geändert.","Checks file and image targets, Markdown and HTML anchors locally. Network addresses are not opened. The list is a snapshot; files are not changed."),false);
        explanation.add_css_class("muted");
        root.append(&explanation);
        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        controls.append(&label(lang.text("Bereich", "Scope"), false));
        let scope = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        scope.add_css_class("linked");
        let document = gtk::ToggleButton::with_label(lang.text("Dokument", "Document"));
        document.set_widget_name("referenceScopeDocument");
        document.set_active(true);
        let project = gtk::ToggleButton::with_label(lang.text("Projekt", "Project"));
        project.set_widget_name("referenceScopeProject");
        project.set_group(Some(&document));
        project.set_sensitive(project_view::current_binding(ui).is_some());
        scope.append(&document);
        scope.append(&project);
        controls.append(&scope);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        controls.append(&spacer);
        let start = button(lang, "Prüfen", "Check", "referenceStart");
        start.add_css_class("suggested-action");
        controls.append(&start);
        root.append(&controls);
        root.append(&label(lang.text("Projekt-Ausschlüsse gelten. Versteckte Dateien, Pakete und Linkquellen bleiben ausgeschlossen. Grenzen: 200 Dateien, 10 MiB und 200.000 Umbruchzeichen je Quelle, 64 MiB insgesamt sowie jeweils 10.000 Verweise und Anker. Gequotete HTML-Verweise werden geprüft; weitere Grenzen stehen in der Hilfe.","Project exclusions apply. Hidden files, packages and symbolic-link sources are excluded. Limits: 200 files, 10 MiB and 200,000 line-break characters per source, 64 MiB in total, and 10,000 references and anchors each. Quoted HTML references are checked; further limits are described in Help."),true));
        root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let status_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let status_icon = gtk::Image::new();
        status_icon.set_pixel_size(14);
        status_icon.set_visible(false);
        status_row.append(&status_icon);
        let spinner = gtk::Spinner::new();
        spinner.set_visible(false);
        status_row.append(&spinner);
        let status = label("", false);
        status.set_widget_name("referenceFinished");
        status_row.append(&status);
        let space = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        space.set_hexpand(true);
        status_row.append(&space);
        let timestamp = label("", false);
        timestamp.add_css_class("muted");
        timestamp.set_wrap(false);
        status_row.append(&timestamp);
        status_row.set_visible(false);
        root.append(&status_row);
        let detail = label("", true);
        detail.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        detail.set_wrap(false);
        detail.set_visible(false);
        root.append(&detail);
        let summary = label("", true);
        summary.set_visible(false);
        root.append(&summary);
        let notice = label("", false);
        notice.add_css_class("warning");
        notice.set_visible(false);
        notice.set_widget_name("referenceNotice");
        root.append(&notice);
        let issues = label("", false);
        issues.add_css_class("warning");
        let issues_scroll = gtk::ScrolledWindow::builder()
            .child(&issues)
            .max_content_height(80)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        issues_scroll.set_visible(false);
        root.append(&issues_scroll);
        let problems =
            gtk::CheckButton::with_label(lang.text("Nur Probleme anzeigen", "Show Problems Only"));
        problems.set_active(true);
        problems.set_widget_name("referenceProblemsOnly");
        root.append(&problems);
        let model = gtk::StringList::new(&[]);
        let selected = gtk::SingleSelection::new(Some(model.clone()));
        selected.set_autoselect(false);
        selected.set_can_unselect(true);
        let factory = gtk::SignalListItemFactory::new();
        let list = gtk::ListView::new(Some(selected.clone()), Some(factory.clone()));
        list.set_widget_name("referenceFindings");
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .vexpand(true)
            .min_content_height(180)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        scroll.add_css_class("frame");
        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&scroll));
        let empty = label(
            lang.text(
                "Noch keine Prüfung ausgeführt.",
                "No check has been run yet.",
            ),
            true,
        );
        empty.set_halign(gtk::Align::Center);
        empty.set_valign(gtk::Align::Center);
        empty.set_can_target(false);
        overlay.add_overlay(&empty);
        root.append(&overlay);
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        footer.add_css_class("sheet-footer");
        let close = button(lang, "Schließen", "Close", "referenceClose");
        footer.append(&close);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        footer.append(&spacer);
        let jump = button(lang, "Zur Quelle", "Go to Source", "referenceJump");
        jump.set_sensitive(false);
        footer.append(&jump);
        root.append(&footer);
        window.set_child(Some(&root));
        window.set_default_widget(Some(&start));
        let s = Rc::new(Self {
            ui: Rc::downgrade(ui),
            doc: Rc::downgrade(doc),
            window: window.clone(),
            lang,
            report: RefCell::new(None),
            documents: RefCell::new(HashMap::new()),
            job: Cell::new(0),
            busy: Cell::new(false),
            cancel: RefCell::new(Cancellation::default()),
            selected,
            visible: RefCell::new(vec![]),
            model,
            scope,
            project,
            problems,
            start,
            jump,
            status,
            status_row,
            status_icon,
            timestamp,
            spinner,
            summary,
            detail,
            issues,
            issues_scroll,
            notice,
            empty,
            freshness: RefCell::new(HashMap::new()),
        });
        #[cfg(debug_assertions)]
        LAST.with(|last| *last.borrow_mut() = Rc::downgrade(&s));
        factory.connect_setup(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let row = gtk::Box::new(gtk::Orientation::Vertical, 4);
            row.set_margin_top(4);
            row.set_margin_bottom(4);
            row.set_margin_start(12);
            row.set_margin_end(12);
            let head = gtk::Box::new(gtk::Orientation::Horizontal, 12);
            let source = label("", false);
            source.set_hexpand(true);
            source.set_wrap(false);
            source.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            source.add_css_class("heading");
            head.append(&source);
            let status = label("", false);
            status.set_wrap(false);
            head.append(&status);
            row.append(&head);
            let destination = label("", false);
            destination.set_lines(2);
            destination.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            row.append(&destination);
            row.append(&label("", true));
            item.set_child(Some(&row));
        });
        let weak = Rc::downgrade(&s);
        factory.connect_bind(move |_, item| {
            if let Some(s) = weak.upgrade() {
                s.bind(item);
            }
        });
        let weak = Rc::downgrade(&s);
        s.start.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                if s.busy.get() {
                    s.cancel();
                } else {
                    s.start();
                }
            }
        });
        let weak = Rc::downgrade(&s);
        s.problems.connect_toggled(move |_| {
            if let Some(s) = weak.upgrade() {
                s.filter();
            }
        });
        let weak = Rc::downgrade(&s);
        s.project.connect_toggled(move |_| {
            if let Some(s) = weak.upgrade() {
                s.cancel();
                s.report.borrow_mut().take();
                s.status_row.set_visible(false);
                s.summary.set_visible(false);
                s.detail.set_visible(false);
                s.issues_scroll.set_visible(false);
                s.notice.set_visible(false);
                s.filter();
            }
        });
        let weak = Rc::downgrade(&s);
        s.selected.connect_selected_notify(move |_| {
            if let Some(s) = weak.upgrade() {
                s.jump.set_sensitive(
                    !s.busy.get() && s.selected.selected() != gtk::INVALID_LIST_POSITION,
                );
            }
        });
        let weak = Rc::downgrade(&s);
        s.jump.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.jump();
            }
        });
        let weak = window.downgrade();
        close.connect_clicked(move |_| {
            if let Some(w) = weak.upgrade() {
                w.close();
            }
        });
        let keys = gtk::EventControllerKey::new();
        let weak = window.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gtk::gdk::Key::Escape {
                if let Some(w) = weak.upgrade() {
                    w.close();
                }
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(keys);
        let weak = Rc::downgrade(&s);
        glib::timeout_add_local(Duration::from_millis(250), move || {
            let Some(s) = weak.upgrade().filter(|s| s.window.is_visible()) else {
                return glib::ControlFlow::Break;
            };
            let stale = s.report.borrow().as_ref().is_some_and(|r| {
                r.sources
                    .iter()
                    .any(|source| source.document.is_some() && s.fresh(source).is_none())
            });
            if stale {
                s.error(s.lang.text(
                    "Die Quelle wurde geändert oder geschlossen. Bitte erneut prüfen.",
                    "The source was changed or closed. Please check again.",
                ));
            }
            glib::ControlFlow::Continue
        });
        git_view::hold(&window, s.clone(), |s| s.cancel());
        s
    }
    fn bind(&self, item: &glib::Object) {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let Some(index) = item
            .item()
            .and_then(|v| v.downcast::<gtk::StringObject>().ok())
            .and_then(|v| v.string().parse::<usize>().ok())
        else {
            return;
        };
        let report = self.report.borrow();
        let Some(report) = report.as_ref() else {
            return;
        };
        let Some(finding) = report.findings.get(index) else {
            return;
        };
        let row = item.child().unwrap().downcast::<gtk::Box>().unwrap();
        row.set_widget_name(&format!("referenceFinding-{}", finding.reference.line));
        let head = row.first_child().unwrap();
        let source = head
            .first_child()
            .unwrap()
            .downcast::<gtk::Label>()
            .unwrap();
        let status = head.last_child().unwrap().downcast::<gtk::Label>().unwrap();
        let name = report
            .sources
            .iter()
            .find(|s| s.id == finding.source)
            .map(|s| {
                s.path
                    .as_ref()
                    .map(|p| project_view::display(p))
                    .unwrap_or_else(|| s.title.clone())
            })
            .unwrap_or_default();
        source.set_text(&format!("{name}:{}", finding.reference.line));
        source.set_tooltip_text(Some(&name));
        status.set_text(finding.status.text(self.lang));
        if finding.status == Status::Valid {
            status.remove_css_class("warning");
            status.add_css_class("muted");
        } else {
            status.add_css_class("warning");
            status.remove_css_class("muted");
        }
        let destination = head
            .next_sibling()
            .unwrap()
            .downcast::<gtk::Label>()
            .unwrap();
        let raw = &finding.reference.destination;
        let shown = if raw.is_empty() {
            "#".into()
        } else {
            let mut text = raw.chars().take(4096).collect::<String>();
            if text.len() < raw.len() {
                text.push('…');
            }
            text
        };
        destination.set_text(&shown);
        row.last_child()
            .unwrap()
            .downcast::<gtk::Label>()
            .unwrap()
            .set_text(finding.message.text(self.lang));
    }
    pub fn error(&self, text: &str) {
        self.notice.set_text(text);
        self.notice.set_visible(true);
    }
    pub fn cancel(&self) {
        self.cancel.borrow().cancel();
        self.job.set(self.job.get().wrapping_add(1));
        if self.busy.replace(false) {
            self.status_row.set_visible(false);
            if self.report.borrow().is_none() {
                self.empty.set_text(
                    self.lang
                        .text("Keine abgeschlossenen Befunde.", "No completed findings."),
                );
                self.empty.set_visible(true);
            }
            self.error(Notice::Cancelled.text(self.lang));
        }
        self.controls();
    }
    pub(super) fn controls(&self) {
        let running = self.busy.get();
        self.spinner.set_visible(running);
        if running {
            self.empty.set_visible(false);
            self.spinner.start();
            self.status_icon.set_visible(false);
            self.timestamp.set_visible(false);
        } else {
            self.spinner.stop();
        }
        self.scope.set_sensitive(!running);
        self.start.set_label(self.lang.text(
            if running {
                "Abbrechen"
            } else if self.report.borrow().is_some() {
                "Erneut prüfen"
            } else {
                "Prüfen"
            },
            if running {
                "Cancel"
            } else if self.report.borrow().is_some() {
                "Check Again"
            } else {
                "Check"
            },
        ));
        self.jump
            .set_sensitive(!running && self.selected.selected() != gtk::INVALID_LIST_POSITION);
    }
    fn filter(&self) {
        self.selected.set_selected(gtk::INVALID_LIST_POSITION);
        let report = self.report.borrow();
        let indices = report
            .as_ref()
            .map(|r| {
                r.findings
                    .iter()
                    .enumerate()
                    .filter(|(_, f)| !self.problems.is_active() || f.status != Status::Valid)
                    .map(|(i, _)| i)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let strings = indices.iter().map(usize::to_string).collect::<Vec<_>>();
        self.model.splice(
            0,
            self.model.n_items(),
            &strings.iter().map(String::as_str).collect::<Vec<_>>(),
        );
        *self.visible.borrow_mut() = indices;
        self.empty.set_visible(strings.is_empty());
        self.empty.set_text(self.lang.text(
            if report.is_some() {
                "Keine Befunde in dieser Ansicht."
            } else {
                "Noch keine Prüfung ausgeführt."
            },
            if report.is_some() {
                "No findings in this view."
            } else {
                "No check has been run yet."
            },
        ));
        self.controls();
    }
    pub fn fresh(&self, source: &Source) -> Option<Rc<Document>> {
        let doc = self.documents.borrow().get(&source.document?)?.upgrade()?;
        let ui = self.ui.upgrade()?;
        if !ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc))
            || doc.disk_path() != source.path
            || !supported(&doc)
        {
            return None;
        }
        let key = (source.id, doc.revision.get());
        let cached = self.freshness.borrow().get(&key).copied();
        let equal = if source.revision == key.1 {
            true
        } else if let Some(equal) = cached {
            equal
        } else {
            let equal = buffer_text(&doc.buffer) == source.content;
            let mut cache = self.freshness.borrow_mut();
            if cache.len() > 1024 {
                cache.clear();
            }
            cache.insert(key, equal);
            equal
        };
        equal.then_some(doc)
    }
    pub(super) fn start(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let Some(doc) = self.doc.upgrade() else {
            self.error(self.lang.text(
                "Die Ausgangsdatei ist nicht mehr geöffnet.",
                "The source document is no longer open.",
            ));
            return;
        };
        if !supported(&doc) || !ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc)) {
            self.error(self.lang.text(
                "Die Quelle wurde geändert oder geschlossen. Bitte erneut öffnen.",
                "The source changed or was closed. Please open the check again.",
            ));
            return;
        }
        let project = if self.project.is_active() {
            match project_view::current_binding(&ui) {
                Some(p) => Some(p),
                None => {
                    self.error(
                        self.lang
                            .text("Kein Projekt geöffnet.", "No project is open."),
                    );
                    return;
                }
            }
        } else {
            None
        };
        self.cancel();
        self.report.borrow_mut().take();
        self.filter();
        self.notice.set_visible(false);
        self.status_row.set_visible(true);
        self.status.set_text(
            self.lang
                .text("Verweise werden geprüft…", "Checking references…"),
        );
        self.summary.set_visible(false);
        self.detail.set_visible(false);
        self.issues_scroll.set_visible(false);
        self.busy.set(true);
        self.controls();
        let documents = if project.is_some() {
            ui.documents
                .borrow()
                .iter()
                .filter(|d| supported(d))
                .cloned()
                .collect::<Vec<_>>()
        } else {
            vec![doc.clone()]
        };
        let weak = Rc::downgrade(self);
        let original = Rc::downgrade(&doc);
        let job = self.job.get();
        crate::rich_editor::flush_documents_owned(
            &documents.clone(),
            Box::new(move |ok| {
                let Some(s) = weak
                    .upgrade()
                    .filter(|s| s.job.get() == job && s.busy.get())
                else {
                    return;
                };
                let Some(doc) = original.upgrade() else {
                    s.cancel();
                    return;
                };
                if !ok {
                    s.cancel();
                    s.error(s.lang.text(
                        "Rich-Quelle konnte nicht sicher synchronisiert werden.",
                        "The Rich source could not be synchronized safely.",
                    ));
                    return;
                }
                s.calculate(doc, documents, project, job);
            }),
        );
    }
    fn calculate(
        self: &Rc<Self>,
        document: Rc<Document>,
        documents: Vec<Rc<Document>>,
        project: Option<project_view::Binding>,
        job: u64,
    ) {
        let mut open = vec![];
        let mut bytes = 0;
        self.documents.borrow_mut().clear();
        self.freshness.borrow_mut().clear();
        for doc in documents {
            if doc.buffer.char_count() as usize > parser::MAX_SOURCE {
                self.cancel();
                self.error(Notice::Budget.text(self.lang));
                return;
            }
            let content = buffer_text(&doc.buffer);
            bytes += content.len();
            if content.len() > parser::MAX_SOURCE || bytes > 64 * 1024 * 1024 {
                self.cancel();
                self.error(Notice::Budget.text(self.lang));
                return;
            }
            let id = Rc::as_ptr(&doc) as usize;
            self.documents.borrow_mut().insert(id, Rc::downgrade(&doc));
            open.push(Source {
                id,
                document: Some(id),
                revision: doc.revision.get(),
                path: doc.disk_path(),
                title: doc.name.clone(),
                content,
                snapshot: None,
            });
        }
        let Some(document) = open
            .iter()
            .find(|s| s.id == Rc::as_ptr(&document) as usize)
            .cloned()
        else {
            self.cancel();
            return;
        };
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let project_guard = project.clone();
        let work = match project.as_ref().map(|p| p.work(&cancel)).transpose() {
            Ok(work) => work,
            Err(error) => {
                self.cancel();
                self.error(&error);
                return;
            }
        };
        let project = project.map(|p| p.root);
        let lang = self.lang;
        let progress = Arc::new(Mutex::new(None));
        let worker_progress = progress.clone();
        let weak = Rc::downgrade(self);
        let mut last = Instant::now() - Duration::from_secs(1);
        git_view::background(
            move || {
                if let Some(work) = &work {
                    work.validate()?;
                }
                let root = project.as_ref().map(|p| p.path.clone());
                let mut options = Options::default();
                if let Some(binding) = &project {
                    binding.validate()?;
                    let store = fastra_workflow::search_locations::Store::open(
                        &crate::search_sources::config_root()?,
                    )
                    .map_err(|e| e.to_string())?;
                    let settings = store.load().map_err(|e| e.to_string())?;
                    options.exclusions = settings
                        .project(&binding.path)
                        .exclusions
                        .split([',', ';', '\n', '\r'])
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned)
                        .collect();
                    if !options.exclusions.iter().any(|s| s == "DerivedData") {
                        options.exclusions.push("DerivedData".into());
                    }
                }
                #[cfg(debug_assertions)]
                {
                    let delay = WORK_DELAY.load(std::sync::atomic::Ordering::Relaxed);
                    if delay > 0 {
                        assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                        let began = Instant::now();
                        while began.elapsed() < Duration::from_millis(delay.min(2000)) {
                            cancel
                                .check()
                                .map_err(|_| Notice::Cancelled.text(lang).to_owned())?;
                            std::thread::sleep(Duration::from_millis(10));
                        }
                    }
                }
                let report = check::check(
                    document,
                    open,
                    root,
                    options,
                    &cancel,
                    |files, refs, title| {
                        if last.elapsed() > Duration::from_millis(50) {
                            *worker_progress.lock().unwrap() =
                                Some(format!("{files} · {refs} · {title}"));
                            last = Instant::now();
                        }
                    },
                )
                .map_err(|e| e.text(lang).to_owned())?;
                if let Some(binding) = project {
                    binding.validate()?;
                }
                if let Some(work) = &work {
                    work.validate()?;
                }
                Ok(report)
            },
            move |result| {
                let Some(s) = weak
                    .upgrade()
                    .filter(|s| s.job.get() == job && s.busy.get())
                else {
                    return;
                };
                s.busy.set(false);
                if project_guard.as_ref().is_some_and(|p| !p.is_current()) {
                    s.status_row.set_visible(false);
                    s.error(s.lang.text(
                        "Die Projektwahl wurde geändert. Bitte erneut prüfen.",
                        "The project selection changed. Please check again.",
                    ));
                    s.controls();
                    return;
                }
                match result {
                    Ok(report) => s.finish(report),
                    Err(error) => {
                        s.status_row.set_visible(false);
                        s.error(&error);
                        s.controls();
                    }
                }
            },
        );
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(50), move || {
            let Some(s) = weak
                .upgrade()
                .filter(|s| s.job.get() == job && s.busy.get())
            else {
                return glib::ControlFlow::Break;
            };
            if let Some(text) = progress.lock().unwrap().take() {
                s.status.set_text(&text);
            }
            glib::ControlFlow::Continue
        });
    }
    pub(super) fn finish(&self, report: Report) {
        let time = report
            .completed
            .duration_since(std::time::UNIX_EPOCH)
            .ok()
            .and_then(|v| glib::DateTime::from_unix_local(v.as_secs() as i64).ok())
            .and_then(|v| v.format("%Y-%m-%d %H:%M").ok())
            .map(|s| s.to_string())
            .unwrap_or_default();
        self.status.set_text(self.lang.text(
            if report.complete {
                "Prüfung vollständig"
            } else {
                "Prüfung unvollständig"
            },
            if report.complete {
                "Check Complete"
            } else {
                "Check Incomplete"
            },
        ));
        self.status_icon.set_icon_name(Some(if report.complete {
            "fastra-check-circle-symbolic"
        } else {
            "dialog-warning-symbolic"
        }));
        self.status_icon.set_visible(true);
        for widget in [
            self.status.upcast_ref::<gtk::Widget>(),
            self.status_icon.upcast_ref::<gtk::Widget>(),
        ] {
            widget.remove_css_class("muted");
            widget.remove_css_class("warning");
            widget.add_css_class(if report.complete { "muted" } else { "warning" });
        }
        self.timestamp.set_text(&time);
        self.timestamp.set_visible(true);
        self.status_row.set_visible(true);
        let name = report
            .project
            .as_ref()
            .map(|p| project_view::display(p))
            .or_else(|| {
                report.sources.first().map(|s| {
                    s.path
                        .as_ref()
                        .map(|p| project_view::display(p))
                        .unwrap_or_else(|| s.title.clone())
                })
            })
            .unwrap_or_default();
        self.detail.set_text(&format!(
            "{}: {name}",
            self.lang.text(
                if report.project.is_some() {
                    "Geprüftes Projekt"
                } else {
                    "Geprüftes Dokument"
                },
                if report.project.is_some() {
                    "Checked project"
                } else {
                    "Checked document"
                }
            )
        ));
        self.detail.set_tooltip_text(Some(&name));
        self.detail.set_visible(true);
        let files = report.sources.len();
        let refs = report.findings.len();
        let remote = report.remote_count;
        self.summary.set_text(&if self.lang.0 {
            format!(
                "{files} {} · {refs} {} · {remote} {}",
                if files == 1 { "Datei" } else { "Dateien" },
                if refs == 1 {
                    "lokaler Verweis"
                } else {
                    "lokale Verweise"
                },
                if remote == 1 {
                    "andere Adresse übersprungen"
                } else {
                    "andere Adressen übersprungen"
                }
            )
        } else {
            format!(
                "{files} {} · {refs} {} · {remote} {}",
                if files == 1 { "file" } else { "files" },
                if refs == 1 {
                    "local reference"
                } else {
                    "local references"
                },
                if remote == 1 {
                    "other address skipped"
                } else {
                    "other addresses skipped"
                }
            )
        });
        self.summary
            .set_tooltip_text(Some(&format!("{} bytes", report.read_bytes)));
        self.summary.set_visible(true);
        self.issues.set_text(
            &report
                .issues
                .iter()
                .map(|i| {
                    format!(
                        "{}{}",
                        i.message.text(self.lang),
                        i.path
                            .as_ref()
                            .map(|p| format!(" — {}", project_view::display(p)))
                            .unwrap_or_default()
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
        );
        self.issues_scroll.set_visible(!report.issues.is_empty());
        *self.report.borrow_mut() = Some(Arc::new(report));
        self.filter();
    }
}
