//! Quellschrift und -farben bleiben auch unter unvollständigen Desktopthemes verlässlich.
use super::*;

type SettingsHandlers = Option<(gtk::Settings, Vec<glib::SignalHandlerId>)>;

thread_local! {
    static FONT_DISPLAYS: RefCell<Vec<glib::WeakRef<gtk::gdk::Display>>> = const { RefCell::new(Vec::new()) };
    static SCHEMES: RefCell<Option<tempfile::TempDir>> = const { RefCell::new(None) };
}

pub(super) fn cleanup_schemes() {
    SCHEMES.with(|directory| {
        directory.borrow_mut().take();
    });
}

fn schemes() -> sourceview5::StyleSchemeManager {
    let manager = sourceview5::StyleSchemeManager::default();
    SCHEMES.with(|storage| {
        if storage.borrow().is_none() {
            // Die unterstützte GtkSourceView-Untergrenze liest Farbschemata nur
            // aus Verzeichnissen; GResource-URIs gibt es dafür erst ab 5.16.
            let directory = tempfile::Builder::new()
                .prefix("fastra-colors-")
                .tempdir()
                .expect("Fastra color resources");
            for (name, content) in [
                ("fastra-light.xml", include_str!("chrome/fastra-light.xml")),
                ("fastra-dark.xml", include_str!("chrome/fastra-dark.xml")),
            ] {
                std::fs::write(directory.path().join(name), content)
                    .expect("Fastra color resource file");
            }
            manager
                .prepend_search_path(directory.path().to_str().expect("temporary resource path"));
            manager.force_rescan();
            *storage.borrow_mut() = Some(directory);
        }
    });
    manager
}

fn install_font(view: &sourceview5::View) {
    view.add_css_class("fastra-source");
    editor_options::font::install(view);
    FONT_DISPLAYS.with(|displays| {
        let display = view.display();
        let mut displays = displays.borrow_mut();
        displays.retain(|weak| weak.upgrade().is_some());
        if displays
            .iter()
            .any(|weak| weak.upgrade().as_ref() == Some(&display))
        {
            return;
        }
        // set_monospace setzt nur eine CSS-Klasse. Manche Desktopthemes liefern
        // dafür keine Regel; feste Spalten brauchen trotzdem gleich breite Zellen.
        let provider = gtk::CssProvider::new();
        provider.load_from_string(".fastra-source { font-family: monospace; }");
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        displays.push(display.downgrade());
    });
}

pub(super) fn print_scheme() -> Option<sourceview5::StyleScheme> {
    schemes().scheme("fastra-light")
}

fn apply(view: &sourceview5::View, buffer: &sourceview5::Buffer) {
    // Vor dem Einbinden ist die View-Farbe noch kein Theme-Beleg. Danach die
    // native Fensterfarbe lesen: Die SourceView-Farbe enthält bereits unser
    // Farbschema und würde einen späteren Themewechsel selbst überdecken.
    let dark = editor_options::appearance::explicit().unwrap_or_else(|| {
        view.root()
            .and_then(|root| root.dynamic_cast::<gtk::Widget>().ok())
            .filter(|_| view.is_mapped())
            .map(|root| {
                let color = root.color();
                color.red() + color.green() + color.blue() > 1.8
            })
            .unwrap_or_else(|| {
                std::env::var("GTK_THEME").is_ok_and(|theme| theme.ends_with(":dark"))
                    || view.settings().is_gtk_application_prefer_dark_theme()
            })
    });
    let schemes = schemes();
    if let Some(scheme) = schemes
        .scheme(if dark { "fastra-dark" } else { "fastra-light" })
        .or_else(|| schemes.scheme(if dark { "oblivion" } else { "classic" }))
    {
        if buffer.style_scheme().as_ref() != Some(&scheme) {
            buffer.set_style_scheme(Some(&scheme));
        }
    }
}

fn queue_refresh(view: &sourceview5::View, buffer: &sourceview5::Buffer, pending: &Rc<Cell<bool>>) {
    if pending.replace(true) {
        return;
    }
    let view = view.downgrade();
    let buffer = buffer.downgrade();
    let pending = pending.clone();
    glib::idle_add_local_once(move || {
        pending.set(false);
        if let (Some(view), Some(buffer)) = (view.upgrade(), buffer.upgrade()) {
            if view.is_mapped() {
                apply(&view, &buffer);
            }
        }
    });
}

pub(super) fn install(view: &sourceview5::View, buffer: &sourceview5::Buffer) {
    install_font(view);
    apply(view, buffer);
    let handlers = Rc::new(RefCell::new(SettingsHandlers::None));
    let pending = Rc::new(Cell::new(false));
    let view_weak = view.downgrade();
    let buffer_weak = buffer.downgrade();
    let theme_pending = pending.clone();
    editor_options::appearance::watch(move || {
        let (Some(view), Some(buffer)) = (view_weak.upgrade(), buffer_weak.upgrade()) else {
            return false;
        };
        if view.is_mapped() {
            queue_refresh(&view, &buffer, &theme_pending);
        }
        true
    });
    let buffer_weak = buffer.downgrade();
    let mapped_handlers = handlers.clone();
    view.connect_map(move |view| {
        let Some(buffer) = buffer_weak.upgrade() else {
            return;
        };
        apply(view, &buffer);
        queue_refresh(view, &buffer, &pending);
        if mapped_handlers.borrow().is_some() {
            return;
        }
        let settings = view.settings();
        let mut ids = Vec::new();
        for property in ["gtk-theme-name", "gtk-application-prefer-dark-theme"] {
            let view_weak = view.downgrade();
            let buffer_weak = buffer.downgrade();
            let pending = pending.clone();
            ids.push(settings.connect_notify_local(Some(property), move |_, _| {
                if let (Some(view), Some(buffer)) = (view_weak.upgrade(), buffer_weak.upgrade()) {
                    queue_refresh(&view, &buffer, &pending);
                }
            }));
        }
        *mapped_handlers.borrow_mut() = Some((settings, ids));
    });
    // GtkSettings lebt pro Display. Geschlossene und verborgene Quellansichten
    // dürfen dort keine dauerhaften Callbacks ansammeln.
    view.connect_unmap(move |_| {
        if let Some((settings, ids)) = handlers.borrow_mut().take() {
            for id in ids {
                settings.disconnect(id);
            }
        }
    });
}

#[cfg(debug_assertions)]
pub(super) mod selftest;
