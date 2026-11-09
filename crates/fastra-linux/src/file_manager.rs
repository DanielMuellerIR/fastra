//! Explizite Dateimanageraktion; rohe Unix-Pfade werden ausschließlich durch Gio zu URIs.
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::Path,
    rc::Rc,
};

const SERVICE: &str = "org.freedesktop.FileManager1";
const OBJECT: &str = "/org/freedesktop/FileManager1";

#[derive(Debug)]
pub(super) enum Error {
    NoSession,
    InvalidPath,
    Transport(glib::Error),
}
impl Error {
    pub(super) fn message(&self, lang: super::Language) -> String {
        match self {
            Self::NoSession => lang
                .text(
                    "Keine Verbindung zur Desktop-Sitzung verfügbar.",
                    "No connection to the desktop session is available.",
                )
                .into(),
            Self::InvalidPath => lang
                .text(
                    "Der gewählte Eintrag hat keinen absoluten lokalen Pfad.",
                    "The selected item has no absolute local path.",
                )
                .into(),
            Self::Transport(error) => error.to_string(),
        }
    }
}

#[derive(Default)]
pub(super) struct Request {
    generation: Cell<u64>,
    pending: RefCell<Option<gio::Cancellable>>,
}
impl Request {
    pub(super) fn pending(&self) -> bool {
        self.pending.borrow().is_some()
    }

    pub(super) fn cancel(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        if let Some(cancel) = self.pending.borrow_mut().take() {
            cancel.cancel();
        }
    }

    pub(super) fn show(
        self: &Rc<Self>,
        parent: &gtk::ApplicationWindow,
        path: &Path,
        done: impl FnOnce(Result<(), Error>) + 'static,
    ) {
        if self.pending() {
            return;
        }
        let Some(connection) = parent.application().and_then(|app| app.dbus_connection()) else {
            done(Err(Error::NoSession));
            return;
        };
        self.show_on(&connection, path, done);
    }

