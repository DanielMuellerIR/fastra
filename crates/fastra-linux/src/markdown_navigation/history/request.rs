use super::*;
#[derive(Clone)]
pub(crate) struct Request {
    history: Rc<History>,
    doc: Weak<Document>,
    revision: u64,
    path: Option<std::path::PathBuf>,
    job: u64,
}
pub(crate) struct PreparedPoint {
    anchor: Anchor,
    heading: Option<Heading>,
    line: usize,
    range: Range<usize>,
}
pub(crate) fn begin_request(ui: &Rc<Ui>, doc: &Rc<Document>) -> (Request, Cancellation) {
    let history = get(ui);
    let (job, cancel) = history.begin();
    (
        Request {
            history,
            doc: Rc::downgrade(doc),
            revision: doc.revision.get(),
            path: doc.disk_path(),
            job,
        },
        cancel,
    )
}
pub(crate) fn prepare_point(
    source: &str,
    revision: u64,
    range: Range<usize>,
    headings: &[Heading],
    cancel: &Cancellation,
) -> Result<PreparedPoint, String> {
    let anchor = Anchor::from_characters(source, revision, range.clone(), cancel)
        .map_err(|e| e.to_string())?;
    let mut line = 1;
    let mut previous_cr = false;
    for (n, c) in source.chars().take(range.start).enumerate() {
        if n & 1023 == 0 {
            cancel.check().map_err(|e| e.to_string())?;
        }
        if c == '\r' || c == '\n' && !previous_cr || matches!(c, '\u{85}' | '\u{2028}' | '\u{2029}')
        {
            line += 1;
        }
        previous_cr = c == '\r';
    }
    let heading = headings
        .iter()
        .find(|h| h.offset.max(0) as usize == range.start)
        .cloned();
    Ok(PreparedPoint {
        anchor,
        heading,
        line,
        range,
    })
}
impl PreparedPoint {
    fn point(self, doc: Weak<Document>) -> Point {
        Point {
            doc,
            anchor: self.anchor,
            heading: self.heading,
            line: self.line,
        }
    }
}
impl Request {
    fn origin(&self) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.history.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        (ui.window.is_visible()
            && self.history.job.get() == self.job
            && doc.revision.get() == self.revision
            && doc.disk_path() == self.path
            && ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc)))
        .then_some((ui, doc))
    }
    pub(crate) fn current_readable(&self) -> bool {
        self.origin().is_some_and(|(ui, doc)| {
            ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                && doc.has_source_text()
                && !doc.saving.get()
                && !doc.close_pending.get()
        })
    }
    pub(crate) fn source(
        &self,
        before: PreparedPoint,
        mut after: PreparedPoint,
        doc: &Rc<Document>,
    ) {
        let Some((ui, origin)) = self.origin() else {
            return;
        };
        if !ui
            .active()
            .is_some_and(|active| Rc::ptr_eq(&active, &origin) || Rc::ptr_eq(&active, doc))
            || !doc.has_source_text()
            || doc.saving.get()
            || doc.close_pending.get()
        {
            return;
        }
        after.anchor.revision = doc.revision.get();
        let destination = Destination::new(after.range.clone(), None);
        let weak = Rc::downgrade(&self.history);
        let original = Rc::downgrade(&origin);
        let target = Rc::downgrade(doc);
        self.history
            .apply(&ui, doc, destination, self.job, move || {
                if let Some(history) = weak.upgrade() {
                    history.visit(before.point(original), after.point(target));
                }
            });
    }
    pub(crate) fn jump(
        &self,
        before: PreparedPoint,
        after: PreparedPoint,
        source: source_panes::Target,
    ) {
        if !self.current_readable() {
            return;
        }
        let Some((ui, doc)) = self.origin() else {
            return;
        };
        if !source.valid_for_reading(&doc) {
            return;
        }
        let destination = Destination {
            range: after.range.clone(),
            heading: after.heading.clone(),
            source: Some(source),
        };
        let weak = Rc::downgrade(&self.history);
        let original = Rc::downgrade(&doc);
        self.history
            .apply(&ui, &doc, destination, self.job, move || {
                if let Some(history) = weak.upgrade() {
                    history.visit(before.point(original.clone()), after.point(original));
                }
            });
    }
    pub(crate) fn opened(
        &self,
        before: PreparedPoint,
        mut after: PreparedPoint,
        doc: &Rc<Document>,
    ) {
        let Some((ui, origin)) = self.origin() else {
            return;
        };
        if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, doc))
            || doc.is_rich_active()
            || !doc.has_source_text()
        {
            return;
        }
        let Some(target) = source_panes::capture(doc) else {
            return;
        };
        let at = target.buffer.start_iter();
        target.buffer.place_cursor(&at);
        let mut at = at;
        target.view.scroll_to_iter(&mut at, 0., true, 0., 0.);
        target.view.grab_focus();
        // Der Worker kennt den Text schon, aber die Zielrevision entsteht erst
        // beim Aufbau dieses Tabs. Erst hier wird der vorbereitete Anker daran gebunden.
        after.anchor.revision = doc.revision.get();
        self.history.visit(
            before.point(Rc::downgrade(&origin)),
            after.point(Rc::downgrade(doc)),
        );
    }
}
