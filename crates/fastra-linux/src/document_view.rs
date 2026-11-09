use super::{loader, Language};
use fastra_core::{
    encoding::{Decoded, Encoding, LineEnding},
    Cancellation,
};
use fastra_document::SectionDocument;
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    rc::Rc,
    sync::mpsc,
    time::Duration,
};

const HEX_PAGE_BYTES: usize = 4096;
pub fn encoding_name(encoding: Encoding) -> &'static str {
    match encoding {
        Encoding::Utf8 => "UTF-8",
        Encoding::Utf16Le => "UTF-16 LE",
        Encoding::Utf16Be => "UTF-16 BE",
        Encoding::Utf32Le => "UTF-32 LE",
        Encoding::Utf32Be => "UTF-32 BE",
        Encoding::Windows1252 => "Windows-1252",
        Encoding::Latin1 => "Latin-1",
        Encoding::MacRoman => "MacRoman",
    }
}
pub fn format_text(decoded: &Decoded, text: &str, lang: Language) -> String {
    format!(
        "{} · {} · {}",
        encoding_name(decoded.encoding()),
        match LineEnding::detect(text) {
            LineEnding::Lf => "LF",
            LineEnding::CrLf => "CRLF",
            LineEnding::Cr => "CR",
        },
        if decoded.bom().is_empty() {
            lang.text("ohne BOM", "no BOM")
        } else {
            "BOM"
        }
    )
}

