#!/usr/bin/env python3
"""F01: öffentliche GTK-Erweiterung, ohne gepatchten Editor oder eigenes Layout."""
import ctypes
import json
from pathlib import Path
import sys
import time

import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
gi.require_version('GtkSource', '5')
gi.require_version('GdkX11', '4.0')
from gi.repository import Gdk, GdkX11, GLib, GObject, Gtk, GtkSource


def line_start(buffer, line):
    return buffer.get_iter_at_line(line)[-1]


class Rectangle:
    def __init__(self, view):
        self.view = view
        self.buffer = view.get_buffer()
        self.bounds = None
        self.dragging = False
        self.tag = self.buffer.create_tag(None, background='#b6d5ff')
        self.gesture = Gtk.GestureDrag(button=1)
        self.gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        self.gesture.connect('drag-begin', self.begin)
        self.gesture.connect('drag-update', self.update)
        self.gesture.connect('drag-end', self.end)
        view.add_controller(self.gesture)
        self.buffer.connect('insert-text', self.insert)
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect('key-pressed', self.key)
        view.add_controller(keys)

    def position(self, x, y):
        bx, by = self.view.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, int(x), int(y))
        _, at = self.view.get_iter_at_location(bx, by)
        start = line_start(self.buffer, at.get_line())
        column = 0
        while start.get_offset() < at.get_offset():
            column += self.view.get_tab_width() - column % self.view.get_tab_width() if start.get_char() == '\t' else 1
            if not start.forward_cursor_position():
                break
        rect = self.view.get_iter_location(at)
        if at.ends_line() and bx > rect.x:
            width = max(self.view.create_pango_layout(' ').get_pixel_size().width, 1)
            column += int((bx - rect.x) / width)
        return at.get_line(), column

    def begin(self, gesture, x, y):
        self.dragging = False
        if not gesture.get_current_event_state() & Gdk.ModifierType.ALT_MASK:
            self.clear()
            return
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)
        self.dragging = True
        self.origin = (x, y)
        self.anchor = self.position(x, y)
        self.select(self.anchor, self.anchor)

    def update(self, gesture, dx, dy):
        if self.dragging:
            self.select(self.anchor, self.position(self.origin[0] + dx, self.origin[1] + dy))

    def end(self, gesture, dx, dy):
        self.update(gesture, dx, dy)
        self.dragging = False

    def offset(self, line, column, trailing=False):
        at = line_start(self.buffer, line)
        current = 0
        while not at.ends_line() and current < column:
            next_column = current + (self.view.get_tab_width() - current % self.view.get_tab_width() if at.get_char() == '\t' else 1)
            if next_column > column and not trailing:
                break
            if not at.forward_cursor_position():
                break
            current = next_column
        return at, current

    def clear(self):
        self.bounds = None
        self.buffer.remove_tag(self.tag, *self.buffer.get_bounds())

    def select(self, anchor, head):
        self.clear()
        self.bounds = (min(anchor[0], head[0]), max(anchor[0], head[0]),
                       min(anchor[1], head[1]), max(anchor[1], head[1]))
        for line, start, end, column in self.rows():
            self.buffer.apply_tag(self.tag, start, end)

    def rows(self):
        if self.bounds is None:
            return []
        first, last, left, right = self.bounds
        return [(line, self.offset(line, left)[0], self.offset(line, right, True)[0],
                 self.offset(line, left)[1]) for line in range(first, last + 1)]

    def replace(self, value, pad=False):
        rows = [(start.get_offset(), end.get_offset(), column)
                for line, start, end, column in self.rows()]
        if not rows:
            return
        left = self.bounds[2]
        self.clear()
        self.buffer.begin_user_action()
        try:
            # Absteigende Offsets halten die noch nicht bearbeiteten Zeilen stabil.
            for a, b, column in reversed(rows):
                self.buffer.delete(self.buffer.get_iter_at_offset(a), self.buffer.get_iter_at_offset(b))
                self.buffer.insert(self.buffer.get_iter_at_offset(a), (' ' * max(left - column, 0) if pad else '') + value)
        finally:
            self.buffer.end_user_action()
        self.clear()

    def insert(self, buffer, location, value, length):
        if self.bounds and self.view.has_focus():
            GObject.signal_stop_emission_by_name(buffer, 'insert-text')
            self.replace(value)
            location.assign(buffer.get_iter_at_mark(buffer.get_insert()))

    def key(self, controller, key, code, state):
        if key == Gdk.KEY_Escape:
            self.clear()
        if self.bounds and key in (Gdk.KEY_BackSpace, Gdk.KEY_Delete):
            self.replace('')
            return True
        return False


