use super::*;
use gtk::{cairo, pango};
#[cfg(debug_assertions)]
use std::path::PathBuf;
use std::sync::Arc;
use webkit6::prelude::*;
mod syntax;
use crate::editor_options::printing;

const MAX_TEXT: usize = 2 * 1024 * 1024;
const MAX_VISUAL_LINES: usize = 25_000;
const MAX_PAGES: usize = 1_000;
const DECORATION: f64 = 22.;

type Completion = Box<dyn FnOnce(Result<(), String>)>;
#[derive(Clone)]
enum Destination {
    Dialog,
    #[cfg(debug_assertions)]
    Pdf(PathBuf),
}
#[derive(Clone)]
struct TextInput {
    title: String,
    text: Arc<str>,
    hex: bool,
    syntax: Option<sourceview5::Language>,
}
fn safe_title(title: &str) -> String {
    title
        .chars()
        .filter(|c| !c.is_control())
        .take(160)
        .collect()
}
struct PrintedLine {
    _layout: pango::Layout,
    line: pango::LayoutLine,
    y: f64,
    baseline: f64,
    number: Option<usize>,
}
struct TextPlan {
    lang: Language,
    input: TextInput,
    cursor: usize,
    logical_line: usize,
    visual_lines: usize,
    pages: Vec<Vec<PrintedLine>>,
    y: f64,
    ready: bool,
    numbers: bool,
    decorations: bool,
    number_width: f64,
    syntax: Option<syntax::Snapshot>,
    syntax_ready: bool,
    colors: bool,
    font: pango::FontDescription,
}
impl TextPlan {
    fn new(input: TextInput, options: printing::Values, font: pango::FontDescription, lang: Language) -> Self {
        Self {
            lang,
            input: input.clone(),
            cursor: 0,
            logical_line: 0,
            visual_lines: 0,
            pages: vec![Vec::new()],
            y: 0.,
            ready: false,
            numbers: options.line_numbers && !input.hex,
            decorations: options.header_footer,
            number_width: 0.,
            syntax: None,
            syntax_ready: false,
            colors: options.syntax_colors,
            font,
        }
    }
    fn step(&mut self, context: &gtk::PrintContext) -> Result<bool, String> {
        if self.ready {
            return Ok(true);
        }
        if !self.syntax_ready {
            if self.colors { self.syntax = syntax::Snapshot::new(&self.input, self.lang)?; }
            if self.input.hex {
                let widest = self.input.text.split('\n').max_by_key(|line| line.len()).unwrap_or("");
                if widest.len() > 64 * 1024 { return Err(self.lang.text("Eine logische Zeile überschreitet die Druckgrenze von 64 KiB.", "A logical line exceeds the 64 KiB printing limit.").into()); }
                let fit = context.create_pango_layout();
                fit.set_text(widest);
                fit.set_font_description(Some(&self.font));
                while f64::from(fit.size().0) / f64::from(pango::SCALE) > context.width() && self.font.size() > 6 * pango::SCALE {
                    self.font.set_size(self.font.size() - pango::SCALE);
                    fit.set_font_description(Some(&self.font));
                }
            }
            self.syntax_ready = true;
        }
        let width = context.width();
        let height = context.height()
            - if self.decorations {
                2. * DECORATION
            } else {
                0.
            };
        if width < 72. || height < 72. {
            return Err(self
                .lang
                .text(
                    "Das gewählte Papier hat zu wenig bedruckbare Fläche.",
                    "The selected paper has too little printable area.",
                )
                .into());
        }
        if self.numbers {
            let layout = context.create_pango_layout();
            layout.set_font_description(Some(&self.font));
            let count = self.input.text.bytes().filter(|byte| *byte == b'\n').count() + 1;
            layout.set_text(&format!("{}  ", "9".repeat(count.to_string().len())));
            self.number_width = f64::from(layout.size().0) / f64::from(pango::SCALE);
        }
        if width - self.number_width < 1. {
            return Err(self.lang.text("Zeilennummern lassen auf dieser Papierbreite keinen Platz für den Text. Zeilennummern ausschalten oder breiteres Papier wählen.", "Line numbers leave no room for text on this paper width. Turn off line numbers or choose wider paper.").into());
        }
        for _ in 0..64 {
            let rest = &self.input.text[self.cursor..];
            let end = rest
                .find('\n')
                .map_or(self.input.text.len(), |n| self.cursor + n);
            let text = self.input.text[self.cursor..end].trim_end_matches('\r');
            if text.len() > 64 * 1024 {
                return Err(self
                    .lang
                    .text(
                        "Eine logische Zeile überschreitet die Druckgrenze von 64 KiB.",
                        "A logical line exceeds the 64 KiB printing limit.",
                    )
                    .into());
            }
            self.logical_line += 1;
            let layout = context.create_pango_layout();
            layout.set_font_description(Some(&self.font));
            layout.set_text(if text.is_empty() { " " } else { text });
            if let Some(syntax) = self.syntax.as_mut() { layout.set_attributes(Some(&syntax.line(text, self.lang)?)); }
            if self.input.hex {
                if f64::from(layout.size().0) / f64::from(pango::SCALE) > width {
                    return Err(
                        self.lang.text("Hex-Zeilen passen nicht auf diese Papierbreite. Wählen Sie breiteres Papier oder Querformat.","Hex rows do not fit this paper width. Choose a wider paper or landscape.")
                            .into(),
                    );
                }
            } else {
                layout.set_width(((width - self.number_width) * f64::from(pango::SCALE)) as i32);
                layout.set_wrap(pango::WrapMode::WordChar);
            }
            if layout.unknown_glyphs_count() > 0 {
                return Err(self.lang.text("Ein benötigtes Schriftzeichen fehlt. Installieren Sie vor dem Drucken eine passende Schrift.","A required font glyph is unavailable. Install a suitable font before printing.").into());
            }
            let mut iter = layout.iter();
            let mut first = true;
            loop {
                let line = iter.line_readonly().ok_or(self.lang.text(
                    "Eine Druckzeile konnte nicht gesetzt werden.",
                    "Pango could not shape a print line.",
                ))?;
                let (ink, logical) = line.extents();
                let top = ink.y().min(logical.y());
                let bottom = (ink.y() + ink.height()).max(logical.y() + logical.height());
                let line_height = (f64::from(bottom - top) / f64::from(pango::SCALE)).max(1.) + 1.;
                if line_height > height {
                    return Err(self
                        .lang
                        .text(
                            "Eine Druckzeile passt nicht auf die gewählte Papierhöhe.",
                            "A print line does not fit the selected paper height.",
                        )
                        .into());
                }
                if self.y + line_height > height && !self.pages.last().unwrap().is_empty() {
                    self.pages.push(Vec::new());
                    self.y = 0.;
                }
                self.visual_lines += 1;
                if self.pages.len() > MAX_PAGES || self.visual_lines > MAX_VISUAL_LINES {
                    return Err(self
                        .lang
                        .text(
                            "Druckgrenze erreicht: 1.000 Seiten oder 25.000 sichtbare Zeilen.",
                            "Print limit reached: 1,000 pages or 25,000 visual lines.",
                        )
                        .into());
                }
                self.pages.last_mut().unwrap().push(PrintedLine {
                    _layout: layout.clone(),
                    line,
                    y: self.y,
                    baseline: -f64::from(top) / f64::from(pango::SCALE),
                    number: (first && self.numbers).then_some(self.logical_line),
                });
                self.y += line_height;
                first = false;
                if !iter.next_line() {
                    break;
                }
            }
            if end == self.input.text.len() {
                self.syntax.take();
                self.ready = true;
                return Ok(true);
            }
            self.cursor = end + 1;
        }
        Ok(false)
    }
    fn draw(&self, context: &gtk::PrintContext, page: usize, lang: Language) -> Result<(), String> {
        let lines = self
            .pages
            .get(page)
            .ok_or(lang.text("Ungültige Druckseite.", "Invalid print page."))?;
        let cr = context.cairo_context();
        cr.set_source_rgb(0., 0., 0.);
        let top = if self.decorations { DECORATION } else { 0. };
        if self.decorations {
            decorations(context, &self.input.title, page + 1, self.pages.len(), lang)?;
        }
        for piece in lines {
            if let Some(number) = piece.number {
                let label = context.create_pango_layout();
                label.set_font_description(Some(&self.font));
                label.set_text(&format!("{number:>width$}", width = self.logical_line.to_string().len()));
                cr.set_source_rgb(0.5, 0.5, 0.5);
                cr.move_to(
                    0.,
                    top + piece.y + piece.baseline
                        - f64::from(label.baseline()) / f64::from(pango::SCALE),
                );
                pangocairo::functions::show_layout(&cr, &label);
            }
            cr.set_source_rgb(0., 0., 0.);
            cr.move_to(self.number_width, top + piece.y + piece.baseline);
            pangocairo::functions::show_layout_line(&cr, &piece.line);
        }
        cr.status().map_err(|e| e.to_string())
    }
}
fn decorations(
    context: &gtk::PrintContext,
    title: &str,
    page: usize,
    total: usize,
    lang: Language,
) -> Result<(), String> {
    let cr = context.cairo_context();
    let layout = context.create_pango_layout();
    layout.set_font_description(Some(&pango::FontDescription::from_string("Sans 8")));
    layout.set_width((context.width() * f64::from(pango::SCALE)) as i32);
    layout.set_ellipsize(pango::EllipsizeMode::End);
    layout.set_text(title);
    cr.move_to(0., 0.);
    pangocairo::functions::show_layout(&cr, &layout);
    layout.set_text(&format!("{} {page} / {total}", lang.text("Seite", "Page")));
    layout.set_alignment(pango::Alignment::Right);
    cr.move_to(0., context.height() - 14.);
    pangocairo::functions::show_layout(&cr, &layout);
    cr.status().map_err(|e| e.to_string())
}
fn page_setup() -> gtk::PageSetup {
    let setup = gtk::PageSetup::new();
    setup.set_paper_size(&gtk::PaperSize::new(Some("iso_a4")));
    setup.set_top_margin(14., gtk::Unit::Mm);
    setup.set_bottom_margin(14., gtk::Unit::Mm);
    setup.set_left_margin(14., gtk::Unit::Mm);
    setup.set_right_margin(14., gtk::Unit::Mm);
    setup
}
fn finish(done: &Rc<RefCell<Option<Completion>>>, result: Result<(), String>) {
    let completion = done.borrow_mut().take();
    if let Some(done) = completion {
        done(result);
    }
}
fn run_text(
    parent: &gtk::ApplicationWindow,
    input: TextInput,
    lang: Language,
    destination: Destination,
    done: Completion,
) {
    if input.text.len() > MAX_TEXT || input.text.contains('\0') {
        done(Err(lang
            .text(
                "Druckgrenze: höchstens 2 MiB Text, keine Nullzeichen.",
                "Print limit: at most 2 MiB text, no NUL characters.",
            )
            .into()));
        return;
    }
    let input = TextInput {
        text: Arc::from(input.text.replace("\r\n", "\n").replace('\r', "\n")),
        ..input
    };
    let options = match printing::values(lang) { Ok(value) => value, Err(error) => { done(Err(error)); return; } };
    let font = match crate::editor_options::font::print_description(&parent.pango_context(), options.font_size, lang) {
        Ok(value) => value,
        Err(error) => { done(Err(format!("{}: {error}", lang.text("Druckschrift nicht bereit", "Print font not ready")))); return; }
    };
    let operation = gtk::PrintOperation::new();
    operation.set_job_name(&input.title);
    operation.set_unit(gtk::Unit::Points);
    operation.set_default_page_setup(Some(&page_setup()));
    operation.set_embed_page_setup(true);
    operation.set_allow_async(true);
    operation.set_show_progress(true);
    operation.set_custom_tab_label(Some("Fastra"));
    let numbers = gtk::CheckButton::with_label(lang.text("Zeilennummern drucken", "Print line numbers"));
    numbers.set_active(options.line_numbers && !input.hex);
    numbers.set_visible(!input.hex);
    numbers.connect_toggled(|choice| printing::line_numbers(choice.is_active()));
    let header = gtk::CheckButton::with_label(lang.text("Kopf- und Fußzeile drucken", "Print header and footer"));
    header.set_active(options.header_footer);
    header.connect_toggled(|choice| printing::header_footer(choice.is_active()));
    let colors = gtk::CheckButton::with_label(lang.text("Syntaxfarben drucken", "Print syntax colors"));
    colors.set_active(options.syntax_colors);
    colors.set_visible(!input.hex && input.syntax.is_some());
    colors.connect_toggled(|choice| printing::syntax_colors(choice.is_active()));
    let choices = gtk::Box::new(gtk::Orientation::Vertical, 8);
    choices.set_margin_top(10); choices.set_margin_bottom(10); choices.set_margin_start(18); choices.set_margin_end(18);
    choices.append(&header); choices.append(&numbers); choices.append(&colors);
    printing::feedback(lang, &choices);
    operation.connect_create_custom_widget(move |_| Some(choices.clone().upcast()));
    let plan = Rc::new(RefCell::new(None::<TextPlan>));
    let error = Rc::new(RefCell::new(None::<String>));
    let completion = Rc::new(RefCell::new(Some(done)));
    let state = plan.clone();
    operation.connect_begin_print(move |_, _| {
        *state.borrow_mut() = Some(TextPlan::new(
            input.clone(),
            printing::Values { line_numbers: numbers.is_active(), header_footer: header.is_active(), syntax_colors: colors.is_active(), ..options },
            font.clone(),
            lang,
        ));
    });
    let state = plan.clone();
    let failure = error.clone();
    operation.connect_paginate(move |op, context| {
        let result = state.borrow_mut().as_mut().unwrap().step(context);
        match result {
            Ok(true) => {
                let count = state.borrow().as_ref().unwrap().pages.len();
                op.set_n_pages(count as i32);
                true
            }
            Ok(false) => false,
            Err(detail) => {
                *failure.borrow_mut() = Some(detail);
                op.cancel();
                true
            }
        }
    });
    let state = plan.clone();
    let failure = error.clone();
    operation.connect_draw_page(move |op, context, page| {
        if let Err(detail) = state
            .borrow()
            .as_ref()
            .unwrap()
            .draw(context, page as usize, lang)
        {
            *failure.borrow_mut() = Some(detail);
            op.cancel();
        }
    });
    let completed = completion.clone();
    operation.connect_done(move |op, result| {
        let result = if let Some(error) = error.borrow_mut().take() {
            Err(error)
        } else {
            match result {
                gtk::PrintOperationResult::Apply => Ok(()),
                gtk::PrintOperationResult::Cancel => Err(lang
                    .text("Drucken abgebrochen.", "Printing cancelled.")
                    .into()),
                _ => Err(op.error().map_or_else(
                    || {
                        lang.text("Drucken fehlgeschlagen.", "Printing failed.")
                            .into()
                    },
                    |e| e.to_string(),
                )),
            }
        };
        finish(&completed, result);
    });
    let action = match destination {
        Destination::Dialog => gtk::PrintOperationAction::PrintDialog,
        #[cfg(debug_assertions)]
        Destination::Pdf(path) => {
            operation.set_export_filename(path);
            gtk::PrintOperationAction::Export
        }
    };
    if let Err(error) = operation.run(action, Some(parent)) {
        finish(&completion, Err(error.to_string()));
    }
}

