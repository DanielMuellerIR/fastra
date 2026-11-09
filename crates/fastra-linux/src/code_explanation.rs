//! Eigene schreibgeschützte Snapshotfenster; keine normalen Dokument-/Speicherbefehle.
use super::{git_view as support, Language, Ui};
use fastra_io::code_explanation::Package;
use gtk::{gio, glib, prelude::*};
use sourceview5::prelude::*;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};
mod layout;
thread_local! {
    static PLAYERS:RefCell<Vec<Rc<Player>>> = const { RefCell::new(Vec::new()) };
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Loading,
    Ready,
    Paused,
    Completed,
    Failed,
    Closed,
}
pub(super) struct Player {
    control: RefCell<Option<ControlCallbacks>>,
    id: String,
    document_ids: Vec<String>,
    package: Arc<Package>,
    lang: Language,
    window: gtk::Window,
    source: sourceview5::View,
    buffer: sourceview5::Buffer,
    source_select: gtk::DropDown,
    step_select: gtk::DropDown,
    explanation: gtk::TextView,
    status: gtk::Label,
    header_status: gtk::Label,
    step_title: gtk::Label,
    path: gtk::Label,
    previous: gtk::Button,
    next: gtk::Button,
    pause_button: gtk::Button,
    return_button: gtk::Button,
    wrap: gtk::CheckButton,
    code_size: gtk::SpinButton,
    text_size: gtk::SpinButton,
    code_font: gtk::TextTag,
    text_font: gtk::TextTag,
    setting: Rc<Cell<bool>>,
    generation: Cell<u64>,
    index: Cell<usize>,
    selected_source: Cell<usize>,
    phase: Cell<Phase>,
}
fn visible(text: &str) -> String {
    text.replace('\0', "\\u{0000}")
}
fn path_text(text: &str) -> String {
    super::project_view::display(std::path::Path::new(text))
}
fn dropdown(items: &[String]) -> gtk::DropDown {
    let values: Vec<_> = items.iter().map(String::as_str).collect();
    let dropdown = gtk::DropDown::from_strings(&values);
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        let item = object.downcast_ref::<gtk::ListItem>().unwrap();
        let label = gtk::Label::builder()
            .xalign(0.)
            .single_line_mode(true)
            .width_chars(8)
            .max_width_chars(34)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        item.set_child(Some(&label));
    });
    factory.connect_bind(|_, object| {
        let item = object.downcast_ref::<gtk::ListItem>().unwrap();
        let text = item
            .item()
            .unwrap()
            .downcast::<gtk::StringObject>()
            .unwrap()
            .string();
        let label = item.child().unwrap().downcast::<gtk::Label>().unwrap();
        label.set_text(&text);
        label.set_tooltip_text(Some(&text));
    });
    dropdown.set_factory(Some(&factory));
    dropdown.set_list_factory(Some(&factory));
    dropdown.set_hexpand(true);
    dropdown
}
fn font_tag(buffer: &gtk::TextBuffer, points: f64, monospace: bool) -> gtk::TextTag {
    let tag = gtk::TextTag::new(None);
    set_font_size(&tag, points, monospace);
    buffer.tag_table().add(&tag);
    tag
}
fn set_font_size(tag: &gtk::TextTag, size: f64, monospace: bool) {
    // Die Paketgrößen stammen aus logischen Mac-Punkten. Pango-Punktgrößen
    // wären bei 96 dpi um ein Drittel größer als dieselbe Quellschrift in CSS.
    let mut description = gtk::pango::FontDescription::new();
    description.set_absolute_size(size * f64::from(gtk::pango::SCALE));
    if monospace {
        description.set_family("monospace");
    }
    tag.set_font_desc(Some(&description));
}
fn offset(text: &str, units: usize) -> i32 {
    let mut count = 0;
    for (index, c) in text.chars().enumerate() {
        if count == units {
            return index as i32;
        }
        count += c.len_utf16();
    }
    text.chars().count() as i32
}
impl Player {
    fn resize_font(&self, spin: &gtk::SpinButton, delta: f64) {
        let adjustment = spin.adjustment();
        let next = (spin.value() + delta).clamp(adjustment.lower(), adjustment.upper());
        // Am Limit meldet GTK keine Wertänderung; der bewusste Klick muss
        // eine ausstehende Navigation trotzdem wie auf dem Mac pausieren.
        if next == spin.value() {
            self.pause();
        } else {
            spin.set_value(next);
        }
    }
    fn pause(&self) {
        if self.phase.get() == Phase::Closed {
            return;
        }
        self.generation.set(self.generation.get() + 1);
        if let Some(c) = self.control.borrow().as_ref() {
            (c.pause)();
        }
        self.phase.set(Phase::Paused);
        self.update();
    }
    fn update(&self) {
        let count = self.package.manifest.steps.len();
        let index = self.index.get();
        let loading = self.phase.get() == Phase::Loading;
        self.previous.set_sensitive(index > 0 && !loading);
        self.next.set_sensitive(index + 1 < count && !loading);
        self.step_select.set_sensitive(!loading);
        self.return_button
            .set_sensitive(self.phase.get() != Phase::Closed && !loading);
        self.pause_button.set_label(self.lang.text(
            if self.phase.get() == Phase::Paused {
                "Pausiert"
            } else {
                "Pause"
            },
            if self.phase.get() == Phase::Paused {
                "Paused"
            } else {
                "Pause"
            },
        ));
        let state = match self.phase.get() {
            Phase::Loading => self.lang.text(
                "Erklärte Stelle wird angezeigt …",
                "Showing the explained location …",
            ),
            Phase::Ready => self.lang.text("Bereit", "Ready"),
            Phase::Completed => self
                .lang
                .text("Letzter Schritt erreicht", "Last step reached"),
            Phase::Paused => self.lang.text(
                "Pausiert – selbst erkunden oder bewusst zur erklärten Stelle zurückkehren.",
                "Paused — explore or explicitly return to the explained location.",
            ),
            Phase::Failed => self.lang.text(
                "Zielstelle konnte nicht sichtbar bestätigt werden. Erneut zurückkehren.",
                "The target location could not be confirmed visible. Return again.",
            ),
            Phase::Closed => self.lang.text("Beendet", "Closed"),
        };
        self.status.set_text(&format!("{} / {}", index + 1, count));
        self.status.set_tooltip_text(Some(state));
        self.status
            .update_property(&[gtk::accessible::Property::Label(&format!(
                "{} / {}: {state}",
                index + 1,
                count
            ))]);
        self.pause_button.set_tooltip_text(Some(state));
        self.header_status
            .set_text(if self.phase.get() == Phase::Failed {
                state
            } else {
                self.lang
                    .text("Schreibgeschützter Snapshot", "Read-only snapshot")
            });
        let step = &self.package.manifest.steps[index];
        self.step_title.set_text(&visible(&step.title));
        self.step_title.set_tooltip_text(Some(&format!(
            "{}\n{}\n{}",
            visible(&self.package.manifest.title),
            visible(&self.package.manifest.question),
            self.path.tooltip_text().unwrap_or_default()
        )));
    }
    fn display_source(&self, index: usize) {
        let spec = &self.package.manifest.sources[index];
        let source = &self.package.sources[&spec.id];
        self.selected_source.set(index);
        self.source_select.set_selected(index as u32);
        self.buffer.set_text(&source.text);
        let manager = sourceview5::LanguageManager::default();
        self.buffer
            .set_language(manager.guess_language(Some(&spec.path), None).as_ref());
        self.buffer.apply_tag(
            &self.code_font,
            &self.buffer.start_iter(),
            &self.buffer.end_iter(),
        );
        self.buffer.set_modified(false);
        self.path.set_text(
            &std::path::Path::new(&source.path)
                .file_name()
                .map(|name| path_text(&name.to_string_lossy()))
                .unwrap_or_else(|| path_text(&source.path)),
        );
        self.path.set_tooltip_text(Some(&format!(
            "{}\nSHA-256 {}",
            path_text(&source.path),
            source.sha256
        )));
        if let Some(c) = self.control.borrow().as_ref() {
            (c.source)(
                self.control_loaded(index),
                fastra_core::local_control::UUID::parse(&self.document_ids[index]).unwrap(),
            );
        }
    }
    fn navigate(self: &Rc<Self>, index: usize) {
        if self.phase.get() == Phase::Closed || index >= self.package.manifest.steps.len() {
            return;
        }
        self.generation.set(self.generation.get() + 1);
        let generation = self.generation.get();
        self.index.set(index);
        self.phase.set(Phase::Loading);
        self.setting.set(true);
        self.step_select.set_selected(index as u32);
        let step = &self.package.manifest.steps[index];
        let source_index = self
            .package
            .manifest
            .sources
            .iter()
            .position(|s| s.id == step.source_id)
            .unwrap();
        if self.selected_source.get() != source_index || self.buffer.char_count() == 0 {
            self.display_source(source_index);
        }
        self.explanation.buffer().set_text(&visible(&step.text));
        let text_buffer = self.explanation.buffer();
        text_buffer.apply_tag(
            &self.text_font,
            &text_buffer.start_iter(),
            &text_buffer.end_iter(),
        );
        let source_id = step.source_id.clone();
        let hash = self.package.sources[&source_id].sha256.clone();
        let document_id = self.document_ids[source_index].clone();
        let text = &self.package.sources[&source_id].text;
        if let Some(c) = self.control.borrow().as_ref() {
            self.setting.set(false);
            self.update();
            (c.step)(index);
            return;
        }
        let start = offset(text, step.location);
        let end = offset(text, step.location + step.length);
        self.buffer.select_range(
            &self.buffer.iter_at_offset(start),
            &self.buffer.iter_at_offset(end),
        );
        self.setting.set(false);
        self.update();
        let weak = Rc::downgrade(self);
        let started = Instant::now();
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(state) = weak.upgrade().filter(|s| {
                s.window.is_visible()
                    && s.generation.get() == generation
                    && s.phase.get() == Phase::Loading
            }) else {
                return glib::ControlFlow::Break;
            };
            let spec = &state.package.manifest.sources[state.selected_source.get()];
            if spec.id != source_id
                || state.document_ids[state.selected_source.get()] != document_id
                || state.package.sources[&source_id].sha256 != hash
                || state.index.get() != index
            {
                return glib::ControlFlow::Break;
            }
            if started.elapsed() > Duration::from_secs(30) {
                state.phase.set(Phase::Failed);
                state.update();
                return glib::ControlFlow::Break;
            }
            if !state.source.is_mapped() || state.source.width() <= 0 || state.source.height() <= 0
            {
                return glib::ControlFlow::Continue;
            }
            let mut iter = state.buffer.iter_at_offset(start);
            state.source.scroll_to_iter(&mut iter, 0.15, true, 0.0, 0.2);
            if state
                .buffer
                .text(&state.buffer.start_iter(), &state.buffer.end_iter(), true)
                .as_str()
                != state.package.sources[&source_id].text.as_ref()
            {
                state.phase.set(Phase::Failed);
                state.update();
                return glib::ControlFlow::Break;
            }
            let exact = state
                .buffer
                .selection_bounds()
                .map(|(a, b)| (a.offset(), b.offset()))
                .unwrap_or_else(|| {
                    let a = state
                        .buffer
                        .iter_at_mark(&state.buffer.get_insert())
                        .offset();
                    (a, a)
                });
            let actual = state.source.iter_location(&iter);
            let viewport = state.source.visible_rect();
            let visible = actual.height() > 0
                && actual.y() >= viewport.y()
                && actual.y() < viewport.y() + viewport.height()
                && actual.x() >= viewport.x()
                && actual.x() <= viewport.x() + viewport.width();
            if exact == (start, end) && visible {
                state
                    .phase
                    .set(if index + 1 == state.package.manifest.steps.len() {
                        Phase::Completed
                    } else {
                        Phase::Ready
                    });
                state.update();
                glib::ControlFlow::Break
            } else {
                glib::ControlFlow::Continue
            }
        });
    }
}
#[cfg(debug_assertions)]
fn open_package(
    application: &gtk::Application,
    package: Package,
    lang: Language,
) -> Result<Rc<Player>, String> {
    open_package_in(application, package, lang, None, None, true)
}
pub(super) fn open_package_in(
    application: &gtk::Application,
    package: Package,
    lang: Language,
    existing: Option<&gtk::Window>,
    initial_document: Option<fastra_core::local_control::UUID>,
    auto_start: bool,
) -> Result<Rc<Player>, String> {
    if PLAYERS.with(|players| players.borrow().len() >= 16) {
        return Err(lang
            .text(
                "Höchstens 16 Snapshotfenster. Zuerst eines schließen.",
                "At most 16 snapshot windows. Close one first.",
            )
            .into());
    }
    let package = Arc::new(package);
    let manifest = &package.manifest;
    let title = format!(
        "{}: {}",
        lang.text("Code-Erklärung", "Code explanation"),
        visible(&manifest.title)
    );
    let window = existing.cloned().unwrap_or_else(|| {
        gtk::Window::builder()
            .application(application)
            .title(&title)
            .default_width(1000)
            .default_height(820)
            .build()
    });
    crate::chrome::snapshot::decorate(&window, &title, lang);
    window.set_size_request(400, 480);
    let step_title = support::label("");
    step_title.set_wrap(false);
    step_title.set_single_line_mode(true);
    step_title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let header_status =
        support::label(lang.text("Schreibgeschützter Snapshot", "Read-only snapshot"));
    let steps: Vec<_> = manifest
        .steps
        .iter()
        .enumerate()
        .map(|(index, step)| format!("{}. {}", index + 1, visible(&step.title)))
        .collect();
    let step_select = dropdown(&steps);
    let source_names: Vec<_> = manifest
        .sources
        .iter()
        .map(|source| path_text(&source.path))
        .collect();
    let source_select = dropdown(&source_names);
    let path = support::label("");
    path.set_wrap(false);
    path.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
    buffer.set_enable_undo(false);
    let source = sourceview5::View::with_buffer(&buffer);
    crate::source_appearance::install(&source, &buffer);
    crate::chrome::snapshot::source(&source);
    source.set_editable(false);
    source.set_monospace(true);
    source.set_wrap_mode(gtk::WrapMode::WordChar);
    let code_font = font_tag(buffer.upcast_ref(), manifest.code_font_size, true);
    let explanation = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    let text_font = font_tag(&explanation.buffer(), manifest.explanation_font_size, false);
    let previous = gtk::Button::new();
    let next = gtk::Button::new();
    let pause_button = gtk::Button::with_label(lang.text("Pause", "Pause"));
    let return_button = gtk::Button::new();
    let end = gtk::Button::with_label(lang.text("Beenden", "End"));
    let wrap = gtk::CheckButton::with_label("Soft Wrap");
    wrap.set_active(true);
    let code_size = gtk::SpinButton::with_range(8., 32., 1.);
    code_size.set_value(manifest.code_font_size);
    let text_size = gtk::SpinButton::with_range(8., 32., 1.);
    text_size.set_value(manifest.explanation_font_size);
    let status = support::label("");
    status.set_wrap(false);
    let state = Rc::new(Player {
        id: glib::uuid_string_random().to_string(),
        document_ids: manifest
            .sources
            .iter()
            .map(|source| {
                if manifest.steps[0].source_id == source.id {
                    initial_document
                        .as_ref()
                        .map(|id| id.as_str().to_string())
                        .unwrap_or_else(|| glib::uuid_string_random().to_string())
                } else {
                    glib::uuid_string_random().to_string()
                }
            })
            .collect(),
        package,
        lang,
        window,
        source,
        buffer,
        source_select,
        step_select,
        explanation,
        status,
        header_status,
        step_title,
        path,
        previous,
        next,
        pause_button,
        return_button,
        wrap,
        code_size,
        text_size,
        code_font,
        text_font,
        setting: Rc::new(Cell::new(false)),
        control: RefCell::new(None),
        generation: Cell::new(0),
        index: Cell::new(0),
        selected_source: Cell::new(usize::MAX),
        phase: Cell::new(Phase::Loading),
    });
    let source_scroll = layout::mount(&state, &end);
    let weak = Rc::downgrade(&state);
    state.previous.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.navigate(s.index.get().saturating_sub(1));
        }
    });
    let weak = Rc::downgrade(&state);
    state.next.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.navigate(s.index.get() + 1);
        }
    });
    let weak = Rc::downgrade(&state);
    state.pause_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.pause();
        }
    });
    let weak = Rc::downgrade(&state);
    state.return_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.navigate(s.index.get());
        }
    });
    let weak = Rc::downgrade(&state);
    end.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.window.close();
        }
    });
    let weak = Rc::downgrade(&state);
    state.step_select.connect_selected_notify(move |dropdown| {
        if let Some(s) = weak.upgrade().filter(|s| !s.setting.get()) {
            s.navigate(dropdown.selected() as usize);
        }
    });
    let weak = Rc::downgrade(&state);
    state
        .source_select
        .connect_selected_notify(move |dropdown| {
            if let Some(s) = weak.upgrade().filter(|s| !s.setting.get()) {
                s.pause();
                s.setting.set(true);
                s.display_source(dropdown.selected() as usize);
                s.setting.set(false);
            }
        });
    let weak = Rc::downgrade(&state);
    state.wrap.connect_toggled(move |wrap| {
        if let Some(s) = weak.upgrade() {
            s.pause();
            s.source.set_wrap_mode(if wrap.is_active() {
                gtk::WrapMode::WordChar
            } else {
                gtk::WrapMode::None
            });
        }
    });
    let weak = Rc::downgrade(&state);
    state.code_size.connect_value_changed(move |spin| {
        if let Some(s) = weak.upgrade() {
            s.pause();
            set_font_size(&s.code_font, spin.value(), true);
        }
    });
    let weak = Rc::downgrade(&state);
    state.text_size.connect_value_changed(move |spin| {
        if let Some(s) = weak.upgrade() {
            s.pause();
            set_font_size(&s.text_font, spin.value(), false);
        }
    });
    let weak = Rc::downgrade(&state);
    state.buffer.connect_mark_set(move |_, _, mark| {
        if !matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
            return;
        }
        if let Some(s) = weak.upgrade().filter(|s| !s.setting.get()) {
            s.pause();
        }
    });
    let weak = Rc::downgrade(&state);
    state.buffer.connect_changed(move |_| {
        if let Some(state) = weak.upgrade().filter(|state| !state.setting.get()) {
            state.pause();
        }
    });
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
    scroll.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&state);
    scroll.connect_scroll(move |_, _, _| {
        if let Some(s) = weak.upgrade() {
            s.pause();
        }
        glib::Propagation::Proceed
    });
    source_scroll.add_controller(scroll);
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&state);
    keys.connect_key_pressed(move |_, _, _, _| {
        if let Some(s) = weak.upgrade() {
            s.pause();
        }
        glib::Propagation::Proceed
    });
    source_scroll.add_controller(keys);
    let click = gtk::GestureClick::new();
    click.set_propagation_phase(gtk::PropagationPhase::Capture);
    click.set_button(0);
    let weak = Rc::downgrade(&state);
    click.connect_pressed(move |_, _, _, _| {
        if let Some(s) = weak.upgrade() {
            s.pause();
        }
    });
    source_scroll.add_controller(click);
    let weak = Rc::downgrade(&state);
    state.window.connect_close_request(move |_| {
        if let Some(s) = weak.upgrade() {
            s.generation.set(s.generation.get() + 1);
            s.phase.set(Phase::Closed);
            PLAYERS.with(|players| players.borrow_mut().retain(|p| p.id != s.id));
        }
        glib::Propagation::Proceed
    });
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&state);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK) && key == gtk::gdk::Key::w {
            if let Some(state) = weak.upgrade() {
                state.window.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    state.window.add_controller(keys);
    PLAYERS.with(|players| players.borrow_mut().push(state.clone()));
    state.window.present();
    if auto_start {
        state.navigate(0);
    }
    Ok(state)
}
pub(super) fn choose(ui: &Rc<Ui>) {
    let dialog = gtk::FileDialog::new();
    dialog.set_title(
        ui.lang
            .text("Gespeicherte Codefrage öffnen", "Open saved code question"),
    );
    let filter = gtk::FileFilter::new();
    filter.set_name(Some("JSON"));
    filter.add_pattern("*.json");
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    dialog.set_filters(Some(&filters));
    let weak = Rc::downgrade(ui);
    dialog.open(Some(&ui.window), None::<&gio::Cancellable>, move |result| {
        if let (Some(ui), Ok(file)) = (weak.upgrade().filter(|ui| ui.window.is_visible()), result) {
            if let Some(path) = file.path() {
                load(&ui, path);
            }
        }
    });
}

fn load(ui: &Rc<Ui>, path: PathBuf) {
    super::local_control::open_manifest(ui, path);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}

struct ControlCallbacks {
    pause: Rc<dyn Fn()>,
    source: Rc<dyn Fn(fastra_io::local_control::Loaded, fastra_core::local_control::UUID)>,
    step: Rc<dyn Fn(usize)>,
}
impl Player {
    fn control_loaded(&self, index: usize) -> fastra_io::local_control::Loaded {
        let spec = &self.package.manifest.sources[index];
        let source = &self.package.sources[&spec.id];
        // Der Paketloader akzeptiert nur UTF-8 mit höchstens einer abgetrennten Datei-BOM.
        let text_sha256 = fastra_io::local_control::hash(source.text.as_bytes());
        let bom_bytes = if source.sha256 == text_sha256 { 0 } else { 3 };
        fastra_io::local_control::Loaded {
            name: source.path.clone(),
            text: source.text.clone(),
            sha256: source.sha256.clone(),
            text_sha256,
            byte_count: source.text.len() + bom_bytes,
            encoding: 4,
            bom_bytes,
        }
    }
    pub(super) fn control_view(
        &self,
    ) -> (
        gtk::Window,
        sourceview5::View,
        sourceview5::Buffer,
        Rc<Cell<bool>>,
    ) {
        (
            self.window.clone(),
            self.source.clone(),
            self.buffer.clone(),
            self.setting.clone(),
        )
    }
    pub(super) fn control_bind(
        &self,
        pause: Rc<dyn Fn()>,
        source: Rc<dyn Fn(fastra_io::local_control::Loaded, fastra_core::local_control::UUID)>,
        step: Rc<dyn Fn(usize)>,
    ) {
        *self.control.borrow_mut() = Some(ControlCallbacks {
            pause,
            source,
            step,
        });
    }
    pub(super) fn control_cancelled(&self) {
        self.phase.set(Phase::Paused);
        self.update();
    }
    pub(super) fn control_loading(&self) {
        self.phase.set(Phase::Loading);
        self.update();
    }
    pub(super) fn control_pause(&self) {
        self.pause();
    }
    pub(super) fn control_navigate(self: &Rc<Self>, index: usize) {
        self.navigate(index);
    }
    pub(super) fn control_step(
        &self,
        index: usize,
    ) -> (fastra_core::local_control::Selection, String) {
        let step = &self.package.manifest.steps[index];
        (
            fastra_core::local_control::Selection {
                location: step.location as i64,
                length: step.length as i64,
            },
            self.package.sources[&step.source_id].sha256.clone(),
        )
    }
    pub(super) fn control_finished(&self, success: bool) {
        self.phase.set(if success {
            if self.index.get() + 1 == self.package.manifest.steps.len() {
                Phase::Completed
            } else {
                Phase::Ready
            }
        } else {
            Phase::Failed
        });
        self.update();
    }
}

#[cfg(debug_assertions)]
impl Player {
    pub(super) fn control_test_paused(&self) -> bool {
        self.phase.get() == Phase::Paused
    }
    pub(super) fn control_test_next(&self) {
        support::test_click(&self.next, &[]);
    }
    pub(super) fn control_test_return(&self) {
        support::test_click(&self.return_button, &[]);
    }
}

#[cfg(debug_assertions)]
impl Player {
    pub(super) fn check_layout(&self) {
        layout::check_geometry(&self.window);
    }
}
