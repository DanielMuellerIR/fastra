use super::*;
use std::cell::Cell;
fn spin(context: &glib::MainContext, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready() {
        assert!(Instant::now() < deadline, "private portal test timed out");
        while context.pending() {
            context.iteration(false);
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}
#[test]
fn response_contract_is_strict() {
    let dict = HashMap::<String, glib::Variant>::new();
    assert_eq!(
        response(&(0u32, dict.clone()).to_variant()).unwrap(),
        Outcome::Opened
    );
    assert_eq!(
        response(&(1u32, dict.clone()).to_variant()).unwrap(),
        Outcome::Cancelled
    );
    assert!(matches!(
        response(&(2u32, dict.clone()).to_variant()),
        Err(Error::Failed)
    ));
    assert!(matches!(
        response(&(3u32, dict).to_variant()),
        Err(Error::InvalidReply)
    ));
    assert!(matches!(
        response(&(0u32, "bad").to_variant()),
        Err(Error::InvalidReply)
    ));
    let missing = Error::Unavailable("synthetic missing portal".into());
    assert!(missing.message(true).contains("Desktopportal"));
    assert!(missing.message(false).contains("desktop portal"));
}
#[test]
#[ignore = "Run alone in a fresh dbus-run-session; never use the desktop bus"]
fn private_dbus_portal_responses_and_cleanup() {
    assert_eq!(
        std::env::var("FASTRA_PRIVATE_DBUS_TEST").as_deref(),
        Ok("1")
    );
    let context = glib::MainContext::default();
    let _owner = context.acquire().unwrap();
    let connection = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).unwrap();
    let request_name = connection
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
    assert_eq!(request_name.get::<(u32,)>(), Some((1,)));
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let closes = Rc::new(Cell::new(0));
    let requests = Rc::new(RefCell::new(Vec::new()));
    let delayed = Rc::new(RefCell::new(None::<(gio::DBusMethodInvocation, String)>));
    let request_info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.portal.Request'><method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal></interface></node>").unwrap();
    let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.portal.OpenURI'><method name='OpenURI'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method></interface></node>").unwrap();
    let received = calls.clone();
    let closed = closes.clone();
    let registered = requests.clone();
    let held = delayed.clone();
    let registration = connection
        .register_object(OBJECT, &info.interfaces()[0])
        .method_call(move |connection, sender, _, _, method, args, invocation| {
            assert_eq!(method, "OpenURI");
            let (parent, uri, options) = args
                .get::<(String, String, HashMap<String, glib::Variant>)>()
                .unwrap();
            assert!(parent.is_empty());
            assert!(super::super::allowed_uri(&uri));
            assert_eq!(
                options.len(),
                1,
                "portal transports only the URI and a request token, never process environment"
            );
            let token = options
                .get("handle_token")
                .unwrap()
                .get::<String>()
                .unwrap();
            assert!(token.starts_with("fastra_") && token.len() > 32);
            let sender = sender.unwrap().trim_start_matches(':').replace('.', "_");
            let path = format!("{OBJECT}/request/{sender}/{token}");
            assert!(
                !registered
                    .borrow()
                    .iter()
                    .any(|(old, _): &(String, gio::RegistrationId)| old == &path)
            );
            received.borrow_mut().push(uri.clone());
            let count = closed.clone();
            let request = connection
                .register_object(&path, &request_info.interfaces()[0])
                .method_call(move |_, _, _, _, method, _, invocation| {
                    assert_eq!(method, "Close");
                    count.set(count.get() + 1);
                    invocation.return_value(Some(&().to_variant()));
                })
                .build()
                .unwrap();
            registered.borrow_mut().push((path.clone(), request));
            if uri.ends_with("/delayed") {
                *held.borrow_mut() = Some((invocation, path));
                return;
            }
            let outcome = if uri.ends_with("/cancel") {
                1
            } else if uri.ends_with("/failed") {
                2
            } else {
                0
            };
            let object = glib::variant::ObjectPath::try_from(path.as_str()).unwrap();
            if uri.ends_with("/bad-handle") {
                let other =
                    glib::variant::ObjectPath::try_from(format!("{OBJECT}/request/{sender}/wrong"))
                        .unwrap();
                invocation.return_value(Some(&(other,).to_variant()));
            } else {
                // Absichtlich vor der OpenURI-Antwort senden: Das ist der echte Racefall.
                let parameters = if uri.ends_with("/bad-response") {
                    ("bad",).to_variant()
                } else {
                    (outcome as u32, HashMap::<String, glib::Variant>::new()).to_variant()
                };
                connection
                    .emit_signal(None, &path, REQUEST, "Response", Some(&parameters))
                    .unwrap();
                if uri.ends_with("/early") {
                    *held.borrow_mut() = Some((invocation, path));
                } else {
                    invocation.return_value(Some(&(object,).to_variant()));
                }
            }
        })
        .build()
        .unwrap();
    let rejected = Rc::new(RefCell::new(None));
    let received = rejected.clone();
    let invalid = open(
        "file:///tmp/must-not-open",
        || true,
        move |result| *received.borrow_mut() = Some(result),
    );
    assert!(matches!(
        rejected.borrow().as_ref().unwrap(),
        Err(Error::InvalidUri)
    ));
    assert!(calls.borrow().is_empty());
    assert!(invalid.state.borrow().timer.is_none());
    drop(invalid);
    let alive = Rc::new(Cell::new(true));
    let current = alive.clone();
    let output = Rc::new(RefCell::new(None));
    let received = output.clone();
    let pending = open(
        "https://example.invalid/stale-before-bus-ready",
        move || current.get(),
        move |result| *received.borrow_mut() = Some(result),
    );
    alive.set(false);
    spin(&context, || output.borrow().is_some());
    assert!(matches!(
        output.borrow().as_ref().unwrap(),
        Ok(Outcome::Cancelled)
    ));
    assert!(
        calls.borrow().is_empty(),
        "stale view must not dispatch OpenURI"
    );
    assert!(pending.state.borrow().completed);
    drop(pending);
    for (uri, outcome) in [
        ("https://example.invalid/success", 0),
        ("https://example.invalid/early", 0),
        ("mailto:person@example.invalid", 0),
        ("https://example.invalid/cancel", 1),
        ("https://example.invalid/failed", 2),
        ("https://example.invalid/bad-response", 3),
        ("https://example.invalid/bad-handle", 3),
    ] {
        let output = Rc::new(RefCell::new(None));
        let received = output.clone();
        let pending = open(
            uri,
            || true,
            move |result| *received.borrow_mut() = Some(result),
        );
        let state = pending.state.clone();
        if uri.ends_with("/early") {
            spin(&context, || state.borrow().early_response.is_some());
            assert!(
                output.borrow().is_none(),
                "early Response is not success before the method handle is confirmed"
            );
            let (reply, path) = delayed.borrow_mut().take().unwrap();
            reply.return_value(Some(
                &(glib::variant::ObjectPath::try_from(path).unwrap(),).to_variant(),
            ));
        }
        spin(&context, || output.borrow().is_some());
        match outcome {
            0 => assert!(matches!(
                output.borrow().as_ref().unwrap(),
                Ok(Outcome::Opened)
            )),
            1 => assert!(matches!(
                output.borrow().as_ref().unwrap(),
                Ok(Outcome::Cancelled)
            )),
            2 => assert!(matches!(
                output.borrow().as_ref().unwrap(),
                Err(Error::Failed)
            )),
            _ => assert!(matches!(
                output.borrow().as_ref().unwrap(),
                Err(Error::InvalidReply)
            )),
        }
        assert!(
            state.borrow().subscription.is_none()
                && state.borrow().timer.is_none()
                && state.borrow().done.is_none()
                && state.borrow().connection.is_none()
                && state.borrow().path.is_none()
        );
        drop(pending);
    }
    // Generation-Wechsel und Drop nach Methodenempfang schließen den Auftrag.
    for cancel_by_drop in [false, true] {
        let output = Rc::new(RefCell::new(None));
        let received = output.clone();
        let alive = Rc::new(Cell::new(true));
        let current = alive.clone();
        let state = state(
            move || current.get(),
            move |result| *received.borrow_mut() = Some(result),
            DEADLINE,
        );
        let mut pending = Some(Pending {
            state: state.clone(),
        });
        begin(&state, &connection, "https://example.invalid/delayed");
        spin(&context, || delayed.borrow().is_some());
        let close_before = closes.get();
        if cancel_by_drop {
            pending.take();
        } else {
            alive.set(false);
        }
        spin(&context, || {
            output.borrow().is_some() && closes.get() > close_before
        });
        assert!(matches!(
            output.borrow().as_ref().unwrap(),
            Ok(Outcome::Cancelled)
        ));
        let (reply, path) = delayed.borrow_mut().take().unwrap();
        reply.return_value(Some(
            &(glib::variant::ObjectPath::try_from(path).unwrap(),).to_variant(),
        ));
        let expected_references = if cancel_by_drop { 1 } else { 2 };
        spin(&context, || Rc::strong_count(&state) == expected_references);
        assert!(state.borrow().completed);
        assert!(
            state.borrow().subscription.is_none()
                && state.borrow().timer.is_none()
                && state.borrow().connection.is_none()
        );
        drop(pending);
    }
    // Ein nicht antwortender Request endet und schließt auch ohne Nutzeraktion.
    let output = Rc::new(RefCell::new(None));
    let received = output.clone();
    let timeout_state = super::state(
        || true,
        move |result| *received.borrow_mut() = Some(result),
        Duration::from_millis(1),
    );
    let pending = Pending {
        state: timeout_state.clone(),
    };
    begin(
        &timeout_state,
        &connection,
        "https://example.invalid/delayed",
    );
    spin(&context, || output.borrow().is_some());
    assert!(matches!(
        output.borrow().as_ref().unwrap(),
        Err(Error::Timeout)
    ));
    drop(pending);
    if let Some((reply, path)) = delayed.borrow_mut().take() {
        reply.return_value(Some(
            &(glib::variant::ObjectPath::try_from(path).unwrap(),).to_variant(),
        ));
    }
    connection.unregister_object(registration).unwrap();
    connection
        .call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ReleaseName",
            Some(&(SERVICE,).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            2000,
            gio::Cancellable::NONE,
        )
        .unwrap();
    let output = Rc::new(RefCell::new(None));
    let received = output.clone();
    let pending = open(
        "https://example.invalid/missing",
        || true,
        move |result| *received.borrow_mut() = Some(result),
    );
    let missing = pending.state.clone();
    spin(&context, || output.borrow().is_some());
    assert!(matches!(
        output.borrow().as_ref().unwrap(),
        Err(Error::Unavailable(_))
    ));
    assert!(missing.borrow().subscription.is_none() && missing.borrow().timer.is_none());
    drop(pending);
    for (_, registration) in requests.borrow_mut().drain(..) {
        connection.unregister_object(registration).unwrap();
    }
    println!(
        "PRIVATE_PORTAL_PASS success/http/mailto/early-response/cancel/error/invalid-handle/invalid-response/generation-cancel/drop-cancel/timeout/Request.Close/missing/RAII-cleanup"
    );
}
