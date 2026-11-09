//! Definitionen werden privat gespeichert; Übernahme ändert nur den gebundenen Editor.
use super::*;
use crate::git_view::{background, column, label, output, scroll, window};
use fastra_core::Utf16Range;
use fastra_workflow::{
    self as workflow,
    store::{Library, Snapshot, Store},
    Definition, Error, Snippet, SnippetArchive, Step, Template, Workflow, WorkflowArchive,
};
use std::{collections::BTreeMap, path::PathBuf};

#[path = "workflow_tabs.rs"]
mod workflow_tabs;
const KINDS: &[(&str, &str, &str)] = &[
    ("replace", "Suchen und Ersetzen", "Find and replace"),
    (
        "titlecase",
        "Wortanfänge groß (Systemlocale)",
        "Titlecase (system locale)",
    ),
    (
        "sortAscending",
        "Zeilen sortieren ↑ (Textlocale)",
        "Sort lines ↑ (text locale)",
    ),
    (
        "sortDescending",
        "Zeilen sortieren ↓ (Textlocale)",
        "Sort lines ↓ (text locale)",
    ),
    (
        "removeDuplicateLines",
        "Doppelte Zeilen: erste behalten",
        "Duplicate lines: keep first",
    ),
    (
        "keepDuplicateLines",
        "Nur doppelte Zeilen behalten",
        "Keep duplicate lines",
    ),
    (
        "removeAllDuplicatedLines",
        "Alle mehrfachen Zeilen entfernen",
        "Remove all repeated lines",
    ),
    (
        "uppercase",
        "Großschrift (Systemlocale)",
        "Uppercase (system locale)",
    ),
    (
        "lowercase",
        "Kleinschrift (Systemlocale)",
        "Lowercase (system locale)",
    ),
    (
        "trimTrailing",
        "Nachlaufende Leerzeichen entfernen",
        "Trim trailing whitespace",
    ),
    (
        "zapGremlins",
        "Unsichtbare Störzeichen bereinigen",
        "Zap gremlins",
    ),
    ("reverseLines", "Zeilenfolge umkehren", "Reverse lines"),
    (
        "removeBlankLines",
        "Leere Zeilen entfernen",
        "Remove blank lines",
    ),
    (
        "joinLines",
        "Zeilen mit Leerzeichen verbinden",
        "Join lines with spaces",
    ),
    (
        "joinLinesTight",
        "Zeilen direkt verbinden",
        "Join lines tightly",
    ),
    ("prefixLines", "Zeilenpräfix", "Line prefix"),
    ("suffixLines", "Zeilensuffix", "Line suffix"),
    ("addLineNumbers", "Zeilen nummerieren", "Add line numbers"),
    (
        "removeLineNumbers",
        "Zeilennummern entfernen",
        "Remove line numbers",
    ),
    (
        "keepLinesMatching",
        "Nur passende Zeilen (Regex)",
        "Keep matching lines (regex)",
    ),
    (
        "deleteLinesMatching",
        "Passende Zeilen entfernen (Regex)",
        "Remove matching lines (regex)",
    ),
    (
        "normalizeSpaces",
        "Leerzeichen vereinheitlichen",
        "Normalize spaces",
    ),
    ("precomposeUnicode", "Unicode NFC", "Unicode NFC"),
    ("decomposeUnicode", "Unicode NFD", "Unicode NFD"),
    (
        "fourDDetokenize",
        "4D-Token-Suffixe entfernen",
        "Remove 4D token suffixes",
    ),
    (
        "fourDTokenizeCommands",
        "4D: Nur Befehle tokenisieren",
        "4D: Tokenize commands only",
    ),
    ("detab", "Tabs in Leerzeichen", "Tabs to spaces"),
    ("entab", "Leerzeichen in Tabs", "Spaces to tabs"),
    ("shiftRight", "Einrücken", "Indent"),
    ("shiftLeft", "Ausrücken", "Unindent"),
    ("hardWrap", "Harter Zeilenumbruch", "Hard wrap"),
    (
        "straightenQuotes",
        "Anführungszeichen begradigen",
        "Straighten quotes",
    ),
    (
        "educateQuotes",
        "Englische typografische Anführungszeichen",
        "English smart quotes",
    ),
    (
        "convertEscapeSequences",
        "Escape-Sequenzen umwandeln",
        "Convert escape sequences",
    ),
    (
        "exchangeCharacters",
        "Zeichen vertauschen",
        "Transpose characters",
    ),
    ("exchangeWords", "Wörter vertauschen", "Transpose words"),
    (
        "stripDiacriticals",
        "Diakritische Zeichen entfernen",
        "Strip diacriticals",
    ),
    (
        "addEmojiPresentation",
        "Emoji-Darstellung ergänzen",
        "Add emoji presentation",
    ),
    (
        "removeEmojiPresentation",
        "Emoji-Darstellung entfernen",
        "Remove emoji presentation",
    ),
];
pub(super) fn title(kind: &str, lang: Language) -> String {
    KINDS
        .iter()
        .find(|v| v.0 == kind)
        .map(|v| lang.text(v.1, v.2).into())
        .unwrap_or_else(|| format!("{}: {kind}", lang.text("Nicht unterstützt", "Unsupported")))
}
fn invalid_detail(detail: &str, lang: Language) -> String {
    if let Some(key) = detail.strip_prefix("archive field conflict: ") {
        return format!(
            "{} {key}",
            lang.text(
                "Zusatzfeld hat widersprüchliche Werte; Import vollständig abgelehnt:",
                "Additional field has conflicting values; the complete import was rejected:"
            )
        );
    }
    match detail {
        "workflow" => lang.text("Ein Ablauf braucht einen Namen bis 256 UTF-8-Bytes, 1–32 Schritte und mindestens einen aktiven Schritt.", "A workflow needs a name up to 256 UTF-8 bytes, 1–32 steps and at least one enabled step."),
        "step parameters" => lang.text("Ungültige Schrittkennung oder Parameter: Textfelder bis 4096 Bytes; Tab-/Einrückungsbreite 1–16; Umbruchspalte 1–10000.", "Invalid step ID or parameters: text fields up to 4096 bytes; tab/indent width 1–16; wrap column 1–10000."),
        "snippet" => lang.text("Ein Textbaustein braucht einen Namen bis 80 Zeichen ohne Steuerzeichen und eine nicht leere Vorlage.", "A snippet needs a name up to 80 characters without control characters and a non-empty template."),
        "{{Name}}" => lang.text("Platzhalter verwenden {{Name}} mit bis zu 64 Zeichen. Leere Namen, Klammern, Zeilenumbrüche und Steuerzeichen sind nicht erlaubt.", "Placeholders use {{Name}} with up to 64 characters. Empty names, braces, line breaks and control characters are not allowed."),
        "archive version/count" => lang.text("Erwartet wird JSON-Schema 1 mit höchstens 50 Definitionen.", "JSON schema 1 with at most 50 definitions is required."),
        "duplicate id" => lang.text("Die Kennungen in einer Sammlung müssen eindeutig sein.", "IDs in a collection must be unique."),
        "empty find" => lang.text("Der Suchtext fehlt.", "The search text is empty."),
        "empty line regex" => lang.text("Der Regex für den Zeilenfilter fehlt.", "The line filter regex is empty."),
        "titlecase locale required" => lang.text("Wortanfänge groß benötigt eine ausdrücklich bestimmte Text-Systemlocale. Es wurde nichts übernommen.", "Titlecase requires an explicitly determined system text locale. Nothing was applied."),
        "text locale required" => lang.text("Die Text-Systemlocale konnte nicht bestimmt werden. Es wurde nichts übernommen.", "The system text locale could not be determined. Nothing was applied."),
        "4D grapheme token" => lang.text("Der 4D-Bereich würde ein zusammengesetztes Unicode-Zeichen teilen. Bitte die Auswahl und Token-Suffixe prüfen. Es wurde nichts übernommen.", "The 4D range would split a composed Unicode character. Check the selection and token suffixes. Nothing was applied."),
        "grapheme selection" => lang.text("Die Auswahl darf zusammengesetzte Unicode-Zeichen nicht teilen.", "The selection must not split composed Unicode characters."),
        "private store permissions/type" => lang.text("Die private Sammlung muss diesem Konto gehören und darf keine Gruppen-/Fremdrechte, Symlinks, Hardlinks oder besonderen Dateitypen enthalten.", "The private collection must belong to this account and cannot allow group/other access, symlinks, hardlinks or special file types."),
        "library version" => lang.text("Die Version der privaten Sammlung wird nicht unterstützt.", "The private collection version is not supported."),
        "config directory" => lang.text("Kein absolutes Konfigurationsverzeichnis verfügbar.", "No absolute configuration directory is available."),
        "local file" => lang.text("Bitte eine lokale Datei wählen.", "Choose a local file."),
        _ => detail,
    }.to_string()
}
pub(super) fn message(error: &Error, lang: Language) -> String {
    match error {
        Error::Unsupported(fields) => format!("{} {}", lang.text(
            "Felder oder aktivierte Schritte werden noch nicht unterstützt; es wurde nichts übernommen:",
            "Fields or enabled steps are not supported yet; nothing was applied:",
        ), fields.join(", ")),
        Error::Limit => lang.text(
            "Größen-/Zeitgrenze erreicht. Abläufe: 32 Schritte, 4 MiB Text, 32 MiB Rechenvorschau, 64 MiB exakte Darstellung, 5 Sekunden. Bausteine: 16 KiB Vorlage/Feldwert, 32 Felder, 256 KiB Ergebnis. Archive: 1 MiB und 50 Definitionen. Keine Teilübernahme.",
            "Size/time limit reached. Workflows: 32 steps, 4 MiB text, 32 MiB computed preview, 64 MiB exact display, 5 seconds. Snippets: 16 KiB template/field value, 32 fields, 256 KiB result. Archives: 1 MiB and 50 definitions. No partial apply.",
        ).into(),
        Error::Stale => lang.text(
            "Dokument, Auswahl oder Sammlung hat sich geändert. Bitte neu laden oder die Vorschau neu berechnen. Es wurde nichts übernommen.",
            "Document, selection or collection changed. Reload or calculate a fresh preview. Nothing was applied.",
        ).into(),
        Error::Core(fastra_core::Error::Cancelled) => lang.text("Abgebrochen. Es wurde nichts übernommen.", "Cancelled. Nothing was applied.").into(),
        Error::Missing(name) => format!("{} {name}", lang.text("Fehlender Platzhalterwert:", "Missing placeholder value:")),
        Error::Invalid(detail) => format!("{} {}", lang.text("Ungültige Definition oder Sammlung:", "Invalid definition or collection:"), invalid_detail(detail, lang)),
        Error::Json(error) => format!("{} {error}", lang.text("Ungültiges JSON:", "Invalid JSON:")),
        Error::Io(error) => format!("{} {error}", lang.text("Sammlung oder Datei konnte nicht gelesen/gesichert werden:", "Could not read/save the collection or file:")),
        Error::Core(fastra_core::Error::Limit) => message(&Error::Limit, lang),
        Error::Core(fastra_core::Error::Regex {code,offset}) => format!("{} {offset} ({} {code}).",lang.text("Ungültiger regulärer Ausdruck an Position", "Invalid regular expression at position"),lang.text("Fehlercode", "error code")),
        Error::Core(fastra_core::Error::InvalidRange) => lang.text("Die Auswahl lässt sich nicht sicher zuordnen. Bitte die Auswahl prüfen und die Vorschau neu berechnen.","The selection cannot be mapped safely. Check the selection and calculate a fresh preview.").into(),
        Error::Core(error) => format!("{} {error}", lang.text("Textschritt fehlgeschlagen:", "Text step failed:")),
    }
}
fn config_path() -> Result<PathBuf, Error> {
    if let Some(path) = std::env::var_os("XDG_CONFIG_HOME") {
        let path = PathBuf::from(path);
        if path.is_absolute() {
            return Ok(path);
        }
    }
    let path = std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".config"))
        .filter(|path| path.is_absolute());
    path.ok_or_else(|| Error::Invalid("config directory".into()))
}
#[derive(Clone)]
enum Draft {
    Flow(Workflow),
    Snippet(Snippet),
}
#[derive(Clone)]
struct Target {
    pane: source_panes::Target,
    doc: Rc<Document>,
    source: String,
    revision: u64,
    range: Option<Utf16Range>,
}
struct DisplayPlan {
    pairs: Vec<(std::sync::Arc<str>, std::sync::Arc<str>)>,
}
struct Calculation {
    result: workflow::Preview,
    display: Option<DisplayPlan>,
}
struct Pending {
    target: Target,
    result: workflow::Preview,
    display: Option<DisplayPlan>,
    generation: u64,
}
struct View {
    ui: std::rc::Weak<Ui>,
    doc: std::rc::Weak<Document>,
    lang: Language,
    snippet: bool,
    snippet_layout: Option<snippet::Layout>,
    snippet_target: Option<snippet::Target>,
    window: gtk::Window,
    editor: gtk::Box,
    saved: gtk::DropDown,
    name: gtk::Entry,
    steps: gtk::ListBox,
    step_editor: gtk::Grid,
    kind: gtk::DropDown,
    argument: gtk::Entry,
    find: gtk::Entry,
    replacement: gtk::Entry,
    regex: gtk::CheckButton,
    case_sensitive: gtk::CheckButton,
    whole_word: gtk::CheckButton,
    literal: gtk::CheckButton,
    profile: gtk::FlowBox,
    tab_width: gtk::SpinButton,
    indent_width: gtk::SpinButton,
    uses_tabs: gtk::CheckButton,
    wrap_column: gtk::SpinButton,
    template: gtk::TextView,
    fields: gtk::Grid,
    fields_scroll: gtk::ScrolledWindow,
    values: RefCell<Vec<(String, gtk::TextView)>>,
    scope: gtk::DropDown,
    exact: gtk::CheckButton,
    stages: gtk::DropDown,
    before: gtk::TextView,
    after: gtk::TextView,
    summary: gtk::Label,
    status: gtk::Label,
    save: gtk::Button,
    new: gtk::Button,
    duplicate: gtk::Button,
    remove: gtk::Button,
    reload: gtk::Button,
    discard: gtk::Button,
    import: gtk::Button,
    export: gtk::Button,
    calculate: gtk::Button,
    all_tabs: gtk::Button,
    disk: gtk::MenuButton,
    apply: gtk::Button,
    cancel_button: gtk::Button,
    snapshot: RefCell<Option<Snapshot>>,
    draft: RefCell<Option<Draft>>,
    pending: RefCell<Option<Pending>>,
    selected: Cell<Option<usize>>,
    selected_step: Cell<Option<usize>>,
    dirty: Cell<bool>,
    busy: Cell<bool>,
    preview_job: Cell<bool>,
    updating: Cell<bool>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    closed: Cell<bool>,
    config: PathBuf,
}
fn entry() -> gtk::Entry {
    gtk::Entry::builder().hexpand(true).max_length(4096).build()
}
fn attach(grid: &gtk::Grid, row: i32, text: &str, widget: &impl IsA<gtk::Widget>) {
    let l = label(text);
    grid.attach(&l, 0, row, 1, 1);
    grid.attach(widget, 1, row, 1, 1);
}
pub fn show(ui: &Rc<Ui>, snippet: bool) {
    if snippet {
        snippet::open(ui);
    } else {
        show_bound(ui, None);
    }
}
fn show_bound(ui: &Rc<Ui>, snippet_target: Option<snippet::Target>) {
    let snippet = snippet_target.is_some();
    if snippet {
        if let Some(existing) = VIEWS.with(|views| {
            views
                .borrow()
                .iter()
                .filter_map(std::rc::Weak::upgrade)
                .find(|v| {
                    v.snippet
                        && !v.closed.get()
                        && v.ui.upgrade().is_some_and(|owner| Rc::ptr_eq(&owner, ui))
                })
        }) {
            existing.window.present();
            return;
        }
    }
    let Some(doc) = ui.active() else {
        return;
    };
    if !snippet && !ui.source_edit_allowed(&doc) {
        return;
    }
    let config = match config_path() {
        Ok(path) => path,
        Err(e) => {
            ui.status.set_text(&message(&e, ui.lang));
            return;
        }
    };
    let lang = ui.lang;
    let window = window(
        ui,
        if snippet {
            lang.text("Textbausteine", "Text snippets")
        } else {
            lang.text("Gespeicherte Textabläufe", "Saved text workflows")
        },
        false,
    );
    window.set_default_size(1180, 900);
    window.set_size_request(860, 760);
    let root = column();
    root.set_spacing(8);
    let note = label(&format!(
        "{} {} · {}",
        lang.text("Ziel:", "Target:"),
        doc.name,
        lang.text(
            "Übernahme ändert nur dieses Dokument im Editor. Speichern bleibt ein eigener Schritt.",
            "Apply changes only this document in the editor. Saving is a separate step."
        )
    ));
    if !snippet {
        root.append(&note);
    }
    let saved = gtk::DropDown::from_strings(&[]);
    saved.set_hexpand(true);
    let new = gtk::Button::with_label(lang.text("Neu", "New"));
    let duplicate = gtk::Button::with_label(lang.text("Duplizieren", "Duplicate"));
    let remove = gtk::Button::with_label(lang.text("Löschen", "Delete"));
    let reload = gtk::Button::with_label(lang.text("Neu laden", "Reload"));
    let discard = gtk::Button::with_label(lang.text("Entwurf verwerfen", "Discard draft"));
    let import = gtk::Button::with_label(lang.text("Importieren …", "Import …"));
    let export =
        gtk::Button::with_label(lang.text("Sammlung exportieren …", "Export collection …"));
    export.set_tooltip_text(Some(lang.text("Exportiert die hier geladene gespeicherte Sammlung. Ungesicherte Entwürfe zuerst speichern.","Exports the saved collection loaded in this window. Save unsaved drafts first.")));
    let collection = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(3)
        .max_children_per_line(5)
        .column_spacing(6)
        .row_spacing(4)
        .build();
    collection.set_vexpand(false);
    if !snippet {
        collection.insert(&saved, -1);
    }
    for button in [
        &new, &duplicate, &remove, &reload, &discard, &import, &export,
    ] {
        if !snippet {
            collection.insert(button, -1);
        }
    }
    if !snippet {
        root.append(&collection);
    }
    let editor = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let name = entry();
    name.set_max_length(256);
    let save = gtk::Button::with_label(if snippet {
        lang.text("Speichern", "Save")
    } else {
        lang.text("Definition speichern", "Save definition")
    });
    let name_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    if !snippet {
        name_row.append(&label(lang.text("Name", "Name")));
    } else {
        name.set_placeholder_text(Some(lang.text("Name des Textbausteins", "Snippet name")));
    }
    name_row.append(&name);
    name_row.append(&save);
    editor.append(&name_row);
    let steps = gtk::ListBox::new();
    steps.set_selection_mode(gtk::SelectionMode::Single);
    let step_editor = gtk::Grid::builder()
        .column_spacing(10)
        .row_spacing(6)
        .hexpand(true)
        .build();
    let kinds: Vec<_> = KINDS.iter().map(|v| lang.text(v.1, v.2)).collect();
    let kind = gtk::DropDown::from_strings(&kinds);
    kind.set_hexpand(true);
    let argument = entry();
    let find = entry();
    let replacement = entry();
    let regex = gtk::CheckButton::with_label("Regex");
    let case_sensitive =
        gtk::CheckButton::with_label(lang.text("Groß-/Kleinschreibung", "Case sensitive"));
    let whole_word =
        gtk::CheckButton::with_label(lang.text("Nur ganze Wörter", "Whole words only"));
    let literal =
        gtk::CheckButton::with_label(lang.text("Platzhalter wörtlich", "Literal wildcards"));
    attach(&step_editor, 0, lang.text("Schrittart", "Step type"), &kind);
    attach(
        &step_editor,
        1,
        lang.text("Argument / Zeilen-Regex", "Argument / line regex"),
        &argument,
    );
    attach(&step_editor, 2, lang.text("Suchen", "Find"), &find);
    attach(
        &step_editor,
        3,
        lang.text("Ersetzen", "Replace"),
        &replacement,
    );
    let flags = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(2)
        .max_children_per_line(4)
        .column_spacing(6)
        .row_spacing(4)
        .build();
    for b in [&regex, &case_sensitive, &whole_word, &literal] {
        flags.insert(b, -1);
    }
    step_editor.attach(&flags, 0, 4, 2, 1);
    let profile = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(8)
        .row_spacing(4)
        .build();
    let tab_width = gtk::SpinButton::with_range(1., 16., 1.);
    let indent_width = gtk::SpinButton::with_range(1., 16., 1.);
    let wrap_column = gtk::SpinButton::with_range(1., 10000., 1.);
    let uses_tabs =
        gtk::CheckButton::with_label(lang.text("Mit Tabs einrücken", "Indent with tabs"));
    for (name, spin) in [
        (lang.text("Tabbreite", "Tab width"), &tab_width),
        (lang.text("Einrückung", "Indent width"), &indent_width),
        (lang.text("Umbruchspalte", "Wrap column"), &wrap_column),
    ] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let caption = label(name);
        caption.set_wrap(false);
        row.append(&caption);
        row.append(spin);
        profile.insert(&row, -1);
    }
    profile.insert(&uses_tabs, -1);
    step_editor.attach(&profile, 0, 5, 2, 1);
    let flow_area = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let step_column = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let step_scroll = scroll(&steps);
    step_scroll.set_vexpand(false);
    step_scroll.set_min_content_height(130);
    step_scroll.set_min_content_width(250);
    step_column.append(&step_scroll);
    let step_buttons = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let add = gtk::Button::with_label(lang.text("+ Schritt", "+ Step"));
    let up = gtk::Button::with_label("↑");
    let down = gtk::Button::with_label("↓");
    let delete = gtk::Button::with_label("−");
    up.set_tooltip_text(Some(lang.text("Schritt nach oben", "Move step up")));
    down.set_tooltip_text(Some(lang.text("Schritt nach unten", "Move step down")));
    delete.set_tooltip_text(Some(lang.text("Schritt entfernen", "Remove step")));
    for b in [&add, &up, &down, &delete] {
        step_buttons.append(b);
    }
    step_column.append(&step_buttons);
    flow_area.append(&step_column);
    flow_area.append(&step_editor);
    flow_area.set_vexpand(false);
    flow_area.set_visible(!snippet);
    editor.append(&flow_area);
    let template = gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    let template_scroll = scroll(&template);
    template_scroll.set_min_content_height(90);
    template_scroll.set_has_frame(true);
    template_scroll.set_vexpand(false);
    template_scroll.set_visible(snippet);
    let template_label = label(lang.text(
        "Vorlage mit {{Name}}. Wiederholte Namen teilen einen Feldwert.",
        "Template with {{Name}}. Repeated names share one field value.",
    ));
    template_label.set_visible(snippet);
    if snippet {
        template_label.set_text(lang.text("Vorlage", "Template"));
        template_label.add_css_class("heading");
    }
    editor.append(&template_label);
    template_scroll.set_max_content_height(170);
    editor.append(&template_scroll);
    if snippet {
        editor.append(&snippet::hint(lang.text("Platzhalter: {{Name}}. Wiederholte Namen teilen ein Feld. Feldwerte werden wörtlich eingesetzt; Return fügt einen Zeilenumbruch ein.","Placeholders: {{Name}}. Repeated names share one field. Values are inserted literally; Return adds a line break.")));
    }
    let fields = gtk::Grid::builder()
        .column_spacing(8)
        .row_spacing(6)
        .hexpand(true)
        .build();
    let field_scroll = scroll(&fields);
    field_scroll.set_min_content_height(80);
    field_scroll.set_max_content_height(-1);
    field_scroll.set_vexpand(snippet);
    field_scroll.set_visible(snippet);
    editor.append(&field_scroll);
    if snippet {
        editor.set_vexpand(true);
    }
    if !snippet {
        root.append(&editor);
    }
    let scope = gtk::DropDown::from_strings(&[
        lang.text("Ganzes Dokument", "Whole document"),
        lang.text("Aktuelle Auswahl", "Current selection"),
    ]);
    if snippet {
        scope.set_selected(1);
        scope.set_sensitive(false);
    }
    let exact = gtk::CheckButton::with_label(lang.text("Exakte Zeichen", "Exact characters"));
    exact.set_tooltip_text(Some(lang.text(
        "Zeigt Backslash, Zeilenenden, Steuerzeichen und Nicht-ASCII als Escapes. Danach die Vorschau neu berechnen.",
        "Shows backslashes, line endings, controls and non-ASCII as escapes. Calculate a fresh preview afterwards.",
    )));
    let calculate = gtk::Button::with_label(lang.text("Vorschau berechnen", "Calculate preview"));
    let all_tabs =
        gtk::Button::with_label(lang.text("Ablauf auf alle Tabs …", "Workflow on all tabs …"));
    all_tabs.set_visible(!snippet);
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let apply = gtk::Button::with_label(lang.text("Vorschau übernehmen", "Apply preview"));
    apply.set_sensitive(false);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    if !snippet {
        actions.append(&scope);
    }
    for b in [&calculate, &cancel_button, &apply] {
        if !snippet {
            actions.append(b);
        }
    }
    if !snippet {
        actions.append(&exact);
    }
    if !snippet {
        root.append(&actions);
    }
    let disk = gtk::MenuButton::builder()
        .label(lang.text("Ablauf auf Dateien …", "Workflow on files …"))
        .build();
    disk.set_visible(!snippet);
    let disk_menu = gio::Menu::new();
    for (action, de, en) in [
        ("file", "Gespeicherte aktive Datei …", "Saved active file …"),
        (
            "folder",
            "Dateien aus einem Ordner …",
            "Files from a folder …",
        ),
        (
            "project",
            "Dateien aus dem Projekt …",
            "Files from the project …",
        ),
    ] {
        disk_menu.append(
            Some(lang.text(de, en)),
            Some(&format!("workflowdisk.{action}")),
        );
    }
    disk.set_menu_model(Some(&disk_menu));
    let scopes = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(2)
        .column_spacing(6)
        .row_spacing(6)
        .build();
    scopes.insert(&all_tabs, -1);
    scopes.insert(&disk, -1);
    if !snippet {
        root.append(&scopes);
    }
    let stages = gtk::DropDown::from_strings(&[lang.text(
        "Endergebnis (ganzes Dokument)",
        "Final result (whole document)",
    )]);
    if !snippet {
        root.append(&stages);
    }
    let summary=label(lang.text("Alle aktivierten Schritte werden vollständig berechnet. Wirkungslose Filter löschen niemals den gesamten Inhalt.","All enabled steps are calculated completely. Filters never remove the entire contents."));
    if !snippet {
        root.append(&summary);
    }
    let previews = gtk::Paned::new(gtk::Orientation::Horizontal);
    let before = output();
    let after = output();
    for (side, view) in [(true, &before), (false, &after)]
        .into_iter()
        .filter(|_| !snippet)
    {
        let pane = gtk::Box::new(gtk::Orientation::Vertical, 4);
        pane.append(&label(if side {
            lang.text("Vorher · vollständiger Text", "Before · full text")
        } else {
            lang.text("Nachher · vollständiger Text", "After · full text")
        }));
        pane.append(&scroll(view));
        if side {
            previews.set_start_child(Some(&pane));
        } else {
            previews.set_end_child(Some(&pane));
        }
    }
    previews.set_resize_start_child(true);
    previews.set_resize_end_child(true);
    previews.set_shrink_start_child(true);
    previews.set_shrink_end_child(true);
    previews.set_vexpand(true);
    if !snippet {
        root.append(&previews);
    }
    let status = label(lang.text("Sammlung wird geladen …", "Loading collection …"));
    let status_scroll = scroll(&status);
    status_scroll.set_min_content_height(40);
    status_scroll.set_max_content_height(80);
    status_scroll.set_propagate_natural_height(true);
    status_scroll.set_vexpand(false);
    if !snippet {
        root.append(&status_scroll);
    }
    if snippet {
        status_scroll.set_min_content_height(0);
        status_scroll.set_visible(!status.text().is_empty());
        let wrapper = status_scroll.downgrade();
        status.connect_label_notify(move |status| {
            if let Some(wrapper) = wrapper.upgrade() {
                wrapper.set_visible(!status.text().is_empty());
            }
        });
    }
    let snippet_layout = snippet.then(|| {
        snippet::Layout::new(
            lang,
            &editor,
            &after,
            &status_scroll,
            &apply,
            [&new, &duplicate, &reload, &import, &export, &remove],
        )
    });
    window.set_child(Some(
        snippet_layout.as_ref().map_or(&root, |layout| &layout.root),
    ));
    let view = Rc::new(View {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(&doc),
        lang,
        snippet,
        snippet_layout,
        snippet_target,
        window: window.clone(),
        editor,
        saved,
        name,
        steps,
        step_editor,
        kind,
        profile,
        tab_width,
        indent_width,
        uses_tabs,
        wrap_column,
        argument,
        find,
        replacement,
        regex,
        case_sensitive,
        whole_word,
        literal,
        template,
        fields,
        fields_scroll: field_scroll,
        values: RefCell::new(Vec::new()),
        scope,
        exact,
        stages,
        before,
        after,
        summary,
        status,
        save,
        new,
        duplicate,
        remove,
        reload,
        discard,
        import,
        export,
        calculate,
        all_tabs,
        disk,
        apply,
        cancel_button,
        snapshot: RefCell::new(None),
        draft: RefCell::new(None),
        pending: RefCell::new(None),
        selected: Cell::new(None),
        selected_step: Cell::new(None),
        dirty: Cell::new(false),
        busy: Cell::new(false),
        preview_job: Cell::new(false),
        updating: Cell::new(false),
        generation: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        closed: Cell::new(false),
        config,
    });
    #[cfg(debug_assertions)]
    TEST_VIEW.with(|slot| *slot.borrow_mut() = Some(Rc::downgrade(&view)));
    VIEWS.with(|views| {
        let mut views = views.borrow_mut();
        views.retain(|view| view.upgrade().is_some_and(|view| !view.closed.get()));
        views.push(Rc::downgrade(&view));
    });
    view.connect(add, up, down, delete);
    if snippet {
        snippet::connect(&view);
    }
    view.reload_collection();
    let weak = Rc::downgrade(&view);
    window.connect_close_request(move |_| {
        let Some(view) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if view.snippet && view.busy.get() {
            return glib::Propagation::Stop;
        }
        if view.dirty.get() {
            if view.snippet {
                snippet::protect(&view, |view| view.window.close());
                return glib::Propagation::Stop;
            }
            let dialog = gtk::AlertDialog::builder()
                .message(view.lang.text(
                    "Ungesicherten Entwurf verwerfen?",
                    "Discard the unsaved draft?",
                ))
                .buttons([
                    view.lang.text("Abbrechen", "Cancel"),
                    view.lang.text("Entwurf verwerfen", "Discard draft"),
                ])
                .cancel_button(0)
                .default_button(0)
                .build();
            let weak = Rc::downgrade(&view);
            dialog.choose(
                Some(&view.window),
                None::<&gio::Cancellable>,
                move |result| {
                    if result == Ok(1) {
                        if let Some(view) = weak.upgrade() {
                            view.dirty.set(false);
                            view.window.close();
                        }
                    }
                },
            );
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    crate::git_view::hold(&window, view.clone(), |view| {
        view.closed.set(true);
        view.cancel.borrow().cancel();
    });
    window.present();
    let weak = previews.downgrade();
    glib::idle_add_local_once(move || {
        if let Some(pane) = weak.upgrade() {
            pane.set_position(pane.width() / 2);
        }
    });
}
fn clicked(button: &gtk::Button, view: &Rc<View>, action: impl Fn(&Rc<View>) + 'static) {
    let weak = Rc::downgrade(view);
    button.connect_clicked(move |_| {
        if let Some(view) = weak.upgrade() {
            action(&view)
        }
    });
}
impl View {
    fn error(&self, error: Error) {
        self.status.set_text(&message(&error, self.lang));
    }
    fn refresh(&self) {
        if self.snippet {
            snippet::refresh(self);
            return;
        }
        let ready = self.snapshot.borrow().is_some() && !self.busy.get();
        let dirty = self.dirty.get();
        self.editor
            .set_sensitive(ready && self.draft.borrow().is_some());
        self.saved.set_sensitive(ready && !dirty);
        self.new.set_sensitive(ready && !dirty);
        self.duplicate
            .set_sensitive(ready && !dirty && self.draft.borrow().is_some());
        self.remove
            .set_sensitive(ready && !dirty && self.selected.get().is_some());
        self.reload.set_sensitive(!self.busy.get() && !dirty);
        self.discard.set_sensitive(ready && dirty);
        self.import.set_sensitive(ready && !dirty);
        self.export.set_sensitive(ready);
        self.save.set_sensitive(ready && dirty);
        self.calculate
            .set_sensitive(ready && !dirty && self.draft.borrow().is_some());
        self.disk.set_sensitive(
            ready
                && !dirty
                && self
                    .draft
                    .borrow()
                    .as_ref()
                    .is_some_and(|draft| matches!(draft, Draft::Flow(_))),
        );
        self.all_tabs.set_sensitive(
            ready
                && !dirty
                && !self.snippet
                && matches!(*self.draft.borrow(), Some(Draft::Flow(_))),
        );
        self.scope.set_sensitive(ready && !self.snippet);
        self.apply.set_sensitive(
            ready
                && !dirty
                && self.pending.borrow().as_ref().is_some_and(|pending| {
                    let output = pending.result.output();
                    output != pending.target.source && !output.contains('\0')
                }),
        );
        self.cancel_button
            .set_sensitive(self.busy.get() && self.preview_job.get());
    }
    fn invalidate(&self) {
        self.generation.set(self.generation.get() + 1);
        self.cancel.borrow().cancel();
        self.pending.borrow_mut().take();
        self.apply.set_sensitive(false);
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
    }
    fn dirty(&self) {
        if self.updating.get() {
            return;
        }
        self.dirty.set(true);
        self.invalidate();
        self.status.set_text(if self.snippet {
            ""
        } else {
            self.lang.text(
                "Entwurf geändert. Bitte die Definition vor der Vorschau speichern.",
                "Draft changed. Save the definition before calculating a preview.",
            )
        });
        self.refresh();
    }
    fn run<T: Send + 'static>(
        self: &Rc<Self>,
        work: impl FnOnce() -> Result<T, Error> + Send + 'static,
        done: impl FnOnce(&Rc<Self>, T) + 'static,
    ) {
        self.busy.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        let lang = self.lang;
        background(
            move || work().map_err(|e| message(&e, lang)),
            move |result| {
                let Some(view) = weak.upgrade().filter(|v| !v.closed.get()) else {
                    return;
                };
                view.busy.set(false);
                view.preview_job.set(false);
                match result {
                    Ok(value) => done(&view, value),
                    Err(error) => {
                        if let Some(layout) = &view.snippet_layout {
                            layout.after_save.borrow_mut().take();
                        }
                        view.status.set_text(&error);
                    }
                }
                if !view.closed.get() {
                    view.refresh();
                }
            },
        );
    }
    fn connect(
        self: &Rc<Self>,
        add: gtk::Button,
        up: gtk::Button,
        down: gtk::Button,
        delete: gtk::Button,
    ) {
        clicked(&self.new, self, |v| {
            snippet::protect(v, |v| v.new_draft(false))
        });
        clicked(&self.duplicate, self, |v| {
            snippet::protect(v, |v| v.new_draft(true))
        });
        clicked(&self.discard, self, |v| v.choose(v.selected.get()));
        clicked(&self.reload, self, |v| {
            snippet::protect(v, |v| v.reload_collection())
        });
        clicked(&self.save, self, |v| v.save_definition());
        clicked(&self.remove, self, |v| {
            snippet::protect(v, |v| v.remove_definition())
        });
        clicked(&self.calculate, self, |v| v.calculate_preview());
        clicked(&self.all_tabs, self, |v| {
            if v.busy.get() || v.dirty.get() || v.closed.get() {
                return;
            }
            if let (Some(ui), Some(Draft::Flow(flow))) = (v.ui.upgrade(), v.draft.borrow().clone())
            {
                if let Err(error) = flow.validate() {
                    v.error(error);
                    return;
                }
                workflow_tabs::open(&ui, flow);
            }
        });
        let actions = gio::SimpleActionGroup::new();
        for (name, scope) in [("file", 0), ("folder", 1), ("project", 2)] {
            let action = gio::SimpleAction::new(name, None);
            let weak = Rc::downgrade(self);
            action.connect_activate(move |_, _| {
                if let Some(v) = weak.upgrade() {
                    if v.busy.get() || v.dirty.get() || v.closed.get() {
                        return;
                    }
                    let unknown = v
                        .snapshot
                        .borrow()
                        .as_ref()
                        .map(|snapshot| {
                            snapshot
                                .library
                                .workflows
                                .extra
                                .keys()
                                .map(|key| format!("archive.{key}"))
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    if !unknown.is_empty() {
                        v.error(Error::Unsupported(unknown));
                        return;
                    }
                    if let (Some(ui), Some(Draft::Flow(flow))) =
                        (v.ui.upgrade(), v.draft.borrow().clone())
                    {
                        if let Err(error) = flow.validate() {
                            v.error(error);
                            return;
                        }
                        crate::folder::open_workflow(&ui, flow, scope);
                    }
                }
            });
            actions.add_action(&action);
        }
        self.window
            .insert_action_group("workflowdisk", Some(&actions));
        clicked(&self.apply, self, |v| v.apply_preview());
        clicked(&self.cancel_button, self, |v| {
            v.invalidate();
            v.status.set_text(
                v.lang
                    .text("Abbruch angefordert …", "Cancellation requested …"),
            );
        });
        clicked(&self.import, self, |v| {
            snippet::protect(v, |v| v.import_file())
        });
        clicked(&self.export, self, |v| v.export_file());
        clicked(&add, self, |v| v.change_steps(0));
        clicked(&up, self, |v| v.change_steps(-1));
        clicked(&down, self, |v| v.change_steps(1));
        clicked(&delete, self, |v| v.change_steps(2));
        let weak = Rc::downgrade(self);
        self.saved.connect_selected_notify(move |drop| {
            if let Some(v) = weak.upgrade() {
                if !v.updating.get() && !v.dirty.get() {
                    v.choose(
                        (drop.selected() != gtk::INVALID_LIST_POSITION)
                            .then_some(drop.selected() as usize),
                    );
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.name.connect_changed(move |entry| {
            if let Some(v) = weak.upgrade() {
                if v.updating.get() {
                    return;
                }
                if let Some(draft) = v.draft.borrow_mut().as_mut() {
                    match draft {
                        Draft::Flow(f) => f.name = entry.text().into(),
                        Draft::Snippet(s) => s.name = entry.text().into(),
                    }
                }
                v.dirty();
            }
        });
        for (entry, index) in [(&self.argument, 0), (&self.find, 1), (&self.replacement, 2)] {
            let weak = Rc::downgrade(self);
            entry.connect_changed(move |entry| {
                if let Some(v) = weak.upgrade() {
                    if v.updating.get() {
                        return;
                    }
                    if let Some(Draft::Flow(flow)) = v.draft.borrow_mut().as_mut() {
                        if let Some(step) =
                            v.selected_step.get().and_then(|i| flow.steps.get_mut(i))
                        {
                            match index {
                                0 => step.argument = entry.text().into(),
                                1 => step.find = entry.text().into(),
                                _ => step.replacement = entry.text().into(),
                            }
                        }
                    }
                    v.dirty();
                }
            });
        }
        for (button, index) in [
            (&self.regex, 0),
            (&self.case_sensitive, 1),
            (&self.whole_word, 2),
            (&self.literal, 3),
            (&self.uses_tabs, 4),
        ] {
            let weak = Rc::downgrade(self);
            button.connect_toggled(move |button| {
                if let Some(v) = weak.upgrade() {
                    if v.updating.get() {
                        return;
                    }
                    if let Some(Draft::Flow(flow)) = v.draft.borrow_mut().as_mut() {
                        if let Some(step) =
                            v.selected_step.get().and_then(|i| flow.steps.get_mut(i))
                        {
                            match index {
                                0 => step.regex = button.is_active(),
                                1 => step.case_sensitive = button.is_active(),
                                2 => step.whole_word = button.is_active(),
                                3 => step.literal_wildcard = button.is_active(),
                                _ => step.uses_tabs = button.is_active(),
                            }
                        }
                    }
                    v.dirty();
                    v.render_step();
                }
            });
        }
        for (spin, index) in [
            (&self.tab_width, 0),
            (&self.indent_width, 1),
            (&self.wrap_column, 2),
        ] {
            let weak = Rc::downgrade(self);
            spin.connect_value_changed(move |spin| {
                if let Some(v) = weak.upgrade() {
                    if v.updating.get() {
                        return;
                    }
                    if let Some(Draft::Flow(flow)) = v.draft.borrow_mut().as_mut() {
                        if let Some(step) =
                            v.selected_step.get().and_then(|i| flow.steps.get_mut(i))
                        {
                            let value = spin.value_as_int() as usize;
                            match index {
                                0 => step.tab_width = value,
                                1 => step.indent_width = value,
                                _ => step.wrap_column = value,
                            }
                        }
                    }
                    v.dirty();
                }
            });
        }
        let weak = Rc::downgrade(self);
        self.kind.connect_selected_notify(move |drop| {
            if let Some(v) = weak.upgrade() {
                if v.updating.get() {
                    return;
                }
                if let Some(kind) = KINDS.get(drop.selected() as usize) {
                    if let Some(Draft::Flow(flow)) = v.draft.borrow_mut().as_mut() {
                        if let Some(step) =
                            v.selected_step.get().and_then(|i| flow.steps.get_mut(i))
                        {
                            step.kind = kind.0.into();
                        }
                    }
                    if matches!(
                        kind.0,
                        "precomposeUnicode"
                            | "decomposeUnicode"
                            | "addEmojiPresentation"
                            | "removeEmojiPresentation"
                    ) {
                        v.exact.set_active(true);
                    }
                    v.dirty();
                    v.render_steps();
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.steps.connect_row_selected(move |_, row| {
            if let Some(v) = weak.upgrade() {
                if !v.updating.get() {
                    v.selected_step.set(row.map(|r| r.index() as usize));
                    v.render_step();
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.template
            .buffer()
            .connect_insert_text(move |buffer, _, text| {
                if let Some(view) = weak.upgrade() {
                    if !view.updating.get()
                        && (text.len() > 16 * 1024
                            || buffer
                                .text(&buffer.start_iter(), &buffer.end_iter(), true)
                                .len()
                                + text.len()
                                > 16 * 1024)
                    {
                        buffer.stop_signal_emission_by_name("insert-text");
                        view.status.set_text(view.lang.text(
                            "Vorlage zu groß: höchstens 16 KiB.",
                            "Template too large: at most 16 KiB.",
                        ));
                    }
                }
            });
        let weak = Rc::downgrade(self);
        self.template.buffer().connect_changed(move |buffer| {
            if let Some(v) = weak.upgrade() {
                if v.updating.get() {
                    return;
                }
                if let Some(Draft::Snippet(snippet)) = v.draft.borrow_mut().as_mut() {
                    snippet.template = buffer
                        .text(&buffer.start_iter(), &buffer.end_iter(), true)
                        .into();
                }
                v.dirty();
                v.render_fields();
            }
        });
        let weak = Rc::downgrade(self);
        self.scope.connect_selected_notify(move |_| {
            if let Some(v) = weak.upgrade() {
                v.invalidate();
                v.refresh();
            }
        });
        let weak = Rc::downgrade(self);
        self.exact.connect_toggled(move |_| {
            if let Some(view) = weak.upgrade() {
                if view.updating.get() {
                    return;
                }
                view.invalidate();
                view.status.set_text(view.lang.text(
                    "Darstellung geändert. Die Vorschau neu berechnen.",
                    "Display changed. Calculate a fresh preview.",
                ));
                view.refresh();
            }
        });
        let weak = Rc::downgrade(self);
        self.stages.connect_selected_notify(move |_| {
            if let Some(v) = weak.upgrade() {
                if !v.updating.get() {
                    v.show_stage();
                }
            }
        });
        if let Some(doc) = self.doc.upgrade() {
            let weak = Rc::downgrade(self);
            doc.buffer.connect_changed(move |_| {
                if let Some(v) = weak.upgrade() {
                    if v.pending.borrow().is_some() || v.preview_job.get() {
                        v.invalidate();
                        v.status.set_text(v.lang.text(
                            "Dokument geändert. Bitte die Vorschau neu berechnen.",
                            "Document changed. Calculate a fresh preview.",
                        ));
                    }
                }
            });
        }
    }
}

#[cfg(debug_assertions)]
thread_local! {static TEST_VIEW: RefCell<Option<std::rc::Weak<View>>> = const { RefCell::new(None) };}
#[cfg(debug_assertions)]
mod extended_selftest;
#[cfg(debug_assertions)]
mod four_d_selftest;
#[cfg(debug_assertions)]
pub fn run_four_d_selftest(ui: Rc<Ui>) {
    four_d_selftest::run(ui);
}
#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub fn run_extended_selftest(ui: Rc<Ui>) {
    extended_selftest::run(ui);
}
#[cfg(debug_assertions)]
pub fn run_selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_SNIPPET_SELFTEST").is_some() {
        snippet::selftest::start(ui);
        return;
    }
    if std::env::var_os("FASTRA_WORKFLOW_DISK_SELFTEST").is_some() {
        disk_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_WORKFLOW_TABS_SELFTEST").is_some() {
        workflow_tabs::selftest(ui);
    } else {
        selftest::run(ui);
    }
}

mod archive;
mod definitions;
mod preview;
mod snippet;

thread_local! {static VIEWS: RefCell<Vec<std::rc::Weak<View>>> = const { RefCell::new(Vec::new()) };}
pub fn prevent_close(ui: &Ui) -> bool {
    let draft = VIEWS.with(|views| {
        views
            .borrow()
            .iter()
            .filter_map(std::rc::Weak::upgrade)
            .find(|view| {
                !view.closed.get()
                    && view.dirty.get()
                    && view
                        .ui
                        .upgrade()
                        .is_some_and(|owner| owner.window == ui.window)
            })
    });
    if let Some(view) = draft {
        view.status.set_text(view.lang.text(
            "Vor dem Schließen den Entwurf speichern oder ausdrücklich verwerfen. Danach das Hauptfenster erneut schließen.",
            "Save or explicitly discard the draft before closing. Then close the main window again.",
        ));
        view.window.present();
        true
    } else {
        false
    }
}

mod display;

#[cfg(debug_assertions)]
mod titlecase_selftest;
#[cfg(debug_assertions)]
pub fn run_titlecase_selftest(ui: Rc<Ui>) {
    titlecase_selftest::run(ui);
}

#[cfg(debug_assertions)]
#[path = "workflow_disk_entry_test.rs"]
mod disk_selftest;
