//! Eine gemeinsame Quellschrift für alle Fenster; persistiert ohne Zugriff auf Dokumentinhalte.
use super::*;
use gtk::{glib::translate::IntoGlib, pango};
pub(super) mod store;

pub(super) struct Face {
    pub(super) name: String,
    pub(super) description: pango::FontDescription,
}
struct Controls {
    choice: glib::WeakRef<gtk::DropDown>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
    compact: bool,
}
struct State {
    selection: Rc<super::font_selection::Selection>,
    displays: RefCell<Vec<(glib::WeakRef<gtk::gdk::Display>, gtk::CssProvider)>>,
    controls: RefCell<Vec<Controls>>,
}
impl std::ops::Deref for State {
    type Target = super::font_selection::Selection;
    fn deref(&self) -> &Self::Target { &self.selection }
}
thread_local! { static STATE: RefCell<Option<Rc<State>>> = const { RefCell::new(None) }; }
fn state(context: &pango::Context) -> Rc<State> {
    STATE.with(|slot| {
        if let Some(state) = slot.borrow().as_ref() {
            return state.clone();
        }
        let state = Rc::new(State {
            selection: super::font_selection::Selection::new(faces(context, true), "source-font.json", super::font_selection::Policy::Deferred),
            displays: RefCell::new(Vec::new()),
            controls: RefCell::new(Vec::new()),
        });
        *slot.borrow_mut() = Some(state.clone());
        let owner = Rc::downgrade(&state);
        state.selection.on_change(move |apply| { if let Some(state) = owner.upgrade() { if apply { state.apply(); } else { state.refresh(); } } });
        state.load();
        state
    })
}
pub(super) fn faces(context: &pango::Context, monospace: bool) -> Vec<Face> {
    let mut faces: Vec<_> = context
        .list_families()
        .iter()
        .filter(|family| family.is_monospace() == monospace)
        .flat_map(|family| family.list_faces())
        .map(|face| {
            let description = face.describe();
            Face {
                name: description.to_string().to_string(),
                description,
            }
        })
        .filter(|face| store::valid_name(&face.name))
        .collect();
    faces.sort_by_cached_key(|face| face.name.to_lowercase());
    faces.dedup_by(|a, b| a.name == b.name);
    faces
}
fn css_string(value: &str) -> String {
    let mut text = String::from("\"");
    for ch in value.chars() {
        match ch {
            '"' | '\\' => {
                text.push('\\');
                text.push(ch);
            }
            ch if ch.is_control() => text.push_str(&format!("\\{:x} ", ch as u32)),
            ch => text.push(ch),
        }
    }
    text.push('"');
    text
}
fn css(description: Option<&pango::FontDescription>) -> String {
    face_css(".fastra-source", description, "monospace")
}
pub(super) fn face_css(
    selector: &str,
    description: Option<&pango::FontDescription>,
    fallback: &str,
) -> String {
    let Some(description) = description else {
        return format!("{selector} {{ font-family: {fallback}; font-weight: 400; font-style: normal; font-stretch: normal; }}");
    };
    let family = css_string(description.family().as_deref().unwrap_or("sans-serif"));
    let weight: i32 = description.weight().into_glib();
    let style = match description.style() {
        pango::Style::Italic => "italic",
        pango::Style::Oblique => "oblique",
        _ => "normal",
    };
    let stretch = match description.stretch() {
        pango::Stretch::UltraCondensed => "ultra-condensed",
        pango::Stretch::ExtraCondensed => "extra-condensed",
        pango::Stretch::Condensed => "condensed",
        pango::Stretch::SemiCondensed => "semi-condensed",
        pango::Stretch::SemiExpanded => "semi-expanded",
        pango::Stretch::Expanded => "expanded",
        pango::Stretch::ExtraExpanded => "extra-expanded",
        pango::Stretch::UltraExpanded => "ultra-expanded",
        _ => "normal",
    };
    format!("{selector} {{ font-family: {family}, {fallback}; font-weight: {weight}; font-style: {style}; font-stretch: {stretch}; }}")
}
impl State {
    fn apply(&self) {
        let css = css(self.description().as_ref());
        let providers: Vec<_> = self
            .displays
            .borrow()
            .iter()
            .map(|(_, provider)| provider.clone())
            .collect();
        for provider in providers {
            provider.load_from_string(&css);
        }
        self.refresh();
    }
    fn load(&self) { self.selection.load(); }
    fn choose(&self, face: Option<String>) { self.selection.choose(face); }
    fn save(&self) { self.selection.save(); }
    fn refresh(&self) {
        self.updating.set(true);
        let error = self.error.borrow().clone();
        self.controls.borrow_mut().retain(|controls| {
            let Some(choice) = controls.choice.upgrade() else { return false };
            let missing = self.selection.sync_choice(&choice, controls.lang, controls.lang.text("System-Monospace", "System monospace"));
            choice.set_sensitive(self.loaded.get() && !self.busy.get());
            if let Some(status) = controls.status.upgrade() {
                status.set_text(&if let Some(error) = &error {
                    format!("{}: {error}", controls.lang.text("Schrifteinstellung nicht gespeichert oder geladen", "Font setting could not be saved or loaded"))
                } else if !self.loaded.get() {
                    controls.lang.text("Schrifteinstellung wird geladen …", "Loading font setting …").to_owned()
                } else if missing {
                    controls.lang.text("Die gespeicherte Schrift fehlt. Vorläufig wird System-Monospace verwendet; die gespeicherte Wahl bleibt erhalten.", "The saved font is unavailable. System monospace is used temporarily; the saved choice is retained.").to_owned()
                } else if self.busy.get() {
                    controls.lang.text("Schrift angewendet; Einstellung wird gespeichert …", "Font applied; saving preference …").to_owned()
                } else {
                    controls.lang.text("Gilt für die Quellansichten aller Fenster. Text, Auswahl, Kodierung und Zeilenenden bleiben erhalten.", "Applies to source views in every window. Text, selection, encoding and line endings are retained.").to_owned()
                });
                status.set_tooltip_text(Some(&status.text()));
                status.set_visible(!controls.compact || error.is_some() || missing || !self.loaded.get() || self.busy.get());
            }
            if let Some(retry) = controls.retry.upgrade() { retry.set_visible(error.is_some()); retry.set_sensitive(!self.busy.get()); }
            true
        });
        self.updating.set(false);
    }
}
pub(crate) fn install(view: &sourceview5::View) {
    let state = state(&view.pango_context());
    let display = view.display();
    let mut displays = state.displays.borrow_mut();
    displays.retain(|(display, _)| display.upgrade().is_some());
    if displays
        .iter()
        .any(|(known, _)| known.upgrade().as_ref() == Some(&display))
    {
        return;
    }
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&css(state.description().as_ref()));
    gtk::style_context_add_provider_for_display(
        &display,
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    displays.push((display.downgrade(), provider));
}
pub(super) fn controls(ui: &Rc<Ui>, root: &gtk::Box) {
    controls_for(ui.lang, root);
}
pub(super) fn controls_for(lang: crate::Language, root: &gtk::Box) {
    build_controls(lang, root, false);
}
pub(super) fn form_controls(lang: crate::Language, root: &gtk::Box) {
    build_controls(lang, root, true);
}
fn build_controls(lang: crate::Language, root: &gtk::Box, compact: bool) {
    let state = state(&root.pango_context());
    let heading = crate::git_view::label(lang.text("Dokumentschrift", "Document font"));
    let row = if compact {
        let row=super::settings_form::row(root);heading.set_hexpand(true);row.append(&heading);row
    } else {
        heading.add_css_class("tool-heading");root.append(&heading);root.clone()
    };
    let choice = gtk::DropDown::from_strings(&[]);
    choice.set_hexpand(!compact);
    if compact { choice.add_css_class("settings-font-choice"); }
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let label = gtk::Label::new(None);
        label.set_xalign(0.);
        label.set_max_width_chars(if compact { 28 } else { 48 });
        label.set_ellipsize(pango::EllipsizeMode::End);
        item.downcast_ref::<gtk::ListItem>()
            .unwrap()
            .set_child(Some(&label));
    });
    factory.connect_bind(|_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let text = item
            .item()
            .and_downcast::<gtk::StringObject>()
            .unwrap()
            .string();
        let label = item.child().and_downcast::<gtk::Label>().unwrap();
        label.set_text(&text);
        label.set_tooltip_text(Some(&text));
    });
    choice.set_factory(Some(&factory));
    choice.set_widget_name("fastra-source-font");
    choice.update_property(&[gtk::accessible::Property::Label(
        lang.text("Dokumentschrift", "Document font"),
    )]);
    row.append(&choice);
    let status = crate::git_view::label("");
    status.set_wrap_mode(pango::WrapMode::WordChar);
    status.set_lines(4);
    status.set_ellipsize(pango::EllipsizeMode::End);
    if compact { status.add_css_class("settings-feedback"); }
    root.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    if compact { retry.add_css_class("settings-feedback"); retry.set_halign(gtk::Align::End); }
    root.append(&retry);
    state.controls.borrow_mut().push(Controls {
        choice: choice.downgrade(),
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
        compact,
    });
    let weak = Rc::downgrade(&state);
    choice.connect_selected_notify(move |choice| {
        if let Some(state) = weak.upgrade() {
            if state.updating.get() {
                return;
            }
            let index = choice.selected() as usize;
            if index == 0 {
                state.choose(None);
            } else if let Some(face) = state.faces.get(index - 1) {
                state.choose(Some(face.name.clone()));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    retry.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if state.loaded.get() {
                state.save();
            } else {
                state.load();
            }
        }
    });
    state.refresh();
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}

