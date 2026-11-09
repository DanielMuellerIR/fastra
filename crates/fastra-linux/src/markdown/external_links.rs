use super::{MarkdownView, BASE};
use gtk::{gio, glib, prelude::*};
use std::{cell::RefCell, rc::Rc};
mod portal;
use webkit6::prelude::*;

pub(super) fn allowed_uri(value: &str) -> bool {
    if value.bytes().any(|byte| byte < 0x20 || byte == 0x7f) {
        return false;
    }
    let Ok(uri) = glib::Uri::parse(value, glib::UriFlags::NONE) else {
        return false;
    };
    match uri.scheme().to_ascii_lowercase().as_str() {
        "http" | "https" => uri.host().is_some_and(|host| !host.is_empty()),
        "mailto" => true,
        _ => false,
    }
}

pub(super) fn install(preview: &Rc<MarkdownView>) {
    let pending = Rc::new(RefCell::new(None::<portal::Pending>));
    let pending_unmap = pending.clone();
    preview.view.connect_unmap(move |_| {
        pending_unmap.borrow_mut().take();
    });
    let weak = Rc::downgrade(preview);
    preview
        .view
        .connect_decide_policy(move |_, decision, kind| {
            if !matches!(
                kind,
                webkit6::PolicyDecisionType::NavigationAction
                    | webkit6::PolicyDecisionType::NewWindowAction
            ) {
                return false;
            }
            let Some(action) = decision
                .downcast_ref::<webkit6::NavigationPolicyDecision>()
                .and_then(|value| value.navigation_action())
            else {
                decision.ignore();
                return true;
            };
            let uri = action
                .request()
                .and_then(|request| request.uri())
                .unwrap_or_default();
            if uri == BASE || uri.starts_with(&format!("{BASE}#")) {
                return false;
            }
            decision.ignore();
            if action.navigation_type() != webkit6::NavigationType::LinkClicked
                || !action.is_user_gesture()
                || !allowed_uri(&uri)
            {
                return true;
            }
            let Some(preview) = weak
                .upgrade()
                .filter(|preview| preview.visible.get() && preview.view.is_mapped())
            else {
                return true;
            };
            let generation = preview.generation.get();
            if preview.rendered.borrow().is_none() {
                return true;
            }
            // Der optionale Startvertrag wurde bereits vor GTK validiert.
            if std::env::var("FASTRA_NATIVE_RUNTIME").as_deref() == Ok("1") {
                pending.borrow_mut().take();
                let alive = Rc::downgrade(&preview);
                let weak = Rc::downgrade(&preview);
                let request = portal::open(
                    &uri,
                    move || {
                        alive.upgrade().is_some_and(|preview| {
                            preview.generation.get() == generation
                                && preview.visible.get()
                                && preview.view.is_mapped()
                        })
                    },
                    move |result| {
                        if let (Err(error), Some(preview)) = (result, weak.upgrade()) {
                            if preview.generation.get() == generation && preview.visible.get() {
                                let german = std::env::var("LANGUAGE")
                                    .or_else(|_| std::env::var("LANG"))
                                    .unwrap_or_default()
                                    .starts_with("de");
                                preview.status.set_text(&error.message(german));
                            }
                        }
                    },
                );
                *pending.borrow_mut() = Some(request);
                return true;
            }
            let context = gtk::gdk::Display::default().map(|display| display.app_launch_context());
            let weak = Rc::downgrade(&preview);
            gio::AppInfo::launch_default_for_uri_async(
                &uri,
                context.as_ref(),
                gio::Cancellable::NONE,
                move |result| {
                    if let (Err(error), Some(preview)) = (result, weak.upgrade()) {
                        if preview.generation.get() == generation && preview.visible.get() {
                            let german = std::env::var("LANGUAGE")
                                .or_else(|_| std::env::var("LANG"))
                                .unwrap_or_default()
                                .starts_with("de");
                            preview.status.set_text(&format!(
                                "{}: {error}",
                                if german {
                                    "Link konnte nicht geöffnet werden"
                                } else {
                                    "Could not open link"
                                }
                            ));
                        }
                    }
                },
            );
            true
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_complete_external_web_or_mail_links_are_allowed() {
        for uri in [
            "https://example.invalid/path?q=1#fragment",
            "HTTP://example.invalid/",
            "mailto:person@example.invalid?body=line%0Abreak",
        ] {
            assert!(allowed_uri(uri), "{uri}");
        }
        for uri in [
            "javascript:alert(1)",
            "data:text/html,hi",
            "file:///tmp/a",
            "fastra-preview://document/page",
            "//example.invalid",
            "https:",
            "https://example.invalid/\n",
            "\thttps://example.invalid",
            "https://example.invalid/\0",
        ] {
            assert!(!allowed_uri(uri), "{uri}");
        }
    }
}