struct Page {
    start: u64,
    end: u64,
    text: String,
}
pub struct DocumentView {
    pub root: gtk::Box,
    actions: gtk::Box,
    source: SectionDocument,
    hex_overlay: RefCell<std::sync::Arc<Vec<(usize, u8, u8)>>>,
    lang: Language,
    title: gtk::Label,
    text: gtk::TextView,
    range: gtk::Label,
    warning: gtk::Label,
    previous: gtk::Button,
    next: gtk::Button,
    hex: gtk::Button,
    offset: gtk::Entry,
    go: gtk::Button,
    busy: Cell<bool>,
    failed: Cell<bool>,
    hex_mode: Cell<bool>,
    current: Cell<u64>,
    next_offset: Cell<u64>,
    history: RefCell<VecDeque<u64>>,
    cancellation: RefCell<Cancellation>,
    generation: Cell<u64>,
}
impl DocumentView {
    pub(crate) fn after_git_attempt(&self) {
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.busy.set(false);
        self.failed.set(true);
        self.warning.set_visible(true);
        self.warning.set_text(self.lang.text("Git-Wechsel versucht. Diese gebundene Ansicht bleibt erhalten; für den aktuellen Dateistand neu öffnen.", "Git switch attempted. This bound view is retained; reopen for current file contents."));
        self.controls();
    }
    pub(crate) fn source(&self) -> SectionDocument {
        self.source.clone()
    }
    pub(crate) fn add_action(&self, button: &gtk::Button) {
        self.actions.append(button);
    }
    pub(crate) fn set_hex_overlay(self: &Rc<Self>, changes: Vec<(usize, u8, u8)>) {
        *self.hex_overlay.borrow_mut() = std::sync::Arc::new(changes);
        self.hex_mode.set(true);
        self.text.set_wrap_mode(gtk::WrapMode::None);
        self.load(self.current.get());
    }
    pub(crate) fn print_text(&self) -> Option<(String, String, bool)> {
        if self.busy.get() || self.failed.get() {
            return None;
        }
        let buffer = self.text.buffer();
        let (start, end) = buffer.bounds();
        Some((
            buffer.text(&start, &end, true).to_string(),
            self.range.text().to_string(),
            self.hex_mode.get(),
        ))
    }
    pub fn new(
        source: SectionDocument,
        hex_mode: bool,
        lang: Language,
        reopen: Rc<dyn Fn()>,
    ) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.set_vexpand(true);
        let title = gtk::Label::new(Some(&format!(
            "{} · {}",
            if hex_mode {
                lang.text("Hex-Ansicht", "Hex view")
            } else {
                lang.text("Abschnittsansicht", "Section view")
            },
            lang.text("schreibgeschützt", "read-only")
        )));
        title.set_xalign(0.);
        title.add_css_class("heading");
        root.append(&title);
        let metadata = gtk::Label::new(Some(&format!(
            "{} · {} {}",
            source
                .encoding()
                .map(encoding_name)
                .unwrap_or(lang.text("Binärdaten", "Binary data")),
            source.identity().size(),
            lang.text(
                "Bytes · nur der sichtbare Abschnitt wird gelesen.",
                "bytes · only the visible section is read."
            )
        )));
        metadata.set_xalign(0.);
        metadata.set_wrap(true);
        root.append(&metadata);
        let navigation = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let previous = gtk::Button::with_label(lang.text("Zurück", "Previous"));
        let next = gtk::Button::with_label(lang.text("Weiter", "Next"));
        let hex = gtk::Button::with_label(lang.text("Hex anzeigen", "Show hex"));
        hex.set_sensitive(!hex_mode);
        let reload = gtk::Button::with_label(lang.text("Neu öffnen", "Reopen"));
        reload.set_tooltip_text(Some(lang.text(
            "Öffnet den aktuellen Dateistand in einem neuen Tab.",
            "Opens the current file in a new tab.",
        )));
        reload.connect_clicked(move |_| reopen());
        for button in [&previous, &next, &hex, &reload] {
            navigation.append(button)
        }
        root.append(&navigation);
        let jump = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        jump.append(&gtk::Label::new(Some(
            lang.text("Byteoffset", "Byte offset"),
        )));
        let offset = gtk::Entry::new();
        offset.set_width_chars(16);
        offset.set_max_width_chars(20);
        offset.set_tooltip_text(Some(lang.text(
            "Dezimal oder 0x vor einer Hexadezimalzahl.",
            "Decimal, or 0x followed by hexadecimal digits.",
        )));
        jump.append(&offset);
        let go = gtk::Button::with_label(lang.text("Anzeigen", "Go"));
        jump.append(&go);
        let range = gtk::Label::new(None);
        range.set_xalign(0.);
        range.set_hexpand(true);
        range.set_wrap(true);
        jump.append(&range);
        root.append(&jump);
        let warning = gtk::Label::new(None);
        warning.set_xalign(0.);
        warning.set_wrap(true);
        warning.add_css_class("error");
        warning.set_visible(false);
        root.append(&warning);
        let text = gtk::TextView::new();
        text.set_editable(false);
        text.set_monospace(true);
        // Zusätzliche Trennstriche an weichen Umbrüchen wären mit Dateiinhalt verwechselbar.
        text.buffer().tag_table().add(
            &gtk::TextTag::builder()
                .name("verbatim")
                .insert_hyphens(false)
                .build(),
        );
        text.set_wrap_mode(if hex_mode {
            gtk::WrapMode::None
        } else {
            gtk::WrapMode::WordChar
        });
        text.set_top_margin(8);
        text.set_bottom_margin(8);
        text.set_left_margin(8);
        text.set_right_margin(8);
        let scroll = gtk::ScrolledWindow::builder()
            .child(&text)
            .vexpand(true)
            .hexpand(true)
            .min_content_height(150)
            .build();
        scroll.add_css_class("frame");
        root.append(&scroll);
        let view = Rc::new(Self {
            root,
            actions: navigation,
            title,
            source,
            hex_overlay: RefCell::new(std::sync::Arc::new(Vec::new())),
            lang,
            text,
            range,
            warning,
            previous,
            next,
            hex,
            offset,
            go,
            busy: Cell::new(false),
            failed: Cell::new(false),
            hex_mode: Cell::new(hex_mode),
            current: Cell::new(0),
            next_offset: Cell::new(0),
            history: RefCell::new(VecDeque::new()),
            cancellation: RefCell::new(Cancellation::default()),
            generation: Cell::new(0),
        });
        let weak = Rc::downgrade(&view);
        view.next.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.remember();
                view.load(view.next_offset.get())
            }
        });
        let weak = Rc::downgrade(&view);
        view.previous.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                let offset = view.history.borrow_mut().pop_back();
                if let Some(offset) = offset {
                    view.load(offset)
                }
            }
        });
        let weak = Rc::downgrade(&view);
        view.hex.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.hex_mode.set(true);
                view.history.borrow_mut().clear();
                view.text.set_wrap_mode(gtk::WrapMode::None);
                let offset = if view.current.get() <= view.source.bom().len() as u64 {
                    0
                } else {
                    view.current.get()
                };
                view.load(offset)
            }
        });
        let weak = Rc::downgrade(&view);
        view.go.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                let input = view.offset.text();
                let parsed = if let Some(hex) = input.strip_prefix("0x") {
                    u64::from_str_radix(hex, 16)
                } else {
                    input.parse()
                };
                match parsed {
                    Ok(offset) if offset <= view.source.identity().size() => {
                        view.remember();
                        view.load(offset)
                    }
                    _ => {
                        view.warning.set_text(view.lang.text(
                            "Bitte einen gültigen Byteoffset eingeben.",
                            "Enter a valid byte offset.",
                        ));
                        view.warning.set_visible(true)
                    }
                }
            }
        });
        let weak = Rc::downgrade(&view);
        view.offset.connect_activate(move |_| {
            if let Some(view) = weak.upgrade() {
                view.go.emit_clicked()
            }
        });
        view.load(0);
        view
    }
    fn remember(&self) {
        let mut history = self.history.borrow_mut();
        if history.len() == 256 {
            history.pop_front();
        }
        history.push_back(self.current.get());
    }
    fn controls(&self) {
        self.title.set_text(&format!(
            "{} · {}",
            if self.hex_mode.get() {
                self.lang.text("Hex-Ansicht", "Hex view")
            } else {
                self.lang.text("Abschnittsansicht", "Section view")
            },
            if self.hex_overlay.borrow().is_empty() {
                self.lang.text("schreibgeschützt", "read-only")
            } else {
                self.lang.text(
                    "Hex-Entwurf · noch nicht gespeichert",
                    "Hex draft · not saved",
                )
            }
        ));
        let ready = !self.busy.get() && !self.failed.get();
        self.previous
            .set_sensitive(ready && !self.history.borrow().is_empty());
        self.next
            .set_sensitive(ready && self.next_offset.get() < self.source.identity().size());
        self.go
            .set_sensitive(!self.busy.get() && !self.failed.get());
        self.offset
            .set_sensitive(!self.busy.get() && !self.failed.get());
        self.hex
            .set_sensitive(!self.busy.get() && !self.hex_mode.get());
    }
    fn load(self: &Rc<Self>, offset: u64) {
        self.cancellation.borrow().cancel();
        let cancel = Cancellation::default();
        *self.cancellation.borrow_mut() = cancel.clone();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.busy.set(true);
        self.failed.set(false);
        self.warning.set_visible(false);
        self.range.set_text(
            self.lang
                .text("Abschnitt wird gelesen …", "Reading section …"),
        );
        self.controls();
        let source = self.source.clone();
        let hex = self.hex_mode.get();
        let overlay = self.hex_overlay.borrow().clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = if hex {
                source
                    .read_hex(offset, HEX_PAGE_BYTES, &cancel)
                    .and_then(|mut page| {
                        for &(offset, old, new) in overlay.iter() {
                            let offset = offset as u64;
                            if page.byte_range.contains(&offset) {
                                let index = (offset - page.byte_range.start) as usize;
                                if page.bytes[index] != old {
                                    return Err(fastra_document::Error::Stale);
                                }
                                page.bytes[index] = new;
                            }
                        }
                        Ok(Page {
                            start: page.byte_range.start,
                            end: page.byte_range.end,
                            text: format_hex(page.byte_range.start, &page.bytes),
                        })
                    })
            } else {
                source.read_text(offset, &cancel).map(|page| Page {
                    start: page.byte_range.start,
                    end: page.next_offset,
                    text: page.text,
                })
            };
            let _ = tx.send(result);
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(15), move || {
            let Some(view) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if generation != view.generation.get() {
                return glib::ControlFlow::Break;
            }
            match rx.try_recv() {
                Ok(Ok(page)) => {
                    view.busy.set(false);
                    if page.text.contains('\0') {
                        view.current.set(page.start);
                        view.text.buffer().set_text("");
                        view.failed.set(true);
                        view.warning.set_text(view.lang.text("Dieser Textabschnitt enthält NUL-Zeichen und kann nicht sicher als Text angezeigt werden. Hex zeigt alle Originalbytes.","This section contains NUL characters and cannot safely be shown as text. Hex shows every original byte."));
                        view.warning.set_visible(true);
                        view.range.set_text(view.lang.text(
                            "Text nicht angezeigt · unverändert",
                            "Text not displayed · unchanged",
                        ));
                    } else {
                        view.current.set(page.start);
                        view.next_offset.set(page.end);
                        view.offset.set_text(&page.start.to_string());
                        view.text.buffer().set_text(&page.text);
                        let buffer = view.text.buffer();
                        buffer.apply_tag(
                            &buffer.tag_table().lookup("verbatim").unwrap(),
                            &buffer.start_iter(),
                            &buffer.end_iter(),
                        );
                        view.text.buffer().set_modified(false);
                        view.range.set_text(&format!(
                            "{} {}–{} / {}",
                            view.lang.text("Bytes", "Bytes"),
                            page.start,
                            page.end,
                            view.source.identity().size()
                        ));
                    }
                    view.controls();
                    glib::ControlFlow::Break
                }
                Ok(Err(error)) => {
                    view.current.set(offset.min(view.source.identity().size()));
                    view.busy.set(false);
                    view.failed.set(true);
                    view.text.buffer().set_text("");
                    view.warning
                        .set_text(&loader::document_error(view.lang, &error));
                    view.warning.set_visible(true);
                    view.range.set_text(
                        view.lang
                            .text("Abschnitt nicht angezeigt", "Section not displayed"),
                    );
                    view.controls();
                    if matches!(error, fastra_document::Error::Stale) {
                        view.hex.set_sensitive(false)
                    }
                    glib::ControlFlow::Break
                }
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Err(_) => {
                    view.busy.set(false);
                    view.failed.set(true);
                    view.text.buffer().set_text("");
                    view.warning.set_text(view.lang.text(
                        "Lesen wurde unerwartet beendet. Datei neu öffnen.",
                        "Reading ended unexpectedly. Reopen the file.",
                    ));
                    view.warning.set_visible(true);
                    view.controls();
                    glib::ControlFlow::Break
                }
            }
        });
    }
}
impl Drop for DocumentView {
    fn drop(&mut self) {
        self.cancellation.borrow().cancel();
    }
}
fn format_hex(offset: u64, bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut text = String::new();
    for (index, row) in bytes.chunks(16).enumerate() {
        let _ = write!(text, "{:016X}  ", offset + index as u64 * 16);
        for column in 0..16 {
            if let Some(byte) = row.get(column) {
                let _ = write!(text, "{byte:02X} ");
            } else {
                text.push_str("   ")
            }
        }
        text.push_str(" │");
        for &byte in row {
            text.push(if (0x20..=0x7e).contains(&byte) {
                byte as char
            } else {
                '.'
            })
        }
        text.push_str("│\n");
    }
    text
}

