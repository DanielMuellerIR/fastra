use super::*;
use std::{cell::RefCell, time::Instant};
fn sources(w: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(v) = w.downcast_ref::<sourceview5::View>() {
        out.push(v.clone());
    }
    let mut c = w.first_child();
    while let Some(w) = c {
        sources(&w, out);
        c = w.next_sibling();
    }
}
fn middle(v: &sourceview5::View, offset: i32, trailing: bool) {
    let r = v.iter_location(&docbuffer(v).iter_at_offset(offset));
    let (mut x, mut y) = v.buffer_to_window_coords(
        gtk::TextWindowType::Widget,
        r.x() + if trailing { r.width() * 3 / 4 } else { 0 },
        r.y() + r.height() / 2,
    );
    let mode = std::env::var("FASTRA_LINEAR_PASTE_CASE").unwrap_or_default();
    if mode == "primary-valid-family" {
        let after_cluster = v.iter_location(&docbuffer(v).iter_at_offset(11));
        (x, y) = v.buffer_to_window_coords(
            gtk::TextWindowType::Widget,
            after_cluster.x(),
            after_cluster.y() + after_cluster.height() / 2,
        );
    }
    if mode == "primary-own-reject-gutter" {
        x = 5;
    }

    let left = v
        .buffer_to_window_coords(gtk::TextWindowType::Widget, 0, 0)
        .0;
    if mode == "primary-valid-eol-space" {
        x += 150;
    }
    if mode == "primary-valid-below-eof" {
        x += 150;
        y = v.height() - 10;
    }
    if mode == "primary-valid-gutter"
        || mode == "primary-valid-gutter-nul"
        || mode == "primary-valid-gutter-line"
    {
        x = 5;
    }
    if mode == "primary-valid-gutter-below" {
        x = 5;
        y = v.height() - 10;
    }
    if mode == "primary-valid-gutter-edge" {
        x = left - 1;
    }
    if mode == "primary-valid-text-edge" {
        x = left + 1;
    }
    eprintln!(
        "INDEPENDENT PRIMARY mode={mode} textleft={left} point={x},{y} picked={:?}",
        v.pick(x as f64, y as f64, gtk::PickFlags::DEFAULT)
            .map(|w| w.type_().name().to_string())
    );
    let native = v.native().unwrap();
    let point = v
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(x as f32, y as f32),
        )
        .unwrap();
    let (sx, sy) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    eprintln!("PRIMARY actual middle target offset={offset} widget={x},{y}");
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowraise",
                &id,
                "windowfocus",
                "--sync",
                &id,
                "mousemove",
                "--window",
                &id,
                &(point.x() as f64 - sx).round().to_string(),
                &(point.y() as f64 - sy).round().to_string(),
                "click",
                "2"
            ])
            .status()
            .unwrap()
            .success());
    });
}
fn docbuffer(v: &sourceview5::View) -> gtk::TextBuffer {
    gtk::prelude::TextViewExt::buffer(v)
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_PRIMARY_COLLAPSE_GUARD").is_some(){collapse_guards(ui);return;}
    if std::env::var_os("FASTRA_REVIEW_PRIMARY_COLLAPSE").is_some(){collapse_probe(ui);return;}
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    crate::git_view::test_size(ui.window.upcast_ref());
    let kind = std::env::var("FASTRA_LINEAR_PASTE_CASE").unwrap();
    let own_long = format!("{}\r\nz\r\n", "x".repeat(40000));
    let original = if kind.starts_with("primary-own-reject") {
        own_long.as_str()
    } else if kind == "primary-valid-combining" {
        "abcde\r\nze\u{301}二Q\r\n"
    } else if kind == "primary-valid-family" {
        "abcde\r\nz👩‍💻二Q\r\n"
    } else if kind == "primary-valid-trailing" {
        "abcde\r\nz🙂二Q\r\n"
    } else {
        "abcde\r\nz\r\n"
    };
    ui.add_document("primary.txt", original);
    let doc = ui.active().unwrap();
    let payload = match kind.as_str() {
        "primary-valid-gutter-nul" => b"safe\0lost".to_vec(),
        "primary-valid-gutter-line" => vec![b'x'; 65537],
        k if k.starts_with("primary-valid") => "é🙂".as_bytes().to_vec(),
        "primary-nul" => b"safe\0lost".to_vec(),
        "primary-total" => vec![b'\n'; 32 * 1024 * 1024],
        k if k.starts_with("primary-stale") || k == "primary-rapid" => b"PASTE".to_vec(),
        _ => vec![b'x'; 65537],
    };
    let original = original.to_string();
    let secondary=std::env::var_os("FASTRA_SPLIT_PRIMARY_SECONDARY").is_some();
    if secondary {let mut widgets=vec![doc.container.clone().upcast::<gtk::Widget>()];while let Some(widget)=widgets.pop(){if let Some(button)=widget.downcast_ref::<gtk::CheckButton>().filter(|b|matches!(b.label().as_deref(),Some("Split source editor"|"Quelltextansicht teilen"))){button.set_active(true);break;}let mut child=widget.first_child();while let Some(c)=child{widgets.push(c.clone());child=c.next_sibling();}}}
    let target=doc.source_panes.borrow().as_ref().unwrap().buffers[usize::from(secondary)].clone();
    let phase = Cell::new(0);
    let selected = Cell::new((0, 0));
    let at = Instant::now();
    let pause = Cell::new(at);
    let view = RefCell::new(None::<sourceview5::View>);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            at.elapsed() < Duration::from_secs(30),
            "primary timeout phase={} status={}",
            phase.get(),
            ui.status.text()
        );
        match phase.get() {
            0 => {
                if pause.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                let mut vs = Vec::new();
                sources(doc.container.upcast_ref(), &mut vs);
                let Some(v) = vs.into_iter().nth(usize::from(secondary)).filter(|v|v.is_mapped()) else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &v,
                    if kind.starts_with("primary-own-reject") {
                        &[]
                    } else {
                        &[
                            "ctrl+Home",
                            "Right",
                            "shift+Right",
                            "shift+Right",
                            "shift+Right",
                        ]
                    },
                );
                *view.borrow_mut() = Some(v);
                pause.set(Instant::now());
                phase.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                if !kind.starts_with("primary-own-reject") {
                    assert_eq!(target.cursor_position(), 4);
                }
                let v = view.borrow().as_ref().unwrap().clone();
                if kind.starts_with("primary-own-reject") {
                    target
                        .select_range(&target.iter_at_offset(40000), &target.start_iter());
                } else if kind != "primary-valid-own" {
                    v.primary_clipboard()
                        .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                            "text/plain;charset=utf-8",
                            &glib::Bytes::from_owned(payload.clone()),
                        )))
                        .unwrap();
                }
                pause.set(Instant::now());
                phase.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                selected.set((
                    target.cursor_position(),
                    target
                        .iter_at_mark(&target.selection_bound())
                        .offset(),
                ));
                eprintln!(
                    "PRIMARY BEFORECLICK selection={:?} bytes={} undo={}",
                    selected.get(),
                    buffer_text(&target).len(),
                    target.can_undo()
                );
                let v = view.borrow().as_ref().unwrap().clone();
                if kind == "primary-readonly" {
                    v.set_editable(false);
                }
                if std::env::var_os("FASTRA_SPLIT_PRIMARY_INACTIVE").is_some(){let mut all=Vec::new();sources(doc.container.upcast_ref(),&mut all);all[0].grab_focus();assert!(!v.has_focus());assert_eq!(source_panes::capture(&doc).unwrap().view,all[0]);}
                middle(
                    &v,
                    if kind.starts_with("primary-own-reject") {
                        0
                    } else {
                        8
                    },
                    matches!(
                        kind.as_str(),
                        "primary-valid-trailing"
                            | "primary-valid-combining"
                            | "primary-valid-family"
                    ),
                );
                pause.set(Instant::now());
                phase.set(
                    if kind.starts_with("primary-stale") || kind == "primary-rapid" {
                        7
                    } else {
                        2
                    },
                );
            }
            7 => {
                if linear_paste::test_counts().0 < 1 {
                    return glib::ControlFlow::Continue;
                }
                let v = view.borrow().as_ref().unwrap().clone();
                if kind == "primary-stale-selection" {
                    target.place_cursor(&target.end_iter());
                    selected.set((target.char_count(), target.char_count()));
                } else if kind == "primary-stale-aba" {
                    target.place_cursor(&target.start_iter());
                    target.select_range(
                        &target.iter_at_offset(selected.get().0),
                        &target.iter_at_offset(selected.get().1),
                    );
                } else if kind == "primary-stale-provider" {
                    v.primary_clipboard()
                        .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                            "text/plain;charset=utf-8",
                            &glib::Bytes::from_static(b"CHANGED"),
                        )))
                        .unwrap();
                } else if kind == "primary-rapid" {
                    middle(&v, 7, false);
                }
                phase.set(2);
            }
            2 => {
                if pause.get().elapsed() < Duration::from_millis(1200) {
                    return glib::ControlFlow::Continue;
                }
                let counts = linear_paste::test_counts();
                if counts.1 < counts.0 || (kind == "primary-rapid" && counts.0 < 2) {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("PRIMARY COUNTS {counts:?}");
                let text = buffer_text(&target);
                assert_eq!(text,buffer_text(&doc.buffer),"primary source/canonical mirror");
                eprintln!(
                    "PRIMARY case={kind} bytes={} original={} head={} anchor={} undo={} status={}",
                    text.len(),
                    text == original,
                    target.cursor_position(),
                    target
                        .iter_at_mark(&target.selection_bound())
                        .offset(),
                    target.can_undo(),
                    ui.status.text()
                );
                if kind.starts_with("primary-valid-gutter") {
                    assert_eq!(
                        counts,
                        (1, 1),
                        "own line-number PRIMARY must complete the shared preflight"
                    );
                    if kind.ends_with("-nul") || kind.ends_with("-line") {
                        assert_eq!(text,original,"gutter must not bypass NUL/line preflight for a real PRIMARY insertion");
                        assert!(!target.can_undo());
                        assert_eq!(
                            (
                                target.cursor_position(),
                                target
                                    .iter_at_mark(&target.selection_bound())
                                    .offset()
                            ),
                            selected.get()
                        );
                    } else {
                        let expected = if kind == "primary-valid-gutter-below" {
                            "abcde\r\nz\r\né🙂"
                        } else {
                            "abcde\r\né🙂z\r\n"
                        };
                        assert_eq!(text, expected);
                        assert!(target.can_undo());
                        target.undo();
                        assert_eq!(buffer_text(&target), original);
                    }
                    println!("PASS own native line-number PRIMARY bound to completed preflight; exact clicked position, selection and Undo retained");
                    std::process::exit(0);
                }
                if kind.starts_with("primary-valid") || kind == "primary-rapid" {
                    if kind == "primary-valid-own" {
                        assert_eq!(text, "abcde\r\nzbcd\r\n");
                    } else if kind == "primary-rapid" {
                        assert_eq!(text, "abcde\r\nPASTEz\r\n");
                    } else if kind == "primary-valid-combining" {
                        assert_eq!(text, "abcde\r\nze\u{301}é🙂二Q\r\n");
                    } else if kind == "primary-valid-family" {
                        assert_eq!(text, "abcde\r\nz👩‍💻é🙂二Q\r\n");
                    } else if kind == "primary-valid-below-eof" {
                        assert_eq!(text, "abcde\r\nz\r\né🙂");
                    } else if kind == "primary-valid-text-edge" {
                        assert_eq!(text, "abcde\r\né🙂z\r\n");
                    } else if kind == "primary-valid-trailing" {
                        eprintln!("PRIMARY trailing native exact text={text:?}");
                        assert_eq!(text, "abcde\r\nz🙂é🙂二Q\r\n");
                    } else {
                        assert_eq!(text, "abcde\r\nzé🙂\r\n");
                    }
                    assert_eq!((target.cursor_position(),target.iter_at_mark(&target.selection_bound()).offset()),selected.get(), "PRIMARY keeps native selection marks when insertion is after their positions");
                    assert!(target.can_undo());
                    target.undo();
                    assert_eq!(buffer_text(&target), original);
                    assert!(!target.can_undo());
                    println!("PASS PRIMARY native click inserts at clicked position with one Undo");
                } else {
                    assert_eq!(
                        text.len(),
                        original.len(),
                        "reject whole primary paste before mutation"
                    );
                    assert_eq!(text, original);
                    assert!(!target.can_undo());
                    assert_eq!(
                        (
                            target.cursor_position(),
                            target
                                .iter_at_mark(&target.selection_bound())
                                .offset()
                        ),
                        selected.get()
                    );
                    println!("PASS PRIMARY rejects without source/selection/Undo mutation");
                }
                std::process::exit(0);
            }
            _ => unreachable!(),
        };
        glib::ControlFlow::Continue
    });
}

