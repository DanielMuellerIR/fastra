use super::*;
use crate::editor_options::async_gui_test::{capture, input, named, wait};
use sourceview5::prelude::*;

fn selection(view: &view::View) -> [(i32, i32); 2] {
    view.texts.each_ref().map(|text| {
        let buffer = text.buffer();
        (
            buffer.cursor_position(),
            buffer.iter_at_mark(&buffer.selection_bound()).offset(),
        )
    })
}
fn verify(view: &view::View, dark: bool) {
    for (side, text) in view.texts.iter().enumerate() {
        for (name, property, expected) in [
            (
                "diff-normal",
                "foreground-rgba",
                if dark { "#AAAAAA" } else { "#737373" },
            ),
            (
                "diff-change",
                "foreground-rgba",
                if side == 0 {
                    if dark {
                        "#E88D7C"
                    } else {
                        "#A3392A"
                    }
                } else if dark {
                    "#94CE9F"
                } else {
                    "#2F5D3A"
                },
            ),
            (
                "diff-change",
                "paragraph-background-rgba",
                if side == 0 {
                    if dark {
                        "#46241F"
                    } else {
                        "#F7E4E0"
                    }
                } else if dark {
                    "#1F3A26"
                } else {
                    "#E2EFE3"
                },
            ),
            (
                "diff-gap",
                "paragraph-background-rgba",
                if dark { "#252525" } else { "#fafafa" },
            ),
            (
                "diff-emphasis",
                "foreground-rgba",
                if side == 0 {
                    if dark {
                        "#E88D7C"
                    } else {
                        "#A3392A"
                    }
                } else if dark {
                    "#94CE9F"
                } else {
                    "#2F5D3A"
                },
            ),
        ] {
            let tag = text.buffer().tag_table().lookup(name).unwrap();
            assert_eq!(
                tag.property::<gtk::gdk::RGBA>(property),
                gtk::gdk::RGBA::parse(expected).unwrap(),
                "{name}/{property}"
            );
        }
        assert_eq!(
            text.buffer()
                .downcast::<sourceview5::Buffer>()
                .unwrap()
                .style_scheme()
                .unwrap()
                .id(),
            if dark { "fastra-dark" } else { "fastra-light" }
        );
    }
}
fn verify_wrap(view: &view::View) {
    let mut heights = Vec::new();
    for text in &view.texts {
        let mut iter = text.buffer().iter_at_line(1).unwrap();
        let _ = text.iter_location(&iter);
        let (top, height) = text.line_yrange(&iter);
        let mut bottom = top;
        let mut fragments = 0;
        loop {
            let rect = text.iter_location(&iter);
            assert!(rect.height() > 0 && rect.y() >= bottom);
            bottom = rect.y() + rect.height();
            assert!(
                bottom <= top + height,
                "theme change must retain the full wrapped row height"
            );
            fragments += 1;
            if !text.forward_display_line(&mut iter) || iter.line() != 1 {
                break;
            }
        }
        assert!(
            fragments > 3,
            "real soft wrap exercised after every appearance change"
        );
        heights.push(height);
    }
    assert!(
        (heights[0] - heights[1]).abs() <= 1,
        "aligned wrapped rows after theme change: {heights:?}"
    );
}
async fn scenario(ui: Rc<Ui>) {
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("theme-left.txt");
    let right = root.join("theme-right.txt");
    let original = format!(
        "start café 😀\nold {}\nend\n",
        "wrapped café 😀 ".repeat(40)
    );
    let changed = original.replace("old", "new");
    std::fs::write(&left, &original).unwrap();
    std::fs::write(&right, &changed).unwrap();
    ui.load_path(left.clone());
    wait("source loaded", || {
        ui.active()
            .is_some_and(|doc| doc.disk_path().as_ref() == Some(&left))
    })
    .await;
    let doc = ui.active().unwrap();
    let revision = doc.revision.get();
    let state = open(&ui);
    state.choose(1, sources::Choice::File(right.clone()));
    wait("compare enabled", || state.picker.compare.is_sensitive()).await;
    input(&state.picker.compare, &[], true).await;
    wait("comparison ready", || {
        state.view.ready.get() && state.view.transfer[0].is_sensitive()
    })
    .await;
    input(&state.view.transfer[0], &[], true).await;
    wait("transfer preview ready", || {
        transfer::test_preview().is_some_and(|p| p.apply.is_sensitive() && p.view.ready.get())
    })
    .await;
    let preview = transfer::test_preview().unwrap();
    let views = [&state.view, &preview.view];
    for view in views {
        for text in &view.texts {
            let buffer = text.buffer();
            buffer.select_range(&buffer.iter_at_offset(4), &buffer.iter_at_offset(1));
        }
    }
    let data = views.map(|view| view.data.borrow().clone().unwrap());
    let renders = views.map(|view| view.render.get());
    let ranges = views.map(|view| selection(view));
    let tags = views.map(|view| {
        view.texts
            .each_ref()
            .map(|text| text.buffer().tag_table().lookup("diff-change").unwrap())
    });
    let app = ui.window.application().unwrap();
    // Auch eine geöffnete Übernahmevorschau muss auf die appweite Wahl reagieren.
    app.activate_action("settings", None);
    wait("Settings window", || {
        app.windows()
            .iter()
            .any(|w| w.widget_name() == "fastra-global-settings")
    })
    .await;
    let settings = app
        .windows()
        .into_iter()
        .find(|w| w.widget_name() == "fastra-global-settings")
        .unwrap();
    for (mode, dark) in [("light", false), ("dark", true), ("light", false)] {
        let button: gtk::ToggleButton = named(&settings, &format!("fastra-appearance-{mode}"));
        wait("appearance loaded", || button.is_sensitive()).await;
        input(&button, &[], true).await;
        wait("effective appearance and save", || {
            crate::editor_options::appearance::explicit() == Some(dark)
                && !crate::editor_options::appearance::pending()
        })
        .await;
        glib::timeout_future(std::time::Duration::from_millis(100)).await;
        for (index, view) in views.into_iter().enumerate() {
            verify(view, dark);
            verify_wrap(view);
            assert!(Rc::ptr_eq(
                view.data.borrow().as_ref().unwrap(),
                &data[index]
            ));
            assert_eq!(view.render.get(), renders[index]);
            assert_eq!(selection(view), ranges[index]);
            for (side, text) in view.texts.iter().enumerate() {
                assert_eq!(
                    text.buffer().tag_table().lookup("diff-change").as_ref(),
                    Some(&tags[index][side])
                );
                assert!(
                    text.buffer()
                        .iter_at_line(1)
                        .unwrap()
                        .has_tag(&tags[index][side]),
                    "changed-row tag retains its range"
                );
            }
        }
        capture(ui.window.upcast_ref(), &format!("diff-{mode}")).await;
        capture(&preview.window, &format!("transfer-{mode}")).await;
    }
    assert_eq!(doc.revision.get(), revision);
    assert!(!doc.buffer.is_modified());
    assert_eq!(std::fs::read_to_string(left).unwrap(), original);
    assert_eq!(std::fs::read_to_string(right).unwrap(), changed);
    eprintln!("DIFF_PALETTE_SELFTEST PASS native Light/Dark/Light including dark GTK_THEME, existing comparison+transfer palette, same model/tag ranges/selection/revision and unchanged disk bytes");
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let task = glib::spawn_future_local(scenario(ui));
    glib::spawn_future_local(async move {
        let code = if task.await.is_ok() { 0 } else { 1 };
        crate::source_appearance::cleanup_schemes();
        std::process::exit(code);
    });
}
