#!/usr/bin/env python3
"""X11-HiDPI-Positionen und Migration über zwei echte Prozessstarts prüfen.

Im vorhandenen isolierten Xvfb-/Openbox-Kontext mit GDK_SCALE=2,
1920x1536 physischen Pixeln und den Startup-Probe-Umgebungsvariablen starten.
FASTRA_SCALE_LEGACY=1 prüft ein altes physisches Positionspaar.
"""
import json
import os
import startup as probe


def scenario():
    assert probe.ENV.get("GDK_SCALE") == "2"
    file = probe.ROOT / "fixture.txt"
    file.write_text("Scale 2 saved window\n")
    position = {"x": 50, "y": 60, "logical": True}
    if probe.ENV.get("FASTRA_SCALE_LEGACY") == "1":
        position = {"x": 100, "y": 120}
    record = {"project": None, "documents": [list(os.fsencode(file))],
              "active": list(os.fsencode(file)), "width": 900, "height": 600,
              "maximized": False, "position": position}
    probe.STATE.parent.mkdir(parents=True, exist_ok=True)
    probe.STATE.parent.chmod(0o700)
    probe.STATE.write_text(json.dumps({"version": 1, "restore": True, "windows": [record]}))
    probe.STATE.chmod(0o600)
    for roundtrip in range(2):
        probe.start()
        probe.remote()
        probe.wait(lambda: probe.ready(1), "scale 2 restored window")
        probe.wait(lambda: abs(probe.state()["windows"][0]["position"]["x"] - 50) <= 1, "restored x settles")
        actual = probe.state()["windows"][0]
        geometry = dict(line.split("=", 1) for line in probe.xdo("getwindowgeometry", "--shell", actual["xid"]).splitlines())
        assert abs(int(geometry["X"]) - 100) <= 2, geometry
        assert abs(actual["width"] - 900) <= 2, actual
        assert abs(actual["height"] - 600) <= 2, actual
        assert actual["position"] == {"x": 50, "y": 60, "logical": True}, actual
        probe.capture(actual["xid"], "scale2-" + str(roundtrip))
        probe.quit_all(actual["xid"])
        saved = json.loads(probe.STATE.read_bytes())["windows"][0]
        assert saved["position"] == {"x": 50, "y": 60, "logical": True}, saved
    print("FASTRA_STARTUP_SCALE2_OK legacy=" + probe.ENV.get("FASTRA_SCALE_LEGACY", "0") + " native x=100 width=1800; saved logical x=50 width=900; two process roundtrips")


if __name__ == "__main__":
    try:
        scenario()
    finally:
        if probe.process is not None and probe.process.poll() is None:
            probe.process.terminate()
            try:
                probe.process.wait(5)
            except probe.subprocess.TimeoutExpired:
                probe.process.kill()
                probe.process.wait(5)