    fn show_on(
        self: &Rc<Self>,
        connection: &gio::DBusConnection,
        path: &Path,
        done: impl FnOnce(Result<(), Error>) + 'static,
    ) {
        if self.pending() {
            return;
        }
        if !path.is_absolute() {
            done(Err(Error::InvalidPath));
            return;
        }
        let uri = gio::File::for_path(path).uri();
        let generation = self.generation.get().wrapping_add(1);
        self.generation.set(generation);
        let cancel = gio::Cancellable::new();
        *self.pending.borrow_mut() = Some(cancel.clone());
        let weak = Rc::downgrade(self);
        connection.call(
            Some(SERVICE),
            OBJECT,
            SERVICE,
            "ShowItems",
            Some(&(vec![uri.as_str()], "").to_variant()),
            Some(glib::VariantTy::UNIT),
            gio::DBusCallFlags::NONE,
            10_000,
            Some(&cancel),
            move |result| {
                let Some(request) = weak.upgrade() else {
                    return;
                };
                // Ein alter Receipt darf weder den neuen Auftrag freigeben noch dessen UI ändern.
                if request.generation.get() != generation {
                    return;
                }
                request.pending.borrow_mut().take();
                done(result.map(|_| ()).map_err(Error::Transport));
            },
        );
    }
}
impl Drop for Request {
    fn drop(&mut self) {
        if let Some(cancel) = self.pending.get_mut().take() {
            cancel.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        ffi::OsString,
        os::unix::ffi::OsStringExt,
        time::{Duration, Instant},
    };

    fn wait(context: &glib::MainContext, complete: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(5);
        while !complete() {
            assert!(
                Instant::now() < end,
                "private file-manager D-Bus test timed out"
            );
            while context.pending() {
                context.iteration(false);
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    #[ignore = "Run alone in a fresh dbus-run-session; never use the desktop bus"]
    fn private_dbus_uri_errors_and_late_reply() {
        assert_eq!(
            std::env::var("FASTRA_PRIVATE_DBUS_TEST").as_deref(),
            Ok("1")
        );
        let context = glib::MainContext::default();
        let _owner = context.acquire().unwrap();
        let connection = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).unwrap();
        let reply = connection
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "RequestName",
                Some(&(SERVICE, 4u32).to_variant()),
                None,
                gio::DBusCallFlags::NONE,
                2000,
                gio::Cancellable::NONE,
            )
            .unwrap();
        assert_eq!(
            reply.get::<(u32,)>(),
            Some((1,)),
            "private sentinel name must be unowned"
        );
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let delayed = Rc::new(RefCell::new(None::<gio::DBusMethodInvocation>));
        let count = Rc::new(Cell::new(0));
        let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.FileManager1'><method name='ShowItems'><arg type='as' direction='in'/><arg type='s' direction='in'/></method></interface></node>").unwrap();
        let received = calls.clone();
        let held = delayed.clone();
        let phase = count.clone();
        let registration = connection
            .register_object(OBJECT, &info.interfaces()[0])
            .method_call(move |_, _, _, _, method, args, invocation| {
                assert_eq!(method, "ShowItems");
                let (uris, startup) = args.get::<(Vec<String>, String)>().unwrap();
                assert_eq!(uris.len(), 1);
                assert_eq!(startup, "");
                received.borrow_mut().push(uris[0].clone());
                let at = phase.get();
                phase.set(at + 1);
                match at {
                    2 => invocation.return_dbus_error(
                        "org.freedesktop.FileManager1.TestFailure",
                        "synthetic file-manager failure",
                    ),
                    3 => *held.borrow_mut() = Some(invocation),
                    _ => invocation.return_value(Some(&().to_variant())),
                }
            })
            .build()
            .unwrap();
        let request = Rc::new(Request::default());
        for (path, expected) in [
            (
                std::path::PathBuf::from("/tmp/space % # ä🙂"),
                "file:///tmp/space%20%25%20%23%20%C3%A4%F0%9F%99%82",
            ),
            (
                std::path::PathBuf::from(OsString::from_vec(b"/tmp/raw-\xff".to_vec())),
                "file:///tmp/raw-%FF",
            ),
        ] {
            let result = Rc::new(RefCell::new(None));
            let output = result.clone();
            request.show_on(&connection, &path, move |value| {
                *output.borrow_mut() = Some(value)
            });
            assert!(request.pending());
            wait(&context, || result.borrow().is_some());
            assert!(result.borrow().as_ref().unwrap().is_ok());
            assert!(!request.pending());
            assert_eq!(calls.borrow().last().unwrap(), expected);
        }
        let failure = Rc::new(RefCell::new(None));
        let output = failure.clone();
        request.show_on(&connection, Path::new("/tmp/error"), move |value| {
            *output.borrow_mut() = Some(value)
        });
        wait(&context, || failure.borrow().is_some());
        assert!(failure
            .borrow()
            .as_ref()
            .unwrap()
            .as_ref()
            .unwrap_err()
            .message(super::super::Language(false))
            .contains("synthetic file-manager failure"));
        let stale = Rc::new(Cell::new(false));
        let output = stale.clone();
        request.show_on(&connection, Path::new("/tmp/stale"), move |_| {
            output.set(true)
        });
        wait(&context, || delayed.borrow().is_some());
        let before = calls.borrow().len();
        request.show_on(&connection, Path::new("/tmp/double"), |_| {
            panic!("double dispatch")
        });
        assert_eq!(calls.borrow().len(), before);
        request.cancel();
        assert!(!request.pending());
        let fresh = Rc::new(Cell::new(false));
        let output = fresh.clone();
        request.show_on(&connection, Path::new("/tmp/fresh"), move |value| {
            value.unwrap();
            output.set(true)
        });
        delayed
            .borrow_mut()
            .take()
            .unwrap()
            .return_value(Some(&().to_variant()));
        wait(&context, || fresh.get());
        while context.pending() {
            context.iteration(false);
        }
        assert!(!stale.get());
        assert!(!request.pending());
        assert_eq!(calls.borrow().last().unwrap(), "file:///tmp/fresh");
        connection.unregister_object(registration).unwrap();
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<super::Ui>) {
    gui_test::run(ui);
}
