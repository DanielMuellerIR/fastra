//! Umbruch zwischen vollständigen Control-Gruppen anhand ihrer eigenen Wunschbreiten.
use super::*;
use gtk::subclass::prelude::*;
#[derive(Clone)]
struct Group {
    label: Option<gtk::Widget>,
    control: gtk::Widget,
}
struct Allocation {
    widget: gtk::Widget,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}
mod imp {
    use super::*;
    #[derive(Default)]
    pub struct Row {
        pub spacing: Cell<i32>,
        pub row_spacing: Cell<i32>,
        pub(super) groups: RefCell<Vec<Group>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Row {
        const NAME: &'static str = "FastraWrapRow";
        type Type = super::Row;
        type ParentType = gtk::Widget;
        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("box");
            klass.set_accessible_role(gtk::AccessibleRole::Group);
        }
    }
    impl ObjectImpl for Row {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
            self.groups.borrow_mut().clear();
        }
    }
    impl WidgetImpl for Row {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let widget = self.obj();
            if orientation == gtk::Orientation::Horizontal {
                let mut min = 0;
                let mut natural = 0;
                let mut count = 0;
                for group in self
                    .groups
                    .borrow()
                    .iter()
                    .filter(|g| g.control.is_visible())
                {
                    let (a, b, _, _) = group.control.measure(orientation, -1);
                    let (label_min, label_nat) = group
                        .label
                        .as_ref()
                        .map(|label| {
                            let (a, b, _, _) = label.measure(orientation, -1);
                            (a.max(80) + 8, b + 8)
                        })
                        .unwrap_or((0, 0));
                    min = min.max(a + label_min);
                    natural += b + label_nat;
                    count += 1;
                }
                natural += self.spacing.get() * (count - 1).max(0);
                (min, natural.max(min), -1, -1)
            } else {
                let height = widget
                    .arrange(if for_size < 0 { i32::MAX } else { for_size })
                    .1;
                (height, height, -1, -1)
            }
        }
        fn size_allocate(&self, width: i32, _height: i32, _baseline: i32) {
            for a in self.obj().arrange(width).0 {
                a.widget.allocate(
                    a.width,
                    a.height,
                    -1,
                    Some(
                        gtk::gsk::Transform::new()
                            .translate(&gtk::graphene::Point::new(a.x as f32, a.y as f32)),
                    ),
                );
            }
        }
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let widget = self.obj();
            for child in chrome::children(widget.upcast_ref::<gtk::Widget>()) {
                if child.is_visible() {
                    widget.snapshot_child(&child, snapshot);
                }
            }
        }
    }
}
glib::wrapper! {pub struct Row(ObjectSubclass<imp::Row>) @extends gtk::Widget,@implements gtk::Accessible,gtk::Buildable,gtk::ConstraintTarget;}
impl Row {
    pub fn new(spacing: i32, row_spacing: i32) -> Self {
        let row: Self = glib::Object::new();
        row.imp().spacing.set(spacing);
        row.imp().row_spacing.set(row_spacing);
        row
    }
    pub fn append(&self, child: &impl IsA<gtk::Widget>) {
        self.push(None, child.as_ref());
    }
    pub fn append_labeled(&self, label: &gtk::Label, child: &impl IsA<gtk::Widget>) {
        label.set_width_request(-1);
        self.push(Some(label.clone().upcast()), child.as_ref());
    }
    fn push(&self, label: Option<gtk::Widget>, control: &gtk::Widget) {
        if let Some(label) = label.as_ref() {
            label.set_parent(self);
        }
        control.set_parent(self);
        self.imp().groups.borrow_mut().push(Group {
            label,
            control: control.clone(),
        });
        self.queue_resize();
    }
    fn arrange(&self, width: i32) -> (Vec<Allocation>, i32) {
        let mut result = Vec::<Allocation>::new();
        let mut row_start = 0;
        let mut x = 0;
        let mut y = 0;
        let mut height = 0;
        for group in self
            .imp()
            .groups
            .borrow()
            .iter()
            .filter(|g| g.control.is_visible())
        {
            let (min, natural, _, _) = group.control.measure(gtk::Orientation::Horizontal, -1);
            let label_nat = group
                .label
                .as_ref()
                .map(|l| l.measure(gtk::Orientation::Horizontal, -1).1)
                .unwrap_or(0);
            let mut label_width = if group.label.is_some() {
                if x == 0 {
                    label_nat.max(80)
                } else {
                    label_nat
                }
            } else {
                0
            };
            let gap = if group.label.is_some() { 8 } else { 0 };
            let candidate = natural + label_width + gap;
            if x > 0 && candidate > width - x {
                for item in &mut result[row_start..] {
                    item.y += (height - item.height) / 2;
                }
                row_start = result.len();
                x = 0;
                y += height + self.imp().row_spacing.get();
                height = 0;
                if group.label.is_some() {
                    label_width = label_nat.max(80);
                }
            }
            if let Some(label) = group.label.as_ref() {
                let h = label.measure(gtk::Orientation::Vertical, label_width).1;
                result.push(Allocation {
                    widget: label.clone(),
                    x,
                    y,
                    width: label_width,
                    height: h,
                });
                height = height.max(h);
                x += label_width + gap;
            }
            let w = natural.min(width - x).max(min);
            let h = group.control.measure(gtk::Orientation::Vertical, w).1;
            result.push(Allocation {
                widget: group.control.clone(),
                x,
                y,
                width: w,
                height: h,
            });
            x += w + self.imp().spacing.get();
            height = height.max(h);
        }
        for item in &mut result[row_start..] {
            item.y += (height - item.height) / 2;
        }
        (result, y + height)
    }
}