// Fehler der Darstellungseinstellung bleiben sichtbar und erneut versuchbar;
// sie dürfen das Schließen eines unveränderten Dokuments nicht dauerhaft sperren.
pub(super) fn pending() -> bool {
    STATE.with(|slot| {
        slot.borrow().as_ref().is_some_and(|state| {
            state.is_pending()
        })
    })
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Dokumentschrift wird noch gespeichert. Schließen angehalten; nach Abschluss erneut wählen.",
        "Document font is still being saved. Close held; request it again after completion.",
    ));
    let state = STATE.with(|slot| slot.borrow().clone());
    if let Some(state) = state {
        state.save();
    }
    false
}

pub(crate) fn print_description(context: &pango::Context, size: u8, lang: crate::Language) -> Result<pango::FontDescription, String> {
    let state = state(context);
    if !state.loaded.get() || state.busy.get() || state.pending.borrow().is_some() {
        return Err(lang.text("Die Quellschrift wird noch geladen oder gespeichert", "The source font is still loading or saving").into());
    }
    if let Some(error) = state.error.borrow().as_ref() { return Err(error.clone()); }
    let mut description = state.description().unwrap_or_else(|| pango::FontDescription::from_string("Monospace"));
    description.set_size(i32::from(size) * pango::SCALE);
    Ok(description)
}
