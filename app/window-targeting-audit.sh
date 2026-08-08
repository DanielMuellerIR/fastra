#!/usr/bin/env bash
# Fastra — Wächter für die Fenster-Zielwahl
#
# Verhindert die Rückkehr eines Fehlers, der die Anwendung unbenutzbar macht:
# Ein Befehl wirkt im FALSCHEN Fenster. Beobachtet am 2026-08-07 im
# Arbeitsbetrieb — bei zwei offenen Dokumenten formatierte ⌘B im
# Hintergrundfenster, an einer nie angeklickten Stelle.
#
# Die Ursache ist eine Zeile, die harmlos aussieht:
#
#     for window in NSApp.windows where window.isVisible { … }
#
# `NSApp.windows` ist eine UNGEORDNETE Menge aller Fenster — nicht nach
# Vordergrund sortiert. Wer daraus „das erste sichtbare" nimmt, erwischt bei
# mehreren Fenstern ein zufälliges. Nichts am Code sieht falsch aus, und mit
# nur einem offenen Fenster funktioniert alles.
#
# Deshalb ein mechanischer Wächter statt einer Merkregel: Produktcode fragt
# AppKit nicht mehr selbst nach Fenstern, sondern ausschließlich über
# `CommandTargeting`. Dort steht die Begründung ausführlich.
#
# Exit-Codes (maschinenlesbar):
#   0 = keine verbotenen Zugriffe
#   1 = mindestens ein verbotener Zugriff
#   2 = Umgebungsfehler (Quellverzeichnis fehlt)

set -u

cd "$(dirname "$0")"

SOURCE_DIR="Sources/Fastra"
if [ ! -d "$SOURCE_DIR" ]; then
  echo "WINDOW TARGETING AUDIT: Umgebungsfehler — $SOURCE_DIR nicht gefunden." >&2
  exit 2
fi

# Dateien, die AppKit direkt nach Fenstern fragen dürfen:
#   CommandTargeting.swift   — die eine erlaubte Stelle, mit voller Begründung
#   DocumentWindowController.swift — Fenster ERZEUGEN und ordnen; nutzt
#                                    ausschließlich das sortierte
#                                    `orderedWindows`, was der Wächter prüft
#   SelfTest.swift           — Testcode, der Fenster von außen inspiziert
#   SoakTest.swift           — desgleichen, langer Dauertest
#   AppDelegate.swift        — Fenster-Lebenszyklus (Beenden, Aktivierung)
ALLOWED="CommandTargeting.swift DocumentWindowController.swift SelfTest.swift SoakTest.swift AppDelegate.swift"

is_allowed() {
  local base
  base="$(basename "$1")"
  for name in $ALLOWED; do
    [ "$base" = "$name" ] && return 0
  done
  return 1
}

findings=0

# Zeilen mit `NSApp.windows` bzw. `NSApplication.shared.windows`, ohne
# Kommentarzeilen (`///` und `//` am Zeilenanfang) — die erklären den Fehler
# gerade und dürfen ihn benennen.
while IFS=: read -r file line text; do
  [ -z "${file:-}" ] && continue
  is_allowed "$file" && continue
  trimmed="$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
  case "$trimmed" in
    //*) continue ;;
  esac
  if [ "$findings" -eq 0 ]; then
    echo "WINDOW TARGETING AUDIT: FAIL — direkter Fenster-Zugriff außerhalb von CommandTargeting:"
  fi
  findings=$((findings + 1))
  echo "  $file:$line"
  echo "    $trimmed"
done <<EOF
$(grep -rn -E "(NSApp|NSApplication\.shared)\.windows([^A-Za-z0-9_]|$)" "$SOURCE_DIR" 2>/dev/null)
EOF

if [ "$findings" -gt 0 ]; then
  cat >&2 <<'HINT'

  `NSApp.windows` ist NICHT nach Vordergrund sortiert. Ein Befehl, der daraus
  sein Fenster wählt, trifft bei mehreren offenen Dokumenten ein zufälliges.

  Stattdessen verwenden:
    CommandTargeting.target()                 — Fenster + Workspace + Editor,
                                                das der Nutzer gerade bedient
    CommandTargeting.targetEditorTextView()   — nur der Editor
    CommandTargeting.targetWorkspace()        — nur der Workspace
    CommandTargeting.workspace(for: textView) — Workspace zu EINEM Editor
    CommandTargeting.documentWindow(for: ws)  — Fenster eines Workspace

  Braucht eine Datei wirklich den direkten Zugriff, gehört sie mit Begründung
  in die ALLOWED-Liste dieses Skripts — nicht der Zugriff in den Code.
HINT
  exit 1
fi

echo "WINDOW TARGETING AUDIT: PASS — kein direkter Fenster-Zugriff außerhalb von CommandTargeting."
exit 0
