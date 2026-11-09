//! PRIMARY exportiert die letzte echte Sourceauswahl erst bei einer tatsächlichen Leseanforderung.
use super::*;
use gtk::gdk::subclass::prelude::*;
pub(super) struct Selection {
    doc: Weak<Document>,
    view: glib::WeakRef<sourceview5::View>,
    buffer: glib::WeakRef<sourceview5::Buffer>,
    head: gtk::TextMark,
    anchor: gtk::TextMark,
}
impl Selection {
    pub(super) fn new(
        doc: &Rc<Document>,
        view: &sourceview5::View,
        buffer: &sourceview5::Buffer,
    ) -> Option<Self> {
        buffer.selection_bounds()?;
        Some(Self {
            doc: Rc::downgrade(doc),
            view: view.downgrade(),
            buffer: buffer.downgrade(),
            head: buffer.create_mark(None, &buffer.iter_at_mark(&buffer.get_insert()), false),
            anchor: buffer.create_mark(None, &buffer.iter_at_mark(&buffer.selection_bound()), true),
        })
    }
    fn text(&self) -> Result<String, glib::Error> {
        let fail = || {
            glib::Error::new(
                gtk::gio::IOErrorEnum::Closed,
                "Source selection no longer available",
            )
        };
        let doc = self.doc.upgrade().ok_or_else(fail)?;
        let view = self.view.upgrade().ok_or_else(fail)?;
        let buffer = self.buffer.upgrade().ok_or_else(fail)?;
        if !view.is_realized() {
            return Err(fail());
        }
        if !doc
            .source_panes
            .borrow()
            .as_ref()
            .is_some_and(|p| p.owns(&view))
            || view.buffer() != buffer.clone().upcast::<gtk::TextBuffer>()
        {
            return Err(fail());
        }
        let a = buffer.iter_at_mark(&self.head);
        let b = buffer.iter_at_mark(&self.anchor);
        let (mut at, end) = if a.offset() <= b.offset() {
            (a, b)
        } else {
            (b, a)
        };
        let mut out = String::new();
        while at.offset() < end.offset() {
            let mut next = at;
            next.forward_chars((end.offset() - at.offset()).min(4096));
            let chunk = buffer.text(&at, &next, true);
            if out.len().saturating_add(chunk.len()) > fastra_document::EDITABLE_BYTES {
                return Err(glib::Error::new(
                    gtk::gio::IOErrorEnum::NoSpace,
                    "Source selection exceeds32MiB",
                ));
            }
            out.push_str(&chunk);
            at = next;
        }
        Ok(out)
    }
}
impl Drop for Selection {
    fn drop(&mut self) {
        if let Some(buffer) = self.buffer.upgrade() {
            for mark in [&self.head, &self.anchor] {
                if !mark.is_deleted() {
                    buffer.delete_mark(mark);
                }
            }
        }
    }
}
mod imp {
    use super::*;
    #[derive(Default)]
    pub struct Provider {
        pub(super) selection: RefCell<Option<Selection>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Provider {
        const NAME: &'static str = "FastraSourcePrimaryProvider";
        type Type = super::Provider;
        type ParentType = gtk::gdk::ContentProvider;
    }
    impl ObjectImpl for Provider {}
    impl ContentProviderImpl for Provider {
        fn formats(&self) -> gtk::gdk::ContentFormats {
            gtk::gdk::ContentFormats::for_type(String::static_type())
        }
        fn value(&self, type_: glib::Type) -> Result<glib::Value, glib::Error> {
            if type_ != String::static_type() {
                return self.parent_value(type_);
            }
            let selection = self.selection.borrow();
            let Some(selection) = selection.as_ref() else {
                return Err(glib::Error::new(
                    gtk::gio::IOErrorEnum::Closed,
                    "No source selection",
                ));
            };
            selection.text().map(|s| s.to_value())
        }
    }
}
glib::wrapper! {pub struct Provider(ObjectSubclass<imp::Provider>) @extends gtk::gdk::ContentProvider;}
impl Provider {
    pub(super) fn new(selection: Selection) -> Self {
        let provider: Self = glib::Object::new();
        *provider.imp().selection.borrow_mut() = Some(selection);
        provider
    }
}

pub(super) fn changed(
    doc: &Rc<Document>,
    view: &sourceview5::View,
    buffer: &sourceview5::Buffer,
    offered: &glib::WeakRef<gtk::gdk::ContentProvider>,
) {
    if !view.is_realized() || view.buffer() != buffer.clone().upcast::<gtk::TextBuffer>() {
        return;
    }
    let clipboard = view.primary_clipboard();
    if buffer.selection_bounds().is_none() {
        // Nur die eigene aufgehobene Auswahl darf ihr Angebot freigeben.
        if offered
            .upgrade()
            .is_some_and(|own| clipboard.content().as_ref() == Some(&own))
            && clipboard
                .set_content(None::<&gtk::gdk::ContentProvider>)
                .is_ok()
        {
            offered.set(None);
        }
    } else if view.has_focus() {
        if let Some(selection) = Selection::new(doc, view, buffer) {
            let provider = Provider::new(selection);
            if clipboard.set_content(Some(&provider)).is_ok() {
                offered.set(Some(provider.upcast_ref()));
            }
        }
    }
}