def run(output):
    Gtk.init()
    GtkSource.init()
    buffer = GtkSource.Buffer()
    buffer.set_enable_undo(True)
    buffer.set_language(GtkSource.LanguageManager.get_default().get_language('python'))
    views = [GtkSource.View(buffer=buffer), GtkSource.View(buffer=buffer)]
    for view in views:
        view.set_monospace(True)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        view.set_tab_width(4)
        view.set_show_line_numbers(True)
        view.set_left_margin(8)
        view.set_top_margin(8)
    rectangle = Rectangle(views[0])
    fold_tag = buffer.create_tag(None, invisible=True)
    folded = False

    def fold(button):
        nonlocal folded
        start, end = line_start(buffer, 1), line_start(buffer, 3)
        if folded:
            buffer.remove_tag(fold_tag, start, end)
        else:
            buffer.apply_tag(fold_tag, start, end)
        folded = not folded
        button.set_label('Unfold' if folded else 'Fold lines 2–3')

    def paste_column(button):
        views[0].get_clipboard().read_text_async(None, pasted)

    def pasted(clipboard, result):
        value = clipboard.read_text_finish(result)
        if value is not None:
            rectangle.replace(value, pad=True)

    toolbar = Gtk.Box(spacing=12)
    toolbar.set_margin_start(12)
    toolbar.set_margin_end(12)
    toolbar.set_margin_top(12)
    toolbar.set_margin_bottom(12)
    fold_button = Gtk.Button(label='Fold lines 2–3')
    fold_button.connect('clicked', fold)
    toolbar.append(fold_button)
    paste_button = Gtk.Button(label='Paste column')
    paste_button.connect('clicked', paste_column)
    toolbar.append(paste_button)
    capture = Gtk.Label(label='Drag capture $1')
    capture.set_can_target(True)
    source = Gtk.DragSource(actions=Gdk.DragAction.COPY)
    drag_events = []
    def prepare_capture(*args):
        drag_events.append('prepare')
        return Gdk.ContentProvider.new_for_value('$1')
    source.connect('prepare', prepare_capture)
    source.connect('drag-begin', lambda *args: drag_events.append('begin'))
    source.connect('drag-end', lambda *args: drag_events.append('end'))
    capture.add_controller(source)
    toolbar.append(capture)
    replacement = Gtk.Entry(placeholder_text='Replacement')
    replacement.set_hexpand(True)
    target = Gtk.DropTarget.new(str, Gdk.DragAction.COPY)
    target.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
    target.connect('enter', lambda *args: (drag_events.append('enter'), Gdk.DragAction.COPY)[1])
    target.connect('motion', lambda *args: (drag_events.append('motion'), Gdk.DragAction.COPY)[1])

    def dropped(target, value, x, y):
        drag_events.append('drop')
        at = replacement.get_position()
        replacement.insert_text(value, at)
        replacement.set_position(at + len(value))
        return True
    target.connect('drop', dropped)
    replacement.add_controller(target)
    toolbar.append(replacement)
    panes = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
    panes.set_position(470)
    for side, view in zip(('start', 'end'), views):
        scroll = Gtk.ScrolledWindow()
        scroll.set_child(view)
        getattr(panes, 'set_' + side + '_child')(scroll)
    panes.set_vexpand(True)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    box.append(toolbar)
    box.append(panes)
    window = Gtk.Window(title='Fastra F01 — public editor extension', default_width=1000, default_height=600)
    window.set_child(box)
    window.present()

    baseline = '# Logical rectangle with soft wrap\n' + '0123456789' * 12 + '\nx\n\te\u0301😀z\nlast\r\n'
    buffer.set_text(baseline)
    checks = []

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    def text():
        return buffer.get_text(*buffer.get_bounds(), True)

    # XTest liefert echte Eingabe an die isolierte X11-Anzeige, keine Callback-Aufrufe.
    xlib = ctypes.CDLL('libX11.so.6')
    xtst = ctypes.CDLL('libXtst.so.6')
    xlib.XOpenDisplay.restype = ctypes.c_void_p
    display = xlib.XOpenDisplay(None)
    xlib.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    xlib.XFlush.argtypes = [ctypes.c_void_p]
    xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]

    def key(symbol, down):
        xtst.XTestFakeKeyEvent(display, xlib.XKeysymToKeycode(display, symbol), int(down), 0)
        xlib.XFlush(display)

    def point(widget, x, y):
        from gi.repository import Graphene
        ok, location = widget.compute_point(window, Graphene.Point().init(x, y))
        assert ok
        return int(location.x), int(location.y)

    def move(p):
        xtst.XTestFakeMotionEvent(display, -1, *p, 0)
        xlib.XFlush(display)

    def button(down):
        xtst.XTestFakeButtonEvent(display, 1, int(down), 0)
        xlib.XFlush(display)

    def center(widget):
        return point(widget, widget.get_width() / 2, widget.get_height() / 2)

    def click(widget):
        move(center(widget)); button(True); button(False)

    def char_point(line, column):
        at, _ = rectangle.offset(line, column)
        rect = views[0].get_iter_location(at)
        x, y = views[0].buffer_to_window_coords(Gtk.TextWindowType.WIDGET, rect.x + 1, rect.y + rect.height // 2)
        return point(views[0], x, y)

    loop = GLib.MainLoop()
    failure = []
    steps = []

    def step():
        try:
            if not steps:
                loop.quit()
                return False
            steps.pop(0)()
        except BaseException as error:
            failure.append(repr(error))
            loop.quit()
            return False
        return True

    def rectangle_started():
        check('real Alt-drag creates logical rectangle', rectangle.bounds == (1, 3, 4, 6))
        check('wrapped line selected once', len(rectangle.rows()) == 3)
        key(Gdk.KEY_Q, True); key(Gdk.KEY_Q, False)

    def typed():
        expected = baseline.replace('0123456789' * 12, '0123q6789' + '0123456789' * 11).replace('\nx\n', '\nxq\n').replace('\te\u0301😀z', '\tqz')
        check('real key replaces graphemes on all logical rows: ' + repr(text()), text() == expected)
        check('split view shares edited buffer', views[1].get_buffer() == buffer)
        key(Gdk.KEY_Control_L, True); key(Gdk.KEY_z, True); key(Gdk.KEY_z, False); key(Gdk.KEY_Control_L, False)

    def undone():
        check('real Ctrl-Z undoes entire rectangle once', text() == baseline)
        rectangle.select((1, 4), (3, 4))
        views[0].get_clipboard().set('P')
        click(paste_button)

    def pasted_check():
        check('column paste pads short logical row', '\nx   P\n' in text())
        buffer.undo()
        check('column paste has one undo', text() == baseline)
        click(fold_button)

    def folded_check():
        check('mouse fold keeps underlying document bytes', folded and text() == baseline)
        check('fold tag actually hides text', line_start(buffer, 1).has_tag(fold_tag))
        click(fold_button)

    def unfolded_check():
        check('mouse unfolds original content', not folded and not line_start(buffer, 1).has_tag(fold_tag))
        move(center(capture)); button(True)

    def drag_capture():
        move(center(replacement))

    def dropped_check():
        buffer.ensure_highlight(*buffer.get_bounds())
        check('syntax still active', 'comment' in buffer.get_context_classes_at_iter(buffer.get_start_iter()))
        paintable = Gtk.WidgetPaintable.new(window)
        snapshot = Gtk.Snapshot.new()
        paintable.snapshot(snapshot, window.get_width(), window.get_height())
        node = snapshot.to_node()
        texture = window.get_renderer().render_texture(node, None)
        texture.save_to_png(str(output / 'editor-extension.png'))
        check('real capture drag reaches replacement: ' + repr((replacement.get_text(), drag_events)), replacement.get_text() == '$1')

    steps.extend([
        lambda: (views[0].grab_focus(), move(char_point(1, 4)), key(Gdk.KEY_Alt_L, True), button(True)),
        lambda: move(char_point(3, 6)),
        lambda: (button(False), key(Gdk.KEY_Alt_L, False)),
        rectangle_started, typed, undone, pasted_check, folded_check, unfolded_check,
        lambda: move((center(capture)[0] + 25, center(capture)[1])),
        drag_capture, lambda: move((center(replacement)[0] + 10, center(replacement)[1])),
        lambda: button(False), dropped_check,
    ])
    GLib.timeout_add(250, step)
    loop.run()
    xlib.XCloseDisplay(display)
    window.destroy()
    result = dict(passed=checks, failures=failure, publicAPIsOnly=True,
                  notAccepted=['native Wayland/Cinnamon', 'physical German keyboard/IME',
                               'view-local folding', 'production editor', 'fractional accessibility'])
    (output / 'editor-extension.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    if failure:
        raise SystemExit(1)


if __name__ == '__main__':
    run(Path(sys.argv[1]))
