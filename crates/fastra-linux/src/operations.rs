use super::*;
use fastra_core::{
    text_operations::{
        self, CharacterOperation as Characters, DuplicateMode, IndentOptions,
        LineOperation as Lines,
    },
    Utf16Range,
};

#[derive(Clone)]
enum Operation {
    Lines(Lines),
    Characters(Characters),
    Profile(u8),
    Titlecase(text_operations::TitlecaseLocale),
    Case(bool, text_operations::TitlecaseLocale),
    Sort(bool, text_operations::TitlecaseLocale),
}
impl Operation {
    fn execute(
        &self,
        text: &str,
        selection: Utf16Range,
        cancel: &Cancellation,
        profile: IndentOptions,
    ) -> Result<Option<text_operations::TextResult>, fastra_core::Error> {
        let limits = Limits::interactive_text_operations();
        match self {
            Self::Sort(descending, locale) => text_operations::sort_lines_with_locale(
                text, selection, *descending, locale, limits, cancel,
            ),
            Self::Case(uppercase, locale) => text_operations::case_with_locale(text, selection, *uppercase, locale, limits, cancel),
            Self::Titlecase(locale) => {
                text_operations::titlecase_with_locale(text, selection, locale, limits, cancel)
            }
            Self::Lines(op) => {
                text_operations::transform_lines(text, selection, op, limits, cancel)
            }
            Self::Profile(kind) => {
                let op = match kind {
                    0 => Lines::Detab {
                        tab_width: profile.tab_width,
                    },
                    1 => Lines::Entab {
                        tab_width: profile.tab_width,
                    },
                    2 => Lines::ShiftRight(profile),
                    _ => Lines::ShiftLeft(profile),
                };
                text_operations::transform_lines(text, selection, &op, limits, cancel)
            }
            Self::Characters(op) => {
                text_operations::transform_characters(text, selection, *op, limits, cancel)
            }
        }
    }
}
pub fn menu(ui: &Rc<Ui>) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder().label("Text").build();
    button.set_tooltip_text(Some(ui.lang.text("Textwerkzeuge", "Text operations")));
    let menu = gio::Menu::new();
    let lines = gio::Menu::new();
    let characters = gio::Menu::new();
    let parameterized = gio::Menu::new();
    let actions = gio::SimpleActionGroup::new();
    for (id, de, en, descending) in [
        ("sort-ascending", "Zeilen sortieren ↑ · Textlocale", "Sort lines ↑ · text locale", false),
        ("sort-descending", "Zeilen sortieren ↓ · Textlocale", "Sort lines ↓ · text locale", true),
    ] {
        let action = gio::SimpleAction::new(id, None);
        let locale = titlecase_locale();
        action.set_enabled(locale.is_ok());
        let name = locale.as_ref().map_or("?", |locale| locale.as_str()).replace('_', "__");
        lines.append(Some(&format!("{} ({name})", ui.lang.text(de, en))), Some(&format!("text.{id}")));
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            if let Some(ui) = weak.upgrade() {
                match titlecase_locale() {
                    Ok(locale) => run(&ui, Operation::Sort(descending, locale)),
                    Err(_) => ui.status.set_text(ui.lang.text("Die Text-Systemlocale konnte nicht bestimmt werden.", "The system text locale could not be determined.")),
                }
            }
        });
        actions.add_action(&action);
    }
    let items = [
        (
            "Doppelte Zeilen: erste behalten",
            "Duplicate lines: keep first",
            Operation::Lines(Lines::Duplicates(DuplicateMode::KeepFirst)),
        ),
        (
            "Nur doppelte Zeilen behalten",
            "Keep duplicate lines only",
            Operation::Lines(Lines::Duplicates(DuplicateMode::KeepDuplicates)),
        ),
        (
            "Alle mehrfachen Zeilen entfernen",
            "Remove all repeated lines",
            Operation::Lines(Lines::Duplicates(DuplicateMode::RemoveAllDuplicates)),
        ),
        (
            "Zeilenfolge umkehren",
            "Reverse lines",
            Operation::Lines(Lines::Reverse),
        ),
        (
            "Leere Zeilen entfernen",
            "Remove blank lines",
            Operation::Lines(Lines::RemoveBlank),
        ),
        (
            "Nachlaufende Leerzeichen entfernen",
            "Trim trailing whitespace",
            Operation::Lines(Lines::TrimTrailingWhitespace),
        ),
        (
            "Zeilen nummerieren",
            "Number lines",
            Operation::Lines(Lines::AddNumbers),
        ),
        (
            "Zeilennummern entfernen",
            "Remove line numbers",
            Operation::Lines(Lines::RemoveNumbers),
        ),
        (
            "Unicode NFC",
            "Unicode NFC",
            Operation::Characters(Characters::Nfc),
        ),
        (
            "Unicode NFD",
            "Unicode NFD",
            Operation::Characters(Characters::Nfd),
        ),
        (
            "Unicode-Leerzeichen normalisieren",
            "Normalize Unicode spaces",
            Operation::Characters(Characters::NormalizeSpaces),
        ),
        (
            "Unsichtbare Steuerzeichen entfernen",
            "Remove invisible control characters",
            Operation::Characters(Characters::ZapGremlins),
        ),
    ];
    for (index, (de, en, operation)) in items.into_iter().enumerate() {
        let name = format!("op{index}");
        let action = gio::SimpleAction::new(&name, None);
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            if let Some(ui) = weak.upgrade() {
                run(&ui, operation.clone())
            }
        });
        actions.add_action(&action);
        (if index < 8 { &lines } else { &characters })
            .append(Some(ui.lang.text(de, en)), Some(&format!("text.{name}")));
    }
    for (id, de, en, uppercase) in [
        ("titlecase", "Wortanfänge groß · Systemlocale", "Titlecase · system locale", None),
        ("uppercase-localized", "Großschreibung · Systemlocale", "Uppercase · system locale", Some(true)),
        ("lowercase-localized", "Kleinschreibung · Systemlocale", "Lowercase · system locale", Some(false)),
    ] {
        let action = gio::SimpleAction::new(id, None);
        let locale = titlecase_locale();
        action.set_enabled(locale.is_ok());
        let name = locale.as_ref().map_or("?", |locale| locale.as_str()).replace('_', "__");
        characters.append(Some(&format!("{} ({name})", ui.lang.text(de, en))), Some(&format!("text.{id}")));
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            if let Some(ui) = weak.upgrade() {
                match titlecase_locale() {
                    Ok(locale) => run(&ui, match uppercase { Some(upper) => Operation::Case(upper, locale), None => Operation::Titlecase(locale) }),
                    Err(_) => ui.status.set_text(ui.lang.text("Die Text-Systemlocale konnte nicht bestimmt werden.", "The system text locale could not be determined.")),
                }
            }
        });
        actions.add_action(&action);
    }
    let whitespace = gio::Menu::new();
    let quotes = gio::Menu::new();
    let transposition = gio::Menu::new();
    let four_d = gio::Menu::new();
    for (name, de, en, operation, group) in [
        (
            "four-d-detokenize",
            "4D-Token-Suffixe entfernen",
            "Remove 4D token suffixes",
            Operation::Characters(Characters::FourDDetokenize),
            &four_d,
        ),
        (
            "four-d-tokenize",
            "4D-Befehls-Token ergänzen (keine Konstanten)",
            "Add 4D command tokens (no constants)",
            Operation::Characters(Characters::FourDTokenizeCommands),
            &four_d,
        ),
        (
            "detab",
            "Tabs in Leerzeichen",
            "Tabs to spaces",
            Operation::Profile(0),
            &whitespace,
        ),
        (
            "entab",
            "Leerzeichen in Tabs",
            "Spaces to tabs",
            Operation::Profile(1),
            &whitespace,
        ),
        (
            "indent",
            "Einrücken",
            "Indent",
            Operation::Profile(2),
            &whitespace,
        ),
        (
            "unindent",
            "Ausrücken",
            "Unindent",
            Operation::Profile(3),
            &whitespace,
        ),
        (
            "straighten",
            "Anführungszeichen begradigen",
            "Straighten quotes",
            Operation::Characters(Characters::StraightenQuotes),
            &quotes,
        ),
        (
            "educate",
            "Englische typografische Anführungszeichen",
            "English smart quotes",
            Operation::Characters(Characters::EducateQuotes),
            &quotes,
        ),
        (
            "escapes",
            "Escape-Sequenzen umwandeln",
            "Convert escape sequences",
            Operation::Characters(Characters::ConvertEscapes),
            &quotes,
        ),
        (
            "transpose-characters",
            "Zeichen vertauschen",
            "Transpose characters",
            Operation::Characters(Characters::ExchangeCharacters),
            &transposition,
        ),
        (
            "transpose-words",
            "Wörter vertauschen",
            "Transpose words",
            Operation::Characters(Characters::ExchangeWords),
            &transposition,
        ),
        (
            "diacritics",
            "Diakritische Zeichen entfernen",
            "Strip diacriticals",
            Operation::Characters(Characters::StripDiacriticals),
            &characters,
        ),
        (
            "emoji-add",
            "Emoji-Darstellung ergänzen",
            "Add emoji presentation",
            Operation::Characters(Characters::AddEmojiPresentation),
            &characters,
        ),
        (
            "emoji-remove",
            "Emoji-Darstellung entfernen",
            "Remove emoji presentation",
            Operation::Characters(Characters::RemoveEmojiPresentation),
            &characters,
        ),
    ] {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            if let Some(ui) = weak.upgrade() {
                run(&ui, operation.clone())
            }
        });
        actions.add_action(&action);
        group.append(Some(ui.lang.text(de, en)), Some(&format!("text.{name}")));
    }
    for (de, en, kind) in [
        ("Zeilen-Präfix …", "Line prefix …", 0),
        ("Zeilen-Suffix …", "Line suffix …", 1),
        ("Zeilen verbinden …", "Join lines …", 2),
        ("Regex-Zeilen behalten …", "Keep regex lines …", 3),
        ("Regex-Zeilen entfernen …", "Remove regex lines …", 4),
        ("Harter Zeilenumbruch …", "Hard wrap …", 5),
    ] {
        let name = format!("parameter{kind}");
        let action = gio::SimpleAction::new(&name, None);
        let weak = Rc::downgrade(ui);
        action.connect_activate(move |_, _| {
            if let Some(ui) = weak.upgrade() {
                prompt(&ui, ui.lang.text(de, en), kind)
            }
        });
        actions.add_action(&action);
        parameterized.append(Some(ui.lang.text(de, en)), Some(&format!("text.{name}")));
    }
    menu.append_submenu(Some(ui.lang.text("Zeilen", "Lines")), &lines);
    menu.append_submenu(
        Some(ui.lang.text("Einrückung / Tabs", "Indentation / tabs")),
        &whitespace,
    );
    menu.append_submenu(Some("Unicode"), &characters);
    menu.append_submenu(
        Some(
            ui.lang
                .text("Anführungszeichen / Escapes", "Quotes / escapes"),
        ),
        &quotes,
    );
    menu.append_submenu(
        Some(ui.lang.text("Vertauschen", "Transpose")),
        &transposition,
    );
    menu.append_submenu(Some("4D"), &four_d);
    menu.append_section(None, &parameterized);
    ui.window.insert_action_group("text", Some(&actions));
    rectangle::append_menu(ui, &menu, &actions);
    button.set_menu_model(Some(&menu));
    button
}

