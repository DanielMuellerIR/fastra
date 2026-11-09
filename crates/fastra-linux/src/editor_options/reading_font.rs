//! Gemeinsame Leseschrift ohne Neuladen oder Eingriffe in den Rich-Undo-Verlauf.
use super::*;
use gtk::{gio, pango};
use webkit6::prelude::*;
const FILE: &str = "reading-font.json";
struct Controls {
    choice: glib::WeakRef<gtk::DropDown>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
struct State {
    selection: Rc<super::font_selection::Selection>,
    views: RefCell<Vec<glib::WeakRef<webkit6::WebView>>>,
    controls: RefCell<Vec<Controls>>,
}
impl std::ops::Deref for State {
    type Target = super::font_selection::Selection;
    fn deref(&self) -> &Self::Target { &self.selection }
}
thread_local! {
    static STATE: RefCell<Option<Rc<State>>> = const { RefCell::new(None) };
    static APP: RefCell<glib::WeakRef<gtk::Application>> = RefCell::new(glib::WeakRef::new());
}
fn state(context: &pango::Context) -> Rc<State> {
    STATE.with(|slot| {
        if let Some(state) = slot.borrow().as_ref() {
            return state.clone();
        }
        let state = Rc::new(State {
            selection: super::font_selection::Selection::new(font::faces(context, false), FILE, super::font_selection::Policy::Held(|| APP.with(|app| app.borrow().upgrade()))),
            views: RefCell::new(Vec::new()),
            controls: RefCell::new(Vec::new()),
        });
        *slot.borrow_mut() = Some(state.clone());
        let owner = Rc::downgrade(&state);
        state.selection.on_change(move |apply| { if let Some(state) = owner.upgrade() { if apply { state.apply(); } else { state.refresh(); } } });
        state.load();
        state
    })
}
impl State {
    fn apply_web(&self, view: &webkit6::WebView) {
        let css = font::face_css(
            "body",
            self.description().as_ref(),
            "'Fastra UI',system-ui,sans-serif",
        );
        let css = serde_json::to_string(&css).unwrap();
        // Nur ein Stylesheet im Kopf ändern. Contenteditable, Auswahl und native
        // Editierhistorie bleiben unangetastet; ein späterer Font-Ladevorgang darf
        // die Bestätigung einer inzwischen neueren Wahl nicht überschreiben.
        view.evaluate_javascript(&format!(r#"(async()=>{{
            if(!document.head)return;
            let sheet=document.getElementById('fastra-reading-font');
            if(!sheet){{sheet=document.createElement('style');sheet.id='fastra-reading-font';document.head.append(sheet);}}
            const css={css};sheet.textContent=css;
            await document.fonts.ready;
            if(sheet.textContent===css)window.fastraReadingFontApplied=css;
        }})()"#), None, None, None::<&gio::Cancellable>, |_| {});
    }
    fn apply(&self) {
        let views: Vec<_> = self
            .views
            .borrow()
            .iter()
            .filter_map(glib::WeakRef::upgrade)
            .collect();
        self.views
            .borrow_mut()
            .retain(|view| view.upgrade().is_some());
        for view in views {
            self.apply_web(&view);
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
            let Some(choice)=controls.choice.upgrade() else { return false };
            let missing = self.selection.sync_choice(&choice, controls.lang, controls.lang.text("Systemschrift", "System font"));
            choice.set_sensitive(self.loaded.get());
            if let Some(status)=controls.status.upgrade() {
                status.set_text(&if let Some(error)=&error { format!("{}: {error}",controls.lang.text("Leseschrift konnte nicht geladen oder gespeichert werden","Reading font could not be loaded or saved")) }
                    else if !self.loaded.get() { controls.lang.text("Leseschrift wird geladen …","Loading reading font …").into() }
                    else if missing { controls.lang.text("Die gespeicherte Schrift fehlt. Vorläufig wird die Systemschrift verwendet; die gespeicherte Wahl bleibt erhalten.","The saved font is unavailable. The system font is used temporarily; the saved choice is retained.").into() }
                    else if self.busy.get() || self.queued.get() { controls.lang.text("Leseschrift angewendet; Einstellung wird gespeichert …","Reading font applied; saving preference …").into() } else { String::new() });
                status.set_visible(!status.text().is_empty()); status.set_tooltip_text(Some(&status.text()));
            }
            if let Some(retry)=controls.retry.upgrade() { retry.set_visible(error.is_some()); retry.set_sensitive(!self.busy.get()); }
            true
        });
        self.updating.set(false);
    }
}
pub(crate) fn install(app: &gtk::Application) {
    APP.with(|slot| *slot.borrow_mut() = app.downgrade());
    app.connect_startup(|_| {
        state(&gtk::Label::new(None).pango_context());
    });
}
pub(crate) fn install_web(view: &webkit6::WebView) {
    let state = state(&view.pango_context());
    state.views.borrow_mut().push(view.downgrade());
    state.apply_web(view);
    let weak = Rc::downgrade(&state);
    view.connect_load_changed(move |view, event| {
        if event == webkit6::LoadEvent::Finished {
            if let Some(state) = weak.upgrade() {
                state.apply_web(view);
            }
        }
    });
}
pub(super) fn controls(lang: crate::Language, group: &gtk::Box) {
    let state = state(&group.pango_context());
    let row = super::settings_form::row(group);
    super::settings_form::label(&row, lang.text("Vorschau-Schrift", "Preview Font"));
    let choice = gtk::DropDown::from_strings(&[]);
    choice.set_widget_name("fastra-reading-font");
    choice.add_css_class("settings-font-choice");
    choice.update_property(&[gtk::accessible::Property::Label(
        lang.text("Vorschau-Schrift", "Preview Font"),
    )]);
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let label = gtk::Label::new(None);
        label.set_xalign(0.);
        label.set_max_width_chars(28);
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
    row.append(&choice);
    super::settings_form::note(group,lang.text("Leseschrift für die Markdown-Vorschau und den Rich-Editor. Der Quelltext bleibt unverändert.","Reading font for Markdown preview and the Rich editor. Source text remains unchanged."));
    let status = crate::git_view::label("");
    status.set_wrap_mode(pango::WrapMode::WordChar);
    status.set_lines(4);
    status.set_ellipsize(pango::EllipsizeMode::End);
    status.add_css_class("settings-feedback");
    group.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_widget_name("fastra-reading-font-retry");
    retry.add_css_class("settings-feedback");
    retry.set_halign(gtk::Align::End);
    group.append(&retry);
    state.controls.borrow_mut().push(Controls {
        choice: choice.downgrade(),
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
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
        "Leseschrift wird noch gespeichert. Schließen danach erneut wählen.",
        "Reading font is still being saved. Request close again after completion.",
    ));
    false
}
#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