#[cfg(debug_assertions)]
fn capture(
    window: &gtk::ApplicationWindow,
    name: &str,
    state: &RefCell<Option<mpsc::Receiver<bool>>>,
) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_DOCUMENT_SCREENSHOTS") else {
        return true;
    };
    let pending = state.borrow().as_ref().map(mpsc::Receiver::try_recv);
    if let Some(result) = pending {
        match result {
            Ok(success) => {
                assert!(success, "Window screenshot failed: {name}");
            }
            Err(mpsc::TryRecvError::Empty) => return false,
            Err(_) => panic!("Window screenshot worker stopped"),
        }
    } else {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(format!("{name}.png"));
        let (tx, rx) = mpsc::channel();
        *state.borrow_mut() = Some(rx);
        let job = RefCell::new(Some((path, tx)));
        let clock = window.frame_clock().expect("Visible window frame clock");
        clock.connect_after_paint(move |_| {
            let Some((path, tx)) = job.borrow_mut().take() else {
                return;
            };
            std::thread::spawn(move || {
                // Nach dem echten GTK-Zeichenzyklus nur das eigene Xvfb-Fenster aufnehmen.
                let result = std::process::Command::new("xdotool")
                    .args([
                        "search",
                        "--onlyvisible",
                        "--pid",
                        &std::process::id().to_string(),
                    ])
                    .output();
                let success = result
                    .ok()
                    .filter(|output| output.status.success())
                    .and_then(|output| String::from_utf8(output.stdout).ok())
                    .and_then(|ids| ids.lines().next().map(str::to_owned))
                    .is_some_and(|id| {
                        std::process::Command::new("import")
                            .args(["-silent", "-window", &id])
                            .arg(path)
                            .status()
                            .is_ok_and(|status| status.success())
                    });
                let _ = tx.send(success);
            });
        });
        window.queue_draw();
        clock.request_phase(gtk::gdk::FrameClockPhase::PAINT);
        return false;
    }
    state.borrow_mut().take();
    true
}

