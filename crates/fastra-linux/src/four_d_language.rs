use super::*;
/// Registrierung vor dem ersten LanguageManager-Zugriff; die Standardsuchpfade bleiben erhalten.
pub(super) fn install() {
    let bytes = glib::Bytes::from_static(include_bytes!(concat!(
        env!("OUT_DIR"),
        "/fastra.gresource"
    )));
    let resource = gio::Resource::from_data(&bytes).expect("Bundled 4D GResource");
    gio::resources_register(&resource);
    if let Some(display) = gtk::gdk::Display::default() { gtk::IconTheme::for_display(&display).add_resource_path("/org/fastra/icons"); }
    let manager = sourceview5::LanguageManager::default();
    let mut paths = vec!["resource:///org/fastra/language-specs".to_owned()];
    paths.extend(manager.search_path().iter().map(|p| p.to_string()));
    let paths: Vec<&str> = paths.iter().map(String::as_str).collect();
    manager.set_search_path(&paths);
}
