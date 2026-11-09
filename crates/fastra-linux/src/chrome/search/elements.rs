use super::*;
type Element = (&'static str, &'static str, &'static str, &'static str);
type Category = (&'static str, &'static str, &'static [Element]);
const CATEGORIES: &[Category] = &[
    (
        "Anker",
        "Anchors",
        &[
            ("^", "^", "Zeilenanfang", "Start of line"),
            ("$", "$", "Zeilenende", "End of line"),
            (r"\b", r"\b", "Wortgrenze", "Word boundary"),
            (r"\B", r"\B", "Keine Wortgrenze", "Not a word boundary"),
        ],
    ),
    (
        "Zeichenklassen",
        "Character classes",
        &[
            (r"\d", r"\d", "Eine Ziffer 0–9", "A digit 0–9"),
            (r"\D", r"\D", "Keine Ziffer", "Not a digit"),
            (
                r"\w",
                r"\w",
                "Wortzeichen (Buchstabe, Ziffer, _)",
                "Word character (letter, digit, _)",
            ),
            (r"\W", r"\W", "Kein Wortzeichen", "Not a word character"),
            (
                r"\s",
                r"\s",
                "Leerraum (Space, Tab, Umbruch)",
                "Whitespace (space, tab, newline)",
            ),
            (r"\S", r"\S", "Kein Leerraum", "Not whitespace"),
            (".", ".", "Ein beliebiges Zeichen", "Any character"),
        ],
    ),
    (
        "Zeichengruppen",
        "Character sets",
        &[
            (
                "[abc]",
                "[abc]",
                "Eines der Zeichen in der Klammer",
                "One of the enclosed characters",
            ),
            (
                "[^abc]",
                "[^abc]",
                "Keines der Zeichen in der Klammer",
                "None of the enclosed characters",
            ),
            (
                "[a-z]",
                "[a-z]",
                "Ein Zeichen aus dem Bereich",
                "A character in the range",
            ),
        ],
    ),
    (
        "Quantifizierer",
        "Quantifiers",
        &[
            ("*", "*", "Null- oder mehrmals", "Zero or more times"),
            ("+", "+", "Ein- oder mehrmals", "One or more times"),
            (
                "?",
                "?",
                "Optional (null- oder einmal)",
                "Optional (zero or one)",
            ),
            ("{n}", "{1}", "Genau n-mal", "Exactly n times"),
            ("{n,m}", "{1,3}", "n- bis m-mal", "n to m times"),
        ],
    ),
    (
        "Gruppen",
        "Groups",
        &[
            (
                "(…)",
                "()",
                "Capture-Gruppe (für $1, $2 …)",
                "Capture group (for $1, $2 …)",
            ),
            (
                "(?:…)",
                "(?:)",
                "Gruppe ohne Erfassung",
                "Non-capturing group",
            ),
            ("|", "|", "Oder (Alternative)", "Or (alternative)"),
        ],
    ),
];
pub(super) fn picker(ui: &Rc<Ui>, field: &gtk::Entry) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder()
        .icon_name("fastra-plus-circle-symbolic")
        .tooltip_text(
            ui.lang
                .text("RegEx-Element einfügen", "Insert regex element"),
        )
        .build();
    button.add_css_class("chrome-icon");
    let popover = gtk::Popover::new();
    let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
    root.set_margin_top(14);
    root.set_margin_bottom(14);
    root.set_margin_start(14);
    root.set_margin_end(14);
    for &(de, en, elements) in CATEGORIES {
        let title = gtk::Label::new(Some(ui.lang.text(de, en)));
        title.set_xalign(0.);
        title.add_css_class("regex-category");
        root.append(&title);
        for &(symbol, insert, de, en) in elements {
            let item = gtk::Button::new();
            item.add_css_class("regex-element");
            item.set_widget_name(&format!("regex-element-{insert}"));
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let code = gtk::Label::new(Some(symbol));
            code.set_width_request(56);
            code.set_xalign(0.);
            code.add_css_class("regex-symbol");
            let hint = gtk::Label::new(Some(ui.lang.text(de, en)));
            hint.set_wrap(true);
            hint.set_xalign(0.);
            hint.set_hexpand(true);
            row.append(&code);
            row.append(&hint);
            item.set_child(Some(&row));
            root.append(&item);
            let target = field.downgrade();
            let popup = popover.downgrade();
            item.connect_clicked(move |_| {
                if let Some(field) = target.upgrade() {
                    let mut at = field.position();
                    field.insert_text(insert, &mut at);
                    field.set_position(at);
                }
                if let Some(popup) = popup.upgrade() {
                    popup.popdown();
                }
            });
        }
    }
    popover.set_child(Some(
        &gtk::ScrolledWindow::builder()
            .child(&root)
            .width_request(320)
            .height_request(380)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build(),
    ));
    let weak = Rc::downgrade(ui);
    popover.connect_visible_notify(move |popover| {
        if popover.is_visible() {
            if let Some(ui) = weak.upgrade() {
                ui.mode.set_selected(2);
            }
        }
    });
    button.set_popover(Some(&popover));
    button
}
