//! Klicknavigation bindet Originalzeilen an genau eine sichtbare Dokumentrevision.
use super::*;
use fastra_core::navigation::{self, Position};
use pulldown_cmark::CodeBlockKind;
use serde::Deserialize;
use std::{collections::VecDeque, rc::Weak};

pub(super) struct Markers<'a> {
    source: &'a str,
    lines: Vec<usize>,
    tags: VecDeque<(&'static str, usize)>,
    table_head: bool,
}
impl<'a> Markers<'a> {
    pub fn new(source: &'a str) -> Self {
        Self {
            source,
            lines: visible_blank_lines::line_starts(source),
            tags: VecDeque::new(),
            table_head: false,
        }
    }
    pub(super) fn line_at(&self, byte: usize) -> usize { self.lines.partition_point(|start| *start <= byte).max(1) }
    pub fn record(&mut self, event: &Event<'_>, byte: usize) {
        let line = self.line_at(byte);
        let name = match event {
            Event::Start(Tag::Paragraph) => "p",
            Event::Start(Tag::Heading { level, .. }) => match level {
                pulldown_cmark::HeadingLevel::H1 => "h1",
                pulldown_cmark::HeadingLevel::H2 => "h2",
                pulldown_cmark::HeadingLevel::H3 => "h3",
                pulldown_cmark::HeadingLevel::H4 => "h4",
                pulldown_cmark::HeadingLevel::H5 => "h5",
                pulldown_cmark::HeadingLevel::H6 => "h6",
            },
            Event::Start(Tag::BlockQuote(_)) => "blockquote",
            Event::Start(Tag::List(None)) => "ul",
            Event::Start(Tag::List(Some(_))) => "ol",
            Event::Start(Tag::Item) => "li",
            Event::Start(Tag::Table(_)) => "table",
            Event::Start(Tag::TableHead) => {
                self.table_head = true;
                self.tags.push_back(("thead", line));
                "tr"
            }
            Event::End(TagEnd::TableHead) => {
                self.table_head = false;
                return;
            }
            Event::Start(Tag::TableRow) => "tr",
            Event::Start(Tag::TableCell) => {
                if self.table_head {
                    "th"
                } else {
                    "td"
                }
            }
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(_))) => {
                // Die erste Codezeile folgt dem öffnenden Fence, auch bei CRLF.
                let content_line = if self.source[byte..].contains(['\r', '\n']) {
                    line + 1
                } else {
                    line
                };
                self.tags.push_back(("pre", content_line));
                return;
            }
            Event::Start(Tag::CodeBlock(_)) => "pre",
            Event::Rule => "hr",
            _ => return,
        };
        self.tags.push_back((name, line));
    }
    pub fn annotate(mut self, html: &str) -> Option<String> {
        // Nur vom vorhandenen Renderer erzeugte Tags werden ergänzt. Nutzer-HTML
        // bleibt hier hinter internen Platzhaltern; Parserzustand und Tabellenalignment
        // bleiben beim einmaligen html::push_html vollständig erhalten.
        let mut result = String::with_capacity(html.len() + self.tags.len() * 24);
        let mut cursor = 0;
        for (at, _) in html.match_indices('<') {
            let rest = &html[at + 1..];
            let end = rest
                .find(|c: char| !c.is_ascii_alphanumeric())
                .unwrap_or(rest.len());
            let name = &rest[..end];
            if self
                .tags
                .front()
                .is_some_and(|(expected, _)| *expected == name)
            {
                let (_, line) = self.tags.pop_front()?;
                let position = at + 1 + end;
                result.push_str(&html[cursor..position]);
                result.push_str(&format!(" data-srcline=\"{line}\""));
                cursor = position;
            }
        }
        result.push_str(&html[cursor..]);
        self.tags.is_empty().then_some(result)
    }
}

