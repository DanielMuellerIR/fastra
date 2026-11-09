use super::*;
use fastra_core::navigation_anchor::Anchor;
use std::ops::Range;
mod request;
pub(crate) use request::{begin_request, prepare_point, PreparedPoint};
struct Destination {
    range: Range<usize>,
    heading: Option<Heading>,
    source: Option<source_panes::Target>,
}
impl Destination {
    fn new(range: Range<usize>, heading: Option<Heading>) -> Self {
        Self {
            range,
            heading,
            source: None,
        }
    }
}
#[derive(Clone)]
struct Point {
    doc: Weak<Document>,
    anchor: Anchor,
    heading: Option<Heading>,
    line: usize,
}
pub(crate) struct History {
    ui: Weak<Ui>,
    points: RefCell<Vec<Point>>,
    index: Cell<Option<usize>>,
    pub(super) views: RefCell<Vec<Weak<View>>>,
    job: Cell<u64>,
    cancel: RefCell<Cancellation>,
}
impl Drop for History {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
    }
}
pub(super) fn get(ui: &Rc<Ui>) -> Rc<History> {
    if let Some(history) = ui.outline_history.borrow().clone() {
        return history;
    }
    let history = Rc::new(History {
        ui: Rc::downgrade(ui),
        points: RefCell::new(vec![]),
        index: Cell::new(None),
        views: RefCell::new(vec![]),
        job: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
    });
    *ui.outline_history.borrow_mut() = Some(history.clone());
    let weak = Rc::downgrade(&history);
    ui.tabs.connect_switch_page(move |_, _, _| {
        let weak = weak.clone();
        glib::idle_add_local_once(move || {
            if let Some(history) = weak.upgrade() {
                history.refresh();
                for view in history.current_views() {
                    view.schedule();
                    view.follow();
                }
            }
        });
    });
    history
}
fn selected(doc: &Document) -> Range<usize> {
    let buffer = source_panes::buffer(doc);
    let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
        let iter = buffer.iter_at_offset(buffer.cursor_position());
        (iter, iter)
    });
    a.offset().max(0) as usize..b.offset().max(a.offset()).max(0) as usize
}

