use super::*;
use webkit6::prelude::*;
fn apply(view: &webkit6::WebView) {
    let dark = super::dark(&gtk::prelude::WidgetExt::settings(view));
    let (fg, bg, control, secondary, border, link, mark) = if dark {
        (
            "#f2f2f2", "#171717", "#333333", "#aaaaaa", "#484848", "#8bb7f2", "#665200",
        )
    } else {
        (
            "#363636", "#ffffff", "#ececec", "#737373", "#d7d7d7", "#3f69a8", "#ffee9a",
        )
    };
    let palette = serde_json::json!({"fg":fg,"bg":bg,"control":control,"secondary":secondary,"border":border,"link":link,"mark":mark});
    let script = format!(
        r#"(async()=>{{
        const dark={dark},palette={palette},root=document.documentElement;if(!root)return;
        for(const [key,value] of Object.entries(palette))root.style.setProperty('--'+key,value);
        root.dataset.dark=String(dark);root.style.colorScheme=dark?'dark':'light';
        let sheet=document.getElementById('fastra-appearance-style');
        if(!sheet){{sheet=document.createElement('style');sheet.id='fastra-appearance-style';document.head.append(sheet);}}
        sheet.textContent='body{{color:var(--fg);background:var(--bg)}}mark{{background:var(--mark)!important;color:inherit}}';
        await window.fastraPreviewTheme?.(dark);
        const visual=document.getElementById('fastra-visual');if(visual)await window.fastraUpdateMarkdownTheme?.(visual,dark);
        window.fastraAppearanceApplied=dark;
    }})()"#
    );
    view.set_background_color(&if dark {
        gtk::gdk::RGBA::new(23. / 255., 23. / 255., 23. / 255., 1.)
    } else {
        gtk::gdk::RGBA::WHITE
    });
    view.evaluate_javascript(&script, None, None, None::<&gio::Cancellable>, |_| {});
}
pub(crate) fn install(view: &webkit6::WebView) {
    let weak = view.downgrade();
    super::watch(move || {
        let Some(view) = weak.upgrade() else {
            return false;
        };
        apply(&view);
        true
    });
    view.connect_load_changed(|view, event| {
        if event == webkit6::LoadEvent::Finished {
            apply(view);
        }
    });
    apply(view);
}
