use super::*;
use gtk::subclass::prelude::*;
use sourceview5::subclass::prelude::*;
mod imp {
    use super::*;
    #[derive(Default)]
    pub struct Renderer {
        pub(super) owner: RefCell<Weak<Folds>>,
        pub pane: Cell<usize>,
        pub numbers: Cell<bool>,
        pub native: RefCell<Option<sourceview5::GutterRendererText>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Renderer {
        const NAME: &'static str = "FastraFoldGutter";
        type Type = super::Renderer;
        type ParentType = sourceview5::GutterRenderer;
    }
    impl ObjectImpl for Renderer {}
    impl WidgetImpl for Renderer {
        fn measure(&self, orientation: gtk::Orientation, _size: i32) -> (i32, i32, i32, i32) {
            let width = if orientation != gtk::Orientation::Horizontal {
                0
            } else if self.numbers.get() {
                let digits = self.owner.borrow().upgrade().map_or(2, |f| {
                    f.buffers[self.pane.get()]
                        .line_count()
                        .to_string()
                        .len()
                        .max(2)
                });
                self.native.borrow().as_ref().map_or(30, |native| {
                    native
                        .create_pango_layout(Some(&"9".repeat(digits)))
                        .pixel_size()
                        .0
                        + 12
                })
            } else {
                18
            };
            (width, width, -1, -1)
        }
    }
    impl GutterRendererImpl for Renderer {
        fn query_activatable(&self, iter: &gtk::TextIter, area: &gtk::gdk::Rectangle) -> bool {
            if self.numbers.get() {
                self.native
                    .borrow()
                    .as_ref()
                    .is_some_and(|native| native.query_activatable(iter, area))
            } else {
                self.owner
                    .borrow()
                    .upgrade()
                    .is_some_and(|f| f.at_line(iter.line()).is_some())
            }
        }
        fn activate(
            &self,
            iter: &gtk::TextIter,
            area: &gtk::gdk::Rectangle,
            button: u32,
            modifiers: gtk::gdk::ModifierType,
            presses: i32,
        ) {
            if self.numbers.get() {
                if let Some(native) = self.native.borrow().as_ref() {
                    sourceview5::prelude::GutterRendererExt::activate(
                        native, iter, area, button, modifiers, presses,
                    );
                }
                return;
            }
            if button != 1 {
                return;
            }
            if let Some(f) = self.owner.borrow().upgrade() {
                let pane = self.pane.get();
                if let Some(view) = f.views[pane].upgrade() {
                    view.grab_focus();
                }
                if let Some(region) = f.at_line(iter.line()) {
                    f.toggle(
                        pane,
                        &region,
                        modifiers.contains(gtk::gdk::ModifierType::ALT_MASK),
                    );
                }
            }
        }
        fn snapshot_line(
            &self,
            snapshot: &gtk::Snapshot,
            lines: &sourceview5::GutterLines,
            line: u32,
        ) {
            let Some(f) = self.owner.borrow().upgrade() else {
                return;
            };
            let pane = self.pane.get();
            let iter = lines.iter_at_line(line);
            if iter.has_tag(&f.tags[pane]) {
                return;
            }
            let widget = self.obj();
            if self.numbers.get() {
                let native = self.native.borrow();
                let Some(native) = native.as_ref() else {
                    return;
                };
                let text = (line + 1).to_string();
                let layout = native.create_pango_layout(Some(&text));
                let current = f.buffers[pane]
                    .iter_at_offset(f.buffers[pane].cursor_position())
                    .line()
                    == line as i32;
                let style = f.buffers[pane].style_scheme().and_then(|scheme| {
                    scheme.style(if current {
                        "current-line-number"
                    } else {
                        "line-numbers"
                    })
                });
                if let Some(style) = style.as_ref().filter(|s| s.is_bold_set() && s.is_bold()) {
                    let attrs = gtk::pango::AttrList::new();
                    attrs.insert(gtk::pango::AttrInt::new_weight(if style.is_weight_set() {
                        style.weight()
                    } else {
                        gtk::pango::Weight::Bold
                    }));
                    layout.set_attributes(Some(&attrs));
                }
                let (w, h) = layout.pixel_size();
                let (x, y) = widget.align_cell(line, w as f32, h as f32);
                let color = style
                    .as_ref()
                    .and_then(|s| s.foreground())
                    .and_then(|text| gtk::gdk::RGBA::parse(text.as_str()).ok())
                    .unwrap_or_else(|| native.color());
                snapshot.save();
                snapshot.translate(&gtk::graphene::Point::new(x, y));
                snapshot.append_layout(&layout, &color);
                snapshot.restore();
            } else if let Some(region) = f.at_line(line as i32) {
                let (x, y) = widget.align_cell(line, 12., 14.);
                let cr = snapshot.append_cairo(&gtk::graphene::Rect::new(x, y, 12., 14.));
                let color = f.views[pane]
                    .upgrade()
                    .map_or_else(|| widget.color(), |view| view.color());
                cr.set_source_rgba(
                    color.red() as f64,
                    color.green() as f64,
                    color.blue() as f64,
                    0.65,
                );
                cr.set_line_width(1.3);
                cr.set_line_cap(gtk::cairo::LineCap::Round);
                cr.set_line_join(gtk::cairo::LineJoin::Round);
                if f.is_closed(pane, &region) {
                    cr.move_to(x as f64 + 4., y as f64 + 3.);
                    cr.line_to(x as f64 + 8., y as f64 + 7.);
                    cr.line_to(x as f64 + 4., y as f64 + 11.);
                } else {
                    cr.move_to(x as f64 + 2., y as f64 + 5.);
                    cr.line_to(x as f64 + 6., y as f64 + 9.);
                    cr.line_to(x as f64 + 10., y as f64 + 5.);
                }
                let _ = cr.stroke();
            }
        }
    }
}
glib::wrapper! {pub struct Renderer(ObjectSubclass<imp::Renderer>) @extends sourceview5::GutterRenderer,gtk::Widget,@implements gtk::Accessible,gtk::Buildable,gtk::ConstraintTarget;}
pub(super) struct Decorations {
    native: sourceview5::GutterRendererText,
    numbers: Renderer,
    arrows: Renderer,
}
impl Decorations {
    pub(super) fn sync(&self, f: &Folds, pane: usize, allowed: bool) {
        let Some(view) = f.views[pane].upgrade() else {
            return;
        };
        let folded = !f.closed[pane].borrow().is_empty();
        let numbers = view.shows_line_numbers();
        self.native.set_visible(numbers && !folded);
        self.numbers.set_visible(numbers && folded);
        self.arrows
            .set_visible(allowed && (!f.regions.borrow().is_empty() || folded));
        self.numbers.queue_resize();
        self.numbers.queue_draw();
        self.arrows.queue_draw();
    }
}
pub(super) fn install(f: &Rc<Folds>, pane: usize, view: &sourceview5::View) -> Decorations {
    let gutter = sourceview5::prelude::ViewExt::gutter(view, gtk::TextWindowType::Left);
    let mut child = gutter.first_child();
    let mut native = None;
    while let Some(widget) = child {
        child = widget.next_sibling();
        if let Ok(text) = widget.downcast::<sourceview5::GutterRendererText>() {
            native = Some(text);
            break;
        }
    }
    let native = native.expect("GtkSourceView line-number renderer");
    let make = |numbers: bool| {
        let renderer: Renderer = glib::Object::new();
        *renderer.imp().owner.borrow_mut() = Rc::downgrade(f);
        renderer.imp().pane.set(pane);
        renderer.imp().numbers.set(numbers);
        *renderer.imp().native.borrow_mut() = Some(native.clone());
        renderer.set_alignment_mode(sourceview5::GutterRendererAlignmentMode::First);
        renderer.set_xalign(if numbers { 1.0 } else { 0.5 });
        renderer.set_yalign(0.5);
        renderer.set_visible(false);
        renderer
    };
    let numbers = make(true);
    numbers.set_widget_name(&format!("fastra-fold-numbers-{pane}"));
    let arrows = make(false);
    arrows.set_widget_name(&format!("fastra-fold-arrows-{pane}"));
    if let Some(ui) = f.ui.upgrade() {
        arrows.set_tooltip_text(Some(ui.lang.text(
            "Bereich ein-/ausklappen. Alt schließt oder öffnet auch die Kinder.",
            "Toggle code region. Alt also collapses or expands its children.",
        )));
    }
    assert!(gutter.insert(&numbers, -29));
    assert!(gutter.insert(&arrows, -10));
    Decorations {
        native,
        numbers,
        arrows,
    }
}