fn same_place(a: &Point, b: &Point) -> bool {
    a.doc.ptr_eq(&b.doc)
        && a.anchor.range == b.anchor.range
        && a.heading
            .as_ref()
            .map(|h| (&h.title, h.level, &h.kind, h.line))
            == b.heading
                .as_ref()
                .map(|h| (&h.title, h.level, &h.kind, h.line))
}
impl History {
    pub(super) fn can_move(&self, delta: i32) -> bool {
        self.index
            .get()
            .and_then(|index| index.checked_add_signed(delta as isize))
            .is_some_and(|n| n < self.points.borrow().len())
    }
    fn begin(&self) -> (u64, Cancellation) {
        self.cancel.borrow().cancel();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let job = self.job.get().wrapping_add(1);
        self.job.set(job);
        (job, cancel)
    }
    fn current_views(&self) -> Vec<Rc<View>> {
        let mut refs = self.views.borrow_mut();
        refs.retain(|v| v.strong_count() > 0);
        refs.iter().filter_map(Weak::upgrade).collect()
    }
    pub(super) fn refresh(&self) {
        for view in self.current_views() {
            view.controls();
        }
    }
    fn visit(&self, origin: Point, target: Point) {
        let mut points = self.points.borrow_mut();
        if let Some(index) = self.index.get() {
            let previous = &points[index];
            if !previous.doc.ptr_eq(&origin.doc)
                || origin.heading.is_some()
                || previous.anchor.range.start != origin.anchor.range.start
                || previous.line != origin.line
                || previous.heading.is_none()
            {
                points[index] = origin;
            }
            points.truncate(index + 1);
        } else {
            points.push(origin);
        }
        if points.last().is_some_and(|p| same_place(p, &target)) {
            *points.last_mut().unwrap() = target;
        } else {
            points.push(target);
        }
        if points.len() > 100 {
            let extra = points.len() - 100;
            points.drain(..extra);
        }
        self.index.set(points.len().checked_sub(1));
        drop(points);
        self.refresh();
    }
    pub(super) fn jump(self: &Rc<Self>, view: &Rc<View>, heading: Heading) {
        let (job, _) = self.begin();
        if let Some(editor) = view.rich.as_ref().and_then(Weak::upgrade) {
            let weak = Rc::downgrade(self);
            let weak_view = Rc::downgrade(view);
            editor.outline_prepare(move |snapshot| {
                let (Some(history), Some(view), Some(snapshot)) =
                    (weak.upgrade(), weak_view.upgrade(), snapshot)
                else {
                    return;
                };
                if history.job.get() != job
                    || !view.valid()
                    || snapshot.levels
                        != view
                            .headings
                            .borrow()
                            .iter()
                            .map(|h| h.level)
                            .collect::<Vec<_>>()
                {
                    view.schedule();
                    return;
                }
                history.jump_checked(&view, heading, Some(snapshot.index), job);
            });
        } else {
            self.jump_checked(view, heading, None, job);
        }
    }
    fn jump_checked(
        self: &Rc<Self>,
        view: &Rc<View>,
        heading: Heading,
        rich_origin: Option<Option<usize>>,
        job: u64,
    ) {
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), view.doc.upgrade()) else {
            return;
        };
        if !view.valid()
            || view.revision.get() != doc.revision.get()
            || !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
            || (!doc.is_rich_active() && !ui.source_read_allowed(&doc))
            || !view.headings.borrow().contains(&heading)
        {
            view.schedule();
            return;
        }
        let source = buffer_text(&doc.buffer);
        let revision = doc.revision.get();
        let rich_heading = rich_origin
            .flatten()
            .and_then(|n| view.headings.borrow().get(n).cloned());
        let origin = if rich_origin.is_some() {
            rich_heading
                .as_ref()
                .map_or(0..0, |h| h.offset as usize..h.end as usize)
        } else {
            selected(&doc)
        };
        let origin_line = rich_heading.as_ref().map_or_else(
            || doc.buffer.iter_at_offset(origin.start as i32).line().max(0) as usize + 1,
            |h| h.line,
        );
        let origin_heading = view
            .headings
            .borrow()
            .iter()
            .find(|h| h.offset as usize == origin.start)
            .cloned();
        let destination = heading.offset.max(0) as usize..heading.end.max(heading.offset) as usize;
        let cancel = self.cancel.borrow().clone();
        let owner = ui.generation.get();
        let weak = Rc::downgrade(self);
        let weak_view = Rc::downgrade(view);
        let weak_doc = Rc::downgrade(&doc);
        git_view::background(
            move || {
                let before = Anchor::from_characters(&source, revision, origin, &cancel)
                    .map_err(|e| e.to_string())?;
                let after =
                    Anchor::from_characters(&source, revision, destination.clone(), &cancel)
                        .map_err(|e| e.to_string())?;
                Ok((before, after, destination))
            },
            move |result| {
                let (Some(history), Some(view), Some(doc)) =
                    (weak.upgrade(), weak_view.upgrade(), weak_doc.upgrade())
                else {
                    return;
                };
                let Some(ui) = history.ui.upgrade().filter(|u| {
                    u.window.is_visible() && u.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                }) else {
                    return;
                };
                if history.job.get() != job
                    || doc.revision.get() != revision
                    || !view.valid()
                    || ui.generation.get() != owner
                    || !view.headings.borrow().contains(&heading)
                {
                    return;
                }
                match result {
                    Ok((before, after, range)) => {
                        let weak = Rc::downgrade(&history);
                        let original_doc = Rc::downgrade(&doc);
                        let target_heading = heading.clone();
                        history.apply(
                            &ui,
                            &doc,
                            Destination::new(range, Some(heading.clone())),
                            job,
                            move || {
                                if let Some(history) = weak.upgrade() {
                                    history.visit(
                                        Point {
                                            doc: original_doc.clone(),
                                            anchor: before,
                                            heading: origin_heading,
                                            line: origin_line,
                                        },
                                        Point {
                                            doc: original_doc,
                                            anchor: after,
                                            heading: Some(target_heading.clone()),
                                            line: target_heading.line,
                                        },
                                    );
                                }
                            },
                        );
                    }
                    Err(_) => ui.status.set_text(ui.lang.text(
                        "Sprungziel konnte nicht vollständig geprüft werden.",
                        "The navigation destination could not be checked completely.",
                    )),
                }
            },
        );
    }
    pub(super) fn move_by(self: &Rc<Self>, delta: i32) {
        let (job, _) = self.begin();
        let editor = self
            .ui
            .upgrade()
            .and_then(|ui| ui.active())
            .and_then(|doc| doc.rich.borrow().clone());
        if let Some(editor) = editor {
            let weak = Rc::downgrade(self);
            editor.outline_prepare(move |snapshot| {
                if let Some(history) = weak
                    .upgrade()
                    .filter(|h| h.job.get() == job && snapshot.is_some())
                {
                    history.move_checked(delta, job);
                }
            });
        } else {
            self.move_checked(delta, job);
        }
    }
    fn move_checked(self: &Rc<Self>, delta: i32, job: u64) {
        let Some(ui) = self.ui.upgrade().filter(|u| u.window.is_visible()) else {
            return;
        };
        let cancel = self.cancel.borrow().clone();
        let Some(index) = self.index.get() else {
            return;
        };
        let Some(next) = index
            .checked_add_signed(delta as isize)
            .filter(|n| *n < self.points.borrow().len())
        else {
            return;
        };
        let point = self.points.borrow()[next].clone();
        let Some(doc) = point
            .doc
            .upgrade()
            .filter(|d| ui.documents.borrow().iter().any(|open| Rc::ptr_eq(open, d)))
        else {
            ui.status.set_text(ui.lang.text(
                "Das Dokument im Sprungverlauf wurde geschlossen oder ersetzt.",
                "The document in the jump history was closed or replaced.",
            ));
            return;
        };
        if !doc.is_rich_active() && !ui.source_read_allowed(&doc) {
            return;
        }
        let active = ui.active().map(|d| (Rc::downgrade(&d), d.revision.get()));
        let revision = doc.revision.get();
        let source = buffer_text(&doc.buffer);
        let format = language(&doc);
        let name = title(&doc);
        let weak_doc = Rc::downgrade(&doc);

        let target_heading = point.heading.clone();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                let range = if point.anchor.revision == revision {
                    point
                        .anchor
                        .resolve_characters(&source, revision, &cancel)
                        .map_err(|e| e.to_string())?
                } else if let Some(old) = point.heading {
                    let values = entries(
                        &source,
                        if format == "fastra-4d" {
                            "fastra-4d"
                        } else {
                            "markdown"
                        },
                        &name,
                        &cancel,
                    )
                    .map_err(|_| "outline analysis".to_string())?;
                    let mut matches = values.iter().filter(|h| {
                        h.kind == old.kind && h.title == old.title && h.level == old.level
                    });
                    let candidate = matches.next();
                    if matches.next().is_none() {
                        candidate.map(|h| h.offset as usize..h.end as usize)
                    } else {
                        None
                    }
                } else {
                    point
                        .anchor
                        .resolve_characters(&source, revision, &cancel)
                        .map_err(|e| e.to_string())?
                };
                Ok(range)
            },
            move |result| {
                let (Some(history), Some(doc)) = (weak.upgrade(), weak_doc.upgrade()) else {
                    return;
                };
                let Some(ui) = history.ui.upgrade().filter(|u| u.window.is_visible()) else {
                    return;
                };
                if history.job.get() != job
                    || history.index.get() != Some(index)
                    || doc.revision.get() != revision
                    || !ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc))
                    || match (active.as_ref(), ui.active()) {
                        (Some((weak, rev)), Some(current)) => weak.upgrade().is_none_or(|old| {
                            !Rc::ptr_eq(&old, &current) || current.revision.get() != *rev
                        }),
                        (None, None) => false,
                        _ => true,
                    }
                {
                    return;
                }
                match result {
                    Ok(Some(range)) => {
                        let weak = Rc::downgrade(&history);
                        history.apply(
                            &ui,
                            &doc,
                            Destination::new(range, target_heading),
                            job,
                            move || {
                                if let Some(history) = weak.upgrade() {
                                    history.index.set(Some(next));
                                    history.refresh();
                                }
                            },
                        );
                    }
                    _ => ui.status.set_text(ui.lang.text(
                        "Das Ziel im Sprungverlauf wurde geändert oder ist nicht mehr eindeutig.",
                        "The jump history destination changed or is no longer unique.",
                    )),
                }
            },
        );
    }
    fn apply(
        self: &Rc<Self>,
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        destination: Destination,
        job: u64,
        done: impl FnOnce() + 'static,
    ) {
        let Destination {
            range,
            heading,
            source,
        } = destination;
        let Some(index) = ui
            .documents
            .borrow()
            .iter()
            .position(|d| Rc::ptr_eq(d, doc))
        else {
            return;
        };
        for view in self.current_views() {
            view.menu.popdown();
        }
        ui.tabs.set_current_page(Some(index as u32));
        let weak = Rc::downgrade(self);
        let weak_doc = Rc::downgrade(doc);
        let revision = doc.revision.get();
        glib::idle_add_local_once(move || {
            let (Some(history), Some(doc)) = (weak.upgrade(), weak_doc.upgrade()) else {
                return;
            };
            let Some(ui) = history.ui.upgrade().filter(|u| {
                u.window.is_visible() && u.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
            }) else {
                return;
            };
            if history.job.get() != job || doc.revision.get() != revision {
                return;
            }
            let editor = doc.rich.borrow().clone();
            if let Some(editor) = editor {
                if let Some(heading) = heading {
                    history.apply_rich(&doc, editor, range, heading, job, done);
                } else {
                    let weak = Rc::downgrade(&history);
                    let weak_doc = Rc::downgrade(&doc);
                    editor.outline_source(move |ok| {
                        let (Some(history), Some(doc)) = (weak.upgrade(), weak_doc.upgrade())
                        else {
                            return;
                        };
                        let Some(ui) = history.ui.upgrade() else {
                            return;
                        };
                        if ok
                            && history.job.get() == job
                            && doc.revision.get() == revision
                            && ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                        {
                            history.apply(&ui, &doc, Destination::new(range, None), job, done);
                        }
                    });
                }
                return;
            }
            if !ui.source_read_allowed(&doc) {
                return;
            }
            let Some(target) = source
                .or_else(|| source_panes::capture(&doc))
                .filter(|t| t.valid_for_reading(&doc))
            else {
                ui.status.set_text(ui.lang.text(
                    "Quellansicht nicht verfügbar; kein Sprung ausgeführt.",
                    "Source view unavailable; no navigation was performed.",
                ));
                return;
            };
            if doc.folded.borrow().is_some() {
                if let Some(button) = doc
                    .outline
                    .borrow()
                    .as_ref()
                    .and_then(|v| v.unfold.upgrade())
                {
                    button.emit_clicked();
                }
            }
            let mut first = target
                .buffer
                .iter_at_offset((range.start as i32).clamp(0, target.buffer.char_count()));
            let last = target.buffer.iter_at_offset(
                (range.end as i32).clamp(first.offset(), target.buffer.char_count()),
            );
            target.buffer.select_range(&last, &first);
            target.view.scroll_to_iter(&mut first, 0.15, true, 0., 0.2);
            target.view.grab_focus();
            if doc
                .markdown_toggle
                .borrow()
                .as_ref()
                .is_some_and(|b| b.is_active())
            {
                if let Some(preview) = doc.markdown.borrow().as_ref() {
                    preview.jump(revision, range.start as i32);
                }
            }
            done();
        });
    }
    fn apply_rich(
        self: &Rc<Self>,
        doc: &Rc<Document>,
        editor: Rc<rich_editor::RichEditor>,
        range: Range<usize>,
        heading: Heading,
        job: u64,
        done: impl FnOnce() + 'static,
    ) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let source = buffer_text(&doc.buffer);
        let revision = doc.revision.get();
        let name = title(doc);
        let cancel = self.cancel.borrow().clone();
        let stamp = editor.outline_stamp();
        let weak = Rc::downgrade(self);
        let weak_doc = Rc::downgrade(doc);
        let weak_editor = Rc::downgrade(&editor);
        let owner = ui.generation.get();
        git_view::background(
            move || {
                entries(&source, "markdown", &name, &cancel)
                    .map_err(|_| "outline analysis".to_owned())
            },
            move |result| {
                let (Some(history), Some(doc), Some(editor)) =
                    (weak.upgrade(), weak_doc.upgrade(), weak_editor.upgrade())
                else {
                    return;
                };
                let Some(ui) = history.ui.upgrade().filter(|u| {
                    u.generation.get() == owner && u.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                }) else {
                    return;
                };
                if history.job.get() != job
                    || doc.revision.get() != revision
                    || stamp.is_none()
                    || editor.outline_stamp() != stamp
                {
                    return;
                }
                let destination = result.ok().and_then(|entries| {
                    let index = entries.iter().position(|h| {
                        h.offset as usize == range.start
                            && h.title == heading.title
                            && h.kind == heading.kind
                            && h.level == heading.level
                    })?;
                    Some((index, entries.iter().map(|h| h.level).collect()))
                });
                let Some((index, levels)) = destination else {
                    ui.status.set_text(ui.lang.text(
                        "Das Rich-Sprungziel ist nicht mehr eindeutig.",
                        "The rich navigation destination is no longer unique.",
                    ));
                    return;
                };
                let weak = Rc::downgrade(&history);
                editor.outline_reveal(index, levels, move |ok| {
                    if let Some(history) = weak.upgrade().filter(|h| h.job.get() == job) {
                        if ok { done(); }
                        else if let Some(ui) = history.ui.upgrade() { ui.status.set_text(ui.lang.text("Rich-Inhalt oder Dokument geändert; kein weiterer Sprung ausgeführt.", "Rich content or document changed; no further navigation was performed.")); }
                    }
                });
            },
        );
    }
}
