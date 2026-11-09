//! Nur lesende Geometrie für native Eingaben in der vorhandenen privaten Lifecycle-Prüfung.
use super::*;
pub(super) fn xid(window: &gtk::Window) -> Option<u64> {
    let native = window.native()?;
    let surface = native.surface()?;
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    if symbol.is_null() {
        return None;
    }
    let get: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    Some(unsafe { get(surface.as_ptr().cast()) })
}
fn widgets(widget: &gtk::Widget, window: &gtk::Window, found: &mut Vec<serde_json::Value>) {
    if !widget.is_mapped() || widget.width() <= 0 || widget.height() <= 0 {
        return;
    }
    let kind = if widget.is::<gtk::Button>() {
        "button"
    } else if widget.is::<gtk::MenuButton>() {
        "menu"
    } else if widget.is::<gtk::SpinButton>() {
        "spin"
    } else if widget.downcast_ref::<gtk::Label>().is_some_and(|label| label.text() == "Fastra") {
        "print-tab"
    } else if widget.is::<gtk::Switch>() {
        "switch"
    } else if widget.is::<gtk::CheckButton>() {
        "check"
    } else if widget.is::<sourceview5::View>() {
        "source"
    } else if widget.is::<webkit6::WebView>() {
        "rich"
    } else if widget.is::<gtk::Entry>() {
        "entry"
    } else {
        ""
    };
    if !kind.is_empty() {
        if let Some(bounds) = widget.compute_bounds(window) {
            let label = widget
                .downcast_ref::<gtk::Button>()
                .and_then(|button| button.label())
                .or_else(|| widget.downcast_ref::<gtk::Label>().map(|label| label.text()))
                .or_else(|| widget.downcast_ref::<gtk::MenuButton>().and_then(|button|button.label()))
                .or_else(|| {
                    widget
                        .downcast_ref::<gtk::CheckButton>()
                        .and_then(|button| button.label())
                });
            let active = widget
                .downcast_ref::<gtk::CheckButton>()
                .map(|button| button.is_active()).or_else(||widget.downcast_ref::<gtk::Switch>().map(|switch|switch.is_active()));
            let entry = widget.downcast_ref::<gtk::Entry>();
            let text = entry.map(|entry|entry.text().to_string());
            let selection = entry.and_then(|entry|entry.selection_bounds());
            found.push(serde_json::json!({"value":widget.downcast_ref::<gtk::SpinButton>().map(|spin|spin.value()),"text":text,"selection":selection,"classes":widget.css_classes().iter().map(|class|class.to_string()).collect::<Vec<_>>(),"name":widget.widget_name().as_str(),"kind":kind,"label":label.as_deref(),"active":active,"sensitive":widget.is_sensitive(),"x":bounds.x()+bounds.width()/2.,"y":bounds.y()+bounds.height()/2.,"width":bounds.width(),"height":bounds.height()}));
        }
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        widgets(&item, window, found);
        child = item.next_sibling();
    }
}
pub(super) fn windows() -> serde_json::Value {
    if !gtk::is_initialized_main_thread() {
        return serde_json::json!([]);
    }
    let windows:Vec<_>=gtk::Window::list_toplevels().iter().filter_map(|item|item.downcast_ref::<gtk::Window>()).filter(|window|window.is_visible()&&window.is_mapped()).map(|window|{
        let mut controls=Vec::new();widgets(window.upcast_ref(),window,&mut controls);
        let (surface_x,surface_y)=window.surface_transform();
        serde_json::json!({"minimumWidth":window.measure(gtk::Orientation::Horizontal,-1).0,"surfaceX":surface_x,"surfaceY":surface_y,"xid":xid(window),"title":window.title().as_deref(),"width":window.width(),"height":window.height(),"widgets":controls})
    }).collect();
    serde_json::json!(windows)
}
