//! Lineare Clipboardpaste prüft den vollständigen Ersatz vor der nativen Auswahl-Löschung.
use super::{buffer_text, rectangle, text_limits, Document, Ui};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::{Rc, Weak},
};

#[cfg(debug_assertions)]
thread_local! { static TEST_COUNTS: Cell<(u64,u64)> = const { Cell::new((0,0)) }; }
#[cfg(debug_assertions)]
pub(super) fn test_counts() -> (u64, u64) {
    TEST_COUNTS.with(Cell::get)
}

struct Binding {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    views: [glib::WeakRef<sourceview5::View>; 2],
    pane: Cell<usize>,
    serial: Cell<u64>,
    pending: RefCell<Option<Rc<Cell<bool>>>>,
}
impl Binding {
    fn invalidate(&self) {
        self.serial.set(self.serial.get().wrapping_add(1));
        if let Some(cancel) = self.pending.borrow_mut().take() {
            cancel.set(true);
        }
    }
    fn owner(&self, index: usize) -> Option<(Rc<Ui>, Rc<Document>, sourceview5::View)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        let view = self.views[index].upgrade()?;
        if self.pane.get() != index
            || !ui.window.is_visible()
            || !ui.window.is_active()
            || !view.is_mapped()
            || !view.is_sensitive()
            || !view.is_editable()
            || view
                .root()
                .is_none_or(|root| root != ui.window.clone().upcast::<gtk::Root>())
            || doc.source_edits_locked()
            || doc.close_pending.get()
            || ui.window_close_dialog.get()
            || ui.close_committed.get()
            || super::close_protocol::active(&ui)
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            || !ui
                .documents
                .borrow()
                .iter()
                .any(|item| Rc::ptr_eq(item, &doc))
            || !doc
                .source_panes
                .borrow()
                .as_ref()
                .is_some_and(|panes| panes.owns(&view))
        {
            return None;
        }
        Some((ui, doc, view))
    }
    fn paste(self: &Rc<Self>, index: usize) {
        self.read(index, None);
    }
    fn read(self: &Rc<Self>, index: usize, primary_at: Option<i32>) {
        self.invalidate();
        self.pane.set(index);
        let Some((ui, doc, view)) = self.owner(index) else {
            return;
        };
        if let Some(rect) = doc
            .rectangles
            .borrow()
            .get(index)
            .filter(|rect| primary_at.is_none() && rect.is_selected())
            .cloned()
        {
            rect.paste_mode(false);
            return;
        }
        #[cfg(debug_assertions)]
        TEST_COUNTS.with(|counts| {
            let (started, ended) = counts.get();
            counts.set((started + 1, ended));
        });
        let serial = self.serial.get();
        let revision = doc.revision.get();
        let target = view.buffer();
        let selection = selection(&target);
        let ticket = ui.close_ticket.borrow().clone();
        let request = rectangle::clipboard::Request::bounded(
            if primary_at.is_some() {
                view.primary_clipboard()
            } else {
                view.clipboard()
            },
            view,
            fastra_document::EDITABLE_BYTES,
        );
        *self.pending.borrow_mut() = Some(request.cancellation());
        let weak = Rc::downgrade(self);
        glib::MainContext::default().spawn_local(async move {
            #[cfg(debug_assertions)]
            if let Ok(delay) = std::env::var("FASTRA_LINEAR_PASTE_DELAY_MS") {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                let delay: u64 = delay.parse().unwrap();
                assert!(delay <= 1500);
                glib::timeout_future(std::time::Duration::from_millis(delay)).await;
            }
            let result = request.read().await;
            #[cfg(debug_assertions)]
            TEST_COUNTS.with(|counts| {
                let (started, ended) = counts.get();
                counts.set((started, ended + 1));
            });
            let Some(binding) = weak.upgrade().filter(|binding| binding.serial.get() == serial) else {
                return;
            };
            let Some((ui, doc, view)) = binding.owner(index) else {
                return;
            };
            let same_ticket = match (&ticket, ui.close_ticket.borrow().as_ref()) {
                (None, None) => true,
                (Some(before), Some(after)) => Weak::ptr_eq(before, after),
                _ => false,
            };
            if doc.revision.get() != revision || view.buffer() != target || selection != self::selection(&target) || !same_ticket {
                return;
            }
            binding.pending.borrow_mut().take();
            let value = match result {
                Ok(value) => value,
                Err(error) => {
                    ui.status.set_text(match error {
                        rectangle::Error::Limit => ui.lang.text("Die Zwischenablage überschreitet 32 MiB. Quelltext unverändert.", "Clipboard exceeds 32 MiB. Source unchanged."),
                        _ => ui.lang.text("Die Zwischenablage konnte nicht vollständig als UTF-8-Text ohne Nullzeichen übernommen werden. Quelltext unverändert.", "The clipboard could not be transferred completely as UTF-8 text without NUL. Source unchanged."),
                    });
                    return;
                }
            };
            if value.is_empty() {
                return;
            }
            let source = buffer_text(&doc.buffer);
            if primary_at.is_some() && doc.rectangles.borrow().iter().any(|rect| rect.is_selected()) { return; }
            let start = primary_at.unwrap_or(selection.0.min(selection.1));
            let end = primary_at.unwrap_or(selection.0.max(selection.1));
            if let Err(error) = replacement(&source, start, end, &value, ui.lang) {
                ui.status.set_text(&error);
                return;
            }
            view.grab_focus();
            if doc.revision.get()!=revision || view.buffer()!=target || self::selection(&target)!=selection {return;}
            let mut a = target.iter_at_offset(start);
            let mut b = target.iter_at_offset(end);
            target.begin_user_action();
            if primary_at.is_none() {
                target.delete(&mut a, &mut b);
            }
            target.insert(&mut a, &value);
            if primary_at.is_none() { target.place_cursor(&a); }
            target.end_user_action();
            if primary_at.is_none() && binding.owner(index).is_some() {
                // GTK aktualisiert die Scrollgrenzen nach der neuen Zeilenhöhe.
                let revision=doc.revision.get();
                let selected=self::selection(&target);
                let serial=binding.serial.get();
                let pane=super::source_panes::capture(&doc);
                let weak=Rc::downgrade(&binding);
                glib::idle_add_local_once(move || {
                    let Some(binding)=weak.upgrade().filter(|b|b.serial.get()==serial) else{return};
                    let Some((_,doc,view))=binding.owner(index) else{return};
                    if doc.revision.get()!=revision || self::selection(&target)!=selected || pane.as_ref().is_none_or(|p|p.view!=view || !p.valid(&doc)){return;}
                    let buffer=gtk::prelude::TextViewExt::buffer(&view);
                    view.scroll_to_mark(&buffer.get_insert(),0.1,false,0.,0.);
                });
            }
        });
    }
}
fn selection(buffer: &gtk::TextBuffer) -> (i32, i32) {
    (
        buffer.cursor_position(),
        buffer.iter_at_mark(&buffer.selection_bound()).offset(),
    )
}
fn replacement(
    source: &str,
    start: i32,
    end: i32,
    value: &str,
    lang: super::Language,
) -> Result<(), String> {
    let boundary = |offset: i32| {
        usize::try_from(offset).ok().and_then(|offset| {
            source
                .char_indices()
                .map(|(at, _)| at)
                .chain(std::iter::once(source.len()))
                .nth(offset)
        })
    };
    let (Some(start), Some(end)) = (boundary(start), boundary(end)) else {
        return Err(lang
            .text(
                "Auswahl inzwischen ungültig. Quelltext unverändert.",
                "Selection became invalid. Source unchanged.",
            )
            .into());
    };
    if start > end {
        return Err(lang
            .text(
                "Auswahl inzwischen ungültig. Quelltext unverändert.",
                "Selection became invalid. Source unchanged.",
            )
            .into());
    }
    let length = source
        .len()
        .checked_sub(end - start)
        .and_then(|length| length.checked_add(value.len()));
    let Some(length) = length.filter(|length| *length <= fastra_document::EDITABLE_BYTES) else {
        return Err(lang
            .text(
                "Das Einfügeergebnis überschreitet 32 MiB. Quelltext unverändert.",
                "Paste result exceeds 32 MiB. Source unchanged.",
            )
            .into());
    };
    let mut planned = String::with_capacity(length);
    planned.push_str(&source[..start]);
    planned.push_str(value);
    planned.push_str(&source[end..]);
    text_limits::validate(&planned, lang)
}
pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, views: [&sourceview5::View; 2]) {
    let binding = Rc::new(Binding {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        views: views.map(|view| view.downgrade()),
        pane: Cell::new(0),
        serial: Cell::new(0),
        pending: RefCell::new(None),
    });
    let weak = Rc::downgrade(&binding);
    doc.buffer.connect_changed(move |_| {
        if let Some(binding) = weak.upgrade() {
            binding.invalidate();
        }
    });
    let weak = Rc::downgrade(&binding);
    doc.buffer.connect_mark_set(move |_, _, mark| {
        if matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
            if let Some(binding) = weak.upgrade() {
                binding.invalidate();
            }
        }
    });
    for (index, view) in views.into_iter().enumerate() {
        let weak = Rc::downgrade(&binding);
        view.buffer().connect_mark_set(move |_, _, mark| {
            if matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
                if let Some(b) = weak.upgrade() {
                    b.invalidate();
                }
            }
        });
        let target = binding.clone();
        view.connect_paste_clipboard(move |view| {
            view.stop_signal_emission_by_name("paste-clipboard");
            target.paste(index);
        });
        let primary = gtk::GestureClick::builder()
            .button(2)
            .propagation_phase(gtk::PropagationPhase::Capture)
            .build();
        let target = binding.clone();
        let weak_view = view.downgrade();
        primary.connect_pressed(move |gesture, _, x, y| {
            let Some(view) = weak_view.upgrade() else {
                return;
            };
            if !view.settings().is_gtk_enable_primary_paste()
                || target.doc.upgrade().is_some_and(|doc| {
                    doc.rectangles
                        .borrow()
                        .iter()
                        .any(|rect| rect.is_selected())
                })
                || view
                    .pick(x, y, gtk::PickFlags::DEFAULT)
                    .is_some_and(|picked| {
                        let text = picked == view.clone().upcast::<gtk::Widget>();
                        // Nur der eigene native Zeilennummernrenderer reicht Button2 an GtkTextView weiter.
                        let line_numbers = picked.type_().name() == "GtkSourceGutterRendererLines"
                            && picked.is_ancestor(&sourceview5::prelude::ViewExt::gutter(
                                &view,
                                gtk::TextWindowType::Left,
                            ));
                        !text && !line_numbers
                    })
            {
                return;
            }
            gesture.set_state(gtk::EventSequenceState::Claimed);
            let (x, y) =
                view.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
            let buffer = gtk::prelude::TextViewExt::buffer(&view);
            let mut iter = buffer.start_iter();
            // Auch neben/unter Text liefert GTK den nächstgelegenen Einfügepunkt; der Bool bedeutet nur „auf Glyphen“.
            unsafe {
                use glib::translate::{ToGlibPtr, ToGlibPtrMut};
                gtk::ffi::gtk_text_view_get_iter_at_location(
                    view.upcast_ref::<gtk::TextView>().to_glib_none().0,
                    iter.to_glib_none_mut().0,
                    x,
                    y,
                );
            }
            target.read(index, Some(iter.offset()));
        });
        view.add_controller(primary);
        let weak = Rc::downgrade(&binding);
        view.connect_has_focus_notify(move |view| {
            if view.has_focus() {
                if let Some(binding) = weak.upgrade() {
                    if binding.pane.replace(index) != index {
                        binding.invalidate();
                    }
                }
            }
        });
        let weak = Rc::downgrade(&binding);
        view.connect_unmap(move |_| {
            if let Some(binding) = weak.upgrade() {
                binding.invalidate();
            }
        });
        let weak = Rc::downgrade(&binding);
        view.connect_buffer_notify(move |_| {
            if let Some(binding) = weak.upgrade() {
                binding.invalidate();
            }
        });
        let weak = Rc::downgrade(&binding);
        view.connect_editable_notify(move |_| {
            if let Some(binding) = weak.upgrade() {
                binding.invalidate();
            }
        });
        let weak = Rc::downgrade(&binding);
        view.connect_state_flags_changed(move |view, _| {
            if !view.is_sensitive() {
                if let Some(binding) = weak.upgrade() {
                    binding.invalidate();
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checks_complete_prefix_suffix_and_utf8_boundaries() {
        assert!(replacement("a", 1, 1, &"x".repeat(65535), super::super::Language(false)).is_ok());
        assert!(replacement("a", 1, 1, &"x".repeat(65536), super::super::Language(false)).is_err());
        assert!(replacement(
            "prefixSELECTsuffix",
            6,
            12,
            &"x".repeat(65536),
            super::super::Language(false)
        )
        .is_err());
        assert!(replacement("é🙂\r\n二", 1, 2, "ok\r\n", super::super::Language(false)).is_ok());
        assert!(replacement("abc", 1, 2, "x\0y", super::super::Language(false)).is_err());
        assert!(replacement("é🙂", 0, 8, "x", super::super::Language(false)).is_err());
    }
    #[test]
    fn total_boundary_counts_complete_replacement_bytes() {
        let source = "\n".repeat(fastra_document::EDITABLE_BYTES);
        assert!(replacement(&source, 0, 1, "\n", super::super::Language(false)).is_ok());
        assert!(replacement(&source, 0, 0, "x", super::super::Language(false)).is_err());
    }
}
