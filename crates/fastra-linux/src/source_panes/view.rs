//! Die abgeleitete View besitzt den vollständigen PRIMARY-Lifecycle ihrer Elternklasse.
use super::*;
use gtk::subclass::prelude::*;
use sourceview5::subclass::prelude::*;
mod imp {
    use super::*;
    #[derive(Default)]
    pub struct View {
        pub buffer: RefCell<Option<gtk::TextBuffer>>,
        pub detached: Cell<bool>,
        pub disposed: Cell<bool>,
        pub(super) return_owner: RefCell<Weak<Ui>>,
        pub(super) folds: RefCell<Weak<folding::Folds>>,
        pub(super) fold_pane: Cell<usize>,
        pub(super) search_caret: RefCell<Option<gtk::TextMark>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for View {
        const NAME: &'static str = "FastraSourcePaneView";
        type Type = super::View;
        type ParentType = sourceview5::View;
    }
    impl ObjectImpl for View {
        fn properties() -> &'static [glib::ParamSpec] {
            static PROPS: std::sync::OnceLock<Vec<glib::ParamSpec>> = std::sync::OnceLock::new();
            PROPS.get_or_init(|| {
                vec![glib::ParamSpecBoolean::builder("fastra-linear-return-v1")
                    .read_only()
                    .build()]
            })
        }
        fn property(&self, _id: usize, pspec: &glib::ParamSpec) -> glib::Value {
            assert_eq!(pspec.name(), "fastra-linear-return-v1");
            let linear = self
                .return_owner
                .borrow()
                .upgrade()
                .and_then(|ui| ui.active())
                .is_none_or(|doc| {
                    doc.rectangles
                        .borrow()
                        .iter()
                        .all(|rectangle| !rectangle.is_selected())
                });
            linear.to_value()
        }
        fn dispose(&self) {
            if !self.disposed.replace(true) {
                self.obj().set_search_caret(None);
                self.restore();
                self.buffer.borrow_mut().take();
            }
        }
    }
    impl WidgetImpl for View {
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            self.parent_snapshot(snapshot);
            if let Some(folds) = self.folds.borrow().upgrade() {
                folds.snapshot(self.fold_pane.get(), self.obj().upcast_ref(), snapshot);
            }
            let view = self.obj();
            let Some(mark) = self.search_caret.borrow().clone().filter(|mark| {
                !mark.is_deleted() && mark.buffer().as_ref() == Some(&view.buffer())
            }) else {
                return;
            };
            let iter = view.buffer().iter_at_mark(&mark);
            let rect = view.iter_location(&iter);
            let (x, y) =
                view.buffer_to_window_coords(gtk::TextWindowType::Widget, rect.x(), rect.y());
            snapshot.push_clip(&gtk::graphene::Rect::new(
                0.,
                0.,
                view.width() as f32,
                view.height() as f32,
            ));
            snapshot.append_color(
                &gtk::gdk::RGBA::new(1., 0.70, 0.08, 0.8),
                &gtk::graphene::Rect::new(x as f32, y as f32, 3., rect.height().max(10) as f32),
            );
            snapshot.pop();
        }
        fn realize(&self) {
            self.parent_realize();
            self.detach();
        }
        fn unrealize(&self) {
            self.restore();
            self.parent_unrealize();
        }
    }
    impl TextViewImpl for View {
        fn copy_clipboard(&self) {
            if self
                .folds
                .borrow()
                .upgrade()
                .is_some_and(|f| f.copy(self.fold_pane.get(), false))
            {
                return;
            }
            self.parent_copy_clipboard();
        }
        fn cut_clipboard(&self) {
            if self
                .folds
                .borrow()
                .upgrade()
                .is_some_and(|f| f.copy(self.fold_pane.get(), true))
            {
                return;
            }
            self.parent_cut_clipboard();
        }
        fn backspace(&self) {
            if self
                .folds
                .borrow()
                .upgrade()
                .is_some_and(|f| f.reveal_delete(self.fold_pane.get(), -1))
            {
                return;
            }
            self.parent_backspace();
        }
        fn delete_from_cursor(&self, kind: gtk::DeleteType, count: i32) {
            if self
                .folds
                .borrow()
                .upgrade()
                .is_some_and(|f| f.reveal_delete(self.fold_pane.get(), count))
            {
                return;
            }
            self.parent_delete_from_cursor(kind, count);
        }
    }
    impl ViewImpl for View {}
    impl View {
        pub fn detach(&self) {
            if self.obj().is_realized() && !self.detached.replace(true) {
                if let Some(buffer) = self.buffer.borrow().as_ref() {
                    buffer.remove_selection_clipboard(&self.obj().primary_clipboard());
                }
            }
        }
        pub fn restore(&self) {
            if self.detached.replace(false) {
                if let Some(buffer) = self.buffer.borrow().as_ref() {
                    buffer.add_selection_clipboard(&self.obj().primary_clipboard());
                }
            }
        }
    }
}
glib::wrapper! {
    pub struct View(ObjectSubclass<imp::View>)
    @extends sourceview5::View, gtk::TextView, gtk::Widget,
    @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Scrollable;
}
impl View {
    pub(super) fn bind_folding(&self, folds: &Rc<folding::Folds>, index: usize) {
        *self.imp().folds.borrow_mut() = Rc::downgrade(folds);
        self.imp().fold_pane.set(index);
    }
    pub(super) fn set_search_caret(&self, offset: Option<i32>) {
        if let Some(mark) = self.imp().search_caret.borrow_mut().take() {
            if let Some(buffer) = mark.buffer() {
                buffer.delete_mark(&mark);
            }
        }
        if let Some(offset) =
            offset.filter(|offset| (0..=self.buffer().char_count()).contains(offset))
        {
            let mark = self
                .buffer()
                .create_mark(None, &self.buffer().iter_at_offset(offset), true);
            *self.imp().search_caret.borrow_mut() = Some(mark);
        }
        self.queue_draw();
    }
    pub(super) fn new(buffer: &sourceview5::Buffer) -> Self {
        let view: Self = glib::Object::builder().property("buffer", buffer).build();
        *view.imp().buffer.borrow_mut() = Some(buffer.clone().upcast());
        view
    }
    pub(super) fn bind_return_owner(&self, ui: &Rc<Ui>) {
        *self.imp().return_owner.borrow_mut() = Rc::downgrade(ui);
    }
    #[cfg(debug_assertions)]
    pub(super) fn bind(&self, buffer: &impl IsA<gtk::TextBuffer>) {
        let imp = self.imp();
        if imp.disposed.get() {
            return;
        }
        imp.restore();
        self.set_buffer(Some(buffer));
        *imp.buffer.borrow_mut() = Some(buffer.clone().upcast());
        imp.detach();
    }
}

pub(super) fn native_return_ready() -> bool {
    let view = View::new(&sourceview5::Buffer::new(None));
    let Some(plan) = view.find_property("fastra-return-plan-abi-v1") else {
        return false;
    };
    let Some(policy) = view.find_property("fastra-linear-return-v1") else {
        return false;
    };
    plan.owner_type() == sourceview5::View::static_type()
        && plan.value_type() == u32::static_type()
        && plan.flags().contains(glib::ParamFlags::READABLE)
        && !plan.flags().contains(glib::ParamFlags::WRITABLE)
        && policy.owner_type() == View::static_type()
        && policy.value_type() == bool::static_type()
        && policy.flags().contains(glib::ParamFlags::READABLE)
        && !policy.flags().contains(glib::ParamFlags::WRITABLE)
        && view.property::<u32>("fastra-return-plan-abi-v1") == 0x52544e31
}
