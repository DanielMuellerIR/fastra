use super::*;
use fastra_core::go_to_target::{Action, Context, Format, Notice};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
#[cfg(debug_assertions)]
static REPLY_DELAY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
#[cfg(debug_assertions)]
static READY: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
#[cfg(debug_assertions)]
static RETURNED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
fn notice(lang: Language, value: Notice) -> String {
    let (text,argument)=match value {
        Notice::Limit=>return lang.text("Die Zielauflösung ist auf 10 MiB, 200.000 Zeilen und 10.000 Definitionen begrenzt.","Target resolution is limited to 10 MiB, 200,000 lines and 10,000 definitions.").into(),
        Notice::MultipleFunctions(name)=>(lang.text("Mehrere Funktionen heißen „%@“. Wähle die Definition in der Gliederung.","Several functions are named “%@”. Choose the definition in the outline."),name),
        Notice::MissingTarget(name)=>(lang.text("Kein Ziel für „%@“ gefunden.","No target found for “%@”."),name),
        Notice::MissingHeading(name)=>(lang.text("Keine Überschrift zu „%@“ gefunden.","No heading found for “%@”."),name),
        Notice::RelativeNeedsFile=>return lang.text("Relative Ziele brauchen eine gespeicherte Datei als Ausgangspunkt.","Relative targets need a saved file as their starting point.").into(),
        Notice::MissingFile(name)=>(lang.text("Datei „%@“ nicht gefunden.","File “%@” not found."),name),
        Notice::InvalidAddress(name)=>(lang.text("„%@“ ist keine gültige Adresse.","“%@” is not a valid address."),name),
    };
    text.replace("%@", &argument)
}

