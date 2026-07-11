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

# WindowID des größten sichtbaren Fastra-Fensters ermitteln (ohne Accessibility;
# Swift-Schnipsel — JXA/ObjC-Bridge lieferte hier keine Fensterliste).
winid() {
  local tmp; tmp=$(mktemp -t winid).swift
  cat > "$tmp" <<'SW'
import CoreGraphics
import Foundation
guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best = (id: 0, area: 0.0)
for w in l where (w[kCGWindowOwnerName as String] as? String ?? "") == "Fastra" {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let a = (b["Width"] as? Double ?? 0) * (b["Height"] as? Double ?? 0)
    if a > best.area { best = (w[kCGWindowNumber as String] as? Int ?? 0, a) }
}
print(best.id)
SW
  xcrun swift "$tmp"
  rm -f "$tmp"
}

hide_app() {
  osascript -e 'tell application "System Events" to set visible of (first process whose name is "Fastra") to false' || true
}

# Demo-Datei für die Editor-Shots: echtes Swift mit Keywords/Strings/Kommentaren,
# damit das Syntax-Highlighting sichtbar ist. Fester lesbarer Name (Fenstertitel!).
DEMO_FILE="$TMPDIR/StarCatalog.swift"
write_demo_file() {
  cat > "$DEMO_FILE" <<'SWIFT'
import Foundation

/// Ein kleiner Sternkatalog — Demo-Datei für Fastra.
/// Suchen & Ersetzen mit `*` funktioniert auch hier:
/// Suchen `*, the` — Ersetzen `the *`.
enum SpectralClass: String, CaseIterable {
    case o, b, a, f, g, k, m

    /// Ungefähre Oberflächentemperatur in Kelvin (Klassenmitte).
    var temperature: Int {
        switch self {
        case .o: return 40_000
        case .b: return 20_000
        case .a: return 8_750
        case .f: return 6_750
        case .g: return 5_600   // unsere Sonne: G2V
        case .k: return 4_450
        case .m: return 3_050
        }
    }
}

struct Star {
    let name: String
    let `class`: SpectralClass
    let lightYears: Double
}

let catalog: [Star] = [
    Star(name: "Sirius",     class: .a, lightYears: 8.6),
    Star(name: "Wega",       class: .a, lightYears: 25.0),
    Star(name: "Arktur",     class: .k, lightYears: 36.7),
    Star(name: "Beteigeuze", class: .m, lightYears: 548.0),
    Star(name: "Prokyon",    class: .f, lightYears: 11.5),
]

/// Facillime ad astra: der kürzeste Weg zu den Sternen ist eine gute Suche.
func nearestStar(in stars: [Star]) -> Star? {
    stars.min { $0.lightYears < $1.lightYears }
}

if let nearest = nearestStar(in: catalog) {
    print("Nächster Stern im Katalog: \(nearest.name) — \(nearest.lightYears) Lj")
}
SWIFT
}

editor_shot() {  # $1 = appearance (light|dark), $2 = Zieldatei
  defaults write "$DOMAIN" app.appearance "$1"
  write_demo_file
  open -a "$(cd "$APP" && pwd)" "$DEMO_FILE"
  sleep 4                      # Start + Datei laden + Fenster-Restore
  local id; id=$(winid)
  [ -n "$id" ] && [ "$id" != "0" ] || { echo "FEHLER: kein Fastra-Fenster gefunden"; exit 1; }
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
