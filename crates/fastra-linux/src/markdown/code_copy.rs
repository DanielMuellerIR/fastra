use super::*;
use serde::Deserialize;

const MAX_COPY: usize = 2 * 1024 * 1024;
const MAX_REGISTRY: usize = 4 * 1024 * 1024;
const MAX_BLOCKS: usize = 10_000;
const MAX_REQUEST: u64 = (1 << 53) - 1;

#[derive(Debug)]
enum CopyError {
    Stale,
    Limit,
    Encoding,
    Clipboard,
}

#[derive(Default)]
pub(super) struct Registry {
    blocks: Vec<String>,
    bytes: usize,
}
impl Registry {
    pub(super) fn insert(&mut self, text: String) -> Result<usize, RenderError> {
        // HTML normalisiert Zeilenenden; kopiert wird der sichtbare Code, nicht der Fence.
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        self.bytes = self
            .bytes
            .checked_add(text.len())
            .ok_or(RenderError::Limit)?;
        if self.bytes > MAX_REGISTRY || self.blocks.len() >= MAX_BLOCKS {
            return Err(RenderError::Limit);
        }
        let id = self.blocks.len();
        self.blocks.push(text);
        Ok(id)
    }
    pub(super) fn annotate(&self, html: &str) -> Option<String> {
        // Nutzer-HTML bleibt hier hinter internen Platzhaltern. Nur die vollständig vom Renderer
        // erzeugten pre-Tags erhalten eine ID; die Ereignisse selbst bleiben unverändert.
        let mut output = String::with_capacity(html.len() + self.blocks.len() * 28);
        let mut cursor = 0;
        let mut count = 0;
        for (at, _) in html.match_indices("<pre>") {
            output.push_str(&html[cursor..at]);
            output.push_str(&format!("<pre data-fastra-code=\"{count}\">"));
            cursor = at + 5;
            count += 1;
        }
        output.push_str(&html[cursor..]);
        (count == self.blocks.len()).then_some(output)
    }
    fn text(&self, id: usize) -> Result<&str, CopyError> {
        let text = self.blocks.get(id).ok_or(CopyError::Stale)?;
        if text.len() > MAX_COPY {
            return Err(CopyError::Limit);
        }
        if text.contains('\0') {
            return Err(CopyError::Encoding);
        }
        Ok(text)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    token: String,
    block: usize,
    request: u64,
}
fn decode(raw: &str) -> Option<Request> {
    if raw.len() > 512 {
        return None;
    }
    let request: Request = serde_json::from_str(raw).ok()?;
    (request.token.len() == 69
        && request
            .token
            .bytes()
            .all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'-')
        && request.request > 0
        && request.request <= MAX_REQUEST
        && request.block < MAX_BLOCKS)
        .then_some(request)
}
#[derive(Default)]
pub(super) struct State {
    registry: RefCell<Option<(String, Registry)>>,
    last_request: Cell<u64>,
    de: Cell<bool>,
}
impl State {
    pub(super) fn install(&self, token: String, registry: Registry, lang: Language) {
        *self.registry.borrow_mut() = Some((token, registry));
        self.last_request.set(0);
        self.de.set(lang.0);
    }
    pub(super) fn invalidate(&self) {
        self.registry.borrow_mut().take();
        self.last_request.set(0);
    }
}
pub(super) fn connect(manager: &webkit6::UserContentManager, preview: &Rc<MarkdownView>) {
    manager.register_script_message_handler("markdownCodeCopy", None);
    let weak = Rc::downgrade(preview);
    manager.connect_script_message_received(Some("markdownCodeCopy"), move |_, value| {
        if let Some(preview) = weak.upgrade() {
            let raw = value.to_json(0).filter(|raw| raw.len() <= 512);
            handle(&preview, raw.as_deref());
        }
    });
}
fn handle(preview: &MarkdownView, raw: Option<&str>) {
    let lang = Language(preview.code_copy.de.get());
    let Some(request) = raw.and_then(decode) else {
        preview.status.set_text(lang.text(
            "Code konnte nicht kopiert werden: ungültiger Auftrag.",
            "Code could not be copied: invalid request.",
        ));
        return;
    };
    let result = (|| {
        let (_, doc) = preview.positions.owner(preview).ok_or(CopyError::Stale)?;
        // Dieselbe Seite kann nach einem Tabwechsel wieder sichtbar werden.
        // Die gemeinsame Sichtbarkeitsepoche sperrt Nachrichten vor diesem Wechsel.
        let (render, epoch) = request.token.split_once(':').ok_or(CopyError::Stale)?;
        if epoch != preview.positions.epoch() {
            return Err(CopyError::Stale);
        }
        if preview.print_token(doc.revision.get()).as_deref() != Some(render)
            || request.request <= preview.code_copy.last_request.get()
        {
            return Err(CopyError::Stale);
        }
        let registry = preview.code_copy.registry.borrow();
        let (token, registry) = registry.as_ref().ok_or(CopyError::Stale)?;
        if token != render {
            return Err(CopyError::Stale);
        }
        let text = registry.text(request.block)?;
        let provider = gtk::gdk::ContentProvider::for_value(&text.to_value());
        preview
            .view
            .clipboard()
            .set_content(Some(&provider))
            .map_err(|_| CopyError::Clipboard)?;
        preview.code_copy.last_request.set(request.request);
        Ok(())
    })();
    let success = result.is_ok();
    preview.status.set_text(match result {
        Ok(()) => lang.text("Code kopiert", "Code copied"),
        Err(CopyError::Stale) => lang.text(
            "Vorschau oder Dokument geändert. Code erneut aus der aktuellen Vorschau kopieren.",
            "Preview or document changed. Copy the code again from the current preview.",
        ),
        Err(CopyError::Limit) => lang.text(
            "Code überschreitet 2 MiB UTF-8. Es wurde nichts kopiert.",
            "Code exceeds 2 MiB UTF-8. Nothing was copied.",
        ),
        Err(CopyError::Encoding) => lang.text(
            "Code enthält Nullzeichen. Es wurde nichts kopiert.",
            "Code contains NUL characters. Nothing was copied.",
        ),
        Err(CopyError::Clipboard) => lang.text(
            "Zwischenablage nicht verfügbar. Es wurde nichts kopiert.",
            "Clipboard unavailable. Nothing was copied.",
        ),
    });
    let script = format!(
        "window.fastraCodeCopy?.complete({}, {}, {});",
        serde_json::json!(request.token),
        request.request,
        success
    );
    preview
        .view
        .evaluate_javascript(&script, None, None, None::<&gio::Cancellable>, |_| {});
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_schema_is_bounded_and_has_no_dynamic_text() {
        let token = format!("{}:00000000-0000-0000-0000-000000000000", "0".repeat(32));
        assert!(decode(&format!(r#"{{"token":"{token}","block":0,"request":1}}"#)).is_some());
        for fields in [
            r#""block":-1,"request":1"#,
            r#""block":0,"request":1.0"#,
            r#""block":0,"request":0"#,
            r#""block":0,"request":9007199254740992"#,
            r#""block":0,"request":1,"text":"foreign""#,
            r#""block":10000,"request":1"#,
        ] {
            assert!(decode(&format!(r#"{{"token":"{token}",{fields}}}"#)).is_none());
        }
        assert!(decode(&" ".repeat(513)).is_none());
    }
    #[test]
    fn exact_copy_limit_and_render_budget_are_distinct() {
        let mut registry = Registry::default();
        registry.insert("x".repeat(MAX_COPY)).unwrap();
        assert_eq!(registry.text(0).unwrap().len(), MAX_COPY);
        registry.insert("y".repeat(MAX_COPY)).unwrap();
        assert!(registry.insert("z".into()).is_err());
        let mut blocks = Registry::default();
        for _ in 0..MAX_BLOCKS {
            blocks.insert(String::new()).unwrap();
        }
        assert!(blocks.insert(String::new()).is_err());
    }
    #[test]
    fn registry_preserves_visible_code_and_refuses_lossy_copy() {
        let mut registry = Registry::default();
        registry.insert("ä🙂 <&>\r\n\t \r\n".into()).unwrap();
        assert_eq!(registry.text(0).ok(), Some("ä🙂 <&>\n\t \n"));
        registry.insert("x".repeat(MAX_COPY + 1)).unwrap();
        assert!(registry.text(1).is_err());
        registry.insert("\0".into()).unwrap();
        assert!(registry.text(2).is_err());
        assert!(registry.text(3).is_err());
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(crate) fn selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_HTML_WHITELIST_SELFTEST").is_some() { super::html_gui_test::start(ui); return; }
    if std::env::var_os("FASTRA_MATH_STATIC_SELFTEST").is_some() { super::math_gui_test::start(ui); return; }
    gui_test::start(ui);
}
