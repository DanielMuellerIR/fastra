//! Gemeinsame Anzeige unveränderlicher Treffer mit einer vollständigen Zielansicht.
use super::*;
use std::sync::Arc;
mod review_diff;
pub(crate) mod search;
pub struct Item {
    pub label: String,
    pub preview: Arc<Preview>,
}
pub(crate) type InlineSource = Rc<dyn Fn() -> Option<Arc<Preview>>>;
pub(crate) type NavigationHandler = Rc<dyn Fn(search::Navigation)>;
pub(crate) type ReplacementHandler = Rc<dyn Fn(search::Replacement)>;
struct SearchResume {
    ordinal: usize,
    current: Rc<dyn Fn() -> bool>,
}
type ChangeHandler = Rc<dyn Fn(bool)>;
pub struct ApprovalPane {
    pub root: gtk::Box,
    search: RefCell<Option<Rc<search::Surface>>>,
    pub(crate) inline_source: RefCell<Option<InlineSource>>,
    pub(crate) on_navigate: RefCell<Option<NavigationHandler>>,
    pub(crate) on_replace: RefCell<Option<ReplacementHandler>>,
    resume: RefCell<Option<SearchResume>>,
    pub files: gtk::DropDown,
    pub checks: gtk::Box,
    pub before: gtk::TextView,
    pub after: gtk::TextView,
    items: RefCell<Vec<Item>>,
    visible: RefCell<Vec<usize>>,
    approved: RefCell<Vec<Vec<bool>>>,
    frozen: Cell<bool>,
    pub(super) wrap_around: Cell<bool>,
    pub exact: gtk::CheckButton,
    summary: gtk::Label,
    render_status: gtk::Label,
    render_generation: Cell<u64>,
    render_cancel: RefCell<Cancellation>,
    diff_cancel: RefCell<fastra_diff::Cancellation>,
    render_ready: Cell<bool>,
    render_error: Cell<bool>,
    labels_ready: Cell<bool>,
    changed: RefCell<Option<ChangeHandler>>,
    lang: Language,
    #[cfg(debug_assertions)]
    test_initial_approved: Cell<bool>,
}
impl ApprovalPane {
    pub fn new(lang: Language) -> Rc<Self> {
        Self::with_options(lang, false)
    }
    pub fn single_file(lang: Language) -> Rc<Self> {
        Self::with_options(lang, true)
    }
    fn with_options(lang: Language, single_file: bool) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let files = git_view::file_dropdown();
        files.set_visible(false);
        root.append(&files);
        let checks = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let check_scroll = gtk::ScrolledWindow::builder()
            .height_request(if single_file { 90 } else { 110 })
            .child(&checks)
            .build();
        let before = gtk::TextView::builder()
            .editable(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        let after = gtk::TextView::builder()
            .editable(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        let exact = gtk::CheckButton::with_label(lang.text(
            "Unicode und Steuerzeichen als Escapes zeigen",
            "Show Unicode and control characters as escapes",
        ));
        exact.set_tooltip_text(Some(lang.text("Macht auch unterschiedliche Unicode-Normalisierung, Tabulatoren und Zeilenenden eindeutig sichtbar. Die Freigabe gilt weiter den Originaltexten.", "Makes Unicode normalization, tabs and line endings unambiguous. Approval still refers to the original text.")));
        let summary = gtk::Label::new(None);
        summary.set_xalign(0.);
        summary.set_hexpand(true);
        summary.add_css_class("approval-summary");
        let heading = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        heading.append(&summary);
        let options = gtk::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .tooltip_text(lang.text("Vorschauoptionen", "Preview options"))
            .build();
        options.add_css_class("chrome-icon");
        let options_popover = gtk::Popover::new();
        options_popover.set_child(Some(&exact));
        options.set_popover(Some(&options_popover));
        heading.append(&options);
        root.prepend(&heading);
        let render_status = git_view::label("");
        render_status.set_visible(false);
        render_status.connect_label_notify(|status| status.set_visible(!status.text().is_empty()));
        root.append(&render_status);
        let panes = gtk::Paned::new(gtk::Orientation::Horizontal);
        for (view, label, start) in [
            (&before, lang.text("Vorher", "Before"), true),
            (&after, lang.text("Nachher", "After"), false),
        ] {
            view.update_property(&[gtk::accessible::Property::Label(label)]);
            let column = gtk::Box::new(gtk::Orientation::Vertical, 4);
            column.append(&gtk::Label::new(Some(label)));
            column.append(
                &gtk::ScrolledWindow::builder()
                    .vexpand(true)
                    .hexpand(true)
                    .min_content_height(80)
                    .child(view)
                    .build(),
            );
            if start {
                panes.set_start_child(Some(&column))
            } else {
                panes.set_end_child(Some(&column))
            }
        }
        super::git_view::balance_panes(&panes);
        panes.set_vexpand(true);
        let compact = gtk::Paned::new(gtk::Orientation::Vertical);
        compact.set_start_child(Some(&check_scroll));
        compact.set_end_child(Some(&panes));
        super::git_view::balance_panes(&compact);
        compact.set_vexpand(true);
        root.append(&compact);
        root.set_vexpand(true);
        let pane = Rc::new(Self {
            root,
            search: RefCell::new(None),
            inline_source: RefCell::new(None),
            on_navigate: RefCell::new(None),
            on_replace: RefCell::new(None),
            resume: RefCell::new(None),
            files,
            checks,
            before,
            after,
            items: RefCell::new(vec![]),
            visible: RefCell::new(vec![]),
            approved: RefCell::new(vec![]),
            frozen: Cell::new(false),
            wrap_around: Cell::new(true),
            exact,
            summary,
            render_status,
            render_generation: Cell::new(0),
            render_cancel: RefCell::new(Cancellation::default()),
            diff_cancel: RefCell::new(fastra_diff::Cancellation::default()),
            render_ready: Cell::new(false),
            render_error: Cell::new(false),
            labels_ready: Cell::new(false),
            changed: RefCell::new(None),
            lang,
            #[cfg(debug_assertions)]
            test_initial_approved: Cell::new(false),
        });
        pane.update_summary();
        let weak = Rc::downgrade(&pane);
        pane.files.connect_selected_notify(move |_| {
            if let Some(p) = weak.upgrade() {
                p.show();
            }
        });
        let weak = Rc::downgrade(&pane);
        pane.exact.connect_toggled(move |_| {
            if let Some(pane) = weak.upgrade() {
                pane.update_after();
            }
        });
        let weak = Rc::downgrade(&pane);
        pane.root.connect_unmap(move |_| {
            if let Some(pane) = weak.upgrade() {
                pane.render_cancel.borrow().cancel();
                pane.diff_cancel.borrow().cancel();
                pane.render_generation.set(pane.render_generation.get() + 1);
                pane.render_ready.set(false);
                pane.notify(false);
            }
        });
        let weak = Rc::downgrade(&pane);
        pane.root.connect_map(move |_| {
            if let Some(pane) = weak.upgrade().filter(|pane| !pane.frozen.get()) {
                pane.show();
            }
        });
        #[cfg(debug_assertions)]
        if std::env::var_os("FASTRA_APPROVAL_STRESS").is_some() {
            let weak = Rc::downgrade(&pane);
            let started = Cell::new(false);
            pane.root.connect_map(move |_| {
                if !started.replace(true) {
                    if let Some(pane) = weak.upgrade() {
                        stress(pane);
                    }
                }
            });
        }
        pane
    }
    pub fn search_layout(
        self: &Rc<Self>,
        ui: &Rc<Ui>,
        owner: &gtk::Window,
        apply: &gtk::Button,
        disk: bool,
    ) -> gtk::Button {
        let surface = search::Surface::install(self, ui, owner, apply, disk);
        let button = surface.review.clone();
        *self.search.borrow_mut() = Some(surface);
        button
    }
    pub(crate) fn refresh_pattern(&self) {
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.refresh();
        }
    }
    pub(crate) fn replacement_button(&self) -> gtk::Button {
        self.search.borrow().as_ref().unwrap().replace.clone()
    }
    pub(crate) fn navigation_buttons(&self) -> (gtk::Button, gtk::Button) {
        let search = self.search.borrow();
        let surface = search.as_ref().unwrap();
        let mut buttons = Vec::new();
        for (canonical, title) in [
            (&surface.previous, self.lang.text("Voriger", "Previous")),
            (&surface.next, self.lang.text("Nächster", "Next")),
        ] {
            let button = gtk::Button::with_label(title);
            canonical
                .bind_property("sensitive", &button, "sensitive")
                .sync_create()
                .build();
            button.set_tooltip_text(canonical.tooltip_text().as_deref());
            let target = canonical.downgrade();
            button.connect_clicked(move |_| {
                if let Some(target) = target.upgrade().filter(|b| b.is_sensitive()) {
                    target.emit_clicked();
                }
            });
            buttons.push(button);
        }
        (buttons.remove(0), buttons.remove(0))
    }
    pub(crate) fn resume_at(&self, ordinal: usize, current: Rc<dyn Fn() -> bool>) {
        *self.resume.borrow_mut() = Some(SearchResume { ordinal, current });
    }
    pub fn on_changed(&self, changed: Rc<dyn Fn(bool)>) {
        *self.changed.borrow_mut() = Some(changed);
    }
    fn notify(&self, valid: bool) {
        self.update_summary();
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.refresh();
        }
        let changed = self.changed.borrow().clone();
        if let Some(changed) = changed {
            changed(
                valid
                    && !self.frozen.get()
                    && self.render_ready.get()
                    && self
                        .search
                        .borrow()
                        .as_ref()
                        .is_none_or(|surface| surface.rows_ready()),
            );
        }
    }
    fn update_summary(&self) {
        let total: usize = self
            .items
            .borrow()
            .iter()
            .map(|item| item.preview.matches().len())
            .sum();
        let approved = self
            .approved
            .borrow()
            .iter()
            .flatten()
            .filter(|selected| **selected)
            .count();
        self.summary.set_text(&format!(
            "{} ({total}) · {} {approved}",
            self.lang.text("Treffer", "Matches"),
            self.lang.text("Freigegeben:", "Approved:")
        ));
    }
    pub fn freeze(self: &Rc<Self>, value: bool) {
        self.frozen.set(value);
        self.files.set_sensitive(!value);
        self.checks.set_sensitive(!value);
        self.exact.set_sensitive(!value);
        if value {
            self.render_cancel.borrow().cancel();
            self.diff_cancel.borrow().cancel();
            self.render_generation.set(self.render_generation.get() + 1);
            self.notify(false)
        } else {
            self.update_after();
        }
    }
    pub fn clear(self: &Rc<Self>) {
        self.render_error.set(false);
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.clear();
        }
        self.render_cancel.borrow().cancel();
        self.diff_cancel.borrow().cancel();
        self.render_generation.set(self.render_generation.get() + 1);
        self.render_ready.set(false);
        self.labels_ready.set(false);
        self.render_status.set_text("");
        self.items.borrow_mut().clear();
        self.visible.borrow_mut().clear();
        self.approved.borrow_mut().clear();
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.files.set_model(None::<&gtk::StringList>);
        self.files.set_visible(false);
        self.remove_checks_later();
        self.notify(false);
    }
    pub fn set_items(self: &Rc<Self>, items: Vec<Item>) {
        self.render_error.set(false);
        #[cfg(debug_assertions)]
        self.test_initial_approved.set(false);
        self.render_cancel.borrow().cancel();
        self.diff_cancel.borrow().cancel();
        self.render_generation
            .set(self.render_generation.get().wrapping_add(1));
        self.render_ready.set(false);
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.clear();
        }
        let visible: Vec<_> = items
            .iter()
            .enumerate()
            .filter_map(|(i, item)| (!item.preview.matches().is_empty()).then_some(i))
            .collect();
        let labels: Vec<_> = visible.iter().map(|&i| items[i].label.as_str()).collect();
        let model = gtk::StringList::new(&labels);
        self.files.set_visible(visible.len() > 1);
        *self.approved.borrow_mut() = items
            .iter()
            .map(|item| vec![self.search.borrow().is_none(); item.preview.matches().len()])
            .collect();
        *self.visible.borrow_mut() = visible;
        *self.items.borrow_mut() = items;
        self.files.set_model(Some(&model));
        self.files.set_selected(0);
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.rebuild();
        }
        self.show();
    }
    pub fn has_approvals(&self) -> bool {
        self.approved
            .borrow()
            .iter()
            .flatten()
            .any(|approved| *approved)
    }
    #[cfg(debug_assertions)]
    pub fn test_approve_initial(self: &Rc<Self>) -> bool {
        if !self.render_ready.get()
            || self.frozen.get()
            || self
                .search
                .borrow()
                .as_ref()
                .is_some_and(|s| !s.rows_ready())
        {
            return false;
        }
        if self.test_initial_approved.replace(true) {
            return true;
        }
        let needs_approval = self
            .approved
            .borrow()
            .iter()
            .flatten()
            .any(|approved| !*approved);
        if needs_approval {
            for row in self.approved.borrow_mut().iter_mut() {
                row.fill(true);
            }
            self.update_after();
            false
        } else {
            true
        }
    }
    #[cfg(debug_assertions)]
    pub fn test_approve_hit(&self, item: usize, hit: usize, value: bool) {
        self.search
            .borrow()
            .as_ref()
            .unwrap()
            .test_approve_hit(item, hit, value);
    }
    #[cfg(debug_assertions)]
    pub fn test_review_button(&self) -> gtk::Button {
        self.search.borrow().as_ref().unwrap().review.clone()
    }
    #[cfg(debug_assertions)]
    pub fn review_test_visible(&self) -> bool {
        self.search
            .borrow()
            .as_ref()
            .is_some_and(|surface| surface.diff.test_visible())
    }
    #[cfg(debug_assertions)]
    pub fn is_ready(&self) -> bool {
        self.render_ready.get()
    }
    pub fn approvals(&self) -> Option<Vec<Vec<usize>>> {
        if !self.render_ready.get() || self.frozen.get() {
            return None;
        }
        Some(
            self.approved
                .borrow()
                .iter()
                .map(|row| {
                    row.iter()
                        .enumerate()
                        .filter_map(|(i, &yes)| yes.then_some(i))
                        .collect()
                })
                .collect(),
        )
    }
    fn remove_checks_later(self: &Rc<Self>) {
        let generation = self.render_generation.get();
        let weak = Rc::downgrade(self);
        // Ein normal priorisierter, begrenzter Idle-Takt verhungert nicht hinter
        // fortlaufenden GTK-Layoutframes wie eine DEFAULT_IDLE-Quelle.
        glib::timeout_add_local(Duration::from_millis(8), move || {
            let Some(pane) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if pane.render_generation.get() != generation {
                return glib::ControlFlow::Break;
            }
            let start = std::time::Instant::now();
            for _ in 0..48 {
                let Some(child) = pane.checks.first_child() else {
                    return glib::ControlFlow::Break;
                };
                pane.checks.remove(&child);
                if start.elapsed() >= Duration::from_millis(3) {
                    break;
                }
            }
            glib::ControlFlow::Continue
        });
    }
    fn show(self: &Rc<Self>) {
        self.labels_ready.set(false);
        self.update_after();
    }
    fn update_after(self: &Rc<Self>) {
        self.render_error.set(false);
        self.render_cancel.borrow().cancel();
        self.diff_cancel.borrow().cancel();
        self.render_generation.set(self.render_generation.get() + 1);
        self.render_ready.set(false);
        self.checks.set_sensitive(false);
        self.notify(false);
        let Some(&i) = self.visible.borrow().get(self.files.selected() as usize) else {
            return;
        };
        let preview = self.items.borrow()[i].preview.clone();
        let rebuild_labels = !self.labels_ready.get();
        let selected: Vec<_> = self.approved.borrow()[i]
            .iter()
            .enumerate()
            .filter_map(|(n, &yes)| yes.then_some(n))
            .collect();
        let cancel = Cancellation::default();
        *self.render_cancel.borrow_mut() = cancel.clone();
        let generation = self.render_generation.get();
        let exact = self.exact.is_active();
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.render_status.set_text(self.lang.text(
            "Vollständige Darstellung wird vorbereitet …",
            "Preparing complete display …",
        ));
        let lang = self.lang;
        let diff_cancel = fastra_diff::Cancellation::default();
        *self.diff_cancel.borrow_mut() = diff_cancel.clone();
        let search_layout = self.search.borrow().is_some();
        if let Some(surface) = self.search.borrow().as_ref() {
            surface.diff.clear();
        }
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                check_display_lines(preview.source(), lang, &cancel)?;
                let labels = if rebuild_labels && !search_layout {
                    Some(
                        prepare_labels(&preview, lang, &cancel)
                            .map_err(|e| error_text(lang, &e))?,
                    )
                } else {
                    None
                };
                let text = preview
                    .apply(
                        preview.source(),
                        preview.revision(),
                        preview.generation(),
                        &selected,
                        &cancel,
                    )
                    .map_err(|e| error_text(lang, &e))?;
                if text.contains('\0') {
                    return Err(lang.text("U+0000 kann nicht verlustfrei in den Texteditor übernommen werden. Keine Freigabe möglich.", "U+0000 cannot be adopted losslessly into the text editor. Approval is unavailable.").into());
                }
                check_display_lines(&text, lang, &cancel)?;
                let (before, after) = if exact {
                    let display = |input: &str| {
                        fastra_core::display::escaped_text(input, &cancel, 16 * 1024 * 1024).map_err(|error| match error {
                        fastra_core::Error::Limit => lang.text("Die Escape-Ansicht überschreitet 16 MiB. Zur vollständigen Textansicht zurückwechseln oder die Eingabe verkleinern; keine Freigabe aus einer Teilansicht.", "The escaped display exceeds 16 MiB. Return to complete text display or reduce the input; partial displays cannot be approved.").into(),
                        error => error_text(lang, &error),
                    })
                    };
                    let before = display(preview.source())?;
                    let after = display(&text)?;
                    check_display_lines(&before, lang, &cancel)?;
                    check_display_lines(&after, lang, &cancel)?;
                    (before, after)
                } else {
                    cancel.check().map_err(|e| error_text(lang, &e))?;
                    (preview.source().to_owned(), text)
                };
                let diff = if search_layout {
                    Some(
                        review_diff::prepare(&before, &after, &diff_cancel).map_err(|error| {
                            format!(
                                "{}: {error}",
                                lang.text(
                                    "Vollständige Vergleichsvorschau nicht möglich",
                                    "Complete comparison preview unavailable"
                                )
                            )
                        })?,
                    )
                } else {
                    None
                };
                Ok((labels, before, after, diff))
            },
            move |result| {
                let Some(pane) = weak.upgrade() else {
                    return;
                };
                if pane.render_generation.get() != generation
                    || pane.render_cancel.borrow().check().is_err()
                {
                    return;
                }
                match result {
                    Ok((labels, before, after, diff)) => {
                        pane.install_display(i, generation, exact, labels, (before, after), diff);
                    }
                    Err(error) => {
                        pane.render_error.set(true);
                        pane.render_status.set_text(&error);
                        pane.notify(false);
                    }
                }
            },
        );
    }
    #[cfg(debug_assertions)]
    pub(crate) fn test_display(&self, side: usize) -> String {
        self.search.borrow().as_ref().map_or_else(
            || buffer_text(&if side == 0 { self.before.buffer() } else { self.after.buffer() }),
            |surface| surface.diff.test_content(side),
        )
    }
    fn install_display(
        self: &Rc<Self>,
        item: usize,
        generation: u64,
        exact: bool,
        labels: Option<Vec<String>>,
        texts: (String, String),
        mut diff: Option<review_diff::Prepared>,
    ) {
        let (before, after) = texts;
        // Die Suchansicht besitzt ihre eigene virtuelle Liste und Vergleichspuffer.
        // Abgetrennte Altansichten dürfen deren Freigabe nicht verzögern.
        let search_layout = self.search.borrow().is_some();
        let (before, after) = if search_layout { (String::new(), String::new()) } else { (before, after) };
        let mut labels = labels.map(Vec::into_iter);
        let mut cleared = labels.is_none();
        let mut row = 0;
        let mut before_offset = 0;
        let mut after_offset = 0;
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(8), move || {
            let Some(pane) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if pane.render_generation.get() != generation
                || pane.render_cancel.borrow().check().is_err()
                || pane.frozen.get()
            {
                return glib::ControlFlow::Break;
            }
            let start = std::time::Instant::now();
            for _ in 0..48 {
                if !cleared {
                    if let Some(child) = pane.checks.first_child() {
                        pane.checks.remove(&child);
                    } else {
                        cleared = true;
                    }
                } else if let Some(label) = labels.as_mut().and_then(Iterator::next) {
                    let check = gtk::CheckButton::with_label(&label);
                    check.set_active(pane.approved.borrow()[item][row]);
                    let n = row;
                    row += 1;
                    let weak = Rc::downgrade(&pane);
                    check.connect_toggled(move |check| {
                        if let Some(pane) = weak.upgrade() {
                            if pane.frozen.get() || !pane.render_ready.get() {
                                return;
                            }
                            pane.approved.borrow_mut()[item][n] = check.is_active();
                            pane.update_after();
                        }
                    });
                    pane.checks.append(&check);
                } else {
                    pane.labels_ready.set(true);
                    // Auch die vollständigen Textseiten werden portionsweise eingefügt.
                    // Sonst blockiert die Freigabe trotz asynchroner Labelrechnung erneut.
                    if before_offset < before.len() {
                        append_chunk(&pane.before.buffer(), &before, &mut before_offset);
                    } else if after_offset < after.len() {
                        append_chunk(&pane.after.buffer(), &after, &mut after_offset);
                    } else {
                        if let Some(prepared) = diff.as_mut() {
                            if let Some(surface) = pane.search.borrow().as_ref() {
                                if !prepared.step(&surface.diff, pane.lang) {
                                    return glib::ControlFlow::Continue;
                                }
                            }
                            diff = None;
                        }
                        pane.render_status.set_text(if exact { pane.lang.text("Vollständige Escape-Ansicht · Originaltexte werden angewendet.", "Complete escaped display · original text will be applied.") } else { pane.lang.text("Vollständige Textansicht · Escapes zeigen Unicode und Zeilenenden exakt.", "Complete text display · escapes reveal exact Unicode and line endings.") });
                        pane.render_ready.set(true);
                        pane.checks.set_sensitive(true);
                        pane.notify(true);
                        return glib::ControlFlow::Break;
                    }
                    return glib::ControlFlow::Continue;
                }
                if start.elapsed() >= Duration::from_millis(3) {
                    break;
                }
            }
            glib::ControlFlow::Continue
        });
    }
}

