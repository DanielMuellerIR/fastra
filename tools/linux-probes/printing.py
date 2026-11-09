#!/usr/bin/env python3
"""Gemeinsame Druckvorgaben mit nativen Controls und frischem Prozess prüfen."""
import fcntl
import json
import os
from pathlib import Path
import sys
import subprocess
sys.dont_write_bytecode = True
import startup as ui

MODE = os.environ.get("FASTRA_PRINT_PREFERENCES_SELFTEST", "normal")
PREF = Path(ui.ENV["XDG_CONFIG_HOME"]) / "fastra-editor" / "printing.json"
DEFAULT = {"line_numbers": True, "header_footer": True, "syntax_colors": True, "font_size": 10}

def preference():
    return ui.state()["printing"]

def saved(expected):
    return preference()["values"] == expected and not preference()["busy"] and not preference()["error"] and json.loads(PREF.read_text()) == {"version": 1, "values": expected}

def native(xid):
    return next(window for window in ui.state()["native"] if window["xid"] == xid)

def widget(xid, name):
    return next(control for control in native(xid)["widgets"] if control["name"] == name)

def size(dialog, up, count):
    # Der Pfeil gehört zum beobachteten Regler; keine absoluten Bildschirmkoordinaten.
    spin = ui.wait(lambda: widget(dialog, "print-font-size"), "print size stepper")
    if not 35 < spin["y"] < native(dialog)["height"] - 35:
        ui.reveal(name="print-font-size", xid=dialog)
    window = native(dialog); spin = widget(dialog, "print-font-size")
    button = next(control for control in window["widgets"] if control["kind"] == "button" and ("up" if up else "down") in control["classes"]
                  and abs(control["x"] - spin["x"]) <= spin["width"] / 2 and abs(control["y"] - spin["y"]) <= spin["height"] / 2)
    ui.xdo("windowraise", dialog, "windowfocus", "--sync", dialog, "mousemove", "--window", dialog,
           round(button["x"] + window["surfaceX"]), round(button["y"] + window["surfaceY"]), "click", "--repeat", count, "--delay", 45, 1)

