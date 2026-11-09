//! Gemeinsame Syntaxpläne und davon getrennte Faltzustände je Quellausschnitt.
use super::*;
use fastra_core::folding::{Failure, Region};
use std::{
    collections::{BTreeMap, HashSet},
    ops::Range,
    rc::Weak,
    time::{Duration, Instant},
};
mod gutter;
mod marker;
mod runtime;
mod state;
pub(crate) use runtime::entry as worker_entry;
pub(super) use state::expand_all;
struct Closed {
    buffer: sourceview5::Buffer,
    start: gtk::TextMark,
    end: gtk::TextMark,
}
impl Closed {
    fn range(&self) -> Range<i32> {
        self.buffer.iter_at_mark(&self.start).offset()..self.buffer.iter_at_mark(&self.end).offset()
    }
    fn new(buffer: &sourceview5::Buffer, range: Range<i32>) -> Self {
        Self {
            buffer: buffer.clone(),
            start: buffer.create_mark(None, &buffer.iter_at_offset(range.start), true),
            end: buffer.create_mark(None, &buffer.iter_at_offset(range.end), false),
        }
    }
}
impl Drop for Closed {
    fn drop(&mut self) {
        for mark in [&self.start, &self.end] {
            if !mark.is_deleted() {
                self.buffer.delete_mark(mark);
            }
        }
    }
}
pub(super) struct Folds {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    views: [glib::WeakRef<sourceview5::View>; 2],
    buffers: [sourceview5::Buffer; 2],
    tags: [gtk::TextTag; 2],
    closed: [RefCell<Vec<Closed>>; 2],
    closed_keys: [RefCell<HashSet<(i32, i32)>>; 2],
    tag_dirty: [Cell<bool>; 2],
    regions: RefCell<Vec<Region>>,
    lines: RefCell<BTreeMap<i32, usize>>,
    gutters: RefCell<[Option<gutter::Decorations>; 2]>,
    buttons: [gtk::Button; 3],
    generation: Cell<u64>,
    ready: Cell<bool>,
    notice: RefCell<Option<String>>,
    scheduled: Cell<bool>,
    rendering: Cell<bool>,
    cancel: RefCell<fastra_process::Cancellation>,
}
fn language(buffer: &sourceview5::Buffer) -> Option<&'static str> {
    Some(match buffer.language()?.id().as_str() {
        "fastra-4d" => "fourD",
        "sh" => "bash",
        "c" | "chdr" => "c",
        "cpp" | "cpphdr" => "cpp",
        "c-sharp" => "cSharp",
        "css" => "css",
        "dart" => "dart",
        "docker" => "dockerfile",
        "go" => "go",
        "html" => "html",
        "java" => "java",
        "js" => "javascript",
        "jsx" => "jsx",
        "jsdoc" => "jsdoc",
        "json" => "json",
        "kotlin" => "kotlin",
        "lua" => "lua",
        "markdown" => "markdown",
        "objc" => "objc",
        "perl" => "perl",
        "php" => "php",
        "python" | "python3" => "python",
        "ruby" => "ruby",
        "rust" => "rust",
        "sql" => "sql",
        "swift" => "swift",
        "toml" => "toml",
        "typescript" => "typescript",
        "typescript-jsx" => "tsx",
        "yaml" => "yaml",
        _ => return None,
    })
}
pub(super) fn install(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    views: [&sourceview5::View; 2],
    options: &gtk::FlowBox,
) {
    let buttons = [
        gtk::Button::with_label(
            ui.lang
                .text("Bereich ein-/ausklappen", "Collapse/expand region"),
        ),
        gtk::Button::with_label(
            ui.lang
                .text("Alle Bereiche einklappen", "Collapse all regions"),
        ),
        gtk::Button::with_label(
            ui.lang
                .text("Alle Bereiche ausklappen", "Expand all regions"),
        ),
    ];
    let buffers = views.map(|view| view.buffer().downcast::<sourceview5::Buffer>().unwrap());
    let tags = std::array::from_fn(|_| {
        buffers[0]
            .create_tag(None, &[("invisible", &true)])
            .unwrap()
    });
    let folds = Rc::new(Folds {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        views: views.map(|view| view.downgrade()),
        buffers,
        tags,
        closed: std::array::from_fn(|_| RefCell::new(Vec::new())),
        closed_keys: std::array::from_fn(|_| RefCell::new(HashSet::new())),
        tag_dirty: std::array::from_fn(|_| Cell::new(false)),
        regions: RefCell::new(Vec::new()),
        lines: RefCell::new(BTreeMap::new()),
        gutters: RefCell::new([None, None]),
        buttons,
        generation: Cell::new(0),
        ready: Cell::new(false),
        notice: RefCell::new(None),
        scheduled: Cell::new(false),
        rendering: Cell::new(false),
        cancel: RefCell::new(Default::default()),
    });
    for (index, view) in views.iter().enumerate() {
        let decorations = gutter::install(&folds, index, view);
        folds.gutters.borrow_mut()[index] = Some(decorations);
        source_panes::bind_folding(view, &folds, index);
        let weak = Rc::downgrade(&folds);
        view.connect_preedit_changed(move |_, text| {
            if !text.is_empty() {
                if let Some(f) = weak.upgrade() {
                    f.expand(index);
                }
            }
        });
        marker::install(&folds, index, view);
        let weak = Rc::downgrade(&folds);
        view.connect_map(move |_| {
            if let Some(f) = weak.upgrade() {
                if !f.ready.get() {
                    f.schedule();
                }
            }
        });
        let weak = Rc::downgrade(&folds);
        folds.buffers[index].connect_insert_text(move |_, at, _| {
            if let Some(f) = weak.upgrade() {
                f.before_edit(index, at.offset()..at.offset());
            }
        });
        let weak = Rc::downgrade(&folds);
        folds.buffers[index].connect_delete_range(move |_, a, b| {
            if let Some(f) = weak.upgrade() {
                f.before_edit(index, a.offset()..b.offset());
            }
        });
        let weak = Rc::downgrade(&folds);
        folds.buffers[index].connect_mark_set(move |_, _, mark| {
            if matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
                if let Some(f) = weak.upgrade() {
                    f.reveal(index);
                }
            }
        });
        let weak = Rc::downgrade(&folds);
        view.connect_show_line_numbers_notify(move |_| {
            if let Some(f) = weak.upgrade() {
                f.render();
            }
        });
    }
    let weak = Rc::downgrade(&folds);
    doc.buffer.connect_changed(move |_| {
        if let Some(f) = weak.upgrade() {
            f.schedule();
        }
    });
    let weak = Rc::downgrade(&folds);
    doc.buffer.connect_language_notify(move |_| {
        if let Some(f) = weak.upgrade() {
            f.invalidate();
            f.expand(0);
            f.expand(1);
            f.schedule();
        }
    });
    for (index, button) in folds.buttons.iter().enumerate() {
        let weak = Rc::downgrade(&folds);
        button.connect_clicked(move |button| {
            if let Some(popover) = button
                .ancestor(gtk::Popover::static_type())
                .and_downcast::<gtk::Popover>()
            {
                popover.popdown();
            }
            let weak = weak.clone();
            glib::idle_add_local_once(move || {
                if let Some(f) = weak.upgrade() {
                    f.command(index);
                }
            });
        });
        options.insert(button, -1);
    }
    *doc.syntax_folds.borrow_mut() = Some(folds.clone());
    folds.schedule();
    folds.render();
}
impl Folds {
    fn member(&self, doc: &Rc<Document>) -> bool {
        self.ui.upgrade().is_some_and(|ui| {
            ui.documents
                .try_borrow()
                .is_ok_and(|documents| documents.iter().any(|d| Rc::ptr_eq(d, doc)))
        })
    }
    fn allowed(&self) -> bool {
        self.doc.upgrade().is_some_and(|d| {
            self.member(&d)
                && !d.close_pending.get()
                && d.section_view.try_borrow().is_ok_and(|v| v.is_none())
                && d.visual_view.try_borrow().is_ok_and(|v| v.is_none())
                && d.comparison.try_borrow().is_ok_and(|v| v.is_none())
                && d.rich
                    .try_borrow()
                    .is_ok_and(|r| r.as_ref().is_none_or(|e| !e.active.get()))
                && d.folded.try_borrow().is_ok_and(|v| v.is_none())
        })
    }

