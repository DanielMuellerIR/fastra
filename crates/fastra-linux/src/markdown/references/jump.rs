use super::{check::Source, view::State};
use crate::*;
use std::sync::{Arc, Mutex};
impl State {
    pub(super) fn jump(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(report) = self.report.borrow().clone() else {
            return;
        };
        let Some(index) = self
            .visible
            .borrow()
            .get(self.selected.selected() as usize)
            .copied()
        else {
            return;
        };
        let Some(finding) = report.findings.get(index) else {
            return;
        };
        let Some(source) = report
            .sources
            .iter()
            .find(|s| s.id == finding.source)
            .cloned()
        else {
            return;
        };
        let offset = finding.reference.offset.max(0) as usize;
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let docs = ui.documents.borrow().clone();
        let job = self.job.get();
        let weak = Rc::downgrade(self);
        self.busy.set(true);
        self.controls();
        crate::rich_editor::flush_documents_owned(
            &docs,
            Box::new(move |ok| {
                let Some(s) = weak
                    .upgrade()
                    .filter(|s| s.job.get() == job && s.window.is_visible())
                else {
                    return;
                };
                s.busy.set(false);
                s.controls();
                if !ok {
                    s.stale();
                    return;
                }
                if source.document.is_some() && s.fresh(&source).is_none() {
                    s.stale();
                    return;
                }
                s.prepare_jump(source, offset, job);
            }),
        );
    }
    fn stale(&self) {
        self.error(self.lang.text(
            "Die Quelle wurde geändert oder geschlossen. Bitte erneut prüfen.",
            "The source changed or was closed. Please check again.",
        ));
    }
    fn prepare_jump(self: &Rc<Self>, source: Source, offset: usize, job: u64) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let Some(origin) = ui
            .active()
            .filter(|d| d.has_source_text() && !d.saving.get() && !d.close_pending.get())
        else {
            return;
        };
        let (navigation, cancel) = markdown_navigation::begin_request(&ui, &origin);
        let check_navigation = navigation.clone();
        let original = buffer_text(&origin.buffer);
        let revision = origin.revision.get();
        let buffer = source_panes::buffer(&origin);
        let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
            let at = buffer.iter_at_offset(buffer.cursor_position());
            (at, at)
        });
        let selection = a.offset().max(0) as usize..b.offset().max(a.offset()).max(0) as usize;
        let target = self.fresh(&source);
        let target_revision = target.as_ref().map_or(0, |d| d.revision.get());
        let weak = Rc::downgrade(self);
        let content = source.content.clone();
        let snapshot = source.snapshot.clone();
        let path = source.path.clone();
        let nav_cancel = cancel.clone();
        git_view::background(
            move || {
                let before = markdown_navigation::prepare_point(
                    &original,
                    revision,
                    selection,
                    &[],
                    &cancel,
                )?;
                let after = markdown_navigation::prepare_point(
                    &content,
                    target_revision,
                    offset..offset,
                    &[],
                    &cancel,
                )?;
                let expected = if source.document.is_none() {
                    let expected = snapshot.ok_or("Missing source snapshot")?;
                    let path = source.path.as_ref().ok_or("Missing source path")?;
                    let local = super::local_path::LocalPaths::current(&cancel)
                        .map_err(|_| "Source volume changed")?;
                    if local
                        .resolve(path, &cancel)
                        .map_err(|_| "Source path changed")?
                        != *path
                    {
                        return Err("Source path changed".into());
                    }
                    let current =
                        fastra_io::ReadSnapshot::read_bounded(path, super::parser::MAX_SOURCE, &cancel)
                            .map_err(|_| "Source changed")?;
                    if !current.same_source(&expected) {
                        return Err("Source changed".into());
                    }
                    Some(expected)
                } else {
                    None
                };
                Ok((source, before, after, expected))
            },
            move |result| {
                let Some(s) = weak.upgrade().filter(|s| {
                    s.window.is_visible()
                        && s.job.get() == job
                        && check_navigation.current_readable()
                }) else {
                    return;
                };
                let Some(ui) = s.ui.upgrade() else {
                    return;
                };
                let Ok((source, before, after, expected)) = result else {
                    s.stale();
                    return;
                };
                if source.document.is_some() {
                    let Some(doc) = s.fresh(&source) else {
                        s.stale();
                        return;
                    };
                    if doc.revision.get() != target_revision {
                        s.stale();
                        return;
                    }
                    s.window.close();
                    navigation.source(before, after, &doc);
                } else {
                    let Some(path) = path else {
                        s.stale();
                        return;
                    };
                    let expected_text = source.content;
                    let prepared = Arc::new(Mutex::new(Some(after)));
                    let finish = prepared.clone();
                    let rejected = Arc::new(std::sync::atomic::AtomicBool::new(false));
                    let worker_rejected = rejected.clone();
                    let validator: LoadValidator = Box::new(move |loaded| {
                        if nav_cancel.check().is_err() {
                            return false;
                        }
                        let valid = expected.as_ref().is_some_and(|expected| {
                            let same = match loaded {
                                viewer::Loaded::Editor(loader::Loaded::Text { decoded, snapshot }) => decoded.text() == expected_text && expected.matches_writable_snapshot(snapshot),
                                viewer::Loaded::Editor(loader::Loaded::ReadOnlyText(source)) => source.text() == expected_text && expected.same_source(source.snapshot()),
                                _ => false,
                            };
                            same && expected.verify_current(&nav_cancel).is_ok()
                        });
                        if !valid {
                            worker_rejected.store(true, std::sync::atomic::Ordering::Relaxed);
                        }
                        valid
                    });
                    let active = Rc::new(Cell::new(true));
                    let load_active = active.clone();
                    let finished = active.clone();
                    let began = std::time::Instant::now();
                    let weak = Rc::downgrade(&s);
                    let pending = navigation.clone();
                    glib::timeout_add_local(Duration::from_millis(30), move || {
                        let Some(s) = weak.upgrade().filter(|s| {
                            s.window.is_visible()
                                && s.job.get() == job
                                && pending.current_readable()
                        }) else {
                            return glib::ControlFlow::Break;
                        };
                        if !active.get() {
                            return glib::ControlFlow::Break;
                        }
                        if rejected.load(std::sync::atomic::Ordering::Relaxed)
                            || began.elapsed() > Duration::from_secs(15)
                        {
                            active.set(false);
                            s.error(s.lang.text("Die Quelle konnte nicht auf der geprüften Basis geöffnet werden. Bitte erneut prüfen.","The source could not be opened on the checked basis. Please check again."));
                            return glib::ControlFlow::Break;
                        }
                        glib::ControlFlow::Continue
                    });
                    let weak = Rc::downgrade(&s);
                    let owner_navigation = navigation.clone();
                    let owner = Rc::new(move || {
                        load_active.get()
                            && weak
                                .upgrade()
                                .is_some_and(|s| s.window.is_visible() && s.job.get() == job)
                            && owner_navigation.current_readable()
                    });
                    let weak = Rc::downgrade(&s);
                    import_view::route_open_completed(
                        &ui,
                        path,
                        None,
                        owner,
                        Some(validator),
                        Some(Box::new(move |doc| {
                            finished.set(false);
                            let Some(s) = weak.upgrade().filter(|s| s.job.get() == job) else {
                                return;
                            };
                            let Some(after) = finish.lock().unwrap().take() else {
                                return;
                            };
                            s.window.close();
                            navigation.source(before, after, &doc);
                        })),
                    );
                }
            },
        );
    }
}