#[cfg(debug_assertions)]
fn test_record(result: &Rc<RefCell<Option<Result<(), String>>>>) -> Completion {
    let result = result.clone();
    Box::new(move |value| {
        *result.borrow_mut() = Some(value);
    })
}
#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let output = PathBuf::from(
        std::env::var_os("FASTRA_PRINT_TEST_ROOT").expect("private PDF fixture directory"),
    );
    std::fs::create_dir_all(&output).unwrap();
    let mut source = String::from("// Rust print: Straße α 🌈\r\nfn main() { let label = \"COLOR-SENTINEL\"; }\r\n");
    for n in 1..=120 {
        source.push_str(&format!(
            "{n:03} Straße, café, Ελληνικά 🌈 - native GTK printing.\r\n"
        ));
    }
    source.push_str(&"A long logical source line wraps completely. ".repeat(30));
    source.push_str("\nFINAL-SENTINEL-END\n");
    let source_path = output.join("source-fixture.rs");
    let mut source_bytes = b"\xef\xbb\xbf".to_vec();
    source_bytes.extend(source.as_bytes());
    std::fs::write(&source_path, &source_bytes).unwrap();
    let hex_path = output.join("hex-fixture.bin");
    let hex_bytes = (0..2048).map(|n| (n % 256) as u8).collect::<Vec<_>>();
    std::fs::write(&hex_path, &hex_bytes).unwrap();
    let image_path = output.join("image-fixture.svg");
    let image_bytes=br##"<svg xmlns="http://www.w3.org/2000/svg" width="600" height="360"><rect width="600" height="360" fill="#f8f8ff"/><rect x="40" y="50" width="200" height="180" rx="20" fill="#17845b"/><circle cx="400" cy="150" r="90" fill="#2b63b4"/><text x="50" y="310" font-size="34">IMAGE PRINT</text></svg>"##;
    std::fs::write(&image_path, image_bytes).unwrap();
    let locale = if ui.lang.0 { "de" } else { "en" };
    let path = move |name: &str| output.join(format!("{name}.{locale}.pdf"));
    let stage = Cell::new(0);
    let result = Rc::new(RefCell::new(None::<Result<(), String>>));
    let original_pdf = RefCell::new(None::<Vec<u8>>);
    let image_source = RefCell::new(None::<viewer::Source>);
    let rich_baseline = RefCell::new(String::new());
    let sync = Rc::new(RefCell::new(None::<bool>));
    let syncing = Rc::new(Cell::new(false));
    let started = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(120),
            "Print stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let current = || ui.active().unwrap();
        let completed = || {
            let Some(value) = result.borrow_mut().take() else {
                return false;
            };
            assert!(value.is_ok(), "Print stage {}: {value:?}", stage.get());
            true
        };
        match stage.get() {
            0 => {
                if printing::values(ui.lang).is_err() || crate::editor_options::font::print_description(&ui.window.pango_context(), 10, ui.lang).is_err() { return glib::ControlFlow::Continue; }
                syntax::check(ui.lang);
                ui.load_path(source_path.clone());
                stage.set(1);
            }
            1 => {
                if current().name != "source-fixture.rs" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&current().buffer), source);
                let doc = current();
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "// PRINT-UNDO-MARKER\n");
                doc.buffer.end_user_action();
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(doc.buffer.can_redo(), "print fixture must retain a real redo history");
                doc.buffer.select_range(&doc.buffer.iter_at_offset(3), &doc.buffer.iter_at_offset(12));
                run_text(
                    &ui.window,
                    TextInput {
                        title: ui
                            .lang
                            .text("Quelltext - vollständiger Druck", "Source - complete print")
                            .into(),
                        text: Arc::from(buffer_text(&current().buffer)),
                        hex: false,
                        syntax: current().buffer.language(),
                    },
                    ui.lang,
                    Destination::Pdf(path("source")),
                    test_record(&result),
                );
                stage.set(2);
            }
            2 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                let doc = current();
                assert!(doc.buffer.can_redo(), "printing must not reset source undo history");
                assert_eq!(doc.buffer.selection_bounds().map(|(start, end)| (start.offset(), end.offset())), Some((3, 12)), "printing must retain source selection");
                doc.buffer.redo();
                assert_eq!(buffer_text(&doc.buffer), format!("{source}// PRINT-UNDO-MARKER\n"));
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.is_modified(), "printing must preserve the saved undo boundary");

                assert_eq!(std::fs::read(&source_path).unwrap(), source_bytes);
                ui.load_path(hex_path.clone());
                stage.set(3);
            }
            3 => {
                if current().name != "hex-fixture.bin" {
                    return glib::ControlFlow::Continue;
                }
                let Some(section) = current().section_view.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                let Some((text, range, hex)) = section.print_text() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(hex);
                assert!(text.contains("000007F0"));
                run_text(
                    &ui.window,
                    TextInput {
                        title: format!("Hex - {}", range.replace('–', "-")),
                        text: Arc::from(text),
                        hex: true,
                        syntax: None,
                    },
                    ui.lang,
                    Destination::Pdf(path("hex")),
                    test_record(&result),
                );
                stage.set(4);
            }
            4 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&hex_path).unwrap(), hex_bytes);
                ui.load_path(image_path.clone());
                stage.set(5);
            }
            5 => {
                if current().name != "image-fixture.svg" {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = current().visual_view.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                *image_source.borrow_mut() = Some(view.print_source());
                run_raster(
                    &ui.window,
                    "SVG - IMAGE PRINT".into(),
                    view.print_source(),
                    ui.lang,
                    Destination::Pdf(path("image")),
                    Rc::new(|| true),
                    test_record(&result),
                );
                stage.set(6);
            }
            6 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&image_path).unwrap(), image_bytes);
                *original_pdf.borrow_mut() = Some(std::fs::read(path("source")).unwrap());
                ui.load_path(path("source"));
                stage.set(7);
            }
            7 => {
                if current().name != format!("source.{locale}.pdf") {
                    return glib::ControlFlow::Continue;
                }
                let Some(view) = current().visual_view.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                let source = view.print_source();
                assert!(source.page_count() > 1);
                run_raster(
                    &ui.window,
                    "PDF".into(),
                    source,
                    ui.lang,
                    Destination::Pdf(path("pdf")),
                    Rc::new(|| true),
                    test_record(&result),
                );
                stage.set(8);
            }
            8 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(path("source")).unwrap(),
                    *original_pdf.borrow().as_ref().unwrap()
                );
                let mut markdown="# Native Markdown print\n\nRendered **bold** and *italic*, Unicode Ελληνικά 🌈.\n\nInline math: $x^2 + 1$.\n\n```mermaid\ngraph LR; START-->DONE;\n```\n\n| Number | Value |\n| --- | --- |\n".to_owned();
                for n in 1..=70 {
                    markdown.push_str(&format!("| {n:03} | TABLE-VALUE-{n:03} |\n"));
                }
                markdown.push_str("\nMARKDOWN-FINAL-SENTINEL\n");
                ui.add_document("markdown-print.md", &markdown);
                current()
                    .markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                stage.set(9);
            }
            9 => {
                let doc = current();
                let Some(preview) = doc.markdown.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                let Some(token) = preview.print_token(doc.revision.get()) else {
                    return glib::ControlFlow::Continue;
                };
                run_web(
                    &ui.window,
                    WebInput {
                        view: preview.view.clone(),
                        preview: Some(preview),
                        rich: None,
                        token: Some(token),
                        doc,
                    },
                    ui.lang,
                    Destination::Pdf(path("markdown")),
                    Rc::new(|| true),
                    test_record(&result),
                );
                stage.set(10);
            }
            10 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                let text = "# Rich print\n\n**Bold** and *italic*, non-breaking\u{a0}space Ελληνικά 🌈.\n\n- first\n- second\n\n| A | B |\n| --- | --- |\n| Ω | 42 |\n\nRICH-FINAL-SENTINEL\n";
                ui.add_document("rich-print.md", text);
                *rich_baseline.borrow_mut() = text.into();
                current().rich_toggle.borrow().as_ref().unwrap().set_active(true);
                stage.set(11);
            }
            11 => {
                let Some(editor) = current().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                if let Some(ready) = sync.borrow_mut().take() {
                    if ready {
                        let doc = current();
                        run_web(
                            &ui.window,
                            WebInput {
                                view: editor.view.clone(),
                                preview: None,
                                rich: Some(editor),
                                token: None,
                                doc,
                            },
                            ui.lang,
                            Destination::Pdf(path("rich")),
                            Rc::new(|| true),
                            test_record(&result),
                        );
                        stage.set(12);
                        return glib::ControlFlow::Continue;
                    }
                }
                if !syncing.replace(true) {
                    let ready = sync.clone();
                    let pending = syncing.clone();
                    editor.synchronize(
                        true,
                        Box::new(move |ok| {
                            pending.set(false);
                            *ready.borrow_mut() = Some(ok);
                        }),
                    );
                }
            }
            12 => {
                if !completed() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&current().buffer), *rich_baseline.borrow());
                assert_eq!(std::fs::read(&source_path).unwrap(), source_bytes);
                assert_eq!(std::fs::read(&hex_path).unwrap(), hex_bytes);
                assert_eq!(std::fs::read(&image_path).unwrap(), image_bytes);
                run_raster(
                    &ui.window,
                    "Cancelled owner".into(),
                    image_source.borrow().as_ref().unwrap().clone(),
                    ui.lang,
                    Destination::Pdf(path("cancelled")),
                    Rc::new(|| false),
                    test_record(&result),
                );
                stage.set(13);
            }
            13 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(value.is_err(), "stale owner must cancel deferred drawing");
                let replacement = image_path.with_extension("replacement.svg");
                std::fs::write(&replacement, image_bytes).unwrap();
                std::fs::rename(replacement, &image_path).unwrap();
                run_raster(
                    &ui.window,
                    "Replaced source".into(),
                    image_source.borrow().as_ref().unwrap().clone(),
                    ui.lang,
                    Destination::Pdf(path("stale")),
                    Rc::new(|| true),
                    test_record(&result),
                );
                stage.set(14);
            }
            14 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(value.is_err(), "same-byte new-inode source must fail");
                run_text(
                    &ui.window,
                    TextInput {
                        title: "Limit".into(),
                        text: Arc::from("x".repeat(MAX_TEXT + 1)),
                        hex: false,
                        syntax: None,
                    },
                    ui.lang,
                    Destination::Pdf(path("limit")),
                    test_record(&result),
                );
                stage.set(15);
            }
            15 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(value.is_err(), "oversized text must fail before export");
                assert!(!path("limit").exists());
                assert_eq!(std::fs::read(&image_path).unwrap(), image_bytes);
                let doc = current();
                let editor = doc.rich.borrow().clone().unwrap();
                run_web(
                    &ui.window,
                    WebInput {
                        view: editor.view.clone(),
                        preview: None,
                        rich: Some(editor),
                        token: None,
                        doc: doc.clone(),
                    },
                    ui.lang,
                    Destination::Pdf(path("stale-web")),
                    Rc::new(|| false),
                    test_record(&result),
                );
                assert!(!doc.container.property::<bool>("sensitive"));
                stage.set(16);
            }
            16 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(
                    value.is_err(),
                    "stale WebKit owner must fail before printing"
                );
                assert!(current().container.property::<bool>("sensitive"));
                assert!(!path("stale-web").exists());
                println!(
                    "PASS native print cancellation: changed owner, same-byte replaced inode, oversized text, stale WebKit owner; source and sensitivity retained"
                );
                println!(
                    "PASS native print matrix: source/hex/SVG/PDF/Markdown/Rich; paginated GTK/Pango and deferred sandboxed raster pages; real WebKit print; all source bytes retained; closing cleanly"
                );
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