fn check_display_lines(text: &str, lang: Language, cancel: &Cancellation) -> Result<(), String> {
    let mut bytes = 0usize;
    for (n, byte) in text.bytes().enumerate() {
        if n & 4095 == 0 {
            cancel.check().map_err(|e| error_text(lang, &e))?;
        }
        if byte == b'\n' || byte == b'\r' {
            bytes = 0;
        } else {
            bytes += 1;
        }
        if bytes > 64 * 1024 {
            return Err(lang.text("Eine vollständige Vorschauzeile überschreitet 64 KiB. Diese native Ansicht kann sie nicht sicher darstellen; keine Freigabe möglich. Eingabe oder Ersetzung verkleinern.", "A complete preview line exceeds 64 KiB. This native view cannot display it safely; approval is unavailable. Reduce the input or replacement.").into());
        }
    }
    Ok(())
}

fn append_chunk(buffer: &gtk::TextBuffer, text: &str, offset: &mut usize) {
    let mut end = (*offset + 64 * 1024).min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    buffer.insert(&mut buffer.end_iter(), &text[*offset..end]);
    *offset = end;
}

fn prepare_labels(
    preview: &Preview,
    lang: Language,
    cancel: &Cancellation,
) -> Result<Vec<String>, fastra_core::Error> {
    let mut chars = preview.source().char_indices().peekable();
    let mut units = 0;
    let mut scanned = 0usize;
    let mut boundary = |target: usize| -> Result<usize, fastra_core::Error> {
        while units < target {
            let (_, ch) = chars.next().ok_or(fastra_core::Error::InvalidRange)?;
            units += ch.len_utf16();
            scanned += 1;
            if scanned & 4095 == 0 {
                cancel.check()?;
            }
        }
        if units != target {
            return Err(fastra_core::Error::InvalidRange);
        }
        Ok(chars
            .peek()
            .map_or(preview.source().len(), |(byte, _)| *byte))
    };
    let mut labels = Vec::with_capacity(preview.matches().len());
    for (n, hit) in preview.matches().iter().enumerate() {
        cancel.check()?;
        let start = boundary(hit.range.location)?;
        let end = boundary(hit.range.end()?)?;
        let matched: String = preview.source()[start..end].chars().take(100).collect();
        let label = format!(
            "{} · {} → {}",
            n + 1,
            if matched.is_empty() {
                lang.text("(leerer Treffer)", "(empty match)")
            } else {
                &matched
            },
            hit.replacement.chars().take(100).collect::<String>()
        );
        if label.contains('\0') {
            return Err(fastra_core::Error::InvalidRange);
        }
        labels.push(label);
    }
    cancel.check()?;
    Ok(labels)
}

