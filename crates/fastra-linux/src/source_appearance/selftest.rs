use super::*;
use std::time::Instant;

fn views(root: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(view) = root.downcast_ref::<sourceview5::View>() {
        out.push(view.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        views(&widget, out);
        child = widget.next_sibling();
    }
}
fn split(root: &gtk::Widget) -> Option<gtk::CheckButton> {
    if let Some(button) = root.downcast_ref::<gtk::CheckButton>().filter(|button| {
        matches!(
            button.label().as_deref(),
            Some("Split source editor" | "Quelltextansicht teilen")
        )
    }) {
        return Some(button.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(button) = split(&widget) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn selection(buffer: &gtk::TextBuffer) -> (i32, i32) {
    (
        buffer.iter_at_mark(&buffer.get_insert()).offset(),
        buffer.iter_at_mark(&buffer.selection_bound()).offset(),
    )
}
fn check(views: &[sourceview5::View], dark: bool) {
    for (index, view) in views.iter().enumerate() {
        assert!(view.is_mapped(), "source pane {index} mapped");
        let buffer = view.buffer().downcast::<sourceview5::Buffer>().unwrap();
        let start = buffer.start_iter();
        let mut next = start;
        assert!(next.forward_char());
        let first = view.iter_location(&start);
        let second = view.iter_location(&next);
        let actual_cell = f64::from(second.x() - first.x());
        let space =
            f64::from(view.create_pango_layout(Some(" ")).size().0) / f64::from(gtk::pango::SCALE);
        assert!(actual_cell > 0., "native ASCII advance");
        assert!(
            (actual_cell - space).abs() <= 1.,
            "native advance {actual_cell} versus space {space}"
        );
        for glyph in ["i", "W", "M", "0", " "] {
            let width = f64::from(view.create_pango_layout(Some(glyph)).size().0)
                / f64::from(gtk::pango::SCALE);
            assert!(
                (width - actual_cell).abs() <= 1.,
                "glyph {glyph:?} advance {width} versus native {actual_cell}"
            );
        }
        eprintln!("SOURCE_MONOSPACE pane={index} native_advance={actual_cell} space={space} PASS");

        let scheme = buffer.style_scheme().unwrap();
        let id = scheme.id();
        assert_eq!(id.as_str(), if dark { "fastra-dark" } else { "fastra-light" });
        let background = scheme.style("text").unwrap().background().unwrap();
        let background = background.parse::<gtk::gdk::RGBA>().unwrap();
        assert_eq!(
            background.red() + background.green() + background.blue() < 1.5,
            dark
        );
        eprintln!(
            "SOURCE_APPEARANCE pane={index} scheme={id} background={background} native_foreground={}",
            view.root()
                .unwrap()
                .dynamic_cast::<gtk::Widget>()
                .unwrap()
                .color()
        );
    }
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let settings = gtk::Settings::default().unwrap();
    settings.set_gtk_application_prefer_dark_theme(false);
    let original = "fn main() {\n    println!(\"café🙂\");\n}\n";
    ui.add_document("source-appearance.rs", original);
    let doc = ui.active().unwrap();
    let mut all = Vec::new();
    views(doc.container.upcast_ref(), &mut all);
    assert_eq!(all.len(), 2);
    assert_ne!(all[0].buffer(), all[1].buffer());
    split(doc.container.upcast_ref()).unwrap().set_active(true);
    let language = sourceview5::LanguageManager::default()
        .language("rust")
        .unwrap();
    for view in &all {
        view.buffer()
            .downcast::<sourceview5::Buffer>()
            .unwrap()
            .set_language(Some(&language));
    }
    doc.buffer.begin_user_action();
    doc.buffer
        .insert(&mut doc.buffer.end_iter(), "// retained undo\n");
    doc.buffer.end_user_action();
    for (index, view) in all.iter().enumerate() {
        let buffer = view.buffer();
        buffer.select_range(
            &buffer.iter_at_offset(3 + index as i32),
            &buffer.iter_at_offset(index as i32),
        );
    }
    let expected_text = buffer_text(&doc.buffer);
    let expected_revision = doc.revision.get();
    let selections: Vec<_> = all.iter().map(|view| selection(&view.buffer())).collect();
    let initial_dark = std::env::var("FASTRA_SOURCE_APPEARANCE_EXPECT")
        .unwrap_or_else(|_| "dark".into())
        == "dark";
    let static_theme = std::env::var_os("GTK_THEME").is_some();
    let stage = Cell::new(0);
    let pause = Cell::new(Instant::now());
    glib::timeout_add_local(Duration::from_millis(100), move || {
        if pause.get().elapsed() < Duration::from_millis(500) {
            return glib::ControlFlow::Continue;
        }
        for (index, view) in all.iter().enumerate() {
            let buffer = view.buffer();
            assert_eq!(buffer_text(&buffer), expected_text);
            assert_eq!(selection(&buffer), selections[index]);
            assert!(buffer.is_modified());
            assert!(buffer.can_undo());
            assert!(!buffer.can_redo());
        }
        assert_eq!(doc.revision.get(), expected_revision);
        match stage.get() {
            0 => {
                assert!(!settings.is_gtk_application_prefer_dark_theme());
                check(&all, initial_dark);
                git_view::capture(
                    ui.window.upcast_ref(),
                    if initial_dark {
                        "source-initial-dark"
                    } else {
                        "source-initial-light"
                    },
                );
                if static_theme {
                    doc.buffer.undo();
                    for view in &all {
                        assert_eq!(buffer_text(&view.buffer()), original);
                    }
                    git_view::finish(
                        ui.window.clone().upcast(),
                        ui.clone(),
                        "source-appearance-static",
                    );
                    return glib::ControlFlow::Break;
                }
                settings.set_gtk_theme_name(Some("Adwaita"));
            }
            1 => {
                check(&all, false);
                git_view::capture(ui.window.upcast_ref(), "source-runtime-light");
                settings.set_gtk_theme_name(Some("Adwaita-dark"));
            }
            2 => {
                check(&all, true);
                git_view::capture(ui.window.upcast_ref(), "source-runtime-dark");
                settings.set_gtk_theme_name(Some("Adwaita"));
                settings.set_gtk_application_prefer_dark_theme(true);
            }
            3 => {
                check(&all, true);
                settings.set_gtk_application_prefer_dark_theme(false);
            }
            _ => {
                check(&all, false);
                doc.buffer.undo();
                for view in &all {
                    assert_eq!(buffer_text(&view.buffer()), original);
                }
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "source-appearance-runtime",
                );
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