struct RasterState {
    cancellation: viewer::Cancellation,
    ended: Cell<bool>,
    drawing: Cell<bool>,
    error: RefCell<Option<String>>,
}
impl Drop for RasterState {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}
fn draw_raster(
    context: &gtk::PrintContext,
    raster: viewer::Raster,
    title: &str,
    page: usize,
    total: usize,
    decorated: bool,
    lang: Language,
) -> Result<(), String> {
    let width = raster.width as i32;
    let height = raster.height as i32;
    if width <= 0 || height <= 0 || raster.rgb.len() != width as usize * height as usize * 3 {
        return Err(lang
            .text("Ungültige Druckbilddaten.", "Invalid print raster data.")
            .into());
    }
    // Cairo RGB24 nutzt native Byte-Reihenfolge; der Decoder liefert dichtes RGB8.
    let stride = cairo::Format::Rgb24
        .stride_for_width(raster.width)
        .map_err(|e| e.to_string())?;
    let mut data = vec![0u8; stride as usize * height as usize];
    for (row, target) in raster
        .rgb
        .chunks_exact(width as usize * 3)
        .zip(data.chunks_exact_mut(stride as usize))
    {
        for (source, pixel) in row
            .as_chunks::<3>()
            .0
            .iter()
            .zip(target.as_chunks_mut::<4>().0.iter_mut())
        {
            #[cfg(target_endian = "little")]
            {
                pixel.copy_from_slice(&[source[2], source[1], source[0], 0]);
            }
            #[cfg(target_endian = "big")]
            {
                pixel.copy_from_slice(&[0, source[0], source[1], source[2]]);
            }
        }
    }
    let image =
        cairo::ImageSurface::create_for_data(data, cairo::Format::Rgb24, width, height, stride)
            .map_err(|e| e.to_string())?;
    let cr = context.cairo_context();
    let top = if decorated { DECORATION } else { 0. };
    let area_height = context.height() - 2. * top;
    if context.width() < 1. || area_height < 1. {
        return Err(lang
            .text("Papierfläche zu klein.", "Paper area too small.")
            .into());
    }
    if decorated {
        decorations(context, title, page, total, lang)?;
    }
    let scale = (context.width() / f64::from(width)).min(area_height / f64::from(height));
    cr.save().map_err(|e| e.to_string())?;
    cr.translate(
        (context.width() - f64::from(width) * scale) / 2.,
        top + (area_height - f64::from(height) * scale) / 2.,
    );
    cr.scale(scale, scale);
    cr.set_source_surface(&image, 0., 0.)
        .map_err(|e| e.to_string())?;
    cr.paint().map_err(|e| e.to_string())?;
    cr.restore().map_err(|e| e.to_string())?;
    Ok(())
}
fn run_raster(
    parent: &gtk::ApplicationWindow,
    title: String,
    source: viewer::Source,
    lang: Language,
    destination: Destination,
    owner: Rc<dyn Fn() -> bool>,
    done: Completion,
) {
    let count = source.page_count() as usize;
    if count == 0 || count > MAX_PAGES {
        done(Err(lang
            .text(
                "Druckgrenze: höchstens 1.000 PDF-Seiten.",
                "Print limit: at most 1,000 PDF pages.",
            )
            .into()));
        return;
    }
    let options = match printing::values(lang) { Ok(value) => value, Err(error) => { done(Err(error)); return; } };
    let decorated = !source.is_pdf();
    let header = gtk::CheckButton::with_label(lang.text("Kopf- und Fußzeile drucken", "Print header and footer"));
    header.set_active(options.header_footer);
    header.set_visible(decorated);
    header.connect_toggled(|choice| printing::header_footer(choice.is_active()));
    let operation = gtk::PrintOperation::new();
    operation.set_job_name(&title);
    operation.set_unit(gtk::Unit::Points);
    operation.set_default_page_setup(Some(&page_setup()));
    operation.set_embed_page_setup(true);
    operation.set_allow_async(true);
    operation.set_show_progress(true);
    operation.set_n_pages(count as i32);
    operation.set_custom_tab_label(Some("Fastra"));
    let note = gtk::Label::new(Some(lang.text(
        "Bild- und PDF-Seiten werden als begrenzte Rasterbilder gedruckt (bis 4.000 Pixel Kantenlänge). Sie werden an das gewählte Papier angepasst. PDF-Text und Vektoren bleiben im Ausdruck nicht erhalten.",
        "Image and PDF pages print as bounded raster images (up to 4,000 pixels per edge), fitted to the selected paper. PDF text and vectors are not preserved in the print output.",
    )));
    note.set_wrap(true);
    note.set_max_width_chars(60);
    let choices = gtk::Box::new(gtk::Orientation::Vertical, 8);
    choices.set_margin_top(10); choices.set_margin_bottom(10); choices.set_margin_start(18); choices.set_margin_end(18);
    choices.append(&header); choices.append(&note);
    printing::feedback(lang, &choices);
    operation.connect_create_custom_widget(move |_| Some(choices.clone().upcast()));
    let state = Rc::new(RasterState {
        cancellation: viewer::Cancellation::default(),
        ended: Cell::new(false),
        drawing: Cell::new(false),
        error: RefCell::new(None),
    });
    let job = state.clone();
    operation.connect_draw_page(move |operation, context, page| {
        if job.ended.get() {
            return;
        }
        if job.drawing.replace(true) {
            *job.error.borrow_mut() = Some(
                lang.text(
                    "Parallele Druckseiten überschreiten das Speicherbudget.",
                    "Concurrent print pages exceed the memory budget.",
                )
                .into(),
            );
            operation.cancel();
            return;
        }
        // GTK hält den Druckkontext bis draw_page_finish; Codecs laufen nie auf GtkMain.
        let decorated = decorated && header.is_active();
        operation.set_defer_drawing();
        let source = source.clone();
        let cancel = job.cancellation.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(source.render_print_page(page as u32 + 1, &cancel));
        });
        let operation = operation.clone();
        let context = context.clone();
        let job = job.clone();
        let title = title.clone();
        let owner = owner.clone();
        glib::timeout_add_local(Duration::from_millis(20), move || {
            if job.ended.get() {
                return glib::ControlFlow::Break;
            }
            let result = if !owner() {
                Some(Err(lang
                    .text(
                        "Druckziel inzwischen gewechselt oder geändert. Auftrag abgebrochen.",
                        "Print target switched or changed. Job cancelled.",
                    )
                    .into()))
            } else {
                match rx.try_recv() {
                    Ok(Ok(raster)) => Some(draw_raster(
                        &context,
                        raster,
                        &title,
                        page as usize + 1,
                        count,
                        decorated,
                        lang,
                    )),
                    Ok(Err(error)) => Some(Err(error.message(lang.0))),
                    Err(mpsc::TryRecvError::Empty) => None,
                    Err(_) => Some(Err(lang
                        .text(
                            "Druckbild konnte nicht berechnet werden.",
                            "Print raster could not be rendered.",
                        )
                        .into())),
                }
            };
            if let Some(result) = result {
                job.drawing.set(false);
                if let Err(error) = result {
                    *job.error.borrow_mut() = Some(error);
                    job.cancellation.cancel();
                    operation.cancel();
                }
                if !job.ended.get() {
                    operation.draw_page_finish();
                }
                glib::ControlFlow::Break
            } else {
                glib::ControlFlow::Continue
            }
        });
    });
    let completion = Rc::new(RefCell::new(Some(done)));
    let completed = completion.clone();
    operation.connect_done(move |operation, result| {
        state.ended.set(true);
        state.cancellation.cancel();
        let result = if let Some(error) = state.error.borrow_mut().take() {
            Err(error)
        } else if result == gtk::PrintOperationResult::Apply {
            Ok(())
        } else {
            Err(operation.error().map_or_else(
                || {
                    lang.text("Drucken abgebrochen.", "Printing cancelled.")
                        .into()
                },
                |e| e.to_string(),
            ))
        };
        finish(&completed, result);
    });
    let action = match destination {
        Destination::Dialog => gtk::PrintOperationAction::PrintDialog,
        #[cfg(debug_assertions)]
        Destination::Pdf(path) => {
            operation.set_export_filename(path);
            gtk::PrintOperationAction::Export
        }
    };
    if let Err(error) = operation.run(action, Some(parent)) {
        finish(&completion, Err(error.to_string()));
    }
}

