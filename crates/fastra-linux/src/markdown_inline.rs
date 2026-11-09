//! Markdown-Befehle für den gebundenen Quelleditor und gemeinsame Leistenmetadaten.
use super::*;
mod block;
mod edit;
#[cfg(debug_assertions)]
mod formatting_test;
#[cfg(debug_assertions)]
pub(super) mod selftest;

#[derive(Clone, Copy, Debug)]
enum Style {
    Bold,
    Italic,
    Highlight,
    Code,
}
impl Style {
    fn marker(self) -> &'static str {
        match self {
            Self::Bold => "**",
            Self::Italic => "*",
            Self::Highlight => "==",
            Self::Code => "`",
        }
    }
}
fn markdown(doc: &Document) -> bool {
    doc.buffer
        .language()
        .is_some_and(|language| language.id() == "markdown")
}
fn allowed(doc: &Document) -> bool {
    markdown(doc)
        && !doc.source_edits_locked()
        && !doc.close_pending.get()
        && !doc
            .rectangles
            .borrow()
            .iter()
            .any(|rectangle| rectangle.is_selected())
}
fn apply(ui: &Ui, doc: &Document, target: &source_panes::Target, style: Style) -> bool {
    if !allowed(doc) || !target.valid(doc) {
        ui.status.set_text(ui.lang.text("Inlineformatierung benötigt eine zusammenhängende Auswahl im bearbeitbaren Markdown-Quelltext. Quelle oder Auswahl gegebenenfalls neu wählen.","Inline formatting requires a continuous selection in editable Markdown source. Select the source or selection again if necessary."));
        return false;
    }
    let source = buffer_text(&target.buffer);
    let result = (|| {
        text_limits::validate(&source, ui.lang)?;
        let edit = edit::toggle(&source, target.offsets(), style.marker()).ok_or_else(|| {
            ui.lang
                .text(
                    "Ungültige Textauswahl. Keine Änderung übernommen.",
                    "Invalid text selection. No change was applied.",
                )
                .to_owned()
        })?;
        let mut candidate = source.clone();
        candidate.replace_range(edit.bytes.clone(), &edit.replacement);
        text_limits::validate(&candidate, ui.lang)?;
        Ok::<_, String>(edit)
    })();
    let edit = match result {
        Ok(edit) => edit,
        Err(message) => {
            ui.status.set_text(&message);
            return false;
        }
    };
    if !allowed(doc) || !target.valid(doc) {
        return false;
    }
    let buffer = &target.buffer;
    // GTK 4.14 stellt beim Redo eine Gruppe ohne Abschlussbarriere wieder her.
    // Eine leere UserAction schließt sie ohne Undo-Verlust, verwirft aber Redo.
    // Deshalb erst nach allen Prüfungen unmittelbar vor dem neuen Edit ausführen.
    buffer.begin_user_action();
    buffer.end_user_action();
    buffer.begin_user_action();
    let marker = style.marker();
    let count = marker.len() as i32;
    // Nur die Marker ändern; bestehender Text und die unabhängigen Marken der
    // zweiten Quellansicht bleiben dabei erhalten.
    if edit.remove_markers {
        buffer.delete(
            &mut buffer.iter_at_offset(edit.range.1 - count),
            &mut buffer.iter_at_offset(edit.range.1),
        );
        buffer.delete(
            &mut buffer.iter_at_offset(edit.range.0),
            &mut buffer.iter_at_offset(edit.range.0 + count),
        );
    } else {
        buffer.insert(&mut buffer.iter_at_offset(edit.range.1), marker);
        buffer.insert(&mut buffer.iter_at_offset(edit.range.0), marker);
    }
    buffer.select_range(
        &buffer.iter_at_offset(edit.selection.1),
        &buffer.iter_at_offset(edit.selection.0),
    );
    buffer.end_user_action();
    target.view.grab_focus();
    true
}
pub(super) fn install(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    parent: &gtk::Box,
    views: [&sourceview5::View; 2],
) {
    let tools = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    tools.add_css_class("markdown-source-tools");
    let bar = gtk::ScrolledWindow::builder()
        .child(&tools)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(28)
        .max_content_height(38)
        .propagate_natural_height(true)
        .hexpand(true)
        .build();
    bar.set_widget_name("fastra-markdown-inline");
    for (id, de, en, symbol) in COMMANDS {
        let button = gtk::Button::from_icon_name(symbol);
        button.set_tooltip_text(Some(ui.lang.text(de, en)));
        button.update_property(&[gtk::accessible::Property::Label(ui.lang.text(de, en))]);
        button.set_focus_on_click(false);
        button.set_has_frame(false);
        button.set_size_request(26, 22);
        let owner = Rc::downgrade(doc);
        let weak = Rc::downgrade(ui);
        button.connect_clicked(move |_| {
            if let (Some(ui), Some(doc)) = (weak.upgrade(), owner.upgrade()) {
                command(&ui, &doc, id);
            }
        });
        tools.append(&button);
        if matches!(id, "hardBreak" | "plainParagraph" | "quote") {
            let separator = gtk::Separator::new(gtk::Orientation::Vertical);
            separator.set_margin_top(5);
            separator.set_margin_bottom(5);
            tools.append(&separator);
        }
    }
    let update: Rc<dyn Fn()> = {
        let bar = bar.downgrade();
        let doc = Rc::downgrade(doc);
        Rc::new(move || {
            if let (Some(bar), Some(doc)) = (bar.upgrade(), doc.upgrade()) {
                bar.set_visible(markdown(&doc) && !doc.source_edits_locked());
            }
        })
    };
    let refresh = update.clone();
    doc.buffer.connect_language_notify(move |_| refresh());
    for view in views {
        let controller = gtk::EventControllerKey::new();
        controller.set_propagation_phase(gtk::PropagationPhase::Capture);
        let owner = Rc::downgrade(doc);
        let weak = Rc::downgrade(ui);
        let editor = view.downgrade();
        controller.connect_key_pressed(move |_, key, _, state| {
            let (Some(ui), Some(doc), Some(view)) =
                (weak.upgrade(), owner.upgrade(), editor.upgrade())
            else {
                return glib::Propagation::Proceed;
            };
            if !view.has_focus() || !allowed(&doc) {
                return glib::Propagation::Proceed;
            }
            let ctrl = state.contains(gtk::gdk::ModifierType::CONTROL_MASK);
            let shift = state.contains(gtk::gdk::ModifierType::SHIFT_MASK);
            let alt = state.contains(gtk::gdk::ModifierType::ALT_MASK);
            if !ctrl || state.contains(gtk::gdk::ModifierType::SUPER_MASK) {
                return glib::Propagation::Proceed;
            }
            let id = match (key.to_lower(), shift, alt) {
                (gtk::gdk::Key::b, false, false) => "bold",
                (gtk::gdk::Key::i, false, false) => "italic",
                (gtk::gdk::Key::h, true, false) => "highlight",
                (gtk::gdk::Key::k, true, false) => "code",
                (gtk::gdk::Key::k, false, false) => "link",
                (gtk::gdk::Key::Return, false, true) => "hardBreak",
                (gtk::gdk::Key::_1, false, true) => "heading1",
                (gtk::gdk::Key::_2, false, true) => "heading2",
                (gtk::gdk::Key::_3, false, true) => "heading3",
                (gtk::gdk::Key::_0, false, true) => "plainParagraph",
                (gtk::gdk::Key::asterisk, true, false) | (gtk::gdk::Key::_8, true, false) => {
                    "bulletList"
                }
                (gtk::gdk::Key::ampersand, true, false) | (gtk::gdk::Key::_7, true, false) => {
                    "orderedList"
                }
                (gtk::gdk::Key::parenleft, true, false) | (gtk::gdk::Key::_9, true, false) => {
                    "quote"
                }
                (gtk::gdk::Key::t, true, true) => "insertTable",
                _ => return glib::Propagation::Proceed,
            };
            command(&ui, &doc, id);
            glib::Propagation::Stop
        });
        view.add_controller(controller);
        let refresh = update.clone();
        view.connect_editable_notify(move |_| refresh());
        let refresh = update.clone();
        view.connect_map(move |_| refresh());
        let refresh = update.clone();
        view.connect_unmap(move |_| refresh());
    }
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        let refresh = update.clone();
        toggle.connect_toggled(move |_| refresh());
    }
    update();
    parent.append(&bar);
}

