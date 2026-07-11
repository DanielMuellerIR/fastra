#!/bin/bash
#
# screenshot-run.sh — erzeugt die vier README-Screenshots in screenshots/.
#
# Ablauf (ein GUI-Block, danach ist der Bildschirm sofort wieder frei):
#   1. Editor Light  (Hauptfenster, Erststart-Demo-Inhalt)
#   2. Editor Dark   (gleiches Fenster, App-Einstellung „Dunkel")
#   3. Suchdialog Sternchen-Modus, Light  (-selftest wildcardshot)
#   4. Suchdialog RegEx-Modus, Dark       (-selftest regexshot)
#
# Fenstergezielt via `screencapture -l <WindowID>` (Editor ist CodeEditTextView,
# keine WebView — Window-Capture ist hier zuverlässig). Die App wird nach jedem
# Schritt sofort versteckt bzw. beendet sich selbst (Shot-Selbsttests: ~12 s).
set -euo pipefail
cd "$(dirname "$0")"

APP=".build/debug/Fastra.app"
BIN="$APP/Contents/MacOS/Fastra"
OUT="../screenshots"
DOMAIN="de.dm0.fastra"
mkdir -p "$OUT"

# WindowID des größten sichtbaren Fastra-Fensters ermitteln (ohne Accessibility).
winid() {
  osascript -l JavaScript -e '
    ObjC.import("CoreGraphics");
    const l = $.CFBridgingRelease($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)).js;
    let best = 0, area = 0;
    for (const w of l) {
      const o = w.js["kCGWindowOwnerName"];
      if (o && o.js === "Fastra") {
        const b = w.js["kCGWindowBounds"].js;
        const a = b["Width"].js * b["Height"].js;
        if (a > area) { area = a; best = w.js["kCGWindowNumber"].js; }
      }
    }
    best.toString();'
}

hide_app() {
  osascript -e 'tell application "System Events" to set visible of (first process whose name is "Fastra") to false' || true
}

editor_shot() {  # $1 = appearance (light|dark), $2 = Zieldatei
  defaults write "$DOMAIN" app.appearance "$1"
  open -F "$APP"
  sleep 4                      # Start + Demo-Inhalt + Fenster-Restore
  local id; id=$(winid)
  [ "$id" != "0" ] || { echo "FEHLER: kein Fastra-Fenster gefunden"; exit 1; }
  screencapture -l"$id" -o -x "$OUT/$2"
  hide_app
  osascript -e 'tell application "Fastra" to quit' || pkill -x Fastra || true
  sleep 1
}

dialog_shot() {  # $1 = appearance, $2 = selftest-Name, $3 = stderr-Marker, $4 = Zieldatei
  defaults write "$DOMAIN" app.appearance "$1"
  local log; log=$(mktemp)
  "$BIN" -selftest "$2" -ApplePersistenceIgnoreState YES 2>"$log" &
  local pid=$!
  local id=""
  for _ in $(seq 1 60); do
    id=$(grep -m1 "$3" "$log" | awk '{print $2}' || true)
    [ -n "$id" ] && break
    sleep 0.25
  done
  [ -n "$id" ] || { echo "FEHLER: $3 nicht gefunden"; cat "$log"; kill "$pid" 2>/dev/null; exit 1; }
  sleep 1                      # Pillen/Vorschau fertig gerendert
  screencapture -l"$id" -o -x "$OUT/$4"
  wait "$pid" || true          # Selbsttest beendet sich nach ~12 s selbst
}

editor_shot light editor-light.png
editor_shot dark  editor-dark.png
dialog_shot light wildcardshot WILDCARDSHOT-WINDOW search-wildcards.png
dialog_shot dark  regexshot    REGEXSHOT-WINDOW    search-regex.png

defaults write "$DOMAIN" app.appearance system   # aufräumen
echo "✔ 4 Screenshots in $OUT/"