// Skia ordnet manche Inter-Alternativglyphen im PDF einem privaten Unicodewert
// zu. Im Druck verhindern ausgeschaltete Alternativen unter anderem den
// falschen Kopiertext bei Bindestrichen zwischen Großbuchstaben.
const PRINT_CSS: &str = r#"@media print{html,body{color:#111!important;background:white!important;font-size:10pt!important;font-variant-ligatures:none!important;font-feature-settings:"calt" 0!important}body{margin:0!important;padding:0!important}#fastra-visual{min-height:0!important}h1,h2,h3,h4,h5,h6{color:#111!important;break-after:avoid}p,li{orphans:2;widows:2}pre,code,blockquote,th{color:#111!important;background:#eee!important}pre{white-space:pre-wrap;overflow:visible;overflow-wrap:anywhere}table{width:100%;table-layout:fixed;border-collapse:collapse}thead{display:table-header-group;page-break-inside:avoid}td,th{color:#111!important;border-color:#aaa!important;overflow-wrap:anywhere}tr{break-inside:avoid;page-break-inside:avoid}img,svg{max-width:100%!important;max-height:240mm!important;break-inside:avoid}a{color:#111!important}.protected{color:#111!important;border-color:#aaa!important}mark{color:#111!important;background:#ffeb90!important}}"#;
struct WebInput {
    view: webkit6::WebView,
    preview: Option<Rc<markdown::MarkdownView>>,
    rich: Option<Rc<rich_editor::RichEditor>>,
    token: Option<String>,
    doc: Rc<Document>,
}
fn web_evaluate(view: &webkit6::WebView, code: &str, done: impl FnOnce(bool) + 'static) {
    view.call_async_javascript_function(
        code,
        None,
        None,
        None,
        None::<&gio::Cancellable>,
        move |result| {
            #[cfg(debug_assertions)]
            if let Err(error) = result.as_ref() {
                eprintln!("Print preparation JavaScript: {error}");
            }
            let value = result
                .ok()
                .and_then(|v| serde_json::from_str::<serde_json::Value>(&v.to_str()).ok());
            #[cfg(debug_assertions)]
            if value.as_ref() != Some(&serde_json::Value::Bool(true)) {
                eprintln!("Print preparation result: {value:?}");
            }
            done(value == Some(serde_json::Value::Bool(true)));
        },
    );
}
fn web_evaluate_loaded(view: &webkit6::WebView, code: String, done: impl FnOnce(bool) + 'static) {
    let view = view.clone();
    let pending = RefCell::new(Some(done));
    let began = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(20), move || {
        if view.is_loading() && began.elapsed() < Duration::from_secs(5) {
            return glib::ControlFlow::Continue;
        }
        let done = pending.borrow_mut().take().unwrap();
        if view.is_loading() {
            done(false);
        } else {
            web_evaluate(&view, &code, done);
        }
        glib::ControlFlow::Break
    });
}
fn run_web(
    parent: &gtk::ApplicationWindow,
    input: WebInput,
    lang: Language,
    destination: Destination,
    owner: Rc<dyn Fn() -> bool>,
    done: Completion,
) {
    let options = match printing::values(lang) {
        Ok(value) => value,
        Err(error) => { if let Some(editor) = input.rich.as_ref() { editor.release(); } done(Err(error)); return; }
    };
    // Nur die Renderberechtigung pausieren: der gebundene DOM bleibt zum Drucken sichtbar.
    if let Some(preview) = input.preview.as_ref() {
        preview.visible.set(false);
    }
    let container_sensitive = input.doc.container.property::<bool>("sensitive");
    input.doc.container.set_sensitive(false);
    let mode_doc = input.doc.clone();
    let mode_rich = input.rich.clone();
    let mode_preview = input.preview.clone();
    let mode_owner: Rc<dyn Fn() -> bool> = Rc::new(move || {
        owner()
            && if let Some(rich) = mode_rich.as_ref() {
                rich.active.get()
                    && mode_doc
                        .rich
                        .borrow()
                        .as_ref()
                        .is_some_and(|current| Rc::ptr_eq(current, rich))
            } else if let Some(preview) = mode_preview.as_ref() {
                mode_doc
                    .markdown
                    .borrow()
                    .as_ref()
                    .is_some_and(|current| Rc::ptr_eq(current, preview))
                    && mode_doc
                        .markdown_toggle
                        .borrow()
                        .as_ref()
                        .is_some_and(|toggle| toggle.is_active())
            } else {
                false
            }
    });
    let id = format!("fastra-print-{}", glib::uuid_string_random());
    let view = input.view.clone();
    let token = serde_json::json!(input.token);
    let restored_view = view.clone();
    let style_id = id.clone();
    let completion = Rc::new(RefCell::new(Some(Box::new(move |result| {
        restored_view.evaluate_javascript(
            &format!(
                "document.getElementById({})?.remove()",
                serde_json::json!(style_id)
            ),
            None,
            None,
            None::<&gio::Cancellable>,
            |_| {},
        );
        input.doc.container.set_sensitive(container_sensitive);
        if let Some(rich) = input.rich.as_ref() {
            rich.release();
        }
        if let Some(preview) = input.preview.as_ref() {
            let visible = input
                .doc
                .markdown_toggle
                .borrow()
                .as_ref()
                .is_some_and(|toggle| toggle.is_active());
            preview.visible.set(visible);
            if input
                .doc
                .markdown
                .borrow()
                .as_ref()
                .is_some_and(|current| Rc::ptr_eq(current, preview))
            {
                preview.schedule(&input.doc, lang);
            }
        }
        done(result);
    }) as Completion)));
    let css = serde_json::json!(PRINT_CSS.replace("font-size:10pt!important", &format!("font-size:{}pt!important", options.font_size)));
    let script = format!(
        r#"const token={token};const until=Date.now()+5000;while(token!==null && (!window.fastraPreviewReady || document.documentElement.dataset.fastraRender!==token) && Date.now()<until)await new Promise(r=>setTimeout(r,20));if(token!==null && (!window.fastraPreviewReady || document.documentElement.dataset.fastraRender!==token))return JSON.stringify("render-token-not-ready");if(new TextEncoder().encode(document.body.textContent).length>2097152 || document.querySelectorAll('*').length>50000 || document.querySelectorAll('p,li,pre,tr,h1,h2,h3,h4,h5,h6').length>10000)return JSON.stringify("document-size-limit");let pixels=0;for(const image of document.images){{const count=image.naturalWidth*image.naturalHeight;pixels+=count;if(count>32000000 || pixels>64000000)return JSON.stringify("image-pixel-limit");}}for(const row of document.querySelectorAll('table tr')){{if(row.cells.length>12)return JSON.stringify("table-column-limit");}}const style=document.createElement('style');style.id={};style.textContent={css};document.head.append(style);await document.fonts.ready;return JSON.stringify(token===null || document.documentElement.dataset.fastraRender===token);"#,
        serde_json::json!(id)
    );
    let completed = completion.clone();
    let parent = parent.clone();
    let prepared_view = view.clone();
    let started = Rc::new(Cell::new(false));
    let native_started = started.clone();
    web_evaluate_loaded(&view, script, move |ready| {
        if !ready || !mode_owner() {
            finish(
                &completed,
                Err(lang
                    .text(
                        "Markdown-Druckvorbereitung veraltet, nicht bereit oder außerhalb der Größen-/Layoutgrenzen. Nichts gedruckt.",
                        "Markdown print preparation stale, not ready or beyond size/layout limits. Nothing printed.",
                    )
                    .into()),
            );
            return;
        }
        if completed.borrow().is_none() {
            return;
        }
        native_started.set(true);
        let operation = webkit6::PrintOperation::new(&prepared_view);
        operation.set_page_setup(&page_setup());
        let error = Rc::new(RefCell::new(None::<String>));
        let failed = error.clone();
        operation.connect_failed(move |_, detail| {
            *failed.borrow_mut() = Some(detail.to_string());
        });
        let done = completed.clone();
        operation.connect_finished(move |_| {
            finish(&done, error.borrow_mut().take().map_or(Ok(()), Err));
        });
        match destination {
            Destination::Dialog => {
                if operation.run_dialog(Some(&parent)) == webkit6::PrintOperationResponse::Cancel {
                    finish(
                        &completed,
                        Err(lang
                            .text("Drucken abgebrochen.", "Printing cancelled.")
                            .into()),
                    );
                }
            }
            #[cfg(debug_assertions)]
            Destination::Pdf(path) => {
                let settings = gtk::PrintSettings::new();
                settings.set_printer("Print to File");
                let uri = gio::File::for_path(path).uri();
                settings.set("output-uri", Some(&uri));
                settings.set("output-file-format", Some("pdf"));
                operation.set_print_settings(&settings);
                operation.print();
            }
        }
    });
    glib::timeout_add_local_once(Duration::from_secs(15), move || {
        // Nach Beginn des nativen Dialogs bzw. Druckauftrags besitzt WebKit dessen Lebensdauer.
        if completion.borrow().is_some() && !started.get() {
            finish(
                &completion,
                Err(lang
                    .text(
                        "Markdown-Druckvorbereitung antwortet nicht.",
                        "Markdown print preparation did not respond.",
                    )
                    .into()),
            );
        }
    });
}