fn prompt(ui: &Rc<Ui>, title: &str, kind: i32) {
    let dialog = gtk::Window::builder()
        .transient_for(&ui.window)
        .modal(true)
        .title(title)
        .default_width(440)
        .build();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
    content.set_margin_top(16);
    content.set_margin_bottom(16);
    content.set_margin_start(16);
    content.set_margin_end(16);
    let label = gtk::Label::new(Some(title));
    label.set_xalign(0.);
    content.append(&label);
    let field = gtk::Entry::new();
    if kind == 2 {
        field.set_text(" ")
    } else if kind == 5 {
        field.set_text("72")
    } else if kind >= 3 {
        field.set_text(&ui.find.text())
    }
    content.append(&field);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    buttons.set_halign(gtk::Align::End);
    let cancel = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    let apply = gtk::Button::with_label(ui.lang.text("Anwenden", "Apply"));
    buttons.append(&cancel);
    buttons.append(&apply);
    content.append(&buttons);
    dialog.set_child(Some(&content));
    let window = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(window) = window.upgrade() {
            window.close()
        }
    });
    let weak = Rc::downgrade(ui);
    let window = dialog.downgrade();
    apply.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            let value = field.text().to_string();
            let operation = match kind {
                0 => Lines::Prefix(value),
                1 => Lines::Suffix(value),
                2 => Lines::Join(value),
                5 => {
                    let Ok(column) = value.parse::<usize>() else {
                        label.set_text(ui.lang.text(
                            "Umbruchspalte: ganze Zahl von 1 bis 10000.",
                            "Wrap column: integer from 1 to 10000.",
                        ));
                        field.add_css_class("error");
                        return;
                    };
                    if !(1..=10000).contains(&column) {
                        label.set_text(ui.lang.text(
                            "Umbruchspalte: ganze Zahl von 1 bis 10000.",
                            "Wrap column: integer from 1 to 10000.",
                        ));
                        field.add_css_class("error");
                        return;
                    }
                    Lines::HardWrap { column }
                }
                _ => Lines::Filter {
                    pattern: value,
                    keep_matching: kind == 3,
                    case_sensitive: ui.case.is_active(),
                },
            };
            run(&ui, Operation::Lines(operation));
        }
        if let Some(window) = window.upgrade() {
            window.close()
        }
    });
    dialog.present();
}

