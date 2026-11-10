use super::*;
use std::ffi::{c_void, CStr};
type Display = *mut c_void;
type Xid = libc::c_ulong;

struct X11 {
    display: Display,
    window: Xid,
    root: Xid,
}
unsafe fn symbol<T: Copy>(name: &CStr) -> Option<T> {
    let address = unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()) };
    if address.is_null() || std::mem::size_of::<T>() != std::mem::size_of_val(&address) {
        return None;
    }
    Some(unsafe { std::mem::transmute_copy(&address) })
}
fn native(window: &gtk::ApplicationWindow) -> Option<X11> {
    let surface = window.surface()?;
    // Die optionalen X11-Funktionen dürfen niemals eine Wayland-Surface erhalten.
    if !surface
        .type_()
        .is_a(glib::Type::from_name("GdkX11Surface")?)
    {
        return None;
    }
    unsafe {
        let xid: unsafe extern "C" fn(*mut c_void) -> Xid = symbol(c"gdk_x11_surface_get_xid")?;
        let display: unsafe extern "C" fn(*mut c_void) -> Display =
            symbol(c"gdk_x11_display_get_xdisplay")?;
        let root: unsafe extern "C" fn(Display) -> Xid = symbol(c"XDefaultRootWindow")?;
        let display = display(surface.display().as_ptr().cast());
        if display.is_null() {
            return None;
        }
        Some(X11 {
            display,
            window: xid(surface.as_ptr().cast()),
            root: root(display),
        })
    }
}
pub(super) fn capture(window: &gtk::ApplicationWindow) -> Option<store::Position> {
    let native = native(window)?;
    unsafe {
        let translate: unsafe extern "C" fn(
            Display,
            Xid,
            Xid,
            libc::c_int,
            libc::c_int,
            *mut libc::c_int,
            *mut libc::c_int,
            *mut Xid,
        ) -> libc::c_int = symbol(c"XTranslateCoordinates")?;
        let (mut x, mut y, mut child) = (0, 0, 0);
        (translate(
            native.display,
            native.window,
            native.root,
            0,
            0,
            &mut x,
            &mut y,
            &mut child,
        ) != 0)
            .then(|| {
                logical_position(
                    store::Position {
                        x,
                        y,
                        logical: false,
                    },
                    window.scale_factor(),
                )
            })
    }
}
#[repr(C)]
struct ClientMessage {
    kind: libc::c_int,
    serial: libc::c_ulong,
    sent: libc::c_int,
    display: Display,
    window: Xid,
    message: Xid,
    format: libc::c_int,
    data: [libc::c_long; 5],
}
#[repr(C)]
union Event {
    message: std::mem::ManuallyDrop<ClientMessage>,
    padding: [libc::c_long; 24],
}
fn move_to(window: &gtk::ApplicationWindow, point: store::Position) {
    let Some(native) = native(window) else { return };
    let scale = window.scale_factor().max(1);
    unsafe {
        let Some(atom): Option<
            unsafe extern "C" fn(Display, *const libc::c_char, libc::c_int) -> Xid,
        > = symbol(c"XInternAtom") else {
            return;
        };
        let Some(send): Option<
            unsafe extern "C" fn(
                Display,
                Xid,
                libc::c_int,
                libc::c_long,
                *mut Event,
            ) -> libc::c_int,
        > = symbol(c"XSendEvent") else {
            return;
        };
        let Some(flush): Option<unsafe extern "C" fn(Display) -> libc::c_int> = symbol(c"XFlush")
        else {
            return;
        };
        // EWMH statt einer Bewegung relativ zum möglicherweise vorhandenen
        // WM-Rahmen: Client-Ursprung, nur x/y, normale Anwendungsanfrage.
        let mut event = Event { padding: [0; 24] };
        event.message = std::mem::ManuallyDrop::new(ClientMessage {
            kind: 33,
            serial: 0,
            sent: 1,
            display: native.display,
            window: native.window,
            message: atom(native.display, c"_NET_MOVERESIZE_WINDOW".as_ptr(), 0),
            format: 32,
            data: [
                10 | (1 << 8) | (1 << 9) | (1 << 12),
                i64::from(point.x).saturating_mul(i64::from(scale)) as libc::c_long,
                i64::from(point.y).saturating_mul(i64::from(scale)) as libc::c_long,
                0,
                0,
            ],
        });
        send(
            native.display,
            native.root,
            0,
            (1 << 19) | (1 << 20),
            &mut event,
        );
        flush(native.display);
    }
}
pub(super) fn restore(window: &gtk::ApplicationWindow, record: &store::Window) {
    let display = gtk::prelude::WidgetExt::display(window);
    let monitors: Vec<_> = (0..display.monitors().n_items())
        .filter_map(|index| {
            display
                .monitors()
                .item(index)
                .and_downcast::<gtk::gdk::Monitor>()
        })
        .map(|monitor| monitor.geometry())
        .collect();
    let point = record
        .position
        .filter(|_| native(window).is_some())
        .map(|point| logical_position(point, window.scale_factor()));
    let intersecting = point.and_then(|point| {
        let rect = gtk::gdk::Rectangle::new(point.x, point.y, record.width, record.height);
        monitors
            .iter()
            .filter_map(|monitor| {
                monitor
                    .intersect(&rect)
                    .map(|area| (monitor, i64::from(area.width()) * i64::from(area.height())))
            })
            .max_by_key(|(_, area)| *area)
            .map(|(monitor, _)| monitor)
    });
    let Some(monitor) = intersecting.or_else(|| monitors.first()) else {
        window.set_default_size(record.width, record.height);
        return;
    };
    let width = record.width.clamp(1, monitor.width().max(1));
    let height = record.height.clamp(1, monitor.height().max(1));
    window.set_default_size(width, height);
    if let Some(point) = point {
        let point = store::Position {
            logical: true,
            x: if intersecting.is_none() {
                monitor.x() + (monitor.width() - width) / 2
            } else {
                point
                    .x
                    .clamp(monitor.x(), monitor.x() + monitor.width() - width)
            },
            y: if intersecting.is_none() {
                monitor.y() + (monitor.height() - height) / 2
            } else {
                point
                    .y
                    .clamp(monitor.y(), monitor.y() + monitor.height() - height)
            },
        };
        if window.is_mapped() {
            move_to(window, point);
        } else {
            let once = Cell::new(false);
            window.connect_map(move |window| {
                if !once.replace(true) {
                    move_to(window, point);
                }
            });
        }
    }
}

fn logical_position(point: store::Position, scale: i32) -> store::Position {
    // Alte Dateien enthalten physische X11-Pixel ohne Kennzeichnung.
    // Erst beim Restore mit dem aktuellen X11-Maßstab umrechnen.
    if point.logical {
        point
    } else {
        let scale = scale.max(1);
        store::Position {
            x: point.x.div_euclid(scale),
            y: point.y.div_euclid(scale),
            logical: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_x11_pixels_and_new_logical_positions_share_one_space() {
        for scale in [1, 2] {
            let old = store::Position {
                x: 100 * scale,
                y: -40 * scale,
                logical: false,
            };
            let point = logical_position(old, scale);
            assert_eq!((point.x, point.y), (100, -40));
            assert_eq!(logical_position(point, scale), point);
        }
        // 900 logische Pixel auf einem 960-Pixel-Monitor lassen x=50 zu.
        let old = store::Position {
            x: 100,
            y: 0,
            logical: false,
        };
        let point = logical_position(old, 2);
        assert_eq!(point.x.clamp(0, 960 - 900) * 2, 100);
    }
}