fn collapse_probe(ui:Rc<Ui>){
    ui.add_document("collapse.txt","abcde\nz\n");let doc=ui.active().unwrap();
    let stock=std::env::var("FASTRA_REVIEW_PRIMARY_COLLAPSE").unwrap()=="stock";
    let mut all=Vec::new();sources(doc.container.upcast_ref(),&mut all);
    let popup=if stock{let b=sourceview5::Buffer::new(None);b.set_text("abcde\nz\n");let v=sourceview5::View::with_buffer(&b);let w=gtk::Window::builder().title("Native GTK PRIMARY control").default_width(760).default_height(480).child(&v).build();w.present();all=vec![v];Some(w)}else{None};
    let v=all[0].clone();let phase=Rc::new(Cell::new(0));let began=Instant::now();let pause=Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(80),move||{
        let _hold=&popup;assert!(began.elapsed().as_secs()<20);if pause.get().elapsed()<Duration::from_millis(500){return glib::ControlFlow::Continue;}
        match phase.get(){
         0=>{crate::git_view::test_click(&v,&["ctrl+Home","Right","shift+Right","shift+Right","shift+Right"]);phase.set(1);pause.set(Instant::now());}
         1=>{let b=docbuffer(&v);assert_eq!((b.cursor_position(),b.iter_at_mark(&b.selection_bound()).offset()),(4,1));let c=v.primary_clipboard();let next=phase.clone();phase.set(9);glib::MainContext::default().spawn_local(async move{eprintln!("COLLAPSE before stock={stock} content={:?} read={:?}",c.content().map(|p|p.type_().name().to_string()),c.read_text_future().await);next.set(2);});}
         2=>{crate::git_view::test_click(&v,&["ctrl+Home","Right","Right","Right","Right"]);phase.set(3);pause.set(Instant::now());}
         3=>{let b=docbuffer(&v);assert_eq!((b.cursor_position(),b.iter_at_mark(&b.selection_bound()).offset()),(4,4));assert_eq!(buffer_text(&b),"abcde\nz\n");let c=v.primary_clipboard();let next=phase.clone();phase.set(9);glib::MainContext::default().spawn_local(async move{eprintln!("COLLAPSE after stock={stock} content={:?} read={:?}",c.content().map(|p|p.type_().name().to_string()),c.read_text_future().await);next.set(4);});}
         4=>{println!("PASS actual native collapse measurement stock={stock}");ui.window.application().unwrap().quit();return glib::ControlFlow::Break;}
         _=>{}
        };glib::ControlFlow::Continue
    });
}