#[derive(Default)]
pub(super) struct Binding {
    ui: RefCell<Weak<Ui>>,
    doc: RefCell<Weak<Document>>,
    source: glib::WeakRef<sourceview5::View>,
    unfold: glib::WeakRef<gtk::Button>,
    navigation: Cell<u64>,
    input: Cell<u64>,
    reveal: Cell<Option<(u64, i32)>>,
    epoch: RefCell<String>,
}
impl Binding {
    pub(super) fn epoch(&self) -> String {
        self.epoch.borrow().clone()
    }
    pub fn invalidate(&self) {
        self.navigation.set(self.navigation.get().wrapping_add(1));
        self.reveal.set(None);
    }
    pub(super) fn owner(&self, preview: &MarkdownView) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.ui.borrow().upgrade()?;
        let doc = self.doc.borrow().upgrade()?;
        (preview.visible.get()
            && preview.view.is_mapped()
            && ui.window.is_visible()
            && doc.has_source_text() && !doc.is_rich_active()
            && !doc.close_pending.get()
            && !ui.close_committed.get()
            && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            && ui
                .documents
                .borrow()
                .iter()
                .any(|item| Rc::ptr_eq(item, &doc))
            && doc
                .markdown
                .borrow()
                .as_ref()
                .is_some_and(|view| std::ptr::eq(view.as_ref(), preview)))
        .then_some((ui, doc))
    }
}
pub(crate) fn bind(
    preview: &Rc<MarkdownView>,
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    source: &glib::WeakRef<sourceview5::View>,
    unfold: &glib::WeakRef<gtk::Button>,
) {
    *preview.positions.ui.borrow_mut() = Rc::downgrade(ui);
    *preview.positions.doc.borrow_mut() = Rc::downgrade(doc);
    preview.positions.source.set(source.upgrade().as_ref());
    preview.positions.unfold.set(unfold.upgrade().as_ref());
    *preview.positions.epoch.borrow_mut() = glib::uuid_string_random().to_string();
    let input = gtk::EventControllerLegacy::new();
    input.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(preview);
    input.connect_event(move |_, event| {
        // Ein neuer Drag, Tastendruck oder Scrollvorgang übernimmt die Ansicht.
        // Eine ältere Hintergrundantwort darf ihm den Fokus nicht entziehen.
        if matches!(
            event.event_type(),
            gtk::gdk::EventType::ButtonPress
                | gtk::gdk::EventType::KeyPress
                | gtk::gdk::EventType::Scroll
                | gtk::gdk::EventType::TouchBegin
        ) {
            if let Some(preview) = weak.upgrade() {
                preview.positions.invalidate();
            }
        }
        glib::Propagation::Proceed
    });
    preview.view.add_controller(input);
    let weak = Rc::downgrade(preview);
    preview.view.connect_unmap(move |_| {
        if let Some(preview) = weak.upgrade() {
            renew_epoch(&preview);
        }
    });
    let weak = Rc::downgrade(preview);
    preview.view.connect_map(move |_| {
        if let Some(preview) = weak.upgrade() {
            renew_epoch(&preview);
        }
    });
}
fn renew_epoch(preview: &Rc<MarkdownView>) {
    preview.positions.invalidate();
    *preview.positions.epoch.borrow_mut() = glib::uuid_string_random().to_string();
    ready(preview);
}
pub(super) fn ready(preview: &Rc<MarkdownView>) {
    let code = format!(
        "document.documentElement.dataset.fastraPositionEpoch={};window.fastraCancelSourceReveal?.();",
        serde_json::json!(preview.positions.epoch())
    );
    preview
        .view
        .evaluate_javascript(&code, None, None, None::<&gio::Cancellable>, |_| {});
}
pub(crate) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, view: &sourceview5::View) {
    let pointer = gtk::GestureClick::builder()
        .button(1)
        .propagation_phase(gtk::PropagationPhase::Capture)
        .build();
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_view = view.downgrade();
    pointer.connect_pressed(move |gesture, _, x, y| {
        if gesture
            .current_event_state()
            .contains(gtk::gdk::ModifierType::CONTROL_MASK)
        {
            return;
        }
        let (Some(ui), Some(doc), Some(view)) =
            (weak_ui.upgrade(), weak_doc.upgrade(), weak_view.upgrade())
        else {
            return;
        };
        if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) || !doc.has_source_text() || doc.is_rich_active()
        {
            return;
        }
        let Some(preview) = doc
            .markdown
            .borrow()
            .clone()
            .filter(|view| view.visible.get())
        else {
            return;
        };
        let (x, y) = view.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let Some(at) = view.iter_at_location(x, y) else {
            return;
        };
        let line = at.line() + 1;
        preview.positions.invalidate();
        let generation = preview.positions.navigation.get();
        let revision = doc.revision.get();
        let weak = Rc::downgrade(&preview);
        // Erst nach der normalen GtkTextView-Auswahlverarbeitung navigieren.
        glib::idle_add_local_once(move || {
            let Some(preview) = weak.upgrade() else {
                return;
            };
            if preview.positions.navigation.get() != generation {
                return;
            }
            let Some((_, doc)) = preview.positions.owner(&preview) else {
                return;
            };
            if doc.revision.get() != revision {
                return;
            }
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_SOURCE_SYNC_SELFTEST").is_some()
                && preview.print_token(revision).is_none()
            {
                println!("FASTRA_SOURCE_SYNC_PENDING_RENDER_OBSERVED");
            }
            preview.positions.reveal.set(Some((revision, line)));
            apply_reveal(&preview);
        });
    });
    view.add_controller(pointer);
    let weak = Rc::downgrade(doc);
    view.buffer().connect_mark_set(move |_, _, mark| {
        if !matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
            return;
        }
        if let Some(doc) = weak.upgrade() {
            if let Some(preview) = doc.markdown.borrow().as_ref() {
                preview
                    .positions
                    .input
                    .set(preview.positions.input.get().wrapping_add(1));
                if preview.positions.reveal.take().is_some() {
                    preview.view.evaluate_javascript(
                        "window.fastraCancelSourceReveal?.()",
                        None,
                        None,
                        None::<&gio::Cancellable>,
                        |_| {},
                    );
                }
            }
        }
    });
}
pub(super) fn apply_reveal(preview: &Rc<MarkdownView>) {
    let Some((revision, line)) = preview.positions.reveal.get() else {
        return;
    };
    let Some((_, doc)) = preview.positions.owner(preview) else {
        return;
    };
    if doc.revision.get() != revision {
        preview.positions.reveal.set(None);
        return;
    }
    let Some(token) = preview.print_token(revision) else {
        return;
    };
    let generation = preview.positions.navigation.get();
    let code = format!(
        "if(document.documentElement.dataset.fastraRender!=={} || typeof window.fastraRevealSourceLine!=='function')return null;return await window.fastraRevealSourceLine({line},{},{});",
        serde_json::json!(token),
        serde_json::json!(token),
        serde_json::json!(preview.positions.epoch())
    );
    let weak = Rc::downgrade(preview);
    preview.view.call_async_javascript_function(
        &code,
        None,
        None,
        None,
        None::<&gio::Cancellable>,
        move |result| {
            if let Some(preview) = weak.upgrade() {
                if preview.positions.navigation.get() == generation
                    && result.is_ok_and(|value| value.is_boolean())
                {
                    preview.positions.reveal.set(None);
                }
            }
        },
    );
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    token: String,
    epoch: String,
    line: usize,
    column: usize,
}
pub(super) fn message(preview: &Rc<MarkdownView>, value: serde_json::Value) {
    let Ok(request) = serde_json::from_value::<Request>(value) else {
        return;
    };
    if request.line == 0
        || request.column == 0
        || request.line > 4 * 1024 * 1024
        || request.column > 4 * 1024 * 1024
        || request.token.len() != 32
        || request.epoch.is_empty()
        || request.epoch != preview.positions.epoch()
    {
        return;
    }
    let Some((ui, doc)) = preview.positions.owner(preview) else {
        return;
    };
    let revision = doc.revision.get();
    if preview.print_token(revision).as_deref() != Some(&request.token) {
        return;
    }
    preview.positions.invalidate();
    let generation = preview.positions.navigation.get();
    let input = preview.positions.input.get();
    let owner = ui.generation.get();
    let rectangles: Vec<_> = doc
        .rectangles
        .borrow()
        .iter()
        .map(|r| r.selection_generation())
        .collect();
    let Some(target)=crate::source_panes::capture(&doc) else {return};
    let source = buffer_text(&doc.buffer);
    let weak = Rc::downgrade(preview);
    git_view::background(
        move || {
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_SOURCE_SYNC_SELFTEST").is_some() {
                // Die echte Bridge-Probe ändert während dieser Hintergrundphase die
                // native Auswahl/Revision; sie muss die späte Completion verwerfen.
                std::thread::sleep(Duration::from_millis(80));
            }
            navigation::destination(
                &source,
                Position {
                    line: request.line,
                    column: Some(request.column),
                },
                &Cancellation::default(),
            )
            .map_err(|error| error.to_string())
        },
        move |result| {
            let Some(preview) = weak.upgrade() else {
                return;
            };
            if preview.positions.navigation.get() != generation
                || preview.positions.input.get() != input
            {
                return;
            }
            let Some((ui, doc)) = preview.positions.owner(&preview) else {
                return;
            };
            if ui.generation.get() != owner
                || doc.revision.get() != revision
                || !target.valid_for_reading(&doc)
                || preview.print_token(revision).as_deref() != Some(request.token.as_str())
                || doc
                    .rectangles
                    .borrow()
                    .iter()
                    .map(|r| r.selection_generation())
                    .collect::<Vec<_>>()
                    != rectangles
            {
                return;
            }
            let Ok(destination)=result else {return};
            let view=target.view;
            if doc.folded.borrow().is_some() {
                if let Some(button) = preview.positions.unfold.upgrade() {
                    button.emit_clicked();
                }
            }
            for rect in doc.rectangles.borrow().iter() {
                rect.clear();
            }
            let mut at=target.buffer.iter_at_offset(destination.character_offset as i32);
            target.buffer.place_cursor(&at);
            view.scroll_to_iter(&mut at, 0.15, true, 0., 0.5);
            view.grab_focus();
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_positions_survive_unicode_crlf_marker_and_nested_blocks() {
        let source = "雪🙂\r\n\r\n==Marked==\r\n\r\nLine A\r\nLine B\r\nLine C\r\n\r\n- tight\r\n- item\r\n\r\n> quote\r\n\r\n```rs\r\ncode\r\n```\r\n\r\n| A | B |\r\n| - | - |\r\n| x | y |\r\n";
        let result = render(source, None, false, false, &Cancellation::default()).unwrap();
        for marker in [
            "<p data-srcline=\"1\"",
            "<p data-srcline=\"3\"",
            "<p data-srcline=\"5\"",
            "<li data-srcline=\"9\"",
            "<blockquote data-srcline=\"12\"",
            "<pre data-srcline=\"15\"",
            "<table data-srcline=\"18\"",
            "<tr data-srcline=\"20\"",
            "<th data-srcline=\"18\"",
            "<td data-srcline=\"20\"",
        ] {
            assert!(
                result.html.contains(marker),
                "missing {marker}: {}",
                result.html
            );
        }
        assert!(result.html.contains("Line A\nLine B\nLine C"));
    }
    #[test]
    fn line_endings_code_content_and_literal_html_keep_original_positions() {
        for newline in ["\n", "\r\n"] {
            let source = [
                "# Title",
                "",
                "==Unicode 雪🙂==",
                "",
                "```text",
                "first",
                "second",
                "```",
                "",
                "    indented",
                "",
                "<p data-srcline=\"999\">literal</p>",
            ]
            .join(newline);
            let result = render(&source, None, false, false, &Cancellation::default()).unwrap();
            for marker in [
                "<h1 data-srcline=\"1\"",
                "<p data-srcline=\"3\"",
                "<pre data-srcline=\"6\"",
                "<pre data-srcline=\"10\"",
            ] {
                assert!(
                    result.html.contains(marker),
                    "{newline:?}: {marker}: {}",
                    result
                        .html
                        .split("<body>")
                        .nth(1)
                        .unwrap()
                        .split("<script")
                        .next()
                        .unwrap()
                );
            }
            assert!(!result.html.contains("<p data-srcline=\"999\""));
            assert!(result.warnings > 0, "forged raw source markers are rejected");
        }
    }
    #[test]
    fn cr_only_paragraphs_and_headings_keep_original_line_numbers() {
        let result = render(
            "雪🙂\r\rParagraph\r\r# Heading",
            None,
            false,
            false,
            &Cancellation::default(),
        )
        .unwrap();
        assert!(result.html.contains("<p data-srcline=\"3\">Paragraph</p>"));
        assert!(result.html.contains("<h1 data-srcline=\"5\""));
    }
    #[test]
    fn malformed_navigation_cannot_supply_offsets_or_unknown_fields() {
        for value in [
            serde_json::json!({"line":1,"column":1}),
            serde_json::json!({"token":"x","line":-1,"column":1}),
            serde_json::json!({"token":"x","epoch":"e","line":1,"column":1,"offset":10}),
            serde_json::json!({"token":"x","epoch":"e","line":1.5,"column":1}),
        ] {
            assert!(serde_json::from_value::<Request>(value).is_err());
        }
    }
}
