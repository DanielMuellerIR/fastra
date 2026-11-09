use super::*;
use std::time::Instant;
pub(super) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    std::fs::write(
        root.join("local.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    let source="# HTML preview\r\n\r\n<p align=\"center\" title=\"&copy; safe\"><img src=\"lo&#x00000063;al.png\" width=\"48\" alt=\"Local image\">Centered &copy; 🙂</p>\r\n\r\n<details>\r\n<summary>Native disclosure</summary>\r\n\r\nNormal **Markdown** remains.\r\n\r\n</details>\r\n\r\n<pre><code>raw pre is not a trusted code ID</code></pre>\r\n\r\n```text\r\nTrusted code\r\n```\r\n\r\n<div><p>BAD-SCRIPT</p><script>window.fastraInjected=1;fetch('https://example.invalid/attack')</script></div>\r\n\r\n<p title=\"java&Tab;script\">BAD-ATTR</p>\r\n\r\n<img src=\"https://example.invalid/beacon.png\">\r\n\r\n<a href=\"https&colon;//example.invalid/out\" title=\"Safe external\">External link</a>\r\n\r\n<p data-srcline=\"999\">BAD-MARKER</p>\r\n\r\n<div><p>BAD-MALFORMED</div></p>\r\n\r\n<p title=\"&quot; &apos; &#128578;\">Entity text &lt;img src=x onerror=bad&gt;</p>\r\n\r\n<svg><foreignObject><p>BAD-SVG</p></foreignObject></svg>\r\n\r\n# Target\r\n";
    let path = root.join("html-preview.md");
    std::fs::write(&path, source).unwrap();
    ui.load_path(path);
    git_view::test_size(ui.window.upcast_ref());
    let step = Cell::new(0);
    let since = Cell::new(Instant::now());
    let started = Instant::now();
    let answer = Rc::new(RefCell::new(None));
    let held = RefCell::new(None::<Rc<Document>>);
    let revision = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "HTML native stage{} status{}",
            step.get(),
            ui.status.text()
        );
        if step.get() == 0 {
            let Some(doc) = ui.active().filter(|d| buffer_text(&d.buffer) == source) else {
                return glib::ControlFlow::Continue;
            };
            if doc.source_edits_locked() {
                return glib::ControlFlow::Continue;
            }
            revision.set(doc.revision.get());
            doc.markdown_toggle
                .borrow()
                .as_ref()
                .unwrap()
                .set_active(true);
            *held.borrow_mut() = Some(doc);
            step.set(1);
            return glib::ControlFlow::Continue;
        }
        let doc = held.borrow().as_ref().unwrap().clone();
        let preview = doc.markdown.borrow().clone().unwrap();
        match step.get() {
            1 => {
                if preview.print_token(doc.revision.get()).is_some() {
                    let answer = answer.clone();
                    preview.inspect("if(!window.fastraPreviewReady)return JSON.stringify(null);const local=document.querySelector('img[alt=\"Local image\"]');if(!local?.complete)return JSON.stringify(null);return JSON.stringify({center:document.querySelector('p[align=\"center\"]')?.textContent,local:local.naturalWidth,src:local.getAttribute('src'),details:!!document.querySelector('details>summary'),script:!!window.fastraInjected,bad:document.body.textContent.includes('BAD-SCRIPT')||document.body.textContent.includes('BAD-ATTR')||document.body.textContent.includes('BAD-MARKER')||document.body.textContent.includes('BAD-MALFORMED'),inlineForeignText:document.body.textContent.includes('BAD-SVG'),dangerous:[...document.body.querySelectorAll('[onerror],[onclick],iframe,svg,math,form,style')].filter(n=>!n.closest('#fastra-code-controls')).map(n=>n.outerHTML.slice(0,200)),imageCount:document.images.length,entityTitle:[...document.querySelectorAll('p')].find(p=>p.textContent.startsWith('Entity text'))?.getAttribute('title'),remote:[...document.images].some(i=>i.getAttribute('src')?.includes('example.invalid')),codes:document.querySelectorAll('pre[data-fastra-code]').length,raw:document.querySelector('pre:not([data-fastra-code])')?.textContent,forged:!!document.querySelector('[data-srcline=\"999\"]'),handlers:['markdownPosition','markdownCodeCopy','apply','save','writeFile','execute'].filter(n=>!!window.webkit?.messageHandlers?.[n]).sort()});",move|v|*answer.borrow_mut()=Some(v));
                    step.set(2);
                }
            }
            2 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value.is_null() {
                        step.set(1);
                    } else {
                        eprintln!("NATIVE HTML DOM {value}");
                        assert!(value["center"].as_str().unwrap().contains("Centered © 🙂"));
                        assert_eq!(value["local"], 1);
                        assert!(value["src"]
                            .as_str()
                            .unwrap()
                            .starts_with("fastra-preview://image/"));
                        assert_eq!(value["details"], true);
                        for key in ["script", "bad", "remote", "forged"] {
                            assert_eq!(value[key], false, "{key}");
                        }
                        assert_eq!(value["codes"], 1);
                        assert_eq!(value["inlineForeignText"],true,"forbidden inline foreign tags disappear; ordinary text survives like Mac inline script text");
                        assert_eq!(value["dangerous"],serde_json::json!([]),"no untrusted active/foreign DOM; the existing code-copy icon is owned UI");
                        assert_eq!(value["imageCount"], 2);
                        assert_eq!(value["entityTitle"], "\" ' 🙂");
                        assert!(value["raw"].as_str().unwrap().contains("raw pre"));
                        assert_eq!(
                            value["handlers"],
                            serde_json::json!(["markdownCodeCopy", "markdownPosition"])
                        );
                        git_view::test_click(&preview.view, &[]);
                        since.set(Instant::now());
                        step.set(3);
                    }
                }
            }
            3 => {
                if since.get().elapsed() > Duration::from_millis(250) {
                    let answer = answer.clone();
                    preview.inspect("const s=document.querySelector('summary');s.scrollIntoView({block:'center'});s.focus();return JSON.stringify(document.activeElement.tagName);",move|v|*answer.borrow_mut()=Some(v));
                    step.set(4);
                }
            }
            4 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value, "SUMMARY");
                    std::thread::spawn(|| {
                        assert!(std::process::Command::new("xdotool")
                            .args(["key", "--clearmodifiers", "space"])
                            .status()
                            .unwrap()
                            .success());
                    });
                    since.set(Instant::now());
                    step.set(5);
                }
            }
            5 => {
                if since.get().elapsed() > Duration::from_millis(300) {
                    let answer = answer.clone();
                    preview.inspect("const opened=document.querySelector('details').open;try{await fetch('https://example.invalid/csp-probe')}catch{}document.querySelector('a[title=\"Safe external\"]').click();await new Promise(r=>setTimeout(r,100));return JSON.stringify({opened,blocked:fastraPreviewViolations.some(v=>v.blocked.startsWith('https://')),uri:location.href,injected:!!window.fastraInjected});",move|v|*answer.borrow_mut()=Some(v));
                    step.set(6);
                }
            }
            6 => {
                if let Some(value) = answer.borrow_mut().take() {
                    eprintln!("NATIVE HTML INTERACTION {value}");
                    assert_eq!(
                        value["opened"], true,
                        "real XTest Space toggles native details"
                    );
                    assert_eq!(value["blocked"], true);
                    assert_eq!(value["uri"], BASE);
                    assert_eq!(value["injected"], false);
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), revision.get());
                    assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
                    ui.window.queue_draw();
                    if let Some(clock) = ui.window.frame_clock() {
                        clock.request_phase(gtk::gdk::FrameClockPhase::PAINT);
                    }
                    since.set(Instant::now());
                    step.set(7);
                }
            }
            7 if since.get().elapsed() > Duration::from_millis(800) => {
                assert_eq!(buffer_text(&doc.buffer), source);
                let dir = PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap());
                std::fs::create_dir_all(&dir).unwrap();
                assert!(std::process::Command::new("import")
                    .args(["-window", "root"])
                    .arg(dir.join("html-allowlist.png"))
                    .status()
                    .unwrap()
                    .success());
                println!("PASS native HTML allowlist: canonical README, local image, malformed/entity/script rejects, real details input, CSP/navigation/Source/Undo unchanged");
                std::process::exit(0);
            }
            _ => (),
        }
        glib::ControlFlow::Continue
    });
}