#[cfg(debug_assertions)]
fn stress(pane: Rc<ApprovalPane>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    git_view::background(
        move || {
            let mut source = ("cat".to_owned() + &"x".repeat(415) + "\n").repeat(10_000);
            source.push_str(&"z".repeat(4 * 1024 * 1024 - source.len()));
            let request = SearchRequest {
                pattern: "cat".into(),
                replacement: "dog".into(),
                mode: SearchMode::Literal,
                case_sensitive: true,
                range: None,
            };
            let preview = fastra_core::preview(
                &source,
                1,
                1,
                &request,
                Limits::default(),
                &Cancellation::default(),
            )
            .map_err(|e| format!("{e:?}"))?;
            let make = |source: String, replacement: &str| {
                fastra_core::preview(
                    &source,
                    1,
                    1,
                    &SearchRequest {
                        pattern: "cat".into(),
                        replacement: replacement.into(),
                        mode: SearchMode::Literal,
                        case_sensitive: true,
                        range: None,
                    },
                    Limits::default(),
                    &Cancellation::default(),
                )
                .map(Arc::new)
                .map_err(|e| format!("{e:?}"))
            };
            let long_source = make("cat".to_owned() + &"x".repeat(64 * 1024), "dog")?;
            let long_target = make("cat".into(), &"x".repeat(64 * 1024 + 1))?;
            let long_escape = make("é".repeat(20_000) + "cat", "dog")?;
            Ok((Arc::new(preview), [long_source, long_target, long_escape]))
        },
        move |result| {
            let (preview, long_lines) = result.expect("stress preview");
            assert_eq!(preview.matches().len(), 10_000);
            let stage = Cell::new(0);
            let ticks = Cell::new(0usize);
            let last = Cell::new(std::time::Instant::now());
            let max_gap = Cell::new(Duration::ZERO);
            let start = std::time::Instant::now();
            pane.set_items(vec![Item {
                label: "4 MiB / 10000".into(),
                preview: preview.clone(),
            }]);
            glib::timeout_add_local(Duration::from_millis(10), move || {
                let now = std::time::Instant::now();
                max_gap.set(max_gap.get().max(now.duration_since(last.replace(now))));
                ticks.set(ticks.get() + 1);
                assert!(
                    start.elapsed() < Duration::from_secs(120),
                    "approval stress timed out"
                );
                let rows = pane.search.borrow().as_ref().map_or_else(
                    || pane.checks.observe_children().n_items(),
                    |surface| surface.test_loaded_hits(),
                );
                if ticks.get() & 127 == 0 {
                    eprintln!(
                        "approval progress stage={} rows={rows} ready={} elapsed={:?}",
                        stage.get(),
                        pane.render_ready.get(),
                        start.elapsed()
                    );
                }
                if !pane.render_ready.get() {
                    assert!(pane.approvals().is_none());
                }
                if stage.get() >= 3 && pane.render_ready.get() {
                    pane.test_approve_initial();
                }
                match stage.get() {
                    0 if rows >= 150 => {
                        if pane.search.borrow().is_none() { assert!(!pane.render_ready.get()); }
                        pane.exact.set_active(true);
                        assert!(pane.approvals().is_none());
                        stage.set(1);
                    }
                    1 if rows >= 300 => {
                        if pane.search.borrow().is_none() { assert!(!pane.render_ready.get()); }
                        pane.clear();
                        assert!(pane.approvals().is_none());
                        pane.exact.set_active(false);
                        pane.set_items(vec![Item {
                            label: "fresh generation".into(),
                            preview: preview.clone(),
                        }]);
                        stage.set(2);
                    }
                    2 if pane.render_ready.get() => {
                        if !pane.test_approve_initial() {
                            return glib::ControlFlow::Continue;
                        }
                        assert_eq!(rows, 10_000);
                        if let Some(surface) = pane.search.borrow().as_ref() {
                            assert_eq!(pane.checks.observe_children().n_items(), 0);
                            assert!(buffer_text(&pane.before.buffer()).is_empty());
                            assert!(buffer_text(&pane.after.buffer()).is_empty());
                            let [before, after] = surface.diff.test_texts();
                            assert!(before.len() >= preview.source().len());
                            assert!(after.len() >= preview.source().len());
                            assert_eq!(before.matches("cat").count(), 10000);
                            assert_eq!(after.matches("dog").count(), 10000);
                            let tail = preview.source().rsplit('\n').next().unwrap();
                            assert!(before.ends_with(tail) || before.ends_with(&format!("{tail}\n")));
                        } else {
                            assert_eq!(buffer_text(&pane.before.buffer()), preview.source());
                            assert_eq!(buffer_text(&pane.after.buffer()), preview.source().replace("cat", "dog"));
                        }
                        assert_eq!(pane.approvals().unwrap()[0].len(), 10_000);
                        assert!(ticks.get() >= 20, "no repeated GTK ticks");
                        assert!(
                            max_gap.get() < Duration::from_millis(750),
                            "GTK tick blocked {:?}",
                            max_gap.get()
                        );
                        pane.clear();
                        pane.set_items(vec![Item {
                            label: "long source".into(),
                            preview: long_lines[0].clone(),
                        }]);
                        stage.set(3);
                    }
                    3..=5 if pane.render_status.text().contains("64 KiB") => {
                        assert!(pane.approvals().is_none());
                        assert!(!pane.render_ready.get());
                        assert!(buffer_text(&pane.before.buffer()).is_empty());
                        assert!(buffer_text(&pane.after.buffer()).is_empty());
                        let next = stage.get() + 1;
                        if next == 6 {
                            eprintln!(
                                "FASTRA_APPROVAL_STRESS_OK 10000-hits/4MiB/linear-labels/idle-controls/chunked-text/exact-cancel/clear-cancel/source-target-escaped-longline-denied ticks={} max-gap-ms={} elapsed-ms={}",
                                ticks.get(),
                                max_gap.get().as_millis(),
                                start.elapsed().as_millis()
                            );
                            std::process::exit(0);
                        }
                        pane.exact.set_active(next == 5);
                        pane.set_items(vec![Item {
                            label: "long display".into(),
                            preview: long_lines[(next - 3) as usize].clone(),
                        }]);
                        stage.set(next);
                    }
                    _ => {}
                }
                glib::ControlFlow::Continue
            });
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn labels_map_utf16_boundaries_and_empty_matches_once() {
        for (pattern, mode, expected) in [
            (
                "cat",
                SearchMode::Literal,
                vec!["1 · cat → dog", "2 · cat → dog"],
            ),
            (
                "(?=cat)",
                SearchMode::Regex,
                vec!["1 · (empty match) → dog", "2 · (empty match) → dog"],
            ),
        ] {
            let cancel = Cancellation::default();
            let preview = fastra_core::preview(
                "🙂caté猫 cat",
                1,
                1,
                &SearchRequest {
                    pattern: pattern.into(),
                    replacement: "dog".into(),
                    mode,
                    case_sensitive: true,
                    range: None,
                },
                Limits::default(),
                &cancel,
            )
            .unwrap();
            assert_eq!(
                prepare_labels(&preview, Language(false), &cancel).unwrap(),
                expected
            );
            cancel.cancel();
            assert_eq!(
                prepare_labels(&preview, Language(false), &cancel),
                Err(fastra_core::Error::Cancelled)
            );
        }
    }
}
