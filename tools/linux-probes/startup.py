#!/usr/bin/env python3
"""Native Pfadwiederherstellung mit echter Quit-Freigabe und frischem Prozess."""
import json
import base64
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import time

assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
APP = sys.argv[1]
ROOT = Path(os.environ["FASTRA_UI_TEST_ROOT"])
OBSERVE = ROOT / "startup-observation"
OBSERVE.mkdir()
ENV = os.environ.copy()
ENV["FASTRA_LIFECYCLE_SELFTEST_DIR"] = str(OBSERVE)
STATE = Path(ENV["XDG_CONFIG_HOME"]) / "fastra-editor" / "startup.json"
DE = ENV.get("LANGUAGE", "").startswith("de")
L = lambda de, en: de if DE else en
process = None
MODE = ENV.get("FASTRA_STARTUP_SELFTEST", "normal")


def state():
    return json.loads((OBSERVE / "state.json").read_text())


def wait(check, label, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (FileNotFoundError, json.JSONDecodeError, KeyError, StopIteration):
            pass
        time.sleep(.05)
    raise AssertionError("Timeout " + label + "\n" + json.dumps({"startup":state()["startup"],"windows":state()["windows"],"nativeTitles":[window["title"] for window in state()["native"]]}, ensure_ascii=False)[-16000:])


def xdo(*arguments):
    result = subprocess.run(["xdotool", *map(str, arguments)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def key(xid, *keys):
    xdo("windowraise", xid, "windowfocus", "--sync", xid, "key", "--clearmodifiers", *keys)


def reveal(label=None, kind=None, name=None, xid=None, css=None):
    def find():
        return next(((window, control) for window in state()["native"] if xid is None or window["xid"] == xid
                     for control in window["widgets"] if control["sensitive"]
                     and (label is None or (control["label"] or "").replace("_", "") == label)
                     and (kind is None or control["kind"] == kind)
                     and (name is None or control["name"] == name)
                     and (css is None or css in control["classes"])), None)
    def visible():
        item = find()
        if item is None: return None
        window, control = item
        if 0 < control["y"] < window["height"] and 0 < control["x"] < window["width"]: return item
        xdo("windowraise", window["xid"], "windowfocus", "--sync", window["xid"], "mousemove", "--window", window["xid"], window["width"] // 2, window["height"] // 2, "click", "--repeat", 3, "--delay", 40, 5 if control["y"] >= window["height"] else 4)
        return None
    return wait(visible, "native control " + str((label, kind, name, xid, css)))


def click(label=None, kind=None, name=None, xid=None, css=None):
    window, control = reveal(label, kind, name, xid, css)
    xdo("windowraise", window["xid"], "windowfocus", "--sync", window["xid"],
        "mousemove", "--window", window["xid"], round(control["x"] + window["surfaceX"]), round(control["y"] + window["surfaceY"]), "click", 1)
    return window["xid"]


def remote(*paths):
    result = subprocess.run([APP, *map(os.fspath, paths)], env=ENV, timeout=12)
    assert result.returncode == 0


def start(allow_error=False):
    global process
    for name in ["state.json", "shutdown.json"]:
        (OBSERVE / name).unlink(missing_ok=True)
    process = subprocess.Popen([APP, "--local-control-service"], env=ENV)
    wait(lambda: (state()["startup"]["loaded"] or allow_error and state()["startup"]["error"]) and not state()["windows"], "headless startup")
    return process


def paths(window):
    return [doc["pathBytes"] for doc in window["documents"] if doc["pathBytes"] is not None]


def ready(n):
    current = state()
    return current if len(current["windows"]) == n and not current["startup"]["restoring"] else None


def select(xid, path):
    def find():
        return next(doc for window in state()["windows"] if window["xid"] == xid for doc in window["documents"] if doc["pathBytes"] == list(os.fsencode(path)))
    doc = wait(find, "file tab")
    point = doc["tab"]
    native = next(window for window in state()["native"] if window["xid"] == xid)
    xdo("windowraise", xid, "windowfocus", "--sync", xid, "mousemove", "--window", xid, round(point["x"] + native["surfaceX"]), round(point["y"] + native["surfaceY"]), "click", 1)
    wait(lambda: find()["active"], "active file tab")


def type_source(xid, text):
    click(kind="source", xid=xid)
    key(xid, "ctrl+End")
    xdo("type", "--clearmodifiers", "--delay", 2, text)
    wait(lambda: any(text in doc["text"] for window in state()["windows"] if window["xid"] == xid for doc in window["documents"]), "typed source")


def quit_all(xid):
    key(xid, "ctrl+shift+q")
    deadline = time.monotonic() + 20
    while process.poll() is None and time.monotonic() < deadline:
        discard = [(window, control) for window in state()["native"] for control in window["widgets"]
                   if control["sensitive"] and (control["label"] or "").replace("_", "") == L("Ohne Speichern schließen", "Close without saving")]
        if discard:
            old = click(label=L("Ohne Speichern schließen", "Close without saving"))
            wait(lambda: process.poll() is not None or all(window["xid"] != old for window in state()["native"]), "discard dialog closes")
        time.sleep(.05)
    assert process.wait(3) == 0
    assert json.loads((OBSERVE / "shutdown.json").read_text()) == {"registryEmpty": True, "holdReleased": True}


def capture(xid, name):
    target = Path(ENV["FASTRA_TOOL_SCREENSHOTS"]) / ("startup-" + name + ".png")
    assert subprocess.run(["import", "-silent", "-window", str(xid), str(target)], timeout=10).returncode == 0


def settings(xid):
    key(xid, "ctrl+comma")
    return wait(lambda: next((window for window in state()["native"] if window["title"] == L("Einstellungen", "Settings")), None), "Settings window")["xid"]


def wait_error_dialog():
    return wait(lambda: next((window for window in state()["native"] if any((control["label"] or "").replace("_", "") == L("Ohne Aktualisierung beenden", "Quit without updating") for control in window["widgets"])), None), "capture error dialog")


def choose_path(picker, path):
    xid = picker["xid"]
    key(xid, "ctrl+l")
    def entry():
        return next((control for window in state()["native"] if window["xid"] == xid for control in window["widgets"] if control["kind"] == "entry" and "FileChooser" in control["name"]), None)
    wait(entry, "mapped location entry")
    key(xid, "ctrl+a")
    wait(lambda: entry() and (not entry()["text"] or entry()["selection"] == [0, len(entry()["text"])]), "entire location selected")
    key(xid, "BackSpace")
    wait(lambda: entry() and entry()["text"] == "", "location cleared")
    # Ein Einfügevorgang vermeidet Autovervollständigung zwischen einzelnen Tasten.
    owner = subprocess.Popen([sys.executable, "-c", """
import ctypes, os, sys
from pathlib import Path
gtk = ctypes.CDLL("libgtk-4.so.1")
glib = ctypes.CDLL("libglib-2.0.so.0")
gtk.gtk_init()
gtk.gdk_display_get_default.restype = ctypes.c_void_p
gtk.gdk_display_get_clipboard.argtypes = [ctypes.c_void_p]
gtk.gdk_display_get_clipboard.restype = ctypes.c_void_p
gtk.gdk_clipboard_set_text.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
gtk.gdk_clipboard_set_text(gtk.gdk_display_get_clipboard(gtk.gdk_display_get_default()), os.fsencode(sys.argv[1]))
Path(sys.argv[2]).touch()
glib.g_main_context_iteration.argtypes = [ctypes.c_void_p, ctypes.c_int]
while True: glib.g_main_context_iteration(None, True)
""", str(path), str(OBSERVE / "clipboard-ready")], env=ENV)
    try:
        wait(lambda: (OBSERVE / "clipboard-ready").exists(), "native clipboard owner")
        key(xid, "ctrl+v")
        wait(lambda: entry() and entry()["text"].rstrip("/") == str(path).rstrip("/"), "pasted location")
    finally:
        owner.terminate(); owner.wait(3)
        (OBSERVE / "clipboard-ready").unlink(missing_ok=True)
    try:
        wait(lambda: entry() and entry()["text"].rstrip("/") == str(path).rstrip("/"), "native location text")
    except AssertionError:
        print("LOCATION_ENTRY", json.dumps(entry(), ensure_ascii=False), flush=True)
        capture(xid, "chooser-location-diagnostic")
        raise
    accept = wait(lambda: next((control["label"] for window in state()["native"] if window["xid"] == xid for control in window["widgets"] if control["sensitive"] and (control["label"] or "").replace("_", "") in {"Auswählen", "Select", "Öffnen", "Open"}), None), "native chooser accept")
    key(xid, "Return")
    try:
        wait(lambda: all(window["xid"] != xid for window in state()["native"]), "chooser accepted")
    except AssertionError:
        capture(xid, "chooser-accept-diagnostic")
        print("CHOOSER", json.dumps(next(window for window in state()["native"] if window["xid"] == xid), ensure_ascii=False), flush=True)
        raise


def stop_service():
    assert not state()["windows"]
    (OBSERVE / "quit").touch()
    assert process.wait(5) == 0
    (OBSERVE / "quit").unlink()


def scenario():
    project = ROOT / "saved-project"
    project.mkdir()
    a = ROOT / "a.txt"
    b = ROOT / os.fsdecode(b"raw-\xff.txt")
    c = ROOT / "readonly.txt"
    alias = ROOT / "hardlink.txt"
    a.write_bytes(b"Alpha\r\n")
    b.write_bytes(b"\xef\xbb\xbfRaw BOM\r\n")
    c.write_text("Read-only original\n")
    os.link(c, alias)
    assets = []
    if MODE == "mixed":
        binary = ROOT / "binary.dat"; binary.write_bytes(b"\x00\xff\x10")
        image = ROOT / "pixel.png"; image.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        assets = [binary, image]
    start()
    assert state()["startup"]["restore"] is True, "missing preference defaults to restore"
    remote(a, b, *assets)
    first = wait(lambda: next((w for w in state()["windows"] if len(paths(w)) == 2 + len(assets)), None), "file tabs loaded")
    remote(project, c)
    second = wait(lambda: next((w for w in state()["windows"] if list(os.fsencode(c)) in paths(w) and w["project"] == list(os.fsencode(project))), None), "project and readonly file")
    assert next(doc for doc in second["documents"] if doc["pathBytes"]) ["readOnly"]
    remote(project)
    wait(lambda: ready(3), "project-only window")
    select(first["xid"], a)
    type_source(first["xid"], "UNSAVED_PRIVATE_A")
    key(first["xid"], "ctrl+t")
    wait(lambda: any(doc["active"] and doc["pathBytes"] is None for window in state()["windows"] if window["xid"] == first["xid"] for doc in window["documents"]), "new scratch tab")
    xdo("type", "--clearmodifiers", "--delay", 2, "UNTITLED_PRIVATE_CONTENT")
    wait(lambda: any(doc["text"] == "UNTITLED_PRIVATE_CONTENT" for window in state()["windows"] if window["xid"] == first["xid"] for doc in window["documents"]), "typed scratch")
    select(first["xid"], b)
    xdo("windowsize", second["xid"], 980, 740)
    xdo("windowmove", first["xid"], 200, 120)
    xdo("windowmove", second["xid"], 420, 230)
    if MODE == "maximized":
        click(css="maximize", xid=second["xid"])
        wait(lambda: any(w["xid"] == second["xid"] and w["maximized"] for w in state()["windows"]), "native maximize")
    time.sleep(.25)
    before = state()
    expected = [w for w in before["windows"] if paths(w)]
    quit_all(first["xid"])
    saved_bytes = STATE.read_bytes()
    assert b"PRIVATE" not in saved_bytes, "startup state must contain paths only"
    saved = json.loads(saved_bytes)
    assert saved["restore"] and len(saved["windows"]) == 2
    for actual, old in zip(saved["windows"], expected):
        assert actual["documents"] == paths(old)
        active = next((doc["pathBytes"] for doc in old["documents"] if doc["active"]), None)
        assert actual["active"] == active
        assert actual["position"] == old["position"] and actual["position"] is not None
    a.write_bytes("Fresh disk α\r\n".encode())
    expected_disk = {os.fspath(path): path.read_bytes() for path in [a, b, c, *assets]}
    if MODE == "missing":
        a.unlink(); b.unlink(); project.rmdir()
        start(); remote()
        current = wait(lambda: ready(1) if any(list(os.fsencode(c)) in paths(w) for w in state()["windows"]) else None, "missing windows/project filtered")
        assert paths(current["windows"][0]) == [list(os.fsencode(c))]
        assert current["windows"][0]["project"] is None
        assert all(doc["pathBytes"] for doc in current["windows"][0]["documents"])
        quit_all(current["windows"][0]["xid"])
        print("FASTRA_STARTUP_OK missing files remove the complete unavailable window; missing project leaves surviving readonly document")
        return
    if MODE == "corrupt":
        broken = b"{unsupported startup fixture"
        STATE.write_bytes(broken)
        start(allow_error=True); remote()
        current = wait(lambda: ready(1), "error welcome")
        assert not paths(current["windows"][0]) and STATE.read_bytes() == broken
        key(current["windows"][0]["xid"], "ctrl+shift+q")
        wait_error_dialog(); assert STATE.read_bytes() == broken
        click(label=L("Abbrechen", "Cancel"))
        wait(lambda: all(not w["closeActive"] for w in state()["windows"]), "corrupt quit cancelled")
        dialog = settings(current["windows"][0]["xid"])
        control = wait(lambda: next((control for window in state()["native"] if window["xid"] == dialog for control in window["widgets"] if control["name"] == "fastra-startup-restore"), None), "disabled corrupt control")
        assert not control["sensitive"] and STATE.read_bytes() == broken
        STATE.write_bytes(saved_bytes)  # Explizite Fixture-Reparatur, keine Produkt-Reparatur.
        click(name="fastra-startup-retry", xid=dialog)
        wait(lambda: state()["startup"]["loaded"] and state()["startup"]["error"] is None, "native load retry")
        assert len(state()["windows"]) == 1 and not paths(state()["windows"][0]), "a retry must not launch a late restore over user state"
        capture(dialog, "corrupt-repaired"); key(dialog, "ctrl+w")
        quit_all(current["windows"][0]["xid"])
        print("FASTRA_STARTUP_OK corrupt state retained, visible failure and cancel-safe Quit, disabled preference, explicit fixture repair/native Retry; no late window restore")
        return
    if MODE in {"open", "interrupt-new", "interrupt-typing", "interrupt-file", "interrupt-home", "interrupt-project", "interrupt-peer"}:
        extra = ROOT / "user-file.txt"; extra.write_text("User choice\n")
        extra_two = ROOT / "second-user-file.txt"; extra_two.write_text("Second user choice\n")
        hold = ROOT / "hold-startup-load"; hold.touch()
        start()
        remote(extra) if MODE == "open" else remote()
        wait(lambda: (ROOT / "startup-worker-ready").exists(), "held startup worker")
        first_now = state()["windows"][0]
        if MODE == "interrupt-peer":
            peer = state()["windows"][1]
            key(peer["xid"], "ctrl+t"); xdo("type", "--clearmodifiers", "--delay", 2, "USER_PEER_SCRATCH")
            wait(lambda: any("USER_PEER_SCRATCH" in d["text"] for w in state()["windows"] if w["xid"] == peer["xid"] for d in w["documents"]), "typing in pending peer")
            assert state()["startup"]["restoring"] and not paths(state()["windows"][1])
            hold.unlink(); current = wait(lambda:ready(2), "pending peer respects user state")
            assert paths(current["windows"][0]) == saved["windows"][0]["documents"]
            assert not paths(current["windows"][1]) and any("USER_PEER_SCRATCH" in d["text"] for d in current["windows"][1]["documents"])
            assert int(xdo("getwindowfocus")) == peer["xid"], "remaining source loads must not take focus from an already used window"
            quit_all(peer["xid"])
            print("FASTRA_STARTUP_OK pending peer generation captured before file loading; user text and actual window focus retained")
            return
        if MODE == "open":
            remote(extra_two)
            wait(lambda: state()["startup"]["queued"] == 2, "cold and in-flight Open queued once")
            assert len(state()["windows"]) == 2
            hold.unlink()
            current = wait(lambda: ready(4) if sum(len(paths(w)) for w in state()["windows"]) == 5 else None, "restore then both Open requests")
            for actual, record in zip(current["windows"], saved["windows"]): assert paths(actual) == record["documents"]
            assert sum(list(os.fsencode(extra)) in paths(w) for w in current["windows"]) == 1
            assert sum(list(os.fsencode(extra_two)) in paths(w) for w in current["windows"]) == 1
        else:
            original_text = None
            if MODE == "interrupt-new":
                key(first_now["xid"], "ctrl+t")
                xdo("type", "--clearmodifiers", "--delay", 2, "USER_NEW_SCRATCH")
                wait(lambda: any(doc["text"] == "USER_NEW_SCRATCH" for window in state()["windows"] if window["xid"] == first_now["xid"] for doc in window["documents"]), "complete native scratch typing")
            elif MODE == "interrupt-typing":
                original_text = next(doc["text"] for doc in first_now["documents"] if doc["pathBytes"])
                type_source(first_now["xid"], "USER_EDIT")
            elif MODE == "interrupt-home":
                click(name="fastra-home", xid=first_now["xid"])
            elif MODE == "interrupt-file":
                key(first_now["xid"], "ctrl+o")
                picker = wait(lambda: next((window for window in state()["native"] if window["xid"] not in [w["xid"] for w in state()["windows"]]), None), "native file chooser")
                choose_path(picker, extra)
            else:
                user_project = ROOT / "user-project"; user_project.mkdir()
                key(first_now["xid"], "ctrl+shift+o")
                picker = wait(lambda: next((window for window in state()["native"] if window["title"] == L("Ordner öffnen", "Open folder")), None), "native project chooser")
                choose_path(picker, user_project)
                wait(lambda: state()["windows"][0]["project"] == list(os.fsencode(user_project)), "user project selected")
            # Die laufende IO muss durch die Nutzeraktion selbst abbrechen;
            # der Test öffnet das Gate erst nach dem abgeschlossenen Restore.
            current = wait(lambda: ready(2), "user action cancels old worker and next window still restores")
            hold.unlink()
            first_after = current["windows"][0]
            if MODE == "interrupt-file":
                wait(lambda: list(os.fsencode(extra)) in paths(state()["windows"][0]), "explicit file survives stale callback")
                assert paths(state()["windows"][0]) == [list(os.fsencode(extra))]
            elif MODE == "interrupt-typing":
                assert len(paths(first_after)) == 1
                assert any("USER_EDIT" in doc["text"] for doc in first_after["documents"])
                for _ in range(8):
                    key(first_after["xid"], "ctrl+z"); time.sleep(.05)
                    if any(doc["text"] == original_text for doc in state()["windows"][0]["documents"]): break
                assert any(doc["text"] == original_text for doc in state()["windows"][0]["documents"]), "native Undo survives interrupted restore"
            else:
                assert not paths(first_after)
                if MODE == "interrupt-new": assert any(doc["text"] == "USER_NEW_SCRATCH" for doc in first_after["documents"])
                if MODE == "interrupt-project": assert first_after["project"] == list(os.fsencode(user_project))
            assert paths(current["windows"][1]) == [list(os.fsencode(c))]
        quit_all(state()["windows"][0]["xid"])
        print("FASTRA_STARTUP_OK native", MODE, "held worker, exact once Open delivery or user-owned state retained, no late source insertion")
        return
    if MODE == "offscreen":
        moved = json.loads(saved_bytes); moved["windows"][0]["position"] = {"x":900000,"y":-800000}
        STATE.write_text(json.dumps(moved)); saved = moved; saved_bytes = STATE.read_bytes()
    start()
    assert STATE.read_bytes() == saved_bytes, "service-only activation preserves saved state and opens no windows"
    remote()
    restored = wait(lambda: ready(2), "two restored windows")
    for actual, record in zip(restored["windows"], saved["windows"]):
        assert paths(actual) == record["documents"]
        assert len(actual["documents"]) == len(record["documents"]), "no leftover scratch tab"
        assert actual["project"] == record["project"]
        assert abs(actual["width"] - record["width"]) <= 2
        assert abs(actual["height"] - record["height"]) <= 2
        assert actual["position"] is not None
        assert actual["maximized"] == record["maximized"]
        if MODE == "offscreen" and record is saved["windows"][0]:
            screen_width, screen_height = map(int, xdo("getdisplaygeometry").split())
            assert abs(actual["position"]["x"] - (screen_width - actual["width"]) // 2) <= 2
            assert abs(actual["position"]["y"] - (screen_height - actual["height"]) // 2) <= 2
        else:
            assert abs(actual["position"]["x"] - record["position"]["x"]) <= 2
            assert abs(actual["position"]["y"] - record["position"]["y"]) <= 2
        assert next(doc["pathBytes"] for doc in actual["documents"] if doc["active"]) == record["active"]
        assert all(not doc["dirty"] and "PRIVATE" not in doc["text"] for doc in actual["documents"])
    restored_a = next(doc for w in restored["windows"] for doc in w["documents"] if doc["pathBytes"] == list(os.fsencode(a)))
    assert restored_a["text"].replace("\r\n", "\n") == "Fresh disk α\n"
    assert next(doc for w in restored["windows"] for doc in w["documents"] if doc["pathBytes"] == list(os.fsencode(c))) ["readOnly"]
    for name, content in expected_disk.items():
        assert Path(name).read_bytes() == content
    if MODE == "mixed":
        assert next(doc for w in restored["windows"] for doc in w["documents"] if doc["pathBytes"] == list(os.fsencode(binary)))["section"]
        assert next(doc for w in restored["windows"] for doc in w["documents"] if doc["pathBytes"] == list(os.fsencode(image)))["visual"]
        select(restored["windows"][0]["xid"], binary); capture(restored["windows"][0]["xid"], "restored-hex")
        select(restored["windows"][0]["xid"], image); capture(restored["windows"][0]["xid"], "restored-image")
    if MODE == "disable":
        dialog = settings(restored["windows"][0]["xid"])
        click(name="fastra-startup-restore", xid=dialog)
        wait(lambda: not state()["startup"]["restore"] and not state()["startup"]["busy"], "native opt-out saved")
        assert json.loads(STATE.read_bytes()) == {"version":1,"restore":False,"windows":[]}
        capture(dialog, "disabled")
        if not ENV.get("FASTRA_INITIAL_ZOOM"):
            for width, height in [(480, 380), (1000, 760)]:
                native = next(window for window in state()["native"] if window["xid"] == dialog)
                xdo("windowsize", dialog, width + round(2 * native["surfaceX"]), height + round(2 * native["surfaceY"]))
                wait(lambda: next((window for window in state()["native"] if window["xid"] == dialog and abs(window["width"] - width) <= 2 and abs(window["height"] - height) <= 2), None), "settings resized")
                for _ in range(16):
                    native = next(window for window in state()["native"] if window["xid"] == dialog)
                    switch = next(control for control in native["widgets"] if control["name"] == "fastra-startup-restore")
                    if 45 < switch["y"] < height - 100: break
                    xdo("mousemove", "--window", dialog, width // 2, height // 2, "click", "--repeat", 2, "--delay", 40, 5 if switch["y"] >= height - 100 else 4)
                    time.sleep(.1)
                assert 0 < switch["x"] < width and 35 < switch["y"] < height - 35
                capture(dialog, "settings-" + str(width))
        key(dialog, "ctrl+w")
        quit_all(restored["windows"][0]["xid"])
        start(); remote(); current=wait(lambda:ready(1),"disabled fresh launch")
        assert not paths(current["windows"][0]) and not state()["startup"]["restore"]
        quit_all(current["windows"][0]["xid"])
        print("FASTRA_STARTUP_OK native opt-out clears saved window state, fresh welcome, no file content changes")
        return
    if MODE == "last-close":
        key(restored["windows"][0]["xid"], "ctrl+q")
        wait(lambda: ready(1), "first window closed")
        remaining = state()["windows"][0]
        key(remaining["xid"], "ctrl+q")
        wait(lambda: not state()["windows"] and len(json.loads(STATE.read_bytes())["windows"]) == 1, "last window close captured")
        expected_paths = paths(remaining)
        assert json.loads(STATE.read_bytes())["windows"][0]["documents"] == expected_paths
        stop_service(); start(); remote(); current=wait(lambda:ready(1),"last window restored")
        assert paths(current["windows"][0]) == expected_paths
        quit_all(current["windows"][0]["xid"])
        print("FASTRA_STARTUP_OK last ordinary close captures only the last window; headless service shutdown preserves it")
        return
    if MODE == "busy":
        lock_file = STATE.with_name(".lock").open("r+")
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for action in ["cancel", "skip"]:
                key(restored["windows"][0]["xid"], "ctrl+shift+q")
                dialog = wait_error_dialog(); capture(dialog["xid"], "capture-busy-" + action)
                assert STATE.read_bytes() == saved_bytes
                if action == "cancel":
                    click(label=L("Abbrechen", "Cancel"))
                    wait(lambda: len(state()["windows"]) == 2 and all(not w["closeActive"] for w in state()["windows"]), "failed capture Cancel retains all windows")
                else:
                    click(label=L("Ohne Aktualisierung beenden", "Quit without updating")); assert process.wait(5) == 0
                    assert STATE.read_bytes() == saved_bytes
            fcntl.flock(lock_file, fcntl.LOCK_UN)
            start(); remote(); restored = wait(lambda:ready(2),"old snapshot retained after explicit skip")
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            key(restored["windows"][0]["xid"], "ctrl+shift+q"); wait_error_dialog()
            fcntl.flock(lock_file, fcntl.LOCK_UN); click(label=L("Erneut versuchen", "Retry"))
            assert process.wait(5) == 0 and len(json.loads(STATE.read_bytes())["windows"]) == 2
        finally:
            lock_file.close()
        print("FASTRA_STARTUP_OK busy capture Cancel preserves all windows/old state; explicit Skip and native Retry complete Quit safely")
        return
    if MODE == "normal":
        first = restored["windows"][0]
        key(first["xid"], "ctrl+End")
        xdo("type", "--clearmodifiers", "--delay", 2, "AFTER_RESTORE_TYPING")
        wait(lambda: any(doc["active"] and "AFTER_RESTORE_TYPING" in doc["text"] for doc in state()["windows"][0]["documents"]), "restored active tab accepts immediate typing")
        assert all(Path(name).read_bytes() == content for name, content in expected_disk.items())
    quit_all(restored["windows"][0]["xid"])
    print("FASTRA_STARTUP_OK headless service, default-on, two windows/project/tab order/active/size, actual Quit/Discard, raw filename/BOM/CRLF/readonly, current disk bytes instead of unsaved text, no untitled/project-only restore")
if __name__ == "__main__":
    try:
        scenario()
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(5)
