use super::*;
use gtk::subclass::prelude::*;
use std::cell::OnceCell;

mod imp {
    use super::*;
    #[derive(Default)]
    pub struct Choice {
        pub preferred: Cell<i32>,
        pub child: OnceCell<gtk::Box>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Choice {
        const NAME: &'static str = "FastraAppearanceChoice";
        type Type = super::Choice;
        type ParentType = gtk::Widget;
        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("box");
            klass.set_accessible_role(gtk::AccessibleRole::Group);
        }
    }
    impl ObjectImpl for Choice {
        fn constructed(&self) {
            self.parent_constructed();
            let child = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            child.set_homogeneous(true);
            child.set_parent(&*self.obj());
            self.child.set(child).unwrap();
        }
        fn dispose(&self) {
            if let Some(child) = self.child.get().filter(|child| child.parent().is_some()) {
                child.unparent();
            }
        }
    }
    impl WidgetImpl for Choice {
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let (minimum, natural, minimum_baseline, natural_baseline) =
                self.child.get().unwrap().measure(orientation, for_size);
            // Eine Wunschbreite darf das schmale Fenster nicht wie eine
            // width-request sperren. Die echten Knöpfe bestimmen ihr Minimum.
            let natural = if orientation == gtk::Orientation::Horizontal {
                natural.max(self.preferred.get())
            } else {
                natural
            };
            (minimum, natural, minimum_baseline, natural_baseline)
        }
        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            self.child
                .get()
                .unwrap()
                .allocate(width, height, baseline, None);
        }
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            self.obj()
                .snapshot_child(self.child.get().unwrap(), snapshot);
        }
    }
}
glib::wrapper! {
    pub struct Choice(ObjectSubclass<imp::Choice>) @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}
impl Choice {
    pub(super) fn new() -> Self {
        glib::Object::new()
    }
    pub(super) fn prefer(&self, width: i32) {
        if self.imp().preferred.replace(width) != width {
            self.queue_resize();
        }
    }
    pub(super) fn content(&self) -> &gtk::Box {
        self.imp().child.get().unwrap()
    }
    pub(super) fn append(&self, widget: &impl IsA<gtk::Widget>) {
        self.content().append(widget);
    }
}
