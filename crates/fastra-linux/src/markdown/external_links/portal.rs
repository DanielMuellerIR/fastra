//! Expliziter Desktopportal-Aufruf: Die private ABI-Umgebung startet keinen URI-Handler.
use gtk::{gio, glib, prelude::*};
use std::{
    cell::RefCell,
    collections::HashMap,
    rc::Rc,
    time::{Duration, Instant},
};
const SERVICE: &str = "org.freedesktop.portal.Desktop";
const OBJECT: &str = "/org/freedesktop/portal/desktop";
const INTERFACE: &str = "org.freedesktop.portal.OpenURI";
const REQUEST: &str = "org.freedesktop.portal.Request";
const DEADLINE: Duration = Duration::from_secs(60);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Outcome {
    Opened,
    Cancelled,
}
#[derive(Debug)]
pub(super) enum Error {
    Unavailable(String),
    InvalidReply,
    Failed,
    Timeout,
    InvalidUri,
}
impl Error {
    pub(super) fn message(&self, german: bool) -> String {
        match self {
            Self::Unavailable(detail) => format!("{}: {detail}", if german {
                "Das Desktopportal zum Öffnen von Links ist nicht verfügbar. Die optionale Laufzeit benötigt dieses Portal"
            } else { "The desktop portal for opening links is unavailable. The optional runtime requires this portal" }),
            Self::InvalidReply => if german { "Das Desktopportal hat eine ungültige Antwort gesendet." } else { "The desktop portal returned an invalid response." }.into(),
            Self::Failed => if german { "Das Desktopportal konnte den Link nicht öffnen." } else { "The desktop portal could not open the link." }.into(),
            Self::Timeout => if german { "Das Desktopportal hat nicht rechtzeitig geantwortet. Der Linkauftrag wurde abgebrochen." } else { "The desktop portal did not respond in time. The link request was cancelled." }.into(),
            Self::InvalidUri => if german { "Nur HTTP-, HTTPS- und Mailto-Links sind erlaubt." } else { "Only HTTP, HTTPS and mailto links are allowed." }.into(),
        }
    }
}
type Result = std::result::Result<Outcome, Error>;
type Done = Box<dyn FnOnce(Result)>;
struct State {
    cancel: gio::Cancellable,
    connection: Option<gio::DBusConnection>,
    subscription: Option<gio::SignalSubscription>,
    timer: Option<glib::SourceId>,
    path: Option<String>,
    method_replied: bool,
    early_response: Option<Result>,
    completed: bool,
    alive: Box<dyn Fn() -> bool>,
    done: Option<Done>,
}
pub(super) struct Pending {
    state: Rc<RefCell<State>>,
}
impl Drop for Pending {
    fn drop(&mut self) {
        finish(&self.state, Ok(Outcome::Cancelled), true);
    }
}
fn close(connection: &gio::DBusConnection, path: &str) {
    connection.call(
        Some(SERVICE),
        path,
        REQUEST,
        "Close",
        None,
        Some(glib::VariantTy::UNIT),
        gio::DBusCallFlags::NO_AUTO_START,
        1000,
        gio::Cancellable::NONE,
        |_| {},
    );
}
fn finish(state: &Rc<RefCell<State>>, result: Result, close_request: bool) {
    let (subscription, timer, done, connection, path) = {
        let mut state = state.borrow_mut();
        if state.completed {
            return;
        }
        state.completed = true;
        state.cancel.cancel();
        state.early_response.take();
        (
            state.subscription.take(),
            state.timer.take(),
            state.done.take(),
            state.connection.take(),
            state.path.take(),
        )
    };
    drop(subscription);
    if let Some(timer) = timer {
        timer.remove();
    }
    if close_request {
        if let (Some(connection), Some(path)) = (connection, path) {
            close(&connection, &path);
        }
    }
    if let Some(done) = done {
        done(result);
    }
}
fn response(parameters: &glib::Variant) -> Result {
    let Some((code, _)) = parameters.get::<(u32, HashMap<String, glib::Variant>)>() else {
        return Err(Error::InvalidReply);
    };
    match code {
        0 => Ok(Outcome::Opened),
        1 => Ok(Outcome::Cancelled),
        2 => Err(Error::Failed),
        _ => Err(Error::InvalidReply),
    }
}
fn state(
    alive: impl Fn() -> bool + 'static,
    done: impl FnOnce(Result) + 'static,
    deadline: Duration,
) -> Rc<RefCell<State>> {
    let state = Rc::new(RefCell::new(State {
        cancel: gio::Cancellable::new(),
        connection: None,
        subscription: None,
        timer: None,
        path: None,
        method_replied: false,
        early_response: None,
        completed: false,
        alive: Box::new(alive),
        done: Some(Box::new(done)),
    }));
    let weak = Rc::downgrade(&state);
    let start = Instant::now();
    let timer = glib::timeout_add_local(Duration::from_millis(100), move || {
        let Some(state) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        let alive = (state.borrow().alive)();
        if !alive {
            finish(&state, Ok(Outcome::Cancelled), true);
            return glib::ControlFlow::Break;
        }
        if start.elapsed() >= deadline {
            finish(&state, Err(Error::Timeout), true);
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
    state.borrow_mut().timer = Some(timer);
    state
}
fn begin(state: &Rc<RefCell<State>>, connection: &gio::DBusConnection, uri: &str) {
    if state.borrow().completed {
        return;
    }
    let alive = (state.borrow().alive)();
    if !alive {
        finish(state, Ok(Outcome::Cancelled), true);
        return;
    }
    let Some(sender) = connection.unique_name() else {
        finish(
            state,
            Err(Error::Unavailable("No session bus identity".into())),
            false,
        );
        return;
    };
    let sender = sender.trim_start_matches(':').replace('.', "_");
    let token = format!("fastra_{}", glib::uuid_string_random().replace('-', ""));
    let path = format!("{OBJECT}/request/{sender}/{token}");
    let weak = Rc::downgrade(state);
    // Das Signal kann vor der Methoden-Antwort eintreffen. Bereits vorher auf
    // den eindeutigen Pfad hören, aber Erfolg erst nach bestätigtem Handle melden.
    let subscription = connection.subscribe_to_signal(
        Some(SERVICE),
        Some(REQUEST),
        Some("Response"),
        Some(&path),
        None,
        gio::DBusSignalFlags::NONE,
        move |signal| {
            let Some(state) = weak.upgrade() else {
                return;
            };
            let result = response(signal.parameters);
            {
                let mut state = state.borrow_mut();
                if state.completed {
                    return;
                }
                if !state.method_replied {
                    state.early_response = Some(if state.early_response.is_some() {
                        Err(Error::InvalidReply)
                    } else {
                        result
                    });
                    return;
                }
            }
            let close_request = matches!(result, Err(Error::InvalidReply));
            finish(&state, result, close_request);
        },
    );
    {
        let mut state = state.borrow_mut();
        state.connection = Some(connection.clone());
        state.path = Some(path.clone());
        state.subscription = Some(subscription);
    }
    let options: HashMap<String, glib::Variant> =
        [("handle_token".into(), token.to_variant())].into();
    let held = state.clone();
    let connection_callback = connection.clone();
    let cancel = state.borrow().cancel.clone();
    connection.call(
        Some(SERVICE),
        OBJECT,
        INTERFACE,
        "OpenURI",
        Some(&("", uri, options).to_variant()),
        None,
        gio::DBusCallFlags::NONE,
        10_000,
        Some(&cancel),
        move |reply| {
            let returned = reply.as_ref().ok().and_then(|value| {
                value
                    .get::<(glib::variant::ObjectPath,)>()
                    .map(|value| value.0.to_string())
            });
            if held.borrow().completed {
                // Ein verzögertes Handle nach Abbruch darf keine verwaiste Portalfrage hinterlassen.
                if returned.as_deref() == Some(&path) {
                    close(&connection_callback, &path);
                }
                return;
            }
            if let Err(error) = reply {
                finish(&held, Err(Error::Unavailable(error.to_string())), true);
                return;
            }
            if returned.as_deref() != Some(&path) {
                if let Some(returned) = returned
                    .filter(|value| value.starts_with(&format!("{OBJECT}/request/{sender}/")))
                {
                    close(&connection_callback, &returned);
                }
                finish(&held, Err(Error::InvalidReply), true);
                return;
            }
            let early = {
                let mut state = held.borrow_mut();
                state.method_replied = true;
                state.early_response.take()
            };
            if let Some(result) = early {
                let close_request = matches!(result, Err(Error::InvalidReply));
                finish(&held, result, close_request);
            }
        },
    );
}
pub(super) fn open(
    uri: &str,
    alive: impl Fn() -> bool + 'static,
    done: impl FnOnce(Result) + 'static,
) -> Pending {
    let state = state(alive, done, DEADLINE);
    if !super::allowed_uri(uri) {
        finish(&state, Err(Error::InvalidUri), false);
        return Pending { state };
    }
    let held = state.clone();
    let uri = uri.to_owned();
    let cancel = state.borrow().cancel.clone();
    gio::bus_get(
        gio::BusType::Session,
        Some(&cancel),
        move |result| match result {
            Ok(connection) => begin(&held, &connection, &uri),
            Err(error) => finish(&held, Err(Error::Unavailable(error.to_string())), false),
        },
    );
    Pending { state }
}

#[cfg(test)]
mod tests;
