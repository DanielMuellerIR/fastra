#!/usr/bin/env bash
# Fastra — Wächter für die Fenster-Zielwahl
#
# Produktcode bestimmt Dokumentziele zentral über `CommandTargeting`.
# `NSApp.windows` ist unsortiert und erlaubt keine verlässliche Auswahl
# des vordersten Fensters.
#
# Exit-Codes:
#   0 = keine verbotenen Zugriffe
#   1 = mindestens ein verbotener Zugriff
#   2 = Umgebungsfehler (Quellverzeichnis fehlt oder Suche fehlgeschlagen)

set -u

cd "$(dirname "$0")"

SOURCE_DIR="Sources/Fastra"
if [ ! -d "$SOURCE_DIR" ]; then
  echo "WINDOW TARGETING AUDIT: Umgebungsfehler — $SOURCE_DIR nicht gefunden." >&2
  exit 2
fi

# Dateien, die AppKit direkt nach Fenstern fragen dürfen:
#   CommandTargeting.swift   — die eine erlaubte Stelle, mit voller Begründung
#   DocumentWindowController.swift — Fenster erzeugen und ordnen; nutzt
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

# grep unterscheidet „kein Treffer“ (1) von einem Suchfehler (>1).
# Ein fehlgeschlagener Scan darf niemals einen sauberen Bestand bestätigen.
window_matches="$(grep -rn -E "(NSApp|NSApplication\.shared)\.windows([^A-Za-z0-9_]|$)" "$SOURCE_DIR")"
scan_status=$?
if [ "$scan_status" -gt 1 ]; then
  echo "WINDOW TARGETING AUDIT: Umgebungsfehler — Fenster-Suche fehlgeschlagen (grep: $scan_status)." >&2
  exit 2
fi
# Bezeichnergrenzen schließen NSWorkspace aus, ohne benachbarte echte Leser zu verwerfen.
workspace_matches="$(grep -rn -E "(^|[^[:alnum:]_])Workspace\.shared([^[:alnum:]_]|$)" "$SOURCE_DIR")"
scan_status=$?
if [ "$scan_status" -gt 1 ]; then
  echo "WINDOW TARGETING AUDIT: Umgebungsfehler — Workspace-Suche fehlgeschlagen (grep: $scan_status)." >&2
  exit 2
fi

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
$window_matches
EOF

# Lesen aus `Workspace.shared` kann einen anderen Workspace liefern als
# das separat bestimmte Fenster. Ziel deshalb gemeinsam über
# `CommandTargeting.workspace(for:)` bzw. `CommandTargeting.target()` bestimmen.
# Zuweisungen und Identitätsvergleiche bleiben erlaubt.
#
# Begründete Ausnahmen für Lesezugriffe:
#   AppDelegate.swift — App-Lebenszyklus statt Dokumentbefehl
#   SelfTest.swift    — gezielter Testaufbau
#   SoakTest.swift    — gezielter Dauertestaufbau
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
  # Pro Vorkommen nur direkt folgende Zuweisung/Identität freigeben;
  # weitere Leser derselben Zeile müssen sichtbar bleiben.
  printf '%s\n' "$trimmed" | awk '
    {
      rest = $0
      while (match(rest, /(^|[^[:alnum:]_])Workspace[.]shared([^[:alnum:]_]|$)/)) {
        start = RSTART
        if (substr(rest, start, 1) != "W") start++
        after = substr(rest, start + length("Workspace.shared"))
        if (after !~ /^[[:space:]]*(=([^=]|$)|[!=]==)/) exit 1
        rest = after
      }
    }
  '
  classification_status=$?
  case "$classification_status" in
    0) continue ;;
    1) ;;
    *)
      echo "WINDOW TARGETING AUDIT: Umgebungsfehler — Workspace-Klassifizierung fehlgeschlagen (awk: $classification_status)." >&2
      exit 2 ;;
  esac
  if [ "$read_findings" -eq 0 ]; then
    echo "WINDOW TARGETING AUDIT: FAIL — Lesezugriff auf Workspace.shared außerhalb von CommandTargeting:"
  fi
  read_findings=$((read_findings + 1))
  findings=$((findings + 1))
  echo "  $file:$line"
  echo "    $trimmed"
done <<EOF
$workspace_matches
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
