use super::*;

const MINIMUM: i32 = 96;
thread_local! {
    static OWNERS: RefCell<Vec<Weak<Columns>>> = const { RefCell::new(Vec::new()) };
    static RATIO: Cell<u16> = const { Cell::new(5000) };
    static REVISION: Cell<u64> = const { Cell::new(0) };
    static DIRTY: Cell<bool> = const { Cell::new(false) };
}
pub(super) fn revision() -> u64 {
    REVISION.with(Cell::get)
}
pub(super) fn received(ratio: u16, observed: u64, written: bool) {
    if observed != revision() || (!written && DIRTY.with(Cell::get)) {
        return;
    }
    if written {
        DIRTY.with(|dirty| dirty.set(false));
    }
    broadcast(ratio);
}
fn broadcast(ratio: u16) {
    RATIO.with(|current| current.set(ratio));
    OWNERS.with(|owners| {
        owners.borrow_mut().retain(|owner| {
            if let Some(owner) = owner.upgrade() {
                owner.ratio.set(ratio);
                owner.place();
                true
            } else {
                false
            }
        })
    });
}
fn leading(width: i32, ratio: u16) -> i32 {
    let usable = (width - 1).max(0);
    if usable <= MINIMUM * 2 {
        return usable / 2;
    }
    ((f64::from(usable) * f64::from(ratio) / 10000.).round() as i32)
        .clamp(MINIMUM, usable - MINIMUM)
}
fn ratio_at(width: i32, position: f64) -> u16 {
    if width <= 1 {
        return 5000;
    }
    (position / f64::from(width - 1) * 10000.)
        .round()
        .clamp(0., 10000.) as u16
}
type Persist = Box<dyn Fn(u16)>;
pub(super) struct Columns {
    pub widget: gtk::Paned,
    ratio: Cell<u16>,
    updating: Cell<bool>,
    queued: Cell<bool>,
    width: Cell<i32>,
    drag: Cell<Option<f64>>,
    persist: RefCell<Option<Persist>>,
    lang: Language,
}
impl Columns {
    pub fn new(children: &[gtk::Overlay; 2], lang: Language) -> Rc<Self> {
        let widget = gtk::Paned::new(gtk::Orientation::Horizontal);
        // GTKs eigene Capture-Gesten laufen sonst neben dem breiteren Griff.
        // Angehängt lassen: GtkPaned hält intern Zeiger auf diese Controller.
        let controllers = widget.observe_controllers();
        for index in 0..controllers.n_items() {
            if let Some(controller) = controllers
                .item(index)
                .and_downcast::<gtk::EventController>()
                .filter(|controller| controller.is::<gtk::GestureDrag>())
            {
                controller.set_propagation_phase(gtk::PropagationPhase::None);
            }
        }
        widget.add_css_class("diff-columns");
        widget.set_start_child(Some(&children[0]));
        widget.set_end_child(Some(&children[1]));
        widget.set_resize_start_child(true);
        widget.set_resize_end_child(true);
        widget.set_shrink_start_child(false);
        widget.set_shrink_end_child(false);
        for child in children {
            child.set_size_request(MINIMUM, -1);
        }
        widget.update_property(&[gtk::accessible::Property::Label(
            lang.text("Spaltenteilung", "Column divider"),
        )]);
        let this = Rc::new(Self {
            widget,
            ratio: Cell::new(RATIO.with(Cell::get)),
            updating: Cell::new(false),
            queued: Cell::new(false),
            width: Cell::new(0),
            drag: Cell::new(None),
            persist: RefCell::new(None),
            lang,
        });
        OWNERS.with(|owners| {
            let mut owners = owners.borrow_mut();
            owners.retain(|owner| owner.strong_count() > 0);
            owners.push(Rc::downgrade(&this));
        });
        let weak = Rc::downgrade(&this);
        this.widget.connect_map(move |_| {
            if let Some(this) = weak.upgrade() {
                Self::queue(&this);
            }
        });
        let weak = Rc::downgrade(&this);
        this.widget.connect_min_position_notify(move |_| {
            if let Some(this) = weak.upgrade() {
                Self::queue(&this);
            }
        });
        let weak = Rc::downgrade(&this);
        this.widget.connect_max_position_notify(move |_| {
            if let Some(this) = weak.upgrade() {
                Self::queue(&this);
            }
        });
        let weak = Rc::downgrade(&this);
        this.widget.connect_position_notify(move |widget| {
            if let Some(this) = weak.upgrade().filter(|this| {
                !this.updating.get()
                    && this.drag.get().is_none()
                    && !this.queued.get()
                    && this.width.get() == widget.width()
                    && widget.is_mapped()
            }) {
                this.change(ratio_at(widget.width(), f64::from(widget.position())), true);
            }
        });
        let drag = gtk::GestureDrag::new();
        drag.set_button(1);
        drag.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        drag.connect_drag_begin(move |gesture, x, _| {
            if let Some(this) = weak.upgrade() {
                if this.at_handle(x) {
                    this.drag.set(Some(f64::from(this.widget.position())));
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                    this.widget.grab_focus();
                } else {
                    gesture.set_state(gtk::EventSequenceState::Denied);
                }
            }
        });
        let weak = Rc::downgrade(&this);
        drag.connect_drag_update(move |_, x, _| {
            if let Some(this) = weak.upgrade() {
                this.drag_to(x);
            }
        });
        let weak = Rc::downgrade(&this);
        drag.connect_drag_end(move |_, x, _| {
            if let Some(this) = weak.upgrade().filter(|this| this.drag.get().is_some()) {
                this.drag_to(x);
                this.drag.set(None);
                this.save();
            }
        });
        let weak = Rc::downgrade(&this);
        drag.connect_cancel(move |_, _| {
            if let Some(this) = weak
                .upgrade()
                .filter(|this| this.drag.replace(None).is_some())
            {
                this.save();
            }
        });
        this.widget.add_controller(drag.clone());
        let click = gtk::GestureClick::new();
        click.set_button(1);
        click.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        click.connect_pressed(move |gesture, count, x, _| {
            if count == 2 {
                if let Some(this) = weak.upgrade().filter(|this| this.at_handle(x)) {
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                    this.drag.set(None);
                    this.change(5000, true);
                }
            }
        });
        this.widget.add_controller(click.clone());
        click.group_with(&drag);
        let weak = Rc::downgrade(&this);
        this.widget.connect_move_handle(move |_, direction| {
            let Some(this) = weak.upgrade() else {
                return false;
            };
            let delta = match direction {
                gtk::ScrollType::StepBackward
                | gtk::ScrollType::StepUp
                | gtk::ScrollType::PageUp
                | gtk::ScrollType::StepLeft
                | gtk::ScrollType::PageBackward
                | gtk::ScrollType::PageLeft => -500.,
                gtk::ScrollType::StepForward
                | gtk::ScrollType::StepDown
                | gtk::ScrollType::PageDown
                | gtk::ScrollType::StepRight
                | gtk::ScrollType::PageForward
                | gtk::ScrollType::PageRight => 500.,
                gtk::ScrollType::Start => {
                    this.change(0, true);
                    return true;
                }
                gtk::ScrollType::End => {
                    this.change(10000, true);
                    return true;
                }
                _ => return false,
            };
            let current = ratio_at(this.widget.width(), f64::from(this.widget.position()));
            this.change((f64::from(current) + delta).clamp(0., 10000.) as u16, true);
            true
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if key == gtk::gdk::Key::Home
                && !modifiers.intersects(
                    gtk::gdk::ModifierType::CONTROL_MASK
                        | gtk::gdk::ModifierType::ALT_MASK
                        | gtk::gdk::ModifierType::SHIFT_MASK
                        | gtk::gdk::ModifierType::SUPER_MASK,
                )
            {
                if let Some(this) = weak.upgrade().filter(|this| this.widget.has_focus()) {
                    this.change(5000, true);
                    return glib::Propagation::Stop;
                }
            }
            glib::Propagation::Proceed
        });
        this.widget.add_controller(keys);
        this
    }
    pub fn writer(&self, persist: impl Fn(u16) + 'static) {
        *self.persist.borrow_mut() = Some(Box::new(persist));
    }
    fn at_handle(&self, x: f64) -> bool {
        (x - f64::from(self.widget.position())).abs() <= 4.5
    }
    fn drag_to(&self, offset: f64) {
        if let Some(start) = self.drag.get() {
            self.change(ratio_at(self.widget.width(), start + offset), false);
        }
    }
    fn change(&self, ratio: u16, save: bool) {
        if RATIO.with(Cell::get) != ratio {
            REVISION.with(|revision| revision.set(revision.get().wrapping_add(1)));
            DIRTY.with(|dirty| dirty.set(true));
            broadcast(ratio);
        }
        if save {
            self.save();
        }
    }
    fn save(&self) {
        if let Some(persist) = self.persist.borrow().as_ref() {
            persist(self.ratio.get());
        }
    }
    fn queue(this: &Rc<Self>) {
        if this.queued.replace(true) {
            return;
        }
        let weak = Rc::downgrade(this);
        glib::idle_add_local_once(move || {
            if let Some(this) = weak.upgrade() {
                this.queued.set(false);
                this.place();
            }
        });
    }
    fn place(&self) {
        let width = self.widget.width();
        if width <= 1 {
            return;
        }
        self.width.set(width);
        let old = self.updating.replace(true);
        self.widget.set_position(leading(width, self.ratio.get()));
        self.updating.set(old);
        let percent = (ratio_at(width, f64::from(self.widget.position())) + 50) / 100;
        let value = format!(
            "{} {percent} %",
            self.lang.text("Linke Spalte", "Left column")
        );
        let hint = self.lang.text(
            "Mit F8 fokussieren. Pfeiltasten ändern die Teilung um fünf Prozentpunkte; Pos1 oder Doppelklick setzt sie zurück.",
            "Focus with F8. Arrow keys change the split by five percentage points; Home or double-click resets it.",
        );
        self.widget.update_property(&[
            gtk::accessible::Property::ValueText(&value),
            gtk::accessible::Property::Description(hint),
        ]);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ratios_preserve_both_panes_and_adjust_from_the_visible_edge() {
        assert_eq!(leading(1101, 5000), 550);
        assert_eq!(leading(1101, 0), 96);
        assert_eq!(leading(1101, 10000), 1004);
        assert_eq!(leading(101, 10000), 50);
        assert_eq!(ratio_at(1101, 550.), 5000);
        let visible = ratio_at(1101, f64::from(leading(1101, 0)));
        assert!(leading(1101, visible + 500) > 96);
    }
}