fn run(ui: &Rc<Ui>, operation: Operation) {
    ui.invalidate();
    let Some(doc) = ui.active() else { return };
    if !ui.source_edit_allowed(&doc) {
        return;
    }
    let Some(target)=source_panes::capture(&doc) else{return};
    let source = buffer_text(&doc.buffer);
    let revision = doc.revision.get();
    let generation = ui.generation.get();
    if doc
        .rectangles
        .borrow()
        .iter()
        .any(|rect| rect.is_selected())
    {
        ui.status.set_text(ui.lang.text("Rechteckauswahl zuerst mit Esc beenden. Textoperationen verwenden eine zusammenhängende Auswahl.", "End rectangle selection with Escape first. Text operations use a continuous selection."));
        return;
    }
    let offsets = selection_offsets(&doc);
    let (uses_tabs, indent_width, tab_width) = crate::editor_options::indentation(&doc);
    let profile = IndentOptions {
        uses_tabs,
        indent_width,
        tab_width,
    };
    let cancel = Cancellation::default();
    *ui.cancellation.borrow_mut() = cancel.clone();
    let (tx, rx) = mpsc::channel();
    let four_d = matches!(
        &operation,
        Operation::Characters(Characters::FourDDetokenize | Characters::FourDTokenizeCommands)
    );
    let locale = match &operation {
        Operation::Titlecase(locale) | Operation::Case(_, locale) | Operation::Sort(_, locale) => Some(locale.clone()),
        _ => None,
    };
    let original = source.clone();
    let completion_cancel = cancel.clone();
    std::thread::spawn(move || {
        #[cfg(debug_assertions)] source_panes::delay_reply();
        let start = source
            .chars()
            .take(offsets.0 as usize)
            .map(char::len_utf16)
            .sum();
        let length = source
            .chars()
            .skip(offsets.0 as usize)
            .take((offsets.1 - offsets.0) as usize)
            .map(char::len_utf16)
            .sum();
        let selection = Utf16Range {
            location: start,
            length,
        };
        let _ = tx.send(operation.execute(&source, selection, &cancel, profile));
    });
    let weak = Rc::downgrade(ui);
    glib::timeout_add_local(Duration::from_millis(20), move || {
        let Some(ui) = weak.upgrade() else {
            completion_cancel.cancel();
            return glib::ControlFlow::Break;
        };
        if locale
            .as_ref()
            .is_some_and(|expected| titlecase_locale().as_ref() != Ok(expected))
            || ui.generation.get() != generation
            || doc.revision.get() != revision
            || !target.valid(&doc)
            || selection_offsets(&doc) != offsets
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
        {
            #[cfg(debug_assertions)] eprintln!("SPLIT op stale ui={}/{} {}",ui.generation.get(),generation,target.trace(&doc));
            completion_cancel.cancel();
            if ui.generation.get() == generation {
                ui.status.set_text(ui.lang.text(
                    "Dokument oder Auswahl geändert. Die Textoperation wurde nicht übernommen.",
                    "Document or selection changed. The text operation was not applied.",
                ));
            }
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok(Ok(Some(result))) => {
                if buffer_text(&doc.buffer) != original {
                    return glib::ControlFlow::Break;
                };
                if let Err(error) = crate::text_limits::validate(&result.text, ui.lang) {
                    ui.status.set_text(&error);
                    return glib::ControlFlow::Break;
                }
                source_panes::replace_result(&target.buffer,&result.text);
                ui.status.set_text(ui.lang.text("Textoperation im Editor angewendet. Ein Undo stellt den vorherigen Stand wieder her.","Text operation applied in the editor. One Undo restores the previous contents."));
                glib::ControlFlow::Break
            }
            Ok(Ok(None)) => {
                ui.status.set_text(ui.lang.text(
                    "Textoperation ohne Änderung.",
                    "Text operation made no change.",
                ));
                glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                if four_d && error == fastra_core::Error::InvalidRange {
                    ui.status.set_text(ui.lang.text("Der 4D-Bereich würde ein zusammengesetztes Unicode-Zeichen teilen. Bitte die Auswahl und Token-Suffixe prüfen. Es wurde nichts übernommen.", "The 4D range would split a composed Unicode character. Check the selection and token suffixes. Nothing was applied."));
                } else {
                    ui.status.set_text(&error_text(ui.lang, &error));
                }
                glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}
fn selection_offsets(doc: &Document) -> (i32,i32) {
    source_panes::capture(doc).map(|target|target.offsets()).unwrap_or_else(||{let b=source_panes::buffer(doc);let at=b.cursor_position();(at,at)})
}

#[cfg(debug_assertions)]
pub fn test_sort(ui: &Rc<Ui>) {
    match titlecase_locale() {
        Ok(locale) => run(ui, Operation::Sort(false, locale)),
        Err(_) => ui.status.set_text(ui.lang.text("Die Text-Systemlocale konnte nicht bestimmt werden.", "The system text locale could not be determined.")),
    }
}

pub fn help(ui: &Rc<Ui>) {
    let window = gtk::Window::builder()
        .transient_for(&ui.window)
        .title(ui.lang.text("Fastra – Hilfe", "Fastra – Help"))
        .default_width(640)
        .default_height(600)
        .build();
    let text = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .wrap_mode(gtk::WrapMode::WordChar)
        .left_margin(20)
        .right_margin(20)
        .top_margin(20)
        .bottom_margin(20)
        .build();
    text.buffer().set_text(if ui.lang.0 {
        include_str!("../../../linux/resources/help.de.txt")
    } else {
        include_str!("../../../linux/resources/help.en.txt")
    });
    window.set_child(Some(&scroll(&text)));
    window.present();
}

/// Nur auf dem GTK-Thread lesen; der Snapshot wird vor dem Worker kopiert.
pub(super) fn titlecase_locale() -> Result<text_operations::TitlecaseLocale, fastra_core::Error> {
    let value = unsafe { libc::setlocale(libc::LC_CTYPE, std::ptr::null()) };
    if value.is_null() {
        return Err(fastra_core::Error::InvalidRange);
    }
    let value = unsafe { std::ffi::CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| fastra_core::Error::InvalidRange)?;
    text_operations::TitlecaseLocale::from_ctype(value)
}