thread_local! {static PRINT_BUSY:Cell<bool>=const{Cell::new(false)};}
struct PrintLease;
impl Drop for PrintLease {
    fn drop(&mut self) {
        PRINT_BUSY.with(|busy| busy.set(false));
    }
}
pub fn is_busy() -> bool {
    PRINT_BUSY.with(Cell::get)
}
#[derive(Clone, Copy)]
enum Target {
    Visible,
    Source,
    Markdown,
}
fn report(ui: &std::rc::Weak<Ui>, doc: &std::rc::Weak<Document>, result: Result<(), String>) {
    let (Some(ui), Some(doc)) = (ui.upgrade(), doc.upgrade()) else {
        return;
    };
    if !ui.window.is_visible() || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) {
        return;
    }
    ui.status.set_text(&result.map_or_else(
        |error| format!("{} {error}", ui.lang.text("Druckauftrag:", "Print job:")),
        |_| {
            ui.lang
                .text("Druckauftrag abgeschlossen.", "Print job completed.")
                .to_owned()
        },
    ));
}
fn request(ui: &Rc<Ui>, target: Target) {
    if PRINT_BUSY.with(|busy| busy.replace(true)) {
        ui.status.set_text(ui.lang.text(
            "Ein Druckauftrag läuft bereits.",
            "A print job is already running.",
        ));
        return;
    }
    let lease = Rc::new(PrintLease);
    let Some(doc) = ui.active() else {
        drop(lease);
        return;
    };
    ui.status.set_text(
        ui.lang
            .text("Druckauftrag wird vorbereitet …", "Preparing print job …"),
    );
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(&doc);
    let done: Completion = Box::new(move |result| {
        report(&weak_ui, &weak_doc, result);
        drop(lease);
    });
    let lang = ui.lang;
    let editor = doc.rich.borrow().clone();
    if let Some(editor) = editor {
        let weak = Rc::downgrade(ui);
        let held = editor.clone();
        editor.synchronize(
            true,
            Box::new(move |ok| {
                if !ok {
                    done(Err(lang
                        .text(
                            "Rich-Synchronisation fehlgeschlagen; nichts gedruckt.",
                            "Rich synchronization failed; nothing printed.",
                        )
                        .into()));
                    return;
                }
                if let Some(ui) = weak.upgrade() {
                    prepare(&ui, doc, target, Some(held), done);
                } else {
                    held.release();
                    done(Err(lang
                        .text("Fenster geschlossen.", "Window closed.")
                        .into()));
                }
            }),
        );
    } else {
        prepare(ui, doc, target, None, done);
    }
}
fn prepare(
    ui: &Rc<Ui>,
    doc: Rc<Document>,
    target: Target,
    held: Option<Rc<rich_editor::RichEditor>>,
    done: Completion,
) {
    if doc
        .hex_editor
        .borrow()
        .as_ref()
        .is_some_and(|editor| !editor.can_print())
    {
        if let Some(editor) = held {
            editor.release();
        }
        done(Err(ui
            .lang
            .text(
                "Hex-Feldeingabe zuerst vormerken oder zurücksetzen; Speichern abschließen lassen.",
                "Stage or reset hex field input first; wait for saving to finish.",
            )
            .into()));
        return;
    }
    let revision = doc.revision.get();
    let weak = Rc::downgrade(ui);
    let document = Rc::downgrade(&doc);
    let owner: Rc<dyn Fn() -> bool> = Rc::new(move || {
        let (Some(ui), Some(doc)) = (weak.upgrade(), document.upgrade()) else {
            return false;
        };
        ui.window.is_visible()
            && doc.revision.get() == revision
            && ui
                .active()
                .is_some_and(|current| Rc::ptr_eq(&current, &doc))
    });
    if !owner() {
        if let Some(editor) = held {
            editor.release();
        }
        done(Err(ui
            .lang
            .text(
                "Druckziel inzwischen gewechselt.",
                "Print target switched meanwhile.",
            )
            .into()));
        return;
    }
    if matches!(target, Target::Visible) {
        let visual = doc.visual_view.borrow().as_ref().map(|v| v.print_source());
        if let Some(source) = visual {
            if let Some(editor) = held {
                editor.release();
            }
            run_raster(
                &ui.window,
                safe_title(&doc.name),
                source,
                ui.lang,
                Destination::Dialog,
                owner,
                done,
            );
            return;
        }
    }
    let rich_visible = matches!(target, Target::Visible) && held.is_some();
    let preview = doc.markdown.borrow().clone().filter(|v| v.visible.get());
    if rich_visible
        || matches!(target, Target::Markdown)
        || (matches!(target, Target::Visible) && preview.is_some())
    {
        let (view, token, rich, preview) = if rich_visible {
            let editor = held.unwrap();
            (editor.view.clone(), None, Some(editor), None)
        } else {
            if let Some(editor) = held {
                editor.release();
            }
            let Some(preview) = preview else {
                done(Err(ui
                    .lang
                    .text(
                        "Zuerst die Markdown-Vorschau einschalten.",
                        "Enable Markdown preview first.",
                    )
                    .into()));
                return;
            };
            let Some(token) = preview.print_token(revision) else {
                done(Err(ui
                    .lang
                    .text(
                        "Markdown-Vorschau wird noch berechnet. Bitte erneut drucken.",
                        "Markdown preview is still rendering. Please print again.",
                    )
                    .into()));
                return;
            };
            (preview.view.clone(), Some(token), None, Some(preview))
        };
        run_web(
            &ui.window,
            WebInput {
                view,
                preview,
                rich,
                token,
                doc,
            },
            ui.lang,
            Destination::Dialog,
            owner,
            done,
        );
        return;
    }
    if let Some(editor) = held {
        editor.release();
    }
    if let Some(section) = doc.section_view.borrow().as_ref() {
        let Some((text, range, hex)) = section.print_text() else {
            done(Err(ui
                .lang
                .text(
                    "Abschnitt noch nicht bereit oder veraltet.",
                    "Section not ready or stale.",
                )
                .into()));
            return;
        };
        run_text(
            &ui.window,
            TextInput {
                title: format!("{} - {range}", safe_title(&doc.name)),
                text: Arc::from(text),
                hex,
                syntax: None,
            },
            ui.lang,
            Destination::Dialog,
            done,
        );
        return;
    }
    if doc.is_read_only() && !doc.has_source_text() {
        done(Err(ui
            .lang
            .text(
                "Für diese Ansicht ist kein Quelltextdruck verfügbar.",
                "Source printing is unavailable for this view.",
            )
            .into()));
        return;
    }
    if doc.buffer.char_count() as usize > MAX_TEXT {
        done(Err(ui
            .lang
            .text(
                "Druckgrenze: höchstens 2 MiB Quelltext.",
                "Print limit: at most 2 MiB source text.",
            )
            .into()));
        return;
    }
    run_text(
        &ui.window,
        TextInput {
            title: safe_title(&doc.name),
            text: Arc::from(buffer_text(&doc.buffer)),
            hex: false,
            syntax: doc.buffer.language(),
        },
        ui.lang,
        Destination::Dialog,
        done,
    );
}
pub fn menu(ui: &Rc<Ui>) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder()
        .label(ui.lang.text("Drucken", "Print"))
        .build();
    let popover = gtk::Popover::new();
    let contents = gtk::Box::new(gtk::Orientation::Vertical, 4);
    for (de, en, target) in [
        (
            "Aktuelle Ansicht drucken …",
            "Print current view …",
            Target::Visible,
        ),
        ("Quelltext drucken …", "Print source …", Target::Source),
        (
            "Markdown-Vorschau drucken …",
            "Print Markdown preview …",
            Target::Markdown,
        ),
    ] {
        let item = gtk::Button::with_label(ui.lang.text(de, en));
        let weak = Rc::downgrade(ui);
        let popover = popover.clone();
        item.connect_clicked(move |_| {
            popover.popdown();
            if let Some(ui) = weak.upgrade() {
                request(&ui, target);
            }
        });
        contents.append(&item);
    }
    popover.set_child(Some(&contents));
    button.set_popover(Some(&popover));
    button
}
pub fn print_visible(ui: &Rc<Ui>) {
    request(ui, Target::Visible);
}
