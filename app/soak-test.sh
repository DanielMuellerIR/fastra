#!/usr/bin/env bash
# Fastra — langer, realistischer Dauertest
#
# Bewusst NICHT Teil von `selftest.sh`: Der Lauf dauert je nach Rundenzahl
# viele Minuten bis über eine halbe Stunde. Er wird von Hand gestartet, wenn
# es sich lohnt — vor einem Release, nach größeren Umbauten am Fenster-,
# Sitzungs- oder Editorverhalten, oder wenn aus dem Betrieb etwas gemeldet
# wurde, das die kurzen Tests nicht finden.
#
# WOZU
#
# Am 2026-08-07 kamen vier Fehler aus dem Arbeitsbetrieb, die keiner der rund
# achtzig Selbsttests gefunden hatte — zwei davon ließen sich in einer kurz
# aufgebauten Testwelt nicht einmal nachstellen. Der Grund ist bauartbedingt:
# Ein Selbsttest erzeugt eine frische Miniwelt, prüft eine Sache und räumt
# ab. Fehler, die erst nach längerer Arbeit mit mehreren großen Dokumenten
# entstehen, kommen darin gar nicht vor.
#
# Dieser Lauf arbeitet stattdessen wie ein Mensch: mehrere große Dokumente in
# mehreren Fenstern, die offen bleiben, viele Aktionen in wechselnder
# Reihenfolge — und nach JEDER Aktion die Prüfung aller Invarianten. Zwischen
# den Phasen wird Fastra beendet und neu gestartet, weil zwei der gemeldeten
# Fehler genau am Neustart hingen.
#
# AUFRUF
#
#   ./soak-test.sh                # Standard: 3 Phasen à 60 Aktionen
#   ./soak-test.sh --rounds 200   # längerer Lauf (~30 min)
#   ./soak-test.sh --rounds 10    # schnelle Rauchprobe des Testaufbaus selbst
#
# EXIT-CODES (wie bei selftest.sh)
#   0 = keine Invarianten-Verstöße
#   1 = mindestens ein Verstoß (Protokoll nennt Phase, Aktion und Invariante)
#   2 = Umgebungsfehler (kein Bundle, kein Fensterfokus)

set -u

cd "$(dirname "$0")"

ROUNDS=60
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds)
      ROUNDS="${2:-60}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      exit 2
      ;;
  esac
done

APP=".build/debug/Fastra.app"
BINARY="$APP/Contents/MacOS/Fastra"
if [ ! -x "$BINARY" ]; then
  echo "SOAK: Umgebungsfehler — $BINARY fehlt. Erst ./build.sh ausführen." >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)/fastra-soak"
LOG="$WORK_DIR/befunde.log"
mkdir -p "$WORK_DIR"
: > "$LOG"

# Eigene Defaults-Suite: Der Dauertest darf die echten Einstellungen des
# Nutzers nicht anfassen — er öffnet Fenster, ändert Formate und speichert.
# Die Testsuite waehlt die App selbst (SelfTest.workspaceDefaults); Phase 1
# leert sie, ab Phase 2 bleibt die Sitzung erhalten.

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "▶ Fastra Dauertest — $ROUNDS Aktionen je Phase, 3 Phasen"
echo "   Arbeitsverzeichnis: $WORK_DIR"
echo

run_phase() {
  local phase="$1"
  local label="$2"
  echo "→ Phase $phase: $label"
  # `-selftest soak` beendet die App am Ende selbst. Die Frist ist großzügig:
  # Der Lauf soll an einer echten Hängerei scheitern, nicht an Langsamkeit.
  local timeout=$(( ROUNDS * 3 + 120 ))
  local start
  start=$(date +%s)
  "$BINARY" -selftest soak \
    -soakPhase "$phase" \
    -soakRounds "$ROUNDS" \
    -soakDir "$WORK_DIR" \
    -soakLog "$LOG" \
    >"$WORK_DIR/phase-$phase.out" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( $(date +%s) - start ))
    if [ "$waited" -gt "$timeout" ]; then
      echo "   ✗ Phase $phase hängt seit ${waited}s — abgebrochen" >&2
      kill -9 "$pid" 2>/dev/null || true
      echo "SOAK-BEFUND phase=$phase aktion=? invariante=Lauf endet invariante detail=Zeitüberschreitung nach ${waited}s" >> "$LOG"
      return 1
    fi
  done
  wait "$pid"
  local status=$?
  echo "   Phase $phase beendet (Status $status, ${waited}s)"
  tail -2 "$WORK_DIR/phase-$phase.out" | sed 's/^/   /'
  return 0
}

PHASES_FAILED=0
run_phase 1 "Dokumente anlegen, drei Fenster öffnen, arbeiten" || PHASES_FAILED=$((PHASES_FAILED + 1))
run_phase 2 "nach Neustart: Sitzung prüfen und weiterarbeiten"  || PHASES_FAILED=$((PHASES_FAILED + 1))
run_phase 3 "nach zweitem Neustart: abschließende Runde"        || PHASES_FAILED=$((PHASES_FAILED + 1))

echo
echo "────────────────────────────────────────────────────────────"
# `grep -c` zählt 0 und liefert Status 1 — ohne `|| true` bricht `set -e`-artiges
# Verhalten ab, und ein zusätzliches `echo 0` erzeugte hier eine ZWEITE Zeile,
# an der der Vergleich unten scheiterte.
FINDINGS=$(grep -c "^SOAK-BEFUND" "$LOG" 2>/dev/null | head -1)
FINDINGS=${FINDINGS:-0}
ACTIONS=$(awk -F'aktionen=' '/^SOAK-ZUSAMMENFASSUNG/{split($2,a," "); s+=a[1]} END{print s+0}' "$LOG")

# Ein Lauf, dessen Phasen gar nicht durchliefen, darf NIE grün melden. Der
# erste Probelauf tat genau das: Alle drei Phasen brachen sofort ab, und das
# Skript meldete trotzdem „SOAK OK". Ein Test, der bei kaputtem Aufbau Erfolg
# meldet, ist schlimmer als keiner.
if [ "$PHASES_FAILED" -gt 0 ]; then
  echo "SOAK FAIL — $PHASES_FAILED von 3 Phasen sind nicht durchgelaufen." >&2
  echo "Ausgaben der Phasen:" >&2
  for phase in 1 2 3; do
    echo "  ── Phase $phase ──" >&2
    tail -3 "$WORK_DIR/phase-$phase.out" 2>/dev/null | sed 's/^/    /' >&2
  done
  exit 1
fi

# Ebenso wertlos: Alle Phasen laufen, aber es wurde nichts geprüft.
if [ "$ACTIONS" -eq 0 ]; then
  echo "SOAK FAIL — kein einziger Prüfschritt ausgeführt. Der Testaufbau" >&2
  echo "greift nicht; ein grünes Ergebnis wäre hier bedeutungslos." >&2
  exit 1
fi

if [ "$FINDINGS" -gt 0 ]; then
  echo "SOAK FAIL — $FINDINGS Invarianten-Verstoß(e) bei $ACTIONS Aktionen:"
  echo
  grep "^SOAK-BEFUND" "$LOG" | sed 's/^/  /'
  echo
  echo "Jede Zeile nennt Phase, die AUSLÖSENDE Aktion und die verletzte"
  echo "Invariante. Bei Zustandsfehlern ist die Aktion die wichtigste Spur."
  exit 1
fi

echo "SOAK OK — $ACTIONS Aktionen, keine Invarianten-Verstöße."
exit 0
