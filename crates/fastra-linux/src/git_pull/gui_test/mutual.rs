use super::*;
use webkit6::prelude::*;
fn widgets(widget: &gtk::Widget, out: &mut Vec<gtk::Widget>) {
    out.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(item) = child {
        child = item.next_sibling();
        widgets(&item, out);
    }
}
pub(super) fn all(window: &gtk::Window) -> Vec<gtk::Widget> {
    let mut out = Vec::new();
    widgets(window.upcast_ref(), &mut out);
    out
}
pub(super) fn button(window: &gtk::Window, title: &str) -> gtk::Button {
    all(window)
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(title))
        .unwrap_or_else(|| panic!("button {title}"))
}
fn window(ui: &Ui, title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_visible()
                && w.title().as_deref() == Some(title)
                && w.transient_for().as_ref() == Some(ui.window.upcast_ref::<gtk::Window>())
        })
}
fn clickable(widget: &impl IsA<gtk::Widget>) -> bool {
    let widget = widget.as_ref();
    widget.is_mapped() && widget.width() > 1 && widget.height() > 1
}
pub(super) struct Case {
    ui: Rc<Ui>,
    mode: String,
    path: PathBuf,
    window: RefCell<Option<gtk::Window>>,
    stage: Cell<u8>,
    pause: Cell<Instant>,
    hex: RefCell<Option<Rc<crate::hex_editor::Editor>>>,
    rich: RefCell<Option<Rc<crate::rich_editor::RichEditor>>>,
    evaluated: Rc<Cell<bool>>,
}
impl Case {
    pub(super) fn new(ui: Rc<Ui>, mode: &str, root: &Path) -> Self {
        let path = root.join(if mode == "mutual-assets" {
            "peer.txt"
        } else if mode == "mutual-hex" {
            "hex.bin"
        } else {
            "folder/sample.txt"
        });
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        if mode == "mutual-assets" {
        } else if mode == "mutual-hex" {
            fs::write(
                &path,
                (0..8195).map(|n| (n % 256) as u8).collect::<Vec<_>>(),
            )
            .unwrap();
            ui.load_path(path.clone());
        } else {
            fs::write(&path, "cat cat\n").unwrap();
            ui.find.set_text("cat");
            ui.replace.set_text("dog");
            crate::folder::open(&ui);
        }
        Self {
            ui,
            mode: mode.into(),
            path,
            window: RefCell::new(None),
            stage: Cell::new(0),
            pause: Cell::new(Instant::now()),
            hex: RefCell::new(None),
            rich: RefCell::new(None),
            evaluated: Rc::new(Cell::new(false)),
        }
    }
    fn action(&self) -> gtk::Button {
        let w = self.window.borrow();
        let w = w.as_ref().unwrap();
        button(
            w,
            if self.mode == "mutual-assets" {
                self.ui
                    .lang
                    .text("Bilder speichern und einfügen", "Save images and insert")
            } else if self.mode == "mutual-hex" {
                self.ui
                    .lang
                    .text("Freigegebene Bytes speichern", "Save approved bytes")
            } else if self.mode == "mutual-undo" {
                self.ui
                    .lang
                    .text("Dateiänderungen rückgängig", "Undo file changes")
            } else {
                self.ui.lang.text(
                    "Freigegebene Treffer in Dateien anwenden",
                    "Apply approved matches to files",
                )
            },
        )
    }
    pub(super) fn setup(&self) -> bool {
        if self.mode == "mutual-assets" {
            return true;
        }
        if self.mode == "mutual-hex" {
            match self.stage.get() {
                0 => {
                    let doc = self.ui.active().unwrap();
                    let view = doc.section_view.borrow().clone();
                    let Some(view) = view else {
                        return false;
                    };
                    if view.source().path() != self.path {
                        return false;
                    }
                    let hex = crate::hex_editor::open(&self.ui, &doc, view.source());
                    if let Some(window) = window(
                        &self.ui,
                        self.ui
                            .lang
                            .text("Hex bearbeiten · Entwurf", "Edit hex · draft"),
                    ) {
                        support::test_size(&window);
                    }
                    *self.hex.borrow_mut() = Some(hex);
                    self.stage.set(1);
                }
                1 => {
                    let hex = self.hex.borrow();
                    if hex.as_ref().unwrap().pending() {
                        return false;
                    }
                    let Some(w) = window(
                        &self.ui,
                        self.ui
                            .lang
                            .text("Hex bearbeiten · Entwurf", "Edit hex · draft"),
                    ) else {
                        return false;
                    };
                    let row = all(&w)
                        .into_iter()
                        .filter_map(|w| w.downcast::<gtk::Entry>().ok())
                        .find(|e| e.has_css_class("monospace"))
                        .unwrap();
                    let mut text = row.text().to_string();
                    text.replace_range(..2, "FF");
                    row.set_text(&text);
                    support::test_click(
                        &button(&w, self.ui.lang.text("Zeile vormerken", "Stage row")),
                        &[],
                    );
                    *self.window.borrow_mut() = Some(w);
                    self.stage.set(2);
                }
                2 => {
                    if !self.hex.borrow().as_ref().unwrap().dirty() {
                        return false;
                    }
                    let w = self.window.borrow();
                    support::test_click(
                        &button(
                            w.as_ref().unwrap(),
                            self.ui
                                .lang
                                .text("Alle Hexänderungen prüfen", "Review all hex changes"),
                        ),
                        &[],
                    );
                    self.stage.set(3);
                }
                3 => {
                    if self.hex.borrow().as_ref().unwrap().pending() {
                        return false;
                    }
                    let w = self.window.borrow();
                    let consent = all(w.as_ref().unwrap())
                        .into_iter()
                        .filter_map(|w| w.downcast::<gtk::CheckButton>().ok())
                        .next()
                        .unwrap();
                    if !consent.is_sensitive() {
                        return false;
                    }
                    support::test_click(&consent, &[]);
                    self.stage.set(4);
                }
                4 => return self.action().is_sensitive(),
                _ => unreachable!(),
            };
            return false;
        }
        match self.stage.get() {
            0 => {
                let Some(w) = window(
                    &self.ui,
                    self.ui.lang.text(
                        "Suchen & Ersetzen",
                        "Search & Replace",
                    ),
                ) else {
                    return false;
                };
                support::test_size(&w);
                let entry = all(&w)
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Entry>().ok())
                    .next()
                    .unwrap();
                entry.set_text(self.path.parent().unwrap().to_str().unwrap());
                *self.window.borrow_mut() = Some(w);
                self.pause.set(Instant::now());
                self.stage.set(1);
            }
            1 => {
                if self.pause.get().elapsed() < Duration::from_millis(250) {
                    return false;
                }
                let w = self.window.borrow();
                support::test_click(
                    &button(
                        w.as_ref().unwrap(),
                        self.ui.lang.text("Vorschau erstellen", "Create preview"),
                    ),
                    &[],
                );
                self.stage.set(2);
            }
            2 => {
                let w = self.window.borrow();
                let apply = button(
                    w.as_ref().unwrap(),
                    self.ui.lang.text(
                        "Freigegebene Treffer in Dateien anwenden",
                        "Apply approved matches to files",
                    ),
                );
                if crate::folder::any_busy() || !apply.is_sensitive() {
                    return false;
                }
                if self.mode == "mutual-undo" {
                    support::test_click(&apply, &[]);
                    self.stage.set(3);
                } else {
                    return true;
                }
            }
            3 => {
                return fs::read(&self.path).unwrap() == b"dog dog\n"
                    && !crate::folder::any_busy()
                    && self.action().is_sensitive()
            }
            _ => unreachable!(),
        };
        false
    }
    pub(super) fn hide_for_pull(&self) {
        if self.mode != "mutual-hex" && self.mode != "mutual-assets" {
            self.window.borrow().as_ref().unwrap().set_visible(false);
        }
    }
    pub(super) fn attempt(&self) {
        if self.mode == "mutual-assets" && self.stage.get() == 0 {
            let doc = self.ui.active().unwrap();
            let toggle = doc.rich_toggle.borrow().as_ref().unwrap().clone();
            if !clickable(&toggle) {
                return;
            }
            support::test_click(&toggle, &[]);
            self.stage.set(50);
            return;
        }
        let action = self.action();
        let window = self.window.borrow().as_ref().unwrap().clone();
        if !window.is_visible() {
            window.present();
            glib::timeout_add_local_once(Duration::from_millis(180), move || {
                support::test_click(&action, &[])
            });
        } else {
            support::test_click(&action, &[]);
        }
    }
    pub(super) fn verify_blocked(&self) -> bool {
        if self.mode == "mutual-assets" {
            match self.stage.get() {
                0 => {
                    self.attempt();
                    return false;
                }
                50 => {
                    let doc = self.ui.active().unwrap();
                    let rich = doc.rich.borrow().clone();
                    let Some(rich) = rich else {
                        return false;
                    };
                    if !rich.close_stamp().0 {
                        return false;
                    }
                    let done = self.evaluated.clone();
                    rich.view.evaluate_javascript("const root=document.getElementById('fastra-visual'),range=document.createRange();range.selectNodeContents(root.lastElementChild);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);root.focus();true",None,None,None::<&gtk::gio::Cancellable>,move|result|{assert!(result.is_ok());done.set(true);});
                    *self.rich.borrow_mut() = Some(rich);
                    self.stage.set(51);
                    return false;
                }
                51 => {
                    if !self.evaluated.get() {
                        return false;
                    }
                    if !clickable(&self.rich.borrow().as_ref().unwrap().view) {
                        return false;
                    }
                    let provider = gtk::gdk::ContentProvider::for_bytes(
                        "image/png",
                        &glib::Bytes::from_static(include_bytes!(
                            "../../../tests/fixtures/pixel-1.png"
                        )),
                    );
                    gtk::prelude::WidgetExt::display(&self.ui.window)
                        .clipboard()
                        .set_content(Some(&provider))
                        .unwrap();
                    support::test_click(
                        &self.rich.borrow().as_ref().unwrap().view,
                        &["ctrl+End", "ctrl+v"],
                    );
                    self.stage.set(52);
                    return false;
                }
                52 => {
                    let Some(w) = window(
                        &self.ui,
                        self.ui
                            .lang
                            .text("Bilder und Dateien einfügen", "Insert images and files"),
                    ) else {
                        return false;
                    };
                    support::test_size(&w);
                    *self.window.borrow_mut() = Some(w);
                    self.pause.set(Instant::now());
                    self.stage.set(54);
                    return false;
                }
                54 => {
                    if self.pause.get().elapsed() < Duration::from_millis(220) {
                        return false;
                    }
                    if !clickable(&self.action()) {
                        return false;
                    }
                    support::test_click(&self.action(), &[]);
                    self.pause.set(Instant::now());
                    self.stage.set(53);
                    return false;
                }
                53 => {
                    if self.pause.get().elapsed() < Duration::from_millis(300) {
                        return false;
                    }
                    assert!(!self.path.parent().unwrap().join("images").exists());
                    assert!(self.action().is_sensitive());
                    assert!(all(self.window.borrow().as_ref().unwrap())
                        .iter()
                        .filter_map(|w| w.downcast_ref::<gtk::Label>())
                        .any(|label| label.text().contains("Git")));
                    return support::try_capture(
                        self.window.borrow().as_ref().unwrap(),
                        "pull-write-gate-blocked",
                    );
                }
                _ => unreachable!(),
            }
        }

        let bytes = fs::read(&self.path).unwrap();
        if self.mode == "mutual-hex" {
            assert_eq!(bytes[0], 0);
            assert!(self.hex.borrow().as_ref().unwrap().dirty());
            assert!(!self.hex.borrow().as_ref().unwrap().pending());
        } else {
            assert_eq!(
                bytes,
                if self.mode == "mutual-undo" {
                    b"dog dog\n"
                } else {
                    b"cat cat\n"
                }
            );
        }
        assert!(
            self.action().is_sensitive(),
            "retained approval/transaction"
        );
        assert!(all(self.window.borrow().as_ref().unwrap())
            .iter()
            .filter_map(|w| w.downcast_ref::<gtk::Label>())
            .any(|label| label.text().contains("Git")));
        support::try_capture(
            self.window.borrow().as_ref().unwrap(),
            "pull-write-gate-blocked",
        )
    }
    pub(super) fn finished(&self) -> bool {
        if self.mode == "mutual-assets" {
            return fs::read(self.path.parent().unwrap().join("images/1.png"))
                .is_ok_and(|bytes| bytes == include_bytes!("../../../tests/fixtures/pixel-1.png"))
                && !self.window.borrow().as_ref().unwrap().is_visible()
                && !crate::asset_io::pending();
        }
        let bytes = fs::read(&self.path).unwrap();
        if self.mode == "mutual-hex" {
            bytes[0] == 255
                && !self.hex.borrow().as_ref().unwrap().pending()
                && !self.hex.borrow().as_ref().unwrap().dirty()
        } else {
            bytes
                == if self.mode == "mutual-undo" {
                    b"cat cat\n"
                } else {
                    b"dog dog\n"
                }
                && !crate::folder::any_busy()
        }
    }
}
