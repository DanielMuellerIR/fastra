use super::*;
#[cfg(debug_assertions)]
thread_local! { static LAST: RefCell<Weak<ReadOnly>> = const { RefCell::new(Weak::new()) }; }
#[cfg(debug_assertions)]
mod selftest;

pub(crate) struct ReadOnlyData {
    presentation: presentation::Presentation,
    report: Arc<str>,
    sources: Vec<PathBuf>,
    identities: Vec<fastra_io::FileIdentity>,
}
impl ReadOnlyData {
    pub fn prepare(
        comparison: &fastra_diff::Comparison,
        files: [&fastra_document::ReadOnlyTextDocument; 2],
        paths: [PathBuf; 2],
        names: &[String; 2],
        lang: Language,
        cancel: &fastra_diff::Cancellation,
    ) -> Result<Self, String> {
        let presentation = presentation::Presentation::build(comparison, cancel)?;
        let report = export::report(
            comparison,
            names,
            &paths.each_ref().map(|path| Some(path.clone())),
            [true; 2],
            2 * 1024 * 1024,
            lang,
        )?;
        let identities = files
            .map(|file| fastra_io::FileIdentity {
                device: file.identity().device(),
                inode: file.identity().inode(),
            })
            .to_vec();
        Ok(Self {
            presentation,
            report: report.into(),
            sources: paths.to_vec(),
            identities,
        })
    }
}
pub(crate) struct ReadOnly {
    pub root: gtk::Box,
    view: Rc<view::View>,
    window: glib::WeakRef<gtk::Window>,
    report: RefCell<Option<Report>>,
    closed: Cell<bool>,
    lang: Language,
}
struct Report {
    text: Arc<str>,
    sources: Vec<PathBuf>,
    identities: Vec<fastra_io::FileIdentity>,
}
impl ReadOnly {
    #[cfg(debug_assertions)]
    pub(crate) fn start_test(app: &gtk::Application) {
        selftest::start(app);
    }
    pub fn new(window: &impl IsA<gtk::Window>, names: &[String; 2], lang: Language) -> Rc<Self> {
        let view = view::View::new(lang, window);
        view.show_transfer_controls(false);
        view.export.set_sensitive(false);
        for (label, name) in view.names.iter().zip(names) {
            label.set_text(name);
            label.set_tooltip_text(Some(name));
        }
        let this = Rc::new(Self {
            root: view.root.clone(),
            view,
            window: window.as_ref().downgrade(),
            report: RefCell::new(None),
            closed: Cell::new(false),
            lang,
        });
        #[cfg(debug_assertions)]
        LAST.with(|last| *last.borrow_mut() = Rc::downgrade(&this));
        this.view.loading(lang);
        let weak = Rc::downgrade(&this);
        this.view.export.connect_clicked(move |_| {
            let Some(this) = weak.upgrade().filter(|this| !this.closed.get()) else {
                return;
            };
            let Some(window) = this.window.upgrade() else {
                return;
            };
            let Some((report, sources, identities)) = this.report.borrow().as_ref().map(|report| {
                (
                    report.text.clone(),
                    report.sources.clone(),
                    report.identities.clone(),
                )
            }) else {
                return;
            };
            let weak = Rc::downgrade(&this);
            export::prompt(
                &window,
                report,
                sources,
                identities,
                this.lang,
                move |message| {
                    if let Some(this) = weak.upgrade().filter(|this| !this.closed.get()) {
                        this.view.error(&message);
                    }
                },
            );
        });
        let weak = Rc::downgrade(&this);
        preferences::submit_window(window, None, move |result| {
            if let (Err(error), Some(this)) =
                (result, weak.upgrade().filter(|this| !this.closed.get()))
            {
                this.view.error(&preferences::message(lang, &error));
            }
        });
        this
    }
    pub fn install(self: &Rc<Self>, data: ReadOnlyData) {
        if self.closed.get() {
            return;
        }
        let labels = data.presentation.labels(self.lang);
        *self.report.borrow_mut() = Some(Report {
            text: data.report,
            sources: data.sources,
            identities: data.identities,
        });
        let weak = Rc::downgrade(self);
        self.view
            .install(data.presentation, labels, self.lang, move || {
                if let Some(this) = weak.upgrade().filter(|this| !this.closed.get()) {
                    this.view.export.set_sensitive(true);
                }
            });
    }
    pub fn error(&self, error: &str) {
        if !self.closed.get() {
            self.view.error(error);
        }
    }
    pub fn close(&self) {
        self.closed.set(true);
        self.report.borrow_mut().take();
        self.view.cancel_render();
    }
}