#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<super::Ui>) {
    use fastra_core::encoding;
    use std::{
        fs::{self, File},
        io::Write,
        path::PathBuf,
    };
    assert_eq!(
        std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),
        Ok("1"),
        "Document tests require a private Xvfb display"
    );
    let width = std::env::var("FASTRA_DOCUMENT_WIDTH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1180);
    let height = std::env::var("FASTRA_DOCUMENT_HEIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(850);
    ui.window.set_default_size(width, height);
    let directory = std::env::var_os("FASTRA_DOCUMENT_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!(
            "fastra-document-ui-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
    fs::create_dir(&directory).unwrap();
    struct Case {
        path: PathBuf,
        body: String,
        format: Decoded,
        encoding: Encoding,
    }
    let mut cases = Vec::new();
    for (name, encoding, bom) in [
        ("utf8", Encoding::Utf8, &b"\xef\xbb\xbf"[..]),
        ("utf16le", Encoding::Utf16Le, &b"\xff\xfe"[..]),
        ("utf16be", Encoding::Utf16Be, &b"\xfe\xff"[..]),
        ("utf32le", Encoding::Utf32Le, &b"\xff\xfe\0\0"[..]),
        ("utf32be", Encoding::Utf32Be, &b"\0\0\xfe\xff"[..]),
        ("cp1252", Encoding::Windows1252, &b""[..]),
        ("latin1", Encoding::Latin1, &b""[..]),
        ("macroman", Encoding::MacRoman, &b""[..]),
    ] {
        let body = if encoding == Encoding::Windows1252 {
            "café €\r\nsecond\rfinal\n"
        } else {
            "café Ä\r\nsecond\rfinal\n"
        }
        .to_owned();
        let format = encoding::decode(bom, Some(encoding)).unwrap();
        let path = directory.join(format!("{name}.txt"));
        fs::write(&path, format.encode(&body).unwrap()).unwrap();
        cases.push(Case {
            path,
            body,
            format,
            encoding,
        });
    }
    let large = directory.join("large.txt");
    let mut file = File::create(&large).unwrap();
    let block = [b'A'; 65536];
    for _ in 0..513 {
        file.write_all(&block).unwrap();
    }
    let sparse = directory.join("sparse.bin");
    File::create(&sparse)
        .unwrap()
        .set_len(8 * 1024 * 1024 * 1024)
        .unwrap();
    let nul = directory.join("nul16.txt");
    let nul_bytes = [0xff, 0xfe, b'A', 0, 0, 0, b'B', 0];
    fs::write(&nul, nul_bytes).unwrap();
    let large_nul = directory.join("large-nul16.txt");
    let mut file = File::create(&large_nul).unwrap();
    file.write_all(&nul_bytes).unwrap();
    file.set_len(34 * 1024 * 1024).unwrap();
    let captures = RefCell::new(None);
    let owner_checked = Rc::new(Cell::new(false));
    let owner_allowed = Rc::new(Cell::new(true));
    let owner_tabs = Cell::new(0);
    let stage = Cell::new(0u8);
    let index = Cell::new(0usize);
    let dirty = RefCell::<Option<Rc<super::Document>>>::new(None);
    let started = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(90),
            "Document UI test timed out in stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let current = || ui.active().unwrap();
        let view = || current().section_view.borrow().clone();
        match stage.get() {
            0 => {
                ui.load_path_as(
                    cases[index.get()].path.clone(),
                    Some(cases[index.get()].encoding),
                );
                stage.set(1);
            }
            1 => {
                let case = &cases[index.get()];
                let doc = current();
                if doc.name != case.path.file_name().unwrap().to_string_lossy()
                    || doc.snapshot.borrow().is_none()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(super::buffer_text(&doc.buffer), case.body);
                assert_eq!(doc.format.borrow().encoding(), case.encoding);
                assert!(doc
                    .format_label
                    .text()
                    .contains(encoding_name(case.encoding)));
                doc.buffer.insert(&mut doc.buffer.end_iter(), " saved");
                ui.save_document();
                stage.set(2);
            }
            2 => {
                let doc = current();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                let case = &cases[index.get()];
                let saved = format!("{} saved", case.body);
                let expected = case.format.encode(&saved).unwrap();
                assert_eq!(
                    fs::read(&case.path).unwrap(),
                    expected,
                    "{}: {}",
                    case.path.display(),
                    ui.status.text()
                );
                assert_eq!(doc.snapshot.borrow().as_ref().unwrap().bytes(), expected);
                assert_eq!(*doc.original.borrow(), saved);
                assert!(!doc.buffer.is_modified());
                if index.get() == 1 && !capture(&ui.window, "utf16-editor", &captures) {
                    return glib::ControlFlow::Continue;
                }
                if index.get() + 1 < cases.len() {
                    index.set(index.get() + 1);
                    stage.set(0)
                } else {
                    ui.load_path_as(cases[6].path.clone(), Some(Encoding::Latin1));
                    stage.set(3)
                }
            }
            3 => {
                let doc = current();
                if doc.name != "latin1.txt" {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.insert(&mut doc.buffer.end_iter(), "😀");
                ui.save_document();
                *dirty.borrow_mut() = Some(doc);
                stage.set(4);
            }
            4 => {
                let doc = current();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    fs::read(&cases[6].path).unwrap(),
                    cases[6]
                        .format
                        .encode(&format!("{} saved", cases[6].body))
                        .unwrap()
                );
                assert!(doc.buffer.is_modified());
                assert!(super::buffer_text(&doc.buffer).ends_with('😀'));
                doc.charset.set_selected(7);
                doc.reopen.emit_clicked();
                stage.set(5);
            }
            5 => {
                let doc = current();
                if Rc::ptr_eq(&doc, dirty.borrow().as_ref().unwrap()) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(doc.format.borrow().encoding(), Encoding::Latin1);
                assert!(!doc.buffer.is_modified());
                assert!(dirty.borrow().as_ref().unwrap().buffer.is_modified());
                assert!(
                    super::buffer_text(&dirty.borrow().as_ref().unwrap().buffer).ends_with('😀')
                );
                ui.load_path(large.clone());
                stage.set(6);
            }
            6 => {
                if current().name != "large.txt" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = view() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!view.failed.get());
                assert!(!ui.save.is_sensitive());
                assert!(super::buffer_text(&current().buffer).is_empty());
                assert_eq!(view.text.buffer().char_count(), 65536);
                view.next.emit_clicked();
                stage.set(7);
            }
            7 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.current.get(), 65536);
                view.previous.emit_clicked();
                stage.set(8);
            }
            8 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.current.get(), 0);
                if !capture(&ui.window, "sections", &captures) {
                    return glib::ControlFlow::Continue;
                }
                ui.load_path(sparse.clone());
                stage.set(9);
            }
            9 => {
                if current().name != "sparse.bin" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = view() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.hex_mode.get());
                assert!(view
                    .text
                    .buffer()
                    .text(
                        &view.text.buffer().start_iter(),
                        &view.text.buffer().end_iter(),
                        false
                    )
                    .starts_with("0000000000000000"));
                assert!(!ui.save.is_sensitive());
                ui.save_document();
                assert!(!current().saving.get());
                view.offset
                    .set_text(&(7u64 * 1024 * 1024 * 1024).to_string());
                view.go.emit_clicked();
                stage.set(10);
            }
            10 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.current.get(), 7u64 * 1024 * 1024 * 1024);
                assert!(view
                    .text
                    .buffer()
                    .text(
                        &view.text.buffer().start_iter(),
                        &view.text.buffer().end_iter(),
                        false
                    )
                    .starts_with("00000001C0000000"));
                view.previous.emit_clicked();
                stage.set(11);
            }
            11 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.current.get(), 0);
                if !capture(&ui.window, "hex", &captures) {
                    return glib::ControlFlow::Continue;
                }
                let replacement = directory.join("replacement");
                File::create(&replacement)
                    .unwrap()
                    .set_len(8 * 1024 * 1024 * 1024)
                    .unwrap();
                fs::rename(&replacement, &sparse).unwrap();
                view.next.emit_clicked();
                stage.set(12);
            }
            12 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.failed.get());
                assert_eq!(view.text.buffer().char_count(), 0);
                assert!(!view.next.is_sensitive());
                assert!(!view.hex.is_sensitive());
                assert!(view.warning.is_visible());
                ui.load_path(nul.clone());
                stage.set(13);
            }
            13 => {
                if current().name != "nul16.txt" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = view() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.hex_mode.get());
                assert!(!view.failed.get());
                assert_eq!(current().buffer.char_count(), 0);
                assert!(!ui.save.is_sensitive());
                ui.save_document();
                assert_eq!(fs::read(&nul).unwrap(), nul_bytes);
                ui.load_path(large_nul.clone());
                stage.set(14);
            }
            14 => {
                if current().name != "large-nul16.txt" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = view() else {
                    return glib::ControlFlow::Continue;
                };
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.failed.get());
                assert_eq!(view.text.buffer().char_count(), 0);
                assert!(view.hex.is_sensitive());
                assert!(!ui.save.is_sensitive());
                if !capture(&ui.window, "nul-text-error", &captures) {
                    return glib::ControlFlow::Continue;
                }
                view.hex.emit_clicked();
                stage.set(15);
            }
            15 => {
                let view = view().unwrap();
                if view.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.hex_mode.get());
                assert!(!view.failed.get());
                assert!(view.text.buffer().char_count() > 0);
                assert_eq!(view.current.get(), 0);
                assert!(view
                    .text
                    .buffer()
                    .text(
                        &view.text.buffer().start_iter(),
                        &view.text.buffer().end_iter(),
                        false
                    )
                    .starts_with("0000000000000000  FF FE 41 00 00 00 42 00"));
                if !capture(&ui.window, "nul-safe-hex", &captures) {
                    return glib::ControlFlow::Continue;
                }
                let checked = owner_checked.clone();
                let allowed = owner_allowed.clone();
                ui.load_path_owned(
                    cases[0].path.clone(),
                    Rc::new(move || {
                        checked.set(true);
                        allowed.get()
                    }),
                );
                assert!(
                    !owner_checked.get(),
                    "Owner guard must run at asynchronous completion, not only before loading"
                );
                owner_allowed.set(false);
                owner_tabs.set(ui.tabs.n_pages());
                stage.set(16);
            }
            16 => {
                if !owner_checked.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.tabs.n_pages(), owner_tabs.get());
                assert_eq!(current().name, "large-nul16.txt");
                fs::remove_dir_all(&directory).unwrap();
                println!(
                    "PASS document GTK: 8 encoding/BOM/mixed-line saves, unrepresentable save unchanged, dirty explicit reopen retained, 32 MiB sections next/previous, 8 GiB hex offset navigation, stale source cleared, decoded NUL never inserted/saved, stale async load owner rejected"
                );
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