fn collapse_guards(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let kind = std::env::var("FASTRA_PRIMARY_COLLAPSE_GUARD").unwrap();
    ui.add_document("collapse-guards.txt", "abcde\nz\n");
    let doc = ui.active().unwrap();
    let mut stack = vec![doc.container.clone().upcast::<gtk::Widget>()];
    while let Some(widget) = stack.pop() {
        if let Some(check) = widget.downcast_ref::<gtk::CheckButton>() {
            if matches!(check.label().as_deref(), Some("Split source editor" | "Quelltextansicht teilen")) {
                check.set_active(true);
            }
        }
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            stack.push(next);
        }
    }
    let mut views = Vec::new();
    sources(doc.container.upcast_ref(), &mut views);
    let stage = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let provider = RefCell::new(None::<gtk::gdk::ContentProvider>);
    let expected = RefCell::new(String::new());
    let completed = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(began.elapsed().as_secs() < 25, "collapse guard {kind} stage{}", stage.get());
        if pause.get().elapsed() < Duration::from_millis(500) {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => crate::git_view::test_click(&views[0], &["ctrl+Home", "Right", "shift+Right", "shift+Right", "shift+Right"]),
            1 => {
                let buffer = docbuffer(&views[0]);
                assert_eq!((buffer.cursor_position(), buffer.iter_at_mark(&buffer.selection_bound()).offset()), (4, 1));
                if kind == "foreign" {
                    let foreign = gtk::gdk::ContentProvider::for_value(&"FOREIGN".to_value());
                    views[0].primary_clipboard().set_content(Some(&foreign)).unwrap();
                    *provider.borrow_mut() = Some(foreign);
                    *expected.borrow_mut() = "FOREIGN".into();
                } else if kind == "other" {
                    crate::git_view::test_click(&views[1], &["ctrl+Home", "Right", "shift+Right", "shift+Right"]);
                } else {
                    *provider.borrow_mut() = views[0].primary_clipboard().content();
                    *expected.borrow_mut() = "bcd".into();
                }
            }
            2 => {
                if kind == "other" {
                    let buffer = docbuffer(&views[1]);
                    assert_eq!((buffer.cursor_position(), buffer.iter_at_mark(&buffer.selection_bound()).offset()), (3, 1));
                    *provider.borrow_mut() = views[1].primary_clipboard().content();
                    *expected.borrow_mut() = "bc".into();
                }
                if kind == "focus" {
                    assert!(views[1].grab_focus());
                    assert!(views[0].grab_focus());
                } else {
                    crate::git_view::test_click(&views[0], &["ctrl+Home", "Right", "Right", "Right", "Right"]);
                }
            }
            3 => {
                let buffer = docbuffer(&views[0]);
                let expected_selection = if kind == "focus" {(4, 1)} else {(4, 4)};
                assert_eq!((buffer.cursor_position(), buffer.iter_at_mark(&buffer.selection_bound()).offset()), expected_selection);
                assert_eq!(buffer_text(&doc.buffer), "abcde\nz\n");
                assert_eq!(buffer_text(&docbuffer(&views[1])), "abcde\nz\n");
                assert_eq!(doc.revision.get(), 0);
                assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
                let clipboard = views[0].primary_clipboard();
                let cleared = kind == "collapse";
                if cleared {
                    assert!(clipboard.content().is_none());
                } else {
                    assert_eq!(clipboard.content(), *provider.borrow());
                }
                let expected = expected.borrow().clone();
                let done = completed.clone();
                glib::MainContext::default().spawn_local(async move {
                    let value = clipboard.read_text_future().await;
                    if cleared {assert!(value.is_err());} else {assert_eq!(value.unwrap().as_deref(), Some(expected.as_str()));}
                    done.set(true);
                });
            }
            4 => {
                if !completed.get() {return glib::ControlFlow::Continue;}
                println!("PASS PRIMARY collapse guard {kind}: exact native directed selection, provider identity/read, source/revision/Undo unchanged");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
