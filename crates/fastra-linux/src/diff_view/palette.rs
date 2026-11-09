use super::*;

fn color(tag: &gtk::TextTag, property: &str, value: &str) {
    let rgba = gtk::gdk::RGBA::parse(value).unwrap();
    if tag
        .property::<Option<gtk::gdk::RGBA>>(&format!("{property}-rgba"))
        .as_ref()
        != Some(&rgba)
    {
        tag.set_property(property, value);
    }
}

pub(super) fn tags(texts: &[sourceview5::View; 2]) -> [[gtk::TextTag; 2]; 4] {
    let tags = ["diff-normal", "diff-change", "diff-gap", "diff-emphasis"].map(|name| {
        texts.each_ref().map(|text| {
            let buffer = text.buffer();
            buffer
                .tag_table()
                .lookup(name)
                .unwrap_or_else(|| buffer.create_tag(Some(name), &[]).unwrap())
        })
    });
    let dark = crate::editor_options::appearance::dark(&texts[0].settings());
    for (side, _) in texts.iter().enumerate() {
        let foreground = match (side, dark) {
            (0, true) => "#E88D7C",
            (0, false) => "#A3392A",
            (_, true) => "#94CE9F",
            (_, false) => "#2F5D3A",
        };
        let background = match (side, dark) {
            (0, true) => "#46241F",
            (0, false) => "#F7E4E0",
            (_, true) => "#1F3A26",
            (_, false) => "#E2EFE3",
        };
        color(
            &tags[0][side],
            "foreground",
            if dark { "#AAAAAA" } else { "#737373" },
        );
        color(&tags[1][side], "foreground", foreground);
        color(&tags[1][side], "paragraph-background", background);
        color(
            &tags[2][side],
            "paragraph-background",
            if dark { "#252525" } else { "#fafafa" },
        );
        color(&tags[3][side], "foreground", foreground);
        if tags[3][side].property::<i32>("weight") != 700 {
            tags[3][side].set_property("weight", 700i32);
        }
    }
    tags
}

pub(super) fn watch(view: &Rc<view::View>) {
    let owner = Rc::downgrade(view);
    crate::editor_options::appearance::watch(move || {
        let Some(view) = owner.upgrade() else {
            return false;
        };
        // Vorhandene Tags behalten ihre Bereiche: Vergleich, Auswahl und Umbruch
        // werden bei einem Farbwechsel nicht neu aufgebaut.
        tags(&view.texts);
        true
    });
}