fn find(
    path: &Path,
    case_insensitive: bool,
    cancel: &Cancellation,
) -> Result<Option<PathBuf>, String> {
    match std::fs::metadata(path) {
        Ok(_) => return Ok(Some(path.into())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.to_string()),
    }
    if !case_insensitive {
        return Ok(None);
    }
    let Some(parent) = path.parent() else {
        return Ok(None);
    };
    let entries = match std::fs::read_dir(parent) {
        Ok(v) => v,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    let wanted = path
        .file_name()
        .and_then(|n| n.to_str())
        .map(fastra_core::four_d::method_key);
    let mut found = None;
    for (n, entry) in entries.enumerate() {
        cancel.check().map_err(|e| e.to_string())?;
        if n >= 10_000 {
            return Err("4D source-directory limit: 10,000 entries".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        if wanted.as_ref().is_some_and(|key| {
            entry
                .file_name()
                .to_str()
                .is_some_and(|name| fastra_core::four_d::method_key(name) == *key)
        }) {
            if found.is_some() {
                return Err("More than one 4D file has this name ignoring case".into());
            }
            found = Some(entry.path());
        }
    }
    Ok(found)
}
struct Click {
    view: glib::WeakRef<sourceview5::View>,
    time: u32,
    x: f64,
    y: f64,
    count: u32,
}
pub(super) fn install_window(ui: &Rc<Ui>) {
    let events = gtk::EventControllerLegacy::new();
    events.set_propagation_phase(gtk::PropagationPhase::Capture);
    let previous = RefCell::new(None::<Click>);
    let weak = Rc::downgrade(ui);
    events.connect_event(move |_, event| {
        if event.event_type() != gtk::gdk::EventType::ButtonPress {
            return glib::Propagation::Proceed;
        }
        let Some(ui) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if event.surface() != ui.window.surface() {
            previous.borrow_mut().take();
            return glib::Propagation::Proceed;
        }

        let mask = gtk::gdk::ModifierType::LOCK_MASK
            | gtk::gdk::ModifierType::SHIFT_MASK
            | gtk::gdk::ModifierType::CONTROL_MASK
            | gtk::gdk::ModifierType::ALT_MASK
            | gtk::gdk::ModifierType::SUPER_MASK
            | gtk::gdk::ModifierType::META_MASK;
        if event
            .downcast_ref::<gtk::gdk::ButtonEvent>()
            .is_none_or(|e| e.button() != 1)
            || event.modifier_state() & mask != gtk::gdk::ModifierType::ALT_MASK
        {
            previous.borrow_mut().take();
            return glib::Propagation::Proceed;
        }
        let Some((x, y)) = event.position() else {
            return glib::Propagation::Proceed;
        };
        let (dx, dy) = ui.window.surface_transform();
        let point = gtk::graphene::Point::new((x + dx) as f32, (y + dy) as f32);
        let mut hit = ui.window.pick(x + dx, y + dy, gtk::PickFlags::DEFAULT);
        let mut view = None;
        while let Some(widget) = hit {
            if widget.is::<sourceview5::Gutter>() {
                break;
            }
            if let Ok(source) = widget.clone().downcast::<sourceview5::View>() {
                view = Some(source);
                break;
            }
            hit = widget.parent();
        }
        let Some(view) = view else {
            previous.borrow_mut().take();
            return glib::Propagation::Proceed;
        };
        let Some(local) = ui.window.compute_point(&view, &point) else {
            return glib::Propagation::Proceed;
        };
        let settings = ui.window.settings();
        let maximum = settings.property::<i32>("gtk-double-click-time").max(0) as u32;
        let distance = settings.property::<i32>("gtk-double-click-distance").max(0) as f64;
        let count = previous
            .borrow()
            .as_ref()
            .filter(|old| {
                old.view.upgrade().as_ref() == Some(&view)
                    && event.time().wrapping_sub(old.time) <= maximum
                    && (x - old.x).abs() <= distance
                    && (y - old.y).abs() <= distance
            })
            .map_or(1, |old| old.count.saturating_add(1));
        *previous.borrow_mut() = Some(Click {
            view: view.downgrade(),
            time: event.time(),
            x,
            y,
            count,
        });
        if count == 2 {
            let (x, y) = view.window_to_buffer_coords(
                gtk::TextWindowType::Widget,
                local.x() as i32,
                local.y() as i32,
            );
            if let (Some(doc), Some((iter, _))) = (ui.active(), view.iter_at_position(x, y)) {
                let location = iter.offset();
                view.grab_focus();
                glib::idle_add_local_once(move || request(&ui, &doc, &view, location, false));
            }
        }
        // GtkGestureDrag darf die normale Alt-Ziehauswahl weiter verarbeiten.
        // Sein eigener Doppelklickzähler wird dabei zurückgesetzt; deshalb vor den
        // Kindgesten die nativen Ereignisse mit den GTK-Zeit-/Abstandsregeln lesen.
        glib::Propagation::Proceed
    });
    ui.window.add_controller(events);
}
pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, view: &sourceview5::View) {
    let action = gio::SimpleAction::new("target", None);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_view = view.downgrade();
    action.connect_activate(move |_, _| {
        if let (Some(ui), Some(doc), Some(view)) =
            (weak_ui.upgrade(), weak_doc.upgrade(), weak_view.upgrade())
        {
            view.grab_focus();
            let at = view.buffer().cursor_position();
            request(&ui, &doc, &view, at, true);
        }
    });
    let group = gio::SimpleActionGroup::new();
    group.add_action(&action);
    view.insert_action_group("fastra-navigation", Some(&group));
    let menu = gio::Menu::new();
    if let Some(existing) = view.extra_menu() {
        menu.append_section(None, &existing);
    }
    menu.append(
        Some(
            ui.lang
                .text("Gehe zum Ziel an der Einfügemarke", "Go to target at caret"),
        ),
        Some("fastra-navigation.target"),
    );
    view.set_extra_menu(Some(&menu));
    let weak_doc = Rc::downgrade(doc);
    let update = Rc::new(move || {
        action.set_enabled(
            weak_doc
                .upgrade()
                .is_some_and(|d| document_format(&d).is_some()),
        )
    });
    update();
    let changed = update.clone();
    doc.label.connect_label_notify(move |_| changed());
    let buffer = view.buffer().downcast::<sourceview5::Buffer>().unwrap();
    buffer.connect_language_notify(move |_| update());
}
fn document_format(doc: &Document) -> Option<Format> {
    let name = doc
        .disk_path()
        .and_then(|p| p.file_name().map(|s| s.to_string_lossy().into_owned()))
        .unwrap_or_else(|| doc.name.clone());
    fastra_core::go_to_target::format(&name)
}
fn request(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    view: &sourceview5::View,
    location: i32,
    explicit: bool,
) {
    let Some(format) = document_format(doc) else {
        return;
    };
    if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, doc))
        || !ui.source_read_allowed(doc)
        || doc.saving.get()
        || doc.close_pending.get()
    {
        return;
    }
    for rectangle in doc.rectangles.borrow().iter() {
        rectangle.clear();
    }
    let Some(target) = source_panes::capture(doc).filter(|t| t.view == *view && t.valid_for_reading(doc))
    else {
        return;
    };
    let source = buffer_text(&doc.buffer);
    if source.len() > 10 * 1024 * 1024 {
        ui.status.set_text(&notice(ui.lang, Notice::Limit));
        return;
    }
    let source_range = location.max(0) as usize..location.max(0) as usize;
    let document = doc.disk_path();
    let revision = doc.revision.get();
    let headings = doc
        .outline
        .borrow()
        .as_ref()
        .map(|v| v.snapshot())
        .unwrap_or_default();
    let project = project_view::current_binding(ui);
    let project_id = project.as_ref().map(|p| p.owner_id());
    let root = project.as_ref().map(|p| p.root.path.clone());
    let (navigation, cancel) = markdown_navigation::begin_request(ui, doc);
    let work = match project.as_ref().map(|p| p.work(&cancel)).transpose() {
        Ok(v) => v,
        Err(e) => {
            ui.status.set_text(&e);
            return;
        }
    };
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let owner_navigation = navigation.clone();
    let owner_target = target.clone();
    let owner: Rc<dyn Fn() -> bool> = Rc::new(move || {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return false;
        };
        owner_navigation.current_readable()
            && owner_target.valid_document_for_reading(&doc)
            && project_view::current_binding(&ui)
                .as_ref()
                .map(|p| p.owner_id())
                == project_id
    });
    let guard = owner.clone();
    let load_cancel = cancel.clone();
    let weak_ui = Rc::downgrade(ui);
    git_view::background(
        move || {
            if let Some(work) = &work {
                work.validate()?;
            }
            let before = markdown_navigation::prepare_point(
                &source,
                revision,
                source_range.clone(),
                &headings,
                &cancel,
            )?;
            let location = before_offset(&source, source_range.start);
            let issue = RefCell::new(None::<String>);
            let action = fastra_core::go_to_target::resolve(
                Context {
                    source: &source,
                    location,
                    format,
                    document: document.as_deref(),
                    project: root.as_deref(),
                },
                |path| match std::fs::metadata(path) {
                    Ok(m) => m.is_dir(),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                    Err(e) => {
                        *issue.borrow_mut() = Some(e.to_string());
                        false
                    }
                },
                |path| match find(path, format == Format::FourD, &cancel) {
                    Ok(v) => v,
                    Err(e) => {
                        *issue.borrow_mut() = Some(e);
                        None
                    }
                },
                &cancel,
            )
            .map_err(|e| e.to_string())?;
            if let Some(issue) = issue.into_inner() {
                return Err(issue);
            }
            let after = if let Some(Action::Jump(range)) = action.as_ref() {
                let range = fastra_core::navigation_anchor::characters(
                    &source,
                    range.location..range.location + range.length,
                    &cancel,
                )
                .map_err(|e| e.to_string())?
                .ok_or("Invalid UTF-16 target")?;
                Some(markdown_navigation::prepare_point(
                    &source, revision, range, &headings, &cancel,
                )?)
            } else {
                None
            };
            if let Some(work) = &work {
                work.validate()?;
            }
            #[cfg(debug_assertions)]
            {
                let delay =
                    Duration::from_millis(REPLY_DELAY.load(std::sync::atomic::Ordering::SeqCst));
                READY.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let began = std::time::Instant::now();
                while began.elapsed() < delay {
                    cancel.check().map_err(|e| e.to_string())?;
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
            cancel.check().map_err(|e| e.to_string())?;
            Ok((action, before, after))
        },
        move |result| {
            #[cfg(debug_assertions)]
            RETURNED.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let Some(ui) = weak_ui.upgrade().filter(|_| guard()) else {
                return;
            };
            match result {
                Ok((Some(Action::Jump(_)), before, Some(after))) => {
                    navigation.jump(before, after, target)
                }
                Ok((Some(Action::OpenFile(path)), before, _)) => {
                    let prepared = Arc::new(Mutex::new(None::<markdown_navigation::PreparedPoint>));
                    let worker = prepared.clone();
                    let validator: LoadValidator = Box::new(move |loaded| {
                        let text = match loaded {
                            viewer::Loaded::Editor(loader::Loaded::Text { decoded, .. }) => decoded.text(),
                            viewer::Loaded::Editor(loader::Loaded::ReadOnlyText(source)) => source.text(),
                            _ => return false,
                        };
                        match markdown_navigation::prepare_point(
                            text,
                            0,
                            0..0,
                            &[],
                            &load_cancel,
                        ) {
                            Ok(point) => {
                                *worker.lock().unwrap() = Some(point);
                                true
                            }
                            Err(_) => false,
                        }
                    });
                    let load_request = navigation.clone();
                    let load_ui = Rc::downgrade(&ui);
                    let project_id = project_view::current_binding(&ui).map(|p| p.owner_id());
                    let load_owner: Rc<dyn Fn() -> bool> = Rc::new(move || {
                        load_request.current_readable()
                            && load_ui.upgrade().is_some_and(|u| {
                                project_view::current_binding(&u)
                                    .as_ref()
                                    .map(|p| p.owner_id())
                                    == project_id
                            })
                    });
                    import_view::route_open_completed(
                        &ui,
                        path,
                        None,
                        load_owner,
                        Some(validator),
                        Some(Box::new(move |doc| {
                            let after = prepared.lock().unwrap().take();
                            if let Some(after) = after {
                                navigation.opened(before, after, &doc);
                            }
                        })),
                    );
                }
                Ok((Some(Action::SearchProject(name)), _, _)) => {
                    ui.mode.set_selected(0);
                    ui.find.set_text(&name);
                    if project_view::current_binding(&ui).is_some() {
                        ui.scope.set_selected(3);
                        project_view::search(&ui);
                    } else {
                        ui.scope.set_selected(2);
                        folder::open(&ui);
                    }
                }
                Ok((Some(Action::OpenUrl(address)), _, _)) => open_url(&ui, &address),
                Ok((Some(Action::NotFound(message)), _, _)) => {
                    ui.window.error_bell();
                    ui.status.set_text(&notice(ui.lang, message));
                    ui.status.set_visible(true);
                }
                Ok((None, _, _)) if explicit => ui.status.set_text(ui.lang.text(
                    "An der Einfügemarke gibt es kein Sprungziel.",
                    "There is no navigation target at the caret.",
                )),
                Ok(_) => {}
                Err(error) => {
                    ui.status.set_text(&format!(
                        "{}: {error}",
                        ui.lang.text("Ziel nicht geöffnet", "Target not opened")
                    ));
                    ui.status.set_visible(true);
                }
            }
        },
    );
}
fn before_offset(source: &str, characters: usize) -> usize {
    source.chars().take(characters).map(char::len_utf16).sum()
}
fn open_url(ui: &Rc<Ui>, address: &str) {
    let uri = match glib::Uri::parse(address, glib::UriFlags::PARSE_RELAXED) {
        Ok(uri) => uri,
        Err(_) => {
            ui.status
                .set_text(&notice(ui.lang, Notice::InvalidAddress(address.into())));
            return;
        }
    };
    if !matches!(uri.scheme().as_str(), "http" | "https" | "mailto") {
        ui.status
            .set_text(&notice(ui.lang, Notice::InvalidAddress(address.into())));
        return;
    }
    let weak = Rc::downgrade(ui);
    gtk::UriLauncher::new(&uri.to_string()).launch(
        Some(&ui.window),
        None::<&gio::Cancellable>,
        move |result| {
            if let (Some(ui), Err(error)) = (weak.upgrade(), result) {
                ui.status.set_text(&format!(
                    "{}: {error}",
                    ui.lang.text("Adresse nicht geöffnet", "Address not opened")
                ));
            }
        },
    );
}

#[cfg(debug_assertions)]
pub(super) mod selftest;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_uri_normalization_matches_actual_foundation_addresses() {
        let cases: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../fastra-core/tests/fixtures/swift-go-to-target.json"
        ))
        .unwrap();
        let mut checked = 0;
        for case in cases {
            if let (Some(literal), Some(expected)) = (
                case["expected"]["literal"].as_str(),
                case["expected"]["url"].as_str(),
            ) {
                let uri = glib::Uri::parse(literal, glib::UriFlags::PARSE_RELAXED).unwrap();
                assert!(matches!(uri.scheme().as_str(), "http" | "https" | "mailto"));
                assert_eq!(uri.to_string(), expected);
                checked += 1;
            }
        }
        assert!(checked >= 3);
    }
}
