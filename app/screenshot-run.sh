#!/bin/bash
#
# screenshot-run.sh — erzeugt die deutschen und englischen README-Screenshots.
#
# Ablauf (ein GUI-Block, danach ist der Bildschirm sofort wieder frei):
#   1. Deutsche Light-Mode-Aufnahmen
#   2. Englische Light-Mode-Aufnahmen mit der Endung .en.png
#
# Optional lassen sich Sprache und Umfang begrenzen:
#   ./screenshot-run.sh de|en [all|search]
# `search` erneuert ausschließlich Wildcard- und RegEx-Suchmasken.
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
LANGUAGE="${1:-all}"
SHOT_SET="${2:-all}"
mkdir -p "$OUT"

case "$LANGUAGE" in
  all|de|en) ;;
  *)
    echo "Verwendung: $0 [all|de|en]" >&2
    exit 1
    ;;
esac

case "$SHOT_SET" in
  all|search) ;;
  *)
    echo "Verwendung: $0 [all|de|en] [all|search]" >&2
    exit 1
    ;;
esac

# Nur unsere markierte Desktop-Fixture aufräumen. Ein gleichnamiger fremder
# Ordner ohne Marker bleibt unberührt und lässt den Lauf scheitern.
cleanup_fixture() {
  if [ -f "$PROJECT_FIXTURE/.fastra-screenshot-fixture" ]; then
    rm -rf -- "$PROJECT_FIXTURE"
  fi
}

cleanup() {
  cleanup_fixture
  defaults write "$DOMAIN" app.appearance system
}
trap cleanup EXIT

selftest_shot() {  # $1 = Sprache, $2 = Locale, $3 = Selbsttest, $4 = Marker, $5 = Zieldatei
  defaults write "$DOMAIN" app.appearance light
  local log; log=$(mktemp)
  if [ "$3" = "projectshot" ]; then
    [ ! -e "$PROJECT_FIXTURE" ] || {
      echo "FEHLER: $PROJECT_FIXTURE existiert bereits und bleibt unberührt" >&2
      exit 1
    }
    mkdir "$PROJECT_FIXTURE"
    printf '%s\n' "README-Screenshot-Fixture" > "$PROJECT_FIXTURE/.fastra-screenshot-fixture"
    FASTRA_SCREENSHOT_LANGUAGE="$1" TMPDIR="$PROJECT_FIXTURE/" \
      "$BIN" -selftest "$3" -AppleLanguages "($1)" -AppleLocale "$2" \
        -ApplePersistenceIgnoreState YES 2>"$log" &
  else
    FASTRA_SCREENSHOT_LANGUAGE="$1" \
      "$BIN" -selftest "$3" -AppleLanguages "($1)" -AppleLocale "$2" \
        -ApplePersistenceIgnoreState YES 2>"$log" &
  fi
  local pid=$!
  local id=""
  for _ in $(seq 1 60); do
    id=$(grep -m1 "$4" "$log" | awk '{print $2}' || true)
    [ -n "$id" ] && break
    sleep 0.25
  done
  [ -n "$id" ] || { echo "FEHLER: $4 nicht gefunden"; cat "$log"; kill "$pid" 2>/dev/null; exit 1; }
  sleep 1                      # Pillen/Vorschau fertig gerendert
  screencapture -l"$id" -o -x "$OUT/$5"
  wait "$pid" || true          # Selbsttest beendet sich nach ~12 s selbst
  rm -f -- "$log"
  [ "$3" != "projectshot" ] || cleanup_fixture
}

generate_language() {  # $1 = Sprache, $2 = Locale, $3 = optionale Dateiendung
  if [ "$SHOT_SET" = "all" ]; then
    selftest_shot "$1" "$2" projectshot PROJECTSHOT-WINDOW "editor-light$3.png"
  fi
  selftest_shot "$1" "$2" wildcardshot WILDCARDSHOT-WINDOW "search-wildcards$3.png"
  selftest_shot "$1" "$2" regexshot    REGEXSHOT-WINDOW    "search-regex$3.png"
}

if [ "$LANGUAGE" = "all" ] || [ "$LANGUAGE" = "de" ]; then
  generate_language de de_DE ""
fi
if [ "$LANGUAGE" = "all" ] || [ "$LANGUAGE" = "en" ]; then
  generate_language en en_US ".en"
fi

echo "✔ README-Screenshots ($LANGUAGE, $SHOT_SET) in $OUT/"