pub(super) const COMMANDS: [(&str, &str, &str, &str); 15] = [
    ("bold", "Fett", "Bold", "fastra-bold-symbolic"),
    ("italic", "Kursiv", "Italic", "fastra-italic-symbolic"),
    (
        "highlight",
        "Markierung",
        "Highlight",
        "fastra-highlight-symbolic",
    ),
    ("code", "Inlinecode", "Inline code", "fastra-code-symbolic"),
    (
        "hardBreak",
        "Harter Zeilenumbruch",
        "Hard line break",
        "fastra-return-symbolic",
    ),
    (
        "heading1",
        "Überschrift 1",
        "Heading 1",
        "fastra-heading1-symbolic",
    ),
    (
        "heading2",
        "Überschrift 2",
        "Heading 2",
        "fastra-heading2-symbolic",
    ),
    (
        "heading3",
        "Überschrift 3",
        "Heading 3",
        "fastra-heading3-symbolic",
    ),
    (
        "plainParagraph",
        "Normaler Text",
        "Plain paragraph",
        "fastra-paragraph-symbolic",
    ),
    (
        "bulletList",
        "Aufzählung",
        "Bullet list",
        "fastra-list-symbolic",
    ),
    (
        "orderedList",
        "Nummerierte Liste",
        "Ordered list",
        "fastra-numbered-symbolic",
    ),
    (
        "taskList",
        "Aufgabenliste",
        "Task list",
        "fastra-tasks-symbolic",
    ),
    ("quote", "Zitat", "Quote", "fastra-quote-symbolic"),
    ("link", "Link", "Link", "fastra-link-symbolic"),
    (
        "insertTable",
        "Tabelle einfügen …",
        "Insert table …",
        "fastra-table-symbolic",
    ),
];
fn command(ui: &Rc<Ui>, doc: &Rc<Document>, id: &str) {
    use fastra_core::markdown_formatting::Command as Format;
    let Some(target) = source_panes::capture(doc) else {
        return;
    };
    let style = match id {
        "bold" => Some(Style::Bold),
        "italic" => Some(Style::Italic),
        "highlight" => Some(Style::Highlight),
        "code" => Some(Style::Code),
        _ => None,
    };
    if let Some(style) = style {
        apply(ui, doc, &target, style);
        return;
    }
    if id == "insertTable" {
        block::table(ui, doc, target);
        return;
    }
    let command = match id {
        "heading1" => Format::Heading(1),
        "heading2" => Format::Heading(2),
        "heading3" => Format::Heading(3),
        "plainParagraph" => Format::Heading(0),
        "bulletList" => Format::BulletList,
        "orderedList" => Format::OrderedList,
        "taskList" => Format::TaskList,
        "quote" => Format::Quote,
        "hardBreak" => Format::HardBreak,
        "link" => Format::Link,
        _ => return,
    };
    block::run(ui, doc, target, block::Command::Format(command));
}

