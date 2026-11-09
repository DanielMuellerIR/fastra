use super::*;
pub(super) fn rect(
    view: &sourceview5::View,
    buffer: &sourceview5::Buffer,
    range: &Range<i32>,
) -> gtk::graphene::Rect {
    let at = buffer.iter_at_offset(range.start);
    let location = view.iter_location(&at);
    let (x, y) =
        view.buffer_to_window_coords(gtk::TextWindowType::Widget, location.x(), location.y());
    gtk::graphene::Rect::new(
        x as f32 + 3.,
        y as f32 + 1.,
        24.,
        (location.height() - 2).clamp(12, 28) as f32,
    )
}
pub(super) fn snapshot(f: &Folds, pane: usize, view: &sourceview5::View, snapshot: &gtk::Snapshot) {
    let color = view.color();
    let left =
        sourceview5::prelude::ViewExt::gutter(view, gtk::TextWindowType::Left).width() as f32;
    snapshot.push_clip(&gtk::graphene::Rect::new(
        left,
        0.,
        (view.width() as f32 - left).max(0.),
        view.height() as f32,
    ));
    for range in f.outer_ranges(pane) {
        let area = rect(view, &f.buffers[pane], &range);
        if area.y() + area.height() < 0. || area.y() > view.height() as f32 {
            continue;
        }
        let cr = snapshot.append_cairo(&area);
        cr.set_source_rgba(
            color.red() as f64,
            color.green() as f64,
            color.blue() as f64,
            0.14,
        );
        cr.rectangle(
            area.x() as f64,
            area.y() as f64,
            area.width() as f64,
            area.height() as f64,
        );
        let _ = cr.fill();
        cr.set_source_rgba(
            color.red() as f64,
            color.green() as f64,
            color.blue() as f64,
            0.8,
        );
        for offset in [7., 12., 17.] {
            cr.arc(
                area.x() as f64 + offset,
                area.y() as f64 + area.height() as f64 / 2.,
                1.,
                0.,
                std::f64::consts::TAU,
            );
            let _ = cr.fill();
        }
    }
    snapshot.pop();
}
pub(super) fn install(f: &Rc<Folds>, pane: usize, view: &sourceview5::View) {
    // Die SourceView besitzt eigene Mausgesten. Der Platzhalter fängt die echten
    // Button-Events vorher ab, damit deren Auswahlgeste keinen Doppelklick übernimmt.
    let input = gtk::EventControllerLegacy::new();
    input.set_propagation_phase(gtk::PropagationPhase::Capture);
    let previous = Cell::new(None::<(u32, i32, f64, f64)>);
    let claimed = Cell::new(false);
    let weak = Rc::downgrade(f);
    let target = view.downgrade();
    input.connect_event(move |_, event| {
        if event.event_type() == gtk::gdk::EventType::ButtonRelease && claimed.replace(false) {
            return glib::Propagation::Stop;
        }
        if event.event_type() != gtk::gdk::EventType::ButtonPress
            || event
                .downcast_ref::<gtk::gdk::ButtonEvent>()
                .is_none_or(|e| e.button() != 1)
        {
            return glib::Propagation::Proceed;
        }
        let (Some(f), Some(view)) = (weak.upgrade(), target.upgrade()) else {
            return glib::Propagation::Proceed;
        };
        let Some(native) = view.native() else {
            return glib::Propagation::Proceed;
        };
        if native.surface() != event.surface() {
            return glib::Propagation::Proceed;
        }
        let Some((x, y)) = event.position() else {
            return glib::Propagation::Proceed;
        };
        let (dx, dy) = native.surface_transform();
        let Some(point) = native
            .dynamic_cast::<gtk::Widget>()
            .ok()
            .and_then(|widget| {
                widget.compute_point(
                    &view,
                    &gtk::graphene::Point::new((x + dx) as f32, (y + dy) as f32),
                )
            })
        else {
            return glib::Propagation::Proceed;
        };
        let Some(range) = f
            .outer_ranges(pane)
            .into_iter()
            .find(|r| rect(&view, &f.buffers[pane], r).contains_point(&point))
        else {
            previous.set(None);
            return glib::Propagation::Proceed;
        };
        let settings = view.settings();
        let maximum = settings.property::<i32>("gtk-double-click-time").max(0) as u32;
        let distance = settings.property::<i32>("gtk-double-click-distance").max(0) as f64;
        let double = previous.get().is_some_and(|(time, start, px, py)| {
            start == range.start
                && event.time().wrapping_sub(time) <= maximum
                && (x - px).abs() <= distance
                && (y - py).abs() <= distance
        });
        claimed.set(true);
        if double {
            previous.set(None);
            f.closed[pane]
                .borrow_mut()
                .retain(|closed| closed.range() != range);
            f.tag_dirty[pane].set(true);
            f.render();
            f.buffers[pane].select_range(
                &f.buffers[pane].iter_at_offset(range.end),
                &f.buffers[pane].iter_at_offset(range.start),
            );
        } else {
            previous.set(Some((event.time(), range.start, x, y)));
            f.buffers[pane].place_cursor(&f.buffers[pane].iter_at_offset(range.start));
        }
        view.grab_focus();
        glib::Propagation::Stop
    });
    view.add_controller(input);
}
