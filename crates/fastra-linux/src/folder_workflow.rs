use super::*;
pub(super) struct Stages {
    pub root: gtk::Box,
    files: gtk::DropDown,
    steps: gtk::DropDown,
    pane: Rc<approval::ApprovalPane>,
    status: gtk::Label,
    preview: RefCell<Option<Arc<FolderPreview>>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    lang: Language,
}
impl Stages {
    pub fn new(lang: Language) -> Rc<Self> {
        let root = git_view::column();
        let files = git_view::file_dropdown();
        let steps = gtk::DropDown::from_strings(&[]);
        let status = git_view::label(lang.text(
            "Freigaben gelten ausschließlich dem Endergebnis im ersten Reiter.",
            "Approvals refer only to the final result on the first tab.",
        ));
        let pane = approval::ApprovalPane::new(lang);
        pane.files.set_visible(false);
        pane.checks.set_sensitive(false);
        if let Some(scroll) = pane.checks.ancestor(gtk::ScrolledWindow::static_type()) {
            scroll.set_visible(false);
        }
        root.append(&files);
        root.append(&steps);
        root.append(&status);
        root.append(&pane.root);
        let state = Rc::new(Self {
            root,
            files,
            steps,
            pane,
            status,
            preview: RefCell::new(None),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            lang,
        });
        let weak = Rc::downgrade(&state);
        state.files.connect_selected_notify(move |_| {
            if let Some(s) = weak.upgrade() {
                s.update_steps();
            }
        });
        let weak = Rc::downgrade(&state);
        state.steps.connect_selected_notify(move |_| {
            if let Some(s) = weak.upgrade() {
                s.show();
            }
        });
        state
    }
    pub fn clear(&self) {
        self.generation.set(self.generation.get() + 1);
        self.cancel.borrow().cancel();
        self.preview.borrow_mut().take();
        self.pane.clear();
        self.files.set_model(None::<&gtk::StringList>);
        self.steps.set_model(None::<&gtk::StringList>);
    }
    pub fn set(self: &Rc<Self>, preview: Arc<FolderPreview>) {
        let labels: Vec<_> = preview
            .files()
            .iter()
            .map(|file| project_view::display(&file.path()))
            .collect();
        *self.preview.borrow_mut() = Some(preview);
        self.files.set_model(Some(&gtk::StringList::new(
            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        self.files.set_selected(0);
        self.update_steps();
    }
    fn update_steps(self: &Rc<Self>) {
        let names = self
            .preview
            .borrow()
            .as_ref()
            .and_then(|p| p.files().get(self.files.selected() as usize))
            .and_then(|f| f.workflow_preview())
            .map(|flow| {
                flow.steps
                    .iter()
                    .map(|step| {
                        format!(
                            "{}. {}",
                            step.index + 1,
                            crate::workflow_view::title(&step.kind, self.lang)
                        )
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.steps.set_model(Some(&gtk::StringList::new(
            &names.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        self.steps.set_selected(0);
        self.show();
    }
    fn show(self: &Rc<Self>) {
        self.cancel.borrow().cancel();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.pane.clear();
        let pair = self
            .preview
            .borrow()
            .as_ref()
            .and_then(|p| p.files().get(self.files.selected() as usize))
            .and_then(|file| file.workflow_preview())
            .and_then(|flow| {
                flow.steps.get(self.steps.selected() as usize).map(|step| {
                    (
                        step.before.clone(),
                        step.after.clone(),
                        flow.locale().cloned(),
                    )
                })
            });
        let Some((before, after, locale)) = pair else {
            return;
        };
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        let lang = self.lang;
        self.status.set_text(&format!(
            "{}{}",
            lang.text(
                "Vollständige Stufe; Freigaben gelten dem Endergebnis im ersten Reiter.",
                "Complete stage; approvals refer to the final result on the first tab."
            ),
            locale.as_ref().map_or_else(String::new, |l| format!(
                " · {}: {}",
                lang.text("Text-Systemlocale", "System text locale"),
                l.as_str()
            ))
        ));
        git_view::background(
            move || {
                let batch = fastra_core::batch::BatchPreview::from_replacements(
                    vec![fastra_core::batch::DocumentSnapshot {
                        id: "stage".into(),
                        revision: 0,
                        text: before.to_string(),
                    }],
                    vec![after.to_string()],
                    generation,
                    fastra_core::batch::BatchLimits {
                        max_documents: 1,
                        max_source_bytes: 4 * 1024 * 1024,
                        max_preview_bytes: 8 * 1024 * 1024,
                        max_plan_bytes: 4 * 1024 * 1024,
                        max_matches: 1,
                    },
                    &cancel,
                )
                .map_err(|e| error_text(lang, &e))?;
                Ok(batch.documents()[0].preview())
            },
            move |result| {
                let Some(s) = weak.upgrade().filter(|s| s.generation.get() == generation) else {
                    return;
                };
                match result {
                    Ok(preview) => {
                        s.pane.set_items(vec![approval::Item {
                            label: String::new(),
                            preview,
                        }]);
                        s.pane.freeze(false);
                    }
                    Err(error) => s.status.set_text(&error),
                }
            },
        );
    }
}
impl Drop for Stages {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
    }
}
#[cfg(debug_assertions)]
#[path = "folder_workflow_test.rs"]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn gui_test(state: Rc<FolderWindow>) {
    gui_test::run(state);
}