    fn invalidate(&self) {
        self.ready.set(false);
        self.generation.set(self.generation.get().wrapping_add(1));
        self.cancel.borrow().cancel();
        self.render();
    }
    fn schedule(self: &Rc<Self>) {
        self.invalidate();
        if self.scheduled.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(160), move || {
            if let Some(f) = weak.upgrade() {
                f.scheduled.set(false);
                f.analyze();
            }
        });
    }
    fn analyze(self: &Rc<Self>) {
        let Some(doc) = self
            .doc
            .upgrade()
            .filter(|d| self.member(d) && !d.close_pending.get())
        else {
            return;
        };
        if !self.allowed()
            || !self
                .views
                .iter()
                .any(|view| view.upgrade().is_some_and(|v| v.is_mapped()))
        {
            return;
        }
        let Some(language) = language(&doc.buffer) else {
            self.publish(Vec::new());
            return;
        };
        let generation = self.generation.get();
        let revision = doc.revision.get();
        let cancel = fastra_process::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let job = runtime::Job {
            language: language.into(),
            source: buffer_text(&doc.buffer),
            cancel: cancel.clone(),
            reply: tx,
        };
        self.submit(job, generation);
        let weak = Rc::downgrade(self);
        let began = Instant::now();
        glib::timeout_add_local(Duration::from_millis(16), move || {
            let Some(f) = weak.upgrade() else {
                cancel.cancel();
                return glib::ControlFlow::Break;
            };
            if f.generation.get() != generation
                || f.doc.upgrade().is_none_or(|d| {
                    !f.member(&d)
                        || d.revision.get() != revision
                        || d.close_pending.get()
                        || crate::folding::language(&d.buffer) != Some(language)
                })
            {
                cancel.cancel();
                return glib::ControlFlow::Break;
            }
            let result = match rx.try_recv() {
                Ok(value) => Some(value),
                Err(std::sync::mpsc::TryRecvError::Disconnected) => Some(Err(Failure::Unavailable)),
                Err(std::sync::mpsc::TryRecvError::Empty)
                    if began.elapsed() > Duration::from_secs(12) =>
                {
                    cancel.cancel();
                    Some(Err(Failure::Limit))
                }
                Err(_) => None,
            };
            if let Some(result) = result {
                match result {
                    Ok(regions) => f.publish(regions),
                    Err(error) => f.failed(error),
                }
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
    }
    fn submit(self: &Rc<Self>, job: runtime::Job, generation: u64) {
        if self.generation.get() != generation || job.cancel.is_cancelled() {
            return;
        }
        if let Err(job) = runtime::submit(job) {
            let weak = Rc::downgrade(self);
            glib::timeout_add_local_once(Duration::from_millis(50), move || {
                if let Some(f) = weak.upgrade() {
                    f.submit(job, generation);
                }
            });
        }
    }
    fn publish(&self, regions: Vec<Region>) {
        if let Some(previous) = self.notice.borrow_mut().take() {
            if let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) {
                if ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                    && ui.status.text().as_str() == previous
                {
                    ui.status.set_text("");
                }
            }
        }

        let valid: HashSet<_> = regions
            .iter()
            .map(|r| (r.characters.start as i32, r.characters.end as i32))
            .collect();
        for (index, closed) in self.closed.iter().enumerate() {
            let before = closed.borrow().len();
            closed.borrow_mut().retain(|c| {
                let r = c.range();
                valid.contains(&(r.start, r.end))
            });
            if before != closed.borrow().len() {
                self.tag_dirty[index].set(true);
            }
        }
        let mut lines = BTreeMap::new();
        for (index, r) in regions.iter().enumerate() {
            let line = self.buffers[0]
                .iter_at_offset(r.characters.start as i32)
                .line();
            lines.entry(line).or_insert(index);
        }
        *self.lines.borrow_mut() = lines;
        *self.regions.borrow_mut() = regions;
        self.ready.set(true);
        self.render();
    }
    fn failed(&self, error: Failure) {
        self.expand(0);
        self.expand(1);
        self.regions.borrow_mut().clear();
        self.lines.borrow_mut().clear();
        self.ready.set(false);
        self.render();
        if error == Failure::Cancelled {
            return;
        }
        if let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) {
            if ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) {
                let message = match error {
                    Failure::Limit => ui.lang.text("Syntaxfaltung hat ihre Analysegrenze erreicht; der Quelltext bleibt vollständig sichtbar.", "Code folding reached its analysis limit; all source text remains visible."),
                    _ => ui.lang.text("Syntaxfaltung ist momentan nicht verfügbar; der Quelltext bleibt vollständig sichtbar.", "Code folding is currently unavailable; all source text remains visible."),
                };
                *self.notice.borrow_mut() = Some(message.into());
                ui.status.set_text(message);
            }
        }
    }
    fn index(&self) -> usize {
        self.doc.upgrade().map_or(0, |d| {
            usize::from(source_panes::buffer(&d) == self.buffers[1])
        })
    }
    fn command(&self, command: usize) {
        if !self.allowed() {
            return;
        }
        let index = self.index();
        match command {
            0 => {
                if !self.ready.get() {
                    return;
                }
                let caret = self.buffers[index].cursor_position();
                let line = self.buffers[index].iter_at_offset(caret).line();
                let region = self
                    .lines
                    .borrow()
                    .get(&line)
                    .and_then(|n| self.regions.borrow().get(*n).cloned())
                    .or_else(|| {
                        self.regions
                            .borrow()
                            .iter()
                            .filter(|r| {
                                r.characters.start as i32 <= caret
                                    && caret < (r.characters.end as i32)
                            })
                            .max_by_key(|r| r.depth)
                            .cloned()
                    });
                if let Some(r) = region {
                    self.toggle(index, &r, false);
                }
            }
            1 => {
                if !self.ready.get() {
                    return;
                }
                let regions = self.regions.borrow().clone();
                for region in regions.iter().rev() {
                    self.set(index, region, true);
                }
                self.render();
            }
            _ => self.expand(index),
        }
        if let Some(view) = self.views[index].upgrade() {
            view.grab_focus();
        }
    }
}
impl Drop for Folds {
    fn drop(&mut self) {
        self.cancel.borrow().cancel();
        for (index, buffer) in self.buffers.iter().enumerate() {
            let (a, b) = buffer.bounds();
            buffer.remove_tag(&self.tags[index], &a, &b);
        }
        for tag in &self.tags {
            self.buffers[0].tag_table().remove(tag);
        }
    }
}

pub(super) fn refresh(doc: &Document) {
    if let Some(f) = doc.syntax_folds.borrow().as_ref() {
        f.render();
    }
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(super) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
