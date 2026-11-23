"""Text für einen echten Einfügevorgang auf der privaten GTK-Testanzeige."""

from contextlib import contextmanager
import ctypes
import os
from pathlib import Path
import subprocess
import sys


@contextmanager
def clipboard_text(text, ready, env):
    assert env.get("FASTRA_ISOLATED_DISPLAY") == "1"
    assert not ready.exists()
    owner = subprocess.Popen([sys.executable, __file__, text, str(ready)], env=env)
    try:
        yield
    finally:
        owner.terminate()
        try:
            owner.wait(3)
        except subprocess.TimeoutExpired:
            owner.kill()
            owner.wait(3)
        ready.unlink(missing_ok=True)


def own_clipboard(text, ready):
    assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
    gtk = ctypes.CDLL("libgtk-4.so.1")
    glib = ctypes.CDLL("libglib-2.0.so.0")
    gtk.gtk_init()
    gtk.gdk_display_get_default.restype = ctypes.c_void_p
    gtk.gdk_display_get_clipboard.argtypes = [ctypes.c_void_p]
    gtk.gdk_display_get_clipboard.restype = ctypes.c_void_p
    gtk.gdk_clipboard_set_text.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    display = gtk.gdk_display_get_default()
    assert display
    gtk.gdk_clipboard_set_text(gtk.gdk_display_get_clipboard(display), os.fsencode(text))
    ready.touch(exist_ok=False)
    glib.g_main_context_iteration.argtypes = [ctypes.c_void_p, ctypes.c_int]
    while True:
        glib.g_main_context_iteration(None, True)


if __name__ == "__main__":
    own_clipboard(sys.argv[1], Path(sys.argv[2]))
