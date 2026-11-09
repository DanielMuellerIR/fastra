//! Globale Moduswechsel bereiten alle Rich-Ansichten vor, bevor eine verschwindet.
use super::*;
pub(super) struct SourceDisplay {
    stack: glib::WeakRef<gtk::Stack>,
    options: glib::WeakRef<gtk::FlowBox>,
    toggle: glib::WeakRef<gtk::CheckButton>,
    preview: Rc<Cell<Option<(u64, bool)>>>,
}
impl SourceDisplay {
    pub(super) fn new(
        stack: &gtk::Stack,
        options: &gtk::FlowBox,
        toggle: &gtk::CheckButton,
        preview: Rc<Cell<Option<(u64, bool)>>>,
    ) -> Rc<Self> {
        Rc::new(Self {
            stack: stack.downgrade(),
            options: options.downgrade(),
            toggle: toggle.downgrade(),
            preview,
        })
    }
    fn available(&self) -> bool {
        self.stack.upgrade().is_some()
            && self.options.upgrade().is_some()
            && self.toggle.upgrade().is_some()
    }
    pub(super) fn show(
        &self,
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        editor: &Rc<RichEditor>,
        expected_revision: u64,
        manual: bool,
    ) -> bool {
        let (Some(stack), Some(options), Some(toggle)) = (
            self.stack.upgrade(),
            self.options.upgrade(),
            self.toggle.upgrade(),
        ) else {
            return false;
        };
        if !doc
            .rich
            .borrow()
            .as_ref()
            .is_some_and(|current| Rc::ptr_eq(current, editor))
        {
            return false;
        }
        editor.active.set(false);
        editor.operation.set(editor.operation.get() + 1);
        stack.set_visible_child_name("source");
        stack.remove(&editor.widget);
        doc.rich.borrow_mut().take();
        source_controls(&options, &toggle, true);
        toggle.set_sensitive(true);
        toggle.set_active(false);
        if manual {
            doc.markdown_visual_override.set(Some(false));
        }
        if let Some(preview) = doc.markdown_toggle.borrow().as_ref() {
            preview.set_sensitive(true);
            if let Some((revision, active)) = self.preview.take() {
                if revision <= expected_revision && editor.revision.get() == doc.revision.get() {
                    crate::editor_options::markdown_preview::restore_document(ui, doc, active);
                }
            }
        }
        ui.invalidate();
        true
    }
}
struct Lease {
    editor: Rc<RichEditor>,
    operation: u64,
}
impl Drop for Lease {
    fn drop(&mut self) {
        // Eine inzwischen neuere Aktion besitzt ihre eigene Eingabesperre.
        if self.editor.operation.get() == self.operation && self.editor.active.get() {
            self.editor.release();
        }
    }
}
struct Source {
    editor: Rc<RichEditor>,
    ui: Rc<Ui>,
    doc: Rc<Document>,
    operation: u64,
    revision: u64,
    display: Rc<SourceDisplay>,
}
impl Source {
    fn valid(&self) -> bool {
        self.editor.operation.get() == self.operation
            && self.editor.ready_for_saved_source()
            && !self.editor.pending()
            && !self.doc.is_read_only()
            && !self.doc.saving.get()
            && self.doc.markdown_visual_override.get().is_none()
            && self.doc.revision.get() == self.revision
            && self
                .editor
                .current()
                .as_ref()
                .is_some_and(|doc| Rc::ptr_eq(doc, &self.doc))
            && self.display.available()
    }
}
pub(crate) struct Prepared {
    leases: Vec<Lease>,
    sources: Vec<Source>,
}
impl Prepared {
    pub(crate) fn valid(&self) -> bool {
        self.leases.iter().all(|lease| {
            lease.editor.operation.get() == lease.operation
                && lease.editor.ready_for_saved_source()
                && !lease.editor.pending()
                && lease
                    .editor
                    .current()
                    .is_some_and(|doc| !doc.saving.get() && !doc.is_read_only())
        }) && self.sources.iter().all(Source::valid)
    }
    pub(crate) fn commit_sources(&self) -> bool {
        if !self.valid() {
            return false;
        }
        // Nach der gemeinsamen Prüfung folgen nur synchrone UI-Änderungen.
        for source in &self.sources {
            if !source.display.show(
                &source.ui,
                &source.doc,
                &source.editor,
                source.revision,
                false,
            ) {
                return false;
            }
        }
        true
    }
}
type Ready = Box<dyn FnOnce(Option<Prepared>)>;
pub(crate) fn prepare(documents: &[Rc<Document>], visual: bool, done: Ready) {
    let mut editors = Vec::new();
    for doc in documents {
        if doc.saving.get() {
            done(None);
            return;
        }
        if let Some(editor) = doc.rich.borrow().clone().filter(|r| r.active.get()) {
            if !editor.ready_for_saved_source() || editor.pending() {
                done(None);
                return;
            }
            if !editors.iter().any(|old| Rc::ptr_eq(old, &editor)) {
                editors.push(editor);
            }
        }
    }
    synchronize(
        editors.into(),
        0,
        visual,
        Prepared {
            leases: Vec::new(),
            sources: Vec::new(),
        },
        done,
    );
}
fn synchronize(
    editors: Rc<Vec<Rc<RichEditor>>>,
    index: usize,
    visual: bool,
    mut prepared: Prepared,
    done: Ready,
) {
    let Some(editor) = editors.get(index).cloned() else {
        prepare_sources(editors, 0, visual, prepared, done);
        return;
    };
    if !editor.ready_for_saved_source() || editor.pending() {
        drop(prepared);
        done(None);
        return;
    }
    prepared.leases.push(Lease {
        editor: editor.clone(),
        operation: editor.operation.get() + 1,
    });
    editor.synchronize(
        true,
        Box::new(move |ok| {
            if ok {
                synchronize(editors, index + 1, visual, prepared, done);
            } else {
                drop(prepared);
                done(None);
            }
        }),
    );
}
fn prepare_sources(
    editors: Rc<Vec<Rc<RichEditor>>>,
    index: usize,
    visual: bool,
    mut prepared: Prepared,
    done: Ready,
) {
    if visual || index == editors.len() {
        if prepared.valid() {
            done(Some(prepared));
        } else {
            drop(prepared);
            done(None);
        }
        return;
    }
    let editor = editors[index].clone();
    let Some(doc) = editor.current() else {
        drop(prepared);
        done(None);
        return;
    };
    if doc.markdown_visual_override.get().is_some() {
        prepare_sources(editors, index + 1, visual, prepared, done);
        return;
    }
    let (Some(ui), Some(display)) = (editor.ui.upgrade(), editor.source_display.borrow().clone())
    else {
        drop(prepared);
        done(None);
        return;
    };
    let source = Source {
        editor: editor.clone(),
        ui,
        doc,
        operation: editor.operation.get(),
        revision: editor.revision.get(),
        display,
    };
    asset_ui::for_source(
        editor,
        Box::new(move |ok| {
            if ok && source.valid() {
                prepared.sources.push(source);
                prepare_sources(editors, index + 1, visual, prepared, done);
            } else {
                drop(prepared);
                done(None);
            }
        }),
    );
}
