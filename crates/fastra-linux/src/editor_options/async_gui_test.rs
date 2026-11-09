use super::*;
use crate::git_view as support;
use gtk::gio;
use std::time::{Duration, Instant};
use webkit6::prelude::*;
pub(crate) async fn wait(reason: &str, ready: impl Fn() -> bool) {
    let began = Instant::now();
    while !ready() {
        assert!(began.elapsed() < Duration::from_secs(15), "{reason}");
        glib::timeout_future(Duration::from_millis(40)).await;
    }
}

pub(crate) async fn input(widget: &impl IsA<gtk::Widget>, keys: &[&str], click: bool) {
    if click {
        wait("mapped and allocated native target", || {
            widget.is_mapped() && widget.width() > 0 && widget.height() > 0
        })
        .await;
    }
    let received = support::test_input_completed(widget, keys, click);
    wait("native input completion", || received.try_recv().is_ok()).await;
    glib::timeout_future(Duration::from_millis(100)).await;
}

pub(crate) async fn inspect(view: &webkit6::WebView, script: &str) -> serde_json::Value {
    let reply = Rc::new(RefCell::new(None));
    let result = reply.clone();
    view.call_async_javascript_function(
        script,
        None,
        None,
        None,
        None::<&gio::Cancellable>,
        move |value| {
            *result.borrow_mut() = Some(
                value
                    .ok()
                    .and_then(|v| serde_json::from_str(&v.to_str()).ok())
                    .unwrap_or_default(),
            );
        },
    );
    wait("WebKit reply", || reply.borrow().is_some()).await;
    let result = reply.borrow_mut().take().unwrap();
    result
}

pub(crate) fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    fn walk(root: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
        all.push(root.clone());
        for child in crate::chrome::children(root) {
            walk(&child, all);
        }
    }
    let mut all = Vec::new();
    walk(root.as_ref(), &mut all);
    all
}

pub(crate) fn reveal(widget: &impl IsA<gtk::Widget>) {
    let widget = widget.as_ref();
    let mut parent = widget.parent();
    while let Some(current) = parent {
        if let Some(scroll) = current.downcast_ref::<gtk::ScrolledWindow>() {
            let bounds = widget.compute_bounds(&scroll.child().unwrap()).unwrap();
            scroll.vadjustment().set_value(f64::from(bounds.y()) - 70.);
            return;
        }
        parent = current.parent();
    }
}

pub(crate) async fn capture(window: &gtk::Window, name: &str) {
    wait("painted window", || support::try_capture(window, name)).await;
}

pub(crate) fn named<T: IsA<gtk::Widget> + glib::object::ObjectType>(
    root: &impl IsA<gtk::Widget>,
    name: &str,
) -> T {
    widgets(root)
        .into_iter()
        .find_map(|w| {
            if w.widget_name() == name {
                w.downcast::<T>().ok()
            } else {
                None
            }
        })
        .unwrap()
}
