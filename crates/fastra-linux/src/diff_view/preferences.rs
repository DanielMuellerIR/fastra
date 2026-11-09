use super::*;
use fastra_workflow::comparison_preferences::{Change, Settings, Store};
use std::collections::VecDeque;
type Done = Box<dyn FnOnce(Result<Settings, String>)>;
struct Job {
    root: Result<PathBuf, String>,
    change: Option<Change>,
    done: Done,
    _hold: Option<gio::ApplicationHoldGuard>,
    layout_revision: u64,
    layout_write: bool,
}
#[derive(Default)]
struct Queue {
    running: Cell<bool>,
    jobs: RefCell<VecDeque<Job>>,
}
thread_local! {static QUEUE:Rc<Queue>=Rc::new(Queue::default());}
fn config_root() -> Result<PathBuf, String> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .ok_or("No configuration directory available")?;
    if !root.is_absolute() {
        return Err("Configuration directory must be absolute".into());
    }
    Ok(root)
}
pub(super) fn submit(
    ui: &Ui,
    change: Option<Change>,
    done: impl FnOnce(Result<Settings, String>) + 'static,
) {
    submit_window(&ui.window, change, done);
}
pub(super) fn submit_window(
    window: &impl IsA<gtk::Window>,
    change: Option<Change>,
    done: impl FnOnce(Result<Settings, String>) + 'static,
) {
    let layout_write = matches!(change, Some(Change::SplitRatio(_)));
    let job = Job {
        layout_revision: columns::revision(),
        layout_write,
        root: config_root(),
        change,
        done: Box::new(done),
        _hold: window.as_ref().application().map(|app| app.hold()),
    };
    QUEUE.with(|queue| {
        queue.jobs.borrow_mut().push_back(job);
        queue.next();
    });
}
impl Queue {
    fn next(self: &Rc<Self>) {
        if self.running.replace(true) {
            return;
        }
        let Some(job) = self.jobs.borrow_mut().pop_front() else {
            self.running.set(false);
            return;
        };
        let Job {
            root,
            change,
            done,
            _hold,
            layout_revision,
            layout_write,
        } = job;
        let queue = self.clone();
        support::background(
            move || {
                let store = Store::open(&root?).map_err(|e| e.to_string())?;
                change
                    .as_ref()
                    .map_or_else(|| store.load(), |change| store.apply(change))
                    .map_err(|e| e.to_string())
            },
            move |result| {
                queue.running.set(false);
                if let Ok(settings) = &result {
                    columns::received(settings.split_ratio, layout_revision, layout_write);
                }
                done(result);
                drop(_hold);
                queue.next();
            },
        );
    }
}
pub(super) fn message(lang: Language, error: &str) -> String {
    format!(
        "{} {error}",
        lang.text(
            "Vergleichseinstellungen sind nicht verfügbar. Vorhandene Daten bleiben erhalten.",
            "Comparison settings are unavailable. Existing data is retained."
        )
    )
}
pub(super) fn remember(ui: &Rc<Ui>, path: PathBuf) {
    let owner = Rc::downgrade(ui);
    let lang = ui.lang;
    submit(ui, Some(Change::Opened(path)), move |result| {
        if let (Err(error), Some(ui)) = (result, owner.upgrade()) {
            ui.status.set_text(&format!(
                "{} {error}",
                lang.text(
                    "Dateiverlauf konnte nicht gespeichert werden:",
                    "Could not save recent files:"
                )
            ));
        }
    });
}
