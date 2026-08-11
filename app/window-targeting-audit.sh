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

# Zweite Hälfte derselben Fehlerklasse: Wer sein Ziel aus `Workspace.shared`
# LIEST, verbindet bei mehreren Fenstern womöglich zwei verschiedene Dokumente
# — genau so landete der Alt-Doppelklick-Methodensprung im falschen Fenster
# (Befund aus dem Dauertest, 2026-08-08), obwohl die erste Prüfung oben grün
# war: Sie kennt nur `NSApp.windows`, nicht `Workspace.shared`.
#
# Erlaubt bleiben ZUWEISUNGEN (`Workspace.shared = …`, so wird der Wert ja
# gepflegt) und IDENTITÄTSVERGLEICHE (`=== `/`!== `, „bin ich der aktive?").
# Ein Lesezugriff außerhalb der Liste unten gehört auf
# `CommandTargeting.workspace(for:)` bzw. `CommandTargeting.target()` umgebaut.
#
# Dateien, die `Workspace.shared` mit Begründung lesen dürfen:
#   AppDelegate.swift  — App-Lebenszyklus (Start, Beenden, Aktivierung),
#                        kein Befehl auf ein bestimmtes Fenster
#   SelfTest.swift     — Testcode stellt Zustände von außen her
#   SoakTest.swift     — desgleichen, langer Dauertest
READS_ALLOWED="AppDelegate.swift SelfTest.swift SoakTest.swift"

reads_allowed() {
  local base
  base="$(basename "$1")"
  for name in $READS_ALLOWED; do
    [ "$base" = "$name" ] && return 0
  done
  return 1
}

read_findings=0

while IFS=: read -r file line text; do
  [ -z "${file:-}" ] && continue
  reads_allowed "$file" && continue
  trimmed="$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
  case "$trimmed" in
    //*) continue ;;
  esac
  # Zuweisung an `Workspace.shared` (ein `=` ohne zweites) und
  # Identitätsvergleiche sind erlaubt — gemeldet wird nur das LESEN.
  if printf '%s' "$trimmed" | grep -Eq 'Workspace\.shared[[:space:]]*=([^=]|$)'; then
    continue
  fi
  if printf '%s' "$trimmed" | grep -Eq 'Workspace\.shared[[:space:]]*[!=]=='; then
    continue
  fi
  if [ "$read_findings" -eq 0 ]; then
    echo "WINDOW TARGETING AUDIT: FAIL — Lesezugriff auf Workspace.shared außerhalb von CommandTargeting:"
  fi
  read_findings=$((read_findings + 1))
  findings=$((findings + 1))
  echo "  $file:$line"
  echo "    $trimmed"
done <<EOF
$(grep -rn "Workspace\.shared" "$SOURCE_DIR" 2>/dev/null | grep -v "NSWorkspace\.shared")
EOF

if [ "$findings" -gt 0 ]; then
  cat >&2 <<'HINT'

  `NSApp.windows` ist NICHT nach Vordergrund sortiert. Ein Befehl, der daraus
  sein Fenster wählt, trifft bei mehreren offenen Dokumenten ein zufälliges.
  Und `Workspace.shared` zeigt nicht verlässlich auf das Fenster, das der
  Nutzer gerade bedient (Sitzungswiederherstellung, Event-Monitore VOR dem
  Key-Wechsel) — wer daraus liest und in einen getrennt gefundenen Editor
  schreibt, verbindet zwei verschiedene Fenster.

  Stattdessen verwenden:
    CommandTargeting.target()                 — Fenster + Workspace + Editor,
                                                das der Nutzer gerade bedient
    CommandTargeting.targetDocumentWindow()   — nur das Fenster
    CommandTargeting.targetEditorTextView()   — nur der Editor
    CommandTargeting.workspace(for: textView) — Workspace zu EINEM Editor
    CommandTargeting.documentWindow(for: ws)  — Fenster eines Workspace

  Einen Workspace allein gibt es bewusst nicht: Wer den Workspace des gerade
  bedienten Fensters braucht, nimmt `target()` und verwendet Fenster,
  Workspace und Editor aus DEMSELBEN Zugriff.

  Braucht eine Datei wirklich den direkten Zugriff, gehört sie mit Begründung
  in die ALLOWED- bzw. READS_ALLOWED-Liste dieses Skripts — nicht der
  Zugriff in den Code.
HINT
  exit 1
fi

echo "WINDOW TARGETING AUDIT: PASS — kein direkter Fenster- oder Workspace.shared-Zugriff außerhalb von CommandTargeting."
exit 0
