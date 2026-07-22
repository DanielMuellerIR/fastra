#!/bin/bash
#
# screenshot-run.sh — erzeugt die drei README-Screenshots in screenshots/.
#
# Ablauf (ein GUI-Block, danach ist der Bildschirm sofort wieder frei):
#   1. Editor Light  (kontrolliertes Desktop-Projekt, -selftest projectshot)
#   2. Suchdialog Sternchen-Modus, Light  (-selftest wildcardshot)
#   3. Suchdialog RegEx-Modus, Light       (-selftest regexshot)
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
PROJECT_FIXTURE="$HOME/Desktop/Fastra-Screenshot"
mkdir -p "$OUT"

# Nur unsere markierte Desktop-Fixture aufräumen. Ein gleichnamiger fremder
# Ordner ohne Marker bleibt unberührt und lässt den Lauf scheitern.
cleanup() {
  if [ -f "$PROJECT_FIXTURE/.fastra-screenshot-fixture" ]; then
    rm -rf -- "$PROJECT_FIXTURE"
  fi
  defaults write "$DOMAIN" app.appearance system
}
trap cleanup EXIT

selftest_shot() {  # $1 = appearance, $2 = selftest-Name, $3 = stderr-Marker, $4 = Zieldatei
  defaults write "$DOMAIN" app.appearance "$1"
  local log; log=$(mktemp)
  if [ "$2" = "projectshot" ]; then
    [ ! -e "$PROJECT_FIXTURE" ] || {
      echo "FEHLER: $PROJECT_FIXTURE existiert bereits und bleibt unberührt" >&2
      exit 1
    }
    mkdir "$PROJECT_FIXTURE"
    printf '%s\n' "README-Screenshot-Fixture" > "$PROJECT_FIXTURE/.fastra-screenshot-fixture"
    TMPDIR="$PROJECT_FIXTURE/" \
      "$BIN" -selftest "$2" -ApplePersistenceIgnoreState YES 2>"$log" &
  else
    "$BIN" -selftest "$2" -ApplePersistenceIgnoreState YES 2>"$log" &
  fi
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

selftest_shot light projectshot  PROJECTSHOT-WINDOW  editor-light.png
selftest_shot light wildcardshot WILDCARDSHOT-WINDOW search-wildcards.png
selftest_shot light regexshot    REGEXSHOT-WINDOW    search-regex.png

echo "✔ 3 Screenshots in $OUT/"