def scenario():
    PREF.parent.mkdir(mode=0o700, exist_ok=True)
    if MODE == "corrupt":
        PREF.write_text("invalid printing fixture"); PREF.chmod(0o600)
    source = ui.ROOT / "printing.rs"
    content = b'\xef\xbb\xbf// unchanged source\r\nfn main() { let name = "PRINT-COLOR"; }\r\n'
    source.write_bytes(content)
    ui.start(); ui.remote(source)
    current = ui.wait(lambda: ui.ready(1) if any(list(os.fsencode(source)) in ui.paths(window) for window in ui.state()["windows"]) else None, "source loaded")
    xid = current["windows"][0]["xid"]
    baseline = current["windows"][0]["documents"][-1].copy()
    dialog = ui.settings(xid)
    ui.wait(lambda: widget(dialog, "print-line-numbers"), "allocated print controls")
    scale = 1 + int(ui.ENV.get("FASTRA_INITIAL_ZOOM", "0")) * .13
    def appearance_width():
        controls = [control for control in native(dialog)["widgets"] if control["name"] in {"fastra-appearance-system", "fastra-appearance-light", "fastra-appearance-dark"}]
        if len(controls) != 3: return False
        width = max(control["x"] + control["width"] / 2 for control in controls) - min(control["x"] - control["width"] / 2 for control in controls) + 4
        return abs(width - round(340 * scale)) <= 2 and max(control["width"] for control in controls) - min(control["width"] for control in controls) <= 1
    ui.wait(appearance_width, "Mac appearance width and equal segments")
    ui.capture(dialog, "printing-settings-default")
    if MODE == "corrupt":
        ui.wait(lambda: preference()["error"] and not preference()["busy"], "corrupt preference retained")
        assert not preference()["loaded"] and not widget(dialog, "print-line-numbers")["sensitive"]
        assert PREF.read_text() == "invalid printing fixture"
        ui.reveal(name="print-preferences-retry", xid=dialog)
        ui.capture(dialog, "printing-corrupt")
        PREF.write_text(json.dumps({"version": 1, "values": DEFAULT}))
        ui.click(name="print-preferences-retry", xid=dialog)
        ui.wait(lambda: preference()["loaded"] and not preference()["error"] and not preference()["busy"], "native Retry reloads repaired fixture")
    else:
        ui.wait(lambda: preference()["loaded"] and not preference()["busy"], "print preference ready")
    assert preference()["values"] == DEFAULT
    expected = DEFAULT.copy()
    if MODE == "busy":
        lock = PREF.with_name(".lock").open("a+b")
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            old = PREF.read_bytes() if PREF.exists() else None
            ui.click(name="print-line-numbers", xid=dialog)
            ui.wait(lambda: preference()["error"] and not preference()["busy"], "locked write surfaces error")
            assert (PREF.read_bytes() if PREF.exists() else None) == old
            ui.reveal(name="print-preferences-retry", xid=dialog)
            ui.capture(dialog, "printing-busy")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN); lock.close()
        expected["line_numbers"] = False
        ui.click(name="print-preferences-retry", xid=dialog)
        ui.wait(lambda: saved(expected), "native Retry saves retained choice")
    else:
        for name, field in [("print-line-numbers", "line_numbers"), ("print-header-footer", "header_footer"), ("print-syntax-colors", "syntax_colors")]:
            ui.click(name=name, xid=dialog); expected[field] = False
            ui.wait(lambda: saved(expected), "persist " + field)
        size(dialog, True, 24); expected["font_size"] = 18
        ui.wait(lambda: saved(expected), "font size clamps to 18 pt")
        ui.capture(dialog, "printing-18pt")
        size(dialog, False, 24); expected["font_size"] = 6
        ui.wait(lambda: saved(expected), "font size clamps to 6 pt")
        scale = 1 + int(ui.ENV.get("FASTRA_INITIAL_ZOOM", "0")) * .13
        for width, height in [(round(480 * scale), round(380 * scale)), (max(1000, round(480 * scale)), max(760, round(380 * scale)))]:
            window = native(dialog)
            ui.xdo("windowsize", dialog, width + round(2 * window["surfaceX"]), height + round(2 * window["surfaceY"]))
            try:
                ui.wait(lambda: abs(native(dialog)["width"] - width) <= 2 and abs(native(dialog)["height"] - height) <= 2, "settings size")
            except AssertionError:
                current = native(dialog)
                print("SETTINGS_SIZE", json.dumps({key: current[key] for key in ["width", "height", "surfaceX", "surfaceY", "minimumWidth"]}), "requested", width, height, "layouts", json.dumps([control for control in current["widgets"] if control["kind"] == "layout"]), flush=True)
                ui.capture(dialog, "printing-size-diagnostic")
                raise
            ui.reveal(name="print-font-size", xid=dialog)
            ui.capture(dialog, "printing-settings-" + str(width))
    ui.key(dialog, "ctrl+w")
    ui.quit_all(xid)
    ui.start(); ui.remote(source)
    restored = ui.wait(lambda: ui.ready(1) if any(list(os.fsencode(source)) in ui.paths(window) for window in ui.state()["windows"]) else None, "fresh source")
    ui.wait(lambda: preference()["loaded"] and not preference()["busy"], "fresh print preferences")
    assert preference()["values"] == expected
    xid = restored["windows"][0]["xid"]
    if MODE == "normal":
        ui.key(xid, "ctrl+p")
        print_dialog = ui.wait(lambda: next((window for window in ui.state()["native"] if any(control["kind"] == "print-tab" for control in window["widgets"])), None), "native print dialog")
        ui.click(label="Fastra", xid=print_dialog["xid"])
        for label, field in [(ui.L("Zeilennummern drucken", "Print line numbers"), "line_numbers"), (ui.L("Kopf- und Fußzeile drucken", "Print header and footer"), "header_footer"), (ui.L("Syntaxfarben drucken", "Print syntax colors"), "syntax_colors")]:
            ui.click(label=label, xid=print_dialog["xid"]); expected[field] = True
            ui.wait(lambda: saved(expected), "print tab persists " + field)
        ui.capture(print_dialog["xid"], "printing-native-tab")
        cancel = ui.wait(lambda: next((control["label"].replace("_", "") for control in native(print_dialog["xid"])["widgets"] if control["kind"] == "button" and (control["label"] or "").replace("_", "") in {"Abbrechen", "Cancel"}), None), "native Cancel button")
        ui.click(label=cancel, xid=print_dialog["xid"])
        ui.wait(lambda: all(window["xid"] != print_dialog["xid"] for window in ui.state()["native"]), "native print Cancel")
        dialog = ui.settings(xid)
        def selected():
            choices = {control["name"]: control for control in native(dialog)["widgets"]}
            return all(choices.get(name, {}).get("active") for name in ["print-line-numbers", "print-header-footer", "print-syntax-colors"])
        ui.wait(selected, "shared Settings choices after print Cancel")
        ui.key(dialog, "ctrl+w")
    assert source.read_bytes() == content
    doc = ui.state()["windows"][0]["documents"][-1]
    assert doc["text"] == baseline["text"] and not doc["dirty"] and doc["revision"] == baseline["revision"]
    ui.quit_all(xid)
    print("FASTRA_PRINT_PREFERENCES_OK", MODE, "native choices, shared atomic store/retry, fresh process, original source/undo basis retained", flush=True)

try:
    scenario()
finally:
    if ui.process is not None and ui.process.poll() is None:
        ui.process.terminate()
        try: ui.process.wait(5)
        except subprocess.TimeoutExpired: ui.process.kill(); ui.process.wait(5)