pub(super) fn table_prompt(
    parent: &impl IsA<gtk::Window>,
    lang: Language,
    accept: impl FnOnce(usize, bool) + 'static,
) {
    let window = gtk::Window::builder()
        .title(lang.text("Tabelle einfügen", "Insert table"))
        .transient_for(parent)
        .modal(true)
        .destroy_with_parent(true)
        .resizable(false)
        .default_width(360)
        .build();
    window.add_css_class("fastra-tool");
    window.add_css_class("fastra-owned-review");
    let root = git_view::column();
    let heading = gtk::Label::new(Some(lang.text("Tabelle einfügen", "Insert table")));
    heading.add_css_class("heading");
    heading.set_xalign(0.);
    root.append(&heading);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.append(&gtk::Label::new(Some(
        lang.text("Anzahl der Spalten:", "Number of columns:"),
    )));
    let columns = gtk::Entry::builder()
        .text("3")
        .width_chars(5)
        .max_length(3)
        .activates_default(true)
        .input_purpose(gtk::InputPurpose::Digits)
        .build();
    row.append(&columns);
    root.append(&row);
    let header = gtk::CheckButton::with_label(lang.text("Mit Kopfzeile", "With header row"));
    header.set_active(true);
    root.append(&header);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::End);
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let weak = window.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(window) = weak.upgrade() {
            window.close();
        }
    });
    actions.append(&cancel);
    let insert = gtk::Button::with_label(lang.text("Tabelle einfügen", "Insert table"));
    insert.add_css_class("suggested-action");
    let saved = insert.downgrade();
    columns.connect_changed(move |entry| {
        if let Some(button) = saved.upgrade() {
            button.set_sensitive(
                entry
                    .text()
                    .trim()
                    .parse::<usize>()
                    .is_ok_and(|n| (1..=50).contains(&n)),
            );
        }
    });
    let accept = RefCell::new(Some(accept));
    let weak = window.downgrade();
    insert.connect_clicked(move |_| {
        let Ok(count) = columns.text().trim().parse::<usize>() else {
            return;
        };
        if !(1..=50).contains(&count) {
            return;
        }
        if let (Some(window), Some(accept)) = (weak.upgrade(), accept.borrow_mut().take()) {
            accept(count, header.is_active());
            window.destroy();
        }
    });
    actions.append(&insert);
    root.append(&actions);
    window.set_child(Some(&root));
    window.set_default_widget(Some(&insert));
    window.present();
}
