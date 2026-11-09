use super::*;
pub(super) const MIME: &str = "application/x-fastra-markdown";
pub(super) enum Incoming {
    Text(String),
    Html(String),
    Markdown(String),
    Assets(transfer::Transfer),
}
fn incoming(value: transfer::Transfer) -> Incoming {
    match value {
        transfer::Transfer::Text(text) => Incoming::Text(text),
        transfer::Transfer::Html(html) => Incoming::Html(html),
        transfer::Transfer::Markdown { source, images, .. }
            if images.is_empty() && !transfer::has_images(&source) =>
        {
            Incoming::Markdown(source)
        }
        asset => Incoming::Assets(asset),
    }
}
#[cfg(test)]
pub(super) fn decode(mime: &str, bytes: &[u8]) -> Result<Incoming, &'static str> {
    transfer::decode(mime, bytes).map(incoming)
}
#[cfg(debug_assertions)]
thread_local! { static TEST_DELAY:Cell<u64>=const { Cell::new(0) }; static PENDING:Cell<bool>=const { Cell::new(false) }; }
#[cfg(debug_assertions)]
pub(super) fn delay_for_test(milliseconds: u64) {
    TEST_DELAY.with(|v| v.set(milliseconds.min(6000)));
}
#[cfg(debug_assertions)]
pub(super) fn pending_for_test() -> bool {
    PENDING.with(Cell::get)
}
pub(super) async fn read(
    clipboard: gtk::gdk::Clipboard,
    plain: bool,
) -> Result<Incoming, &'static str> {
    let changed = Rc::new(Cell::new(false));
    let observed = changed.clone();
    let handler = clipboard.connect_changed(move |_| observed.set(true));
    let input = clipboard.clone();
    #[cfg(debug_assertions)]
    PENDING.with(|value| value.set(true));
    let job = async move {
        #[cfg(debug_assertions)]
        {
            let delay = TEST_DELAY.with(Cell::get);
            if delay > 0 {
                glib::timeout_future(std::time::Duration::from_millis(delay)).await;
            }
        }

        let formats = input.formats();
        let selected = transfer::preferred(&formats, plain).ok_or("format")?;
        if !plain
            && selected.starts_with("text/plain")
            && formats
                .mime_types()
                .iter()
                .any(|mime| mime.starts_with("image/"))
        {
            return Err("images");
        }
        // Nur einen Typ anfordern: Providerreihenfolgen dürfen die native Priorität nicht ändern.
        let (stream, mime) = input
            .read_future(&[selected], glib::Priority::DEFAULT)
            .await
            .map_err(|_| "read")?;
        if mime != selected {
            return Err("format");
        }
        transfer::stream(stream, &mime).await.map(incoming)
    };
    let result = glib::future_with_timeout(std::time::Duration::from_secs(5), job)
        .await
        .map_err(|_| "timeout")
        .and_then(|value| value);
    clipboard.disconnect(handler);
    #[cfg(debug_assertions)]
    PENDING.with(|value| value.set(false));
    if changed.get() {
        Err("changed")
    } else {
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_decoder_bounds_utf8_schema_and_image_authority() {
        assert!(
            matches!(decode(MIME,br#"{"markdown":"==Marked==","url":"file:///other/document.md","images":"e30="}"#),Ok(Incoming::Markdown(s)) if s=="==Marked==")
        );
        for input in [
            br#"{"markdown":"![image](images/1.png)"}"#.as_slice(),
            br#"{"markdown":"ok","images":"AAAA"}"#.as_slice(),
            br#"{"markdown":"<IMG src='private.png'>"}"#.as_slice(),
        ] {
            assert!(
                decode(MIME, input).is_err()
                    || matches!(decode(MIME, input), Ok(Incoming::Assets(_)))
            );
        }
        assert!(matches!(
            decode("text/html", b"<strong>Bold</strong>"),
            Ok(Incoming::Html(_))
        ));
        assert!(
            matches!(decode("text/plain", "\u{feff}Bold\u{a0}".as_bytes()),Ok(Incoming::Text(text)) if text=="\u{feff}Bold\u{a0}")
        );
        assert!(decode("text/plain", &[0xff]).is_err());
        assert!(decode(MIME, b"{}").is_err());
        assert!(decode("text/plain", b"a\0b").is_err());
        assert!(decode("text/plain", &vec![b'a'; MAX_BYTES + 1]).is_err());
    }
}
