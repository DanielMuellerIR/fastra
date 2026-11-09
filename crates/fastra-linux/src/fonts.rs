use gtk::{gio, glib, prelude::*};
use std::{cell::RefCell, ffi::CString, os::unix::ffi::OsStrExt};

#[link(name = "fontconfig")]
unsafe extern "C" {
    fn FcConfigGetCurrent() -> *mut std::ffi::c_void;
    fn FcConfigAppFontAddFile(config: *mut std::ffi::c_void, file: *const u8) -> libc::c_int;
}
#[link(name = "pangoft2-1.0")]
unsafe extern "C" {
    fn pango_fc_font_map_config_changed(map: *mut std::ffi::c_void);
}
thread_local! {
    static DIRECTORY: RefCell<Option<tempfile::TempDir>> = const { RefCell::new(None) };
}
const NORMAL: &[u8] = include_bytes!("../resources/fonts/inter-4.1/InterVariable.woff2");
const ITALIC: &[u8] = include_bytes!("../resources/fonts/inter-4.1/InterVariable-Italic.woff2");

pub(crate) fn register() {
    DIRECTORY.with(|storage| {
        if storage.borrow().is_some() {
            return;
        }
        let result = (|| -> Result<tempfile::TempDir, Box<dyn std::error::Error>> {
            let mut builder = tempfile::Builder::new();
            builder.prefix("fastra-fonts-");
            let directory = if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
                builder.tempdir_in(runtime)?
            } else {
                builder.tempdir()?
            };
            let files: [(&str, &[u8]); 3] = [
                (
                    "Sora-SemiBold.ttf",
                    include_bytes!("../../../app/Sources/Fastra/Resources/Brand/Sora-SemiBold.ttf"),
                ),
                (
                    "InterVariable.ttf",
                    include_bytes!("../resources/fonts/inter-4.1/InterVariable.ttf"),
                ),
                (
                    "InterVariable-Italic.ttf",
                    include_bytes!("../resources/fonts/inter-4.1/InterVariable-Italic.ttf"),
                ),
            ];
            for (name, bytes) in files {
                std::fs::write(directory.path().join(name), bytes)?;
            }
            for (name, _) in files {
                let path = directory.path().join(name);
                let path = CString::new(path.as_os_str().as_bytes())?;
                // Nur diese Anwendung erhält die Schriften. Registrierte Dateien
                // auch bei einem Teilfehler bis zum Prozessende behalten.
                if unsafe { FcConfigAppFontAddFile(FcConfigGetCurrent(), path.as_ptr().cast()) }
                    == 0
                {
                    eprintln!("Fastra font registration failed: {name}");
                }
            }
            // GTK kann die Schriftliste bereits vor dem Startup zwischenspeichern.
            let map = pangocairo::FontMap::default();
            unsafe {
                pango_fc_font_map_config_changed(map.as_ptr().cast());
            }
            Ok(directory)
        })();
        match result {
            Ok(directory) => *storage.borrow_mut() = Some(directory),
            Err(error) => eprintln!("Fastra fonts: {error}"),
        }
    });
}
pub(crate) fn cleanup() {
    DIRECTORY.with(|storage| {
        storage.borrow_mut().take();
    });
}
const SORA: &[u8] = include_bytes!("../../../app/Sources/Fastra/Resources/Brand/Sora-SemiBold.ttf");
pub(crate) fn web_style(scheme: &str) -> String {
    format!("@font-face{{font-family:'Fastra UI';font-style:normal;font-weight:100 900;src:url('{scheme}://document/font/InterVariable.woff2') format('woff2')}}\n@font-face{{font-family:'Fastra UI';font-style:italic;font-weight:100 900;src:url('{scheme}://document/font/InterVariable-Italic.woff2') format('woff2')}}\n@font-face{{font-family:'Inter Variable';font-style:normal;font-weight:100 900;src:url('{scheme}://document/font/InterVariable.woff2') format('woff2')}}\n@font-face{{font-family:'Inter Variable';font-style:italic;font-weight:100 900;src:url('{scheme}://document/font/InterVariable-Italic.woff2') format('woff2')}}\n@font-face{{font-family:'Sora';font-style:normal;font-weight:600;src:url('{scheme}://document/font/Sora-SemiBold.ttf') format('truetype')}}\nbody{{font-family:'Fastra UI',system-ui,sans-serif}}")
}
pub(crate) fn serve(request: &webkit6::URISchemeRequest, scheme: &str) -> bool {
    let Some(uri) = request.uri() else {
        return false;
    };
    let prefix = format!("{scheme}://document/font/");
    let (bytes, mime) = match uri.strip_prefix(prefix.as_str()) {
        Some("InterVariable.woff2") => (NORMAL, "font/woff2"),
        Some("InterVariable-Italic.woff2") => (ITALIC, "font/woff2"),
        Some("Sora-SemiBold.ttf") => (SORA, "font/ttf"),
        _ => return false,
    };
    let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from_static(bytes));
    request.finish(&stream, bytes.len() as i64, Some(mime));
    true
}

#[cfg(debug_assertions)]
pub(super) mod selftest;
