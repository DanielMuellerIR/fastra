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
#   ./soak-test.sh --fixtures-only  # ohne echte Dokumente/Projekte
#
# ECHTE DOKUMENTE UND PROJEKTE (optional)
#
# Kurze Tests mit Miniaturdateien finden die Fehler nicht, die im Alltag
# auftreten. Der Lauf kann deshalb mit echten Daten arbeiten, deren private
# Pfade in der gitignorierten Datei `soak-test.local` stehen (Shell-Syntax):
#
#   FASTRA_SOAK_RTFD="…/Testprotokoll.rtfd"   # wird ins Arbeitsverzeichnis
#   FASTRA_SOAK_MD_DIR="…/Protokoll-Ordner"   # KOPIERT (die Umwandlung
#                                             # schreibt neben die Quelle!)
#   FASTRA_SOAK_4D_PROJECT="…/projektwurzel"  # wird vollständig in das
#                                             # Arbeitsverzeichnis KOPIERT
#
# Das 4D-Projekt wird niemals am Ort bearbeitet. Der Runner folgt beim Kopieren
# symbolischen Links, sodass auch verlinkte Methoden und Komponenten als echte
# Dateien INNERHALB der isolierten Kopie landen. Inhalte, Namen oder Auszüge aus
# diesen Quellen dürfen nie ins Repo gelangen.
#
# EXIT-CODES (wie bei selftest.sh)
#   0 = keine Invarianten-Verstöße
#   1 = mindestens ein Verstoß (Protokoll nennt Phase, Aktion und Invariante)
#   2 = Umgebungsfehler (kein Bundle, kein Fensterfokus)

set -u

cd "$(dirname "$0")"

ROUNDS=60
FIXTURES_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds)
      ROUNDS="${2:-60}"
      shift 2
      ;;
    --fixtures-only)
      FIXTURES_ONLY=1
      shift
      ;;
    -h|--help)
      sed -n '2,50p' "$0"
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      exit 2
      ;;
  esac
done

# Private Pfade aus der lokalen, gitignorierten Konfiguration.
if [ "$FIXTURES_ONLY" -eq 0 ] && [ -f soak-test.local ]; then
  # shellcheck disable=SC1091
  . ./soak-test.local
fi

APP=".build/debug/Fastra.app"
BINARY="$APP/Contents/MacOS/Fastra"
if [ ! -x "$BINARY" ]; then
  echo "SOAK: Umgebungsfehler — $BINARY fehlt. Erst ./build.sh ausführen." >&2
  exit 2
fi

WORK_ROOT="$(mktemp -d)"
WORK_DIR="$WORK_ROOT/fastra-soak"
LOG="$WORK_DIR/befunde.log"
PASTEBOARD_BACKUP="$WORK_DIR/pasteboard-backup.plist"
mkdir -p "$WORK_DIR"
: > "$LOG"

# Eigene Defaults-Suite: Der Dauertest darf die echten Einstellungen des
# Nutzers nicht anfassen — er öffnet Fenster, ändert Formate und speichert.
# Die Testsuite waehlt die App selbst (SelfTest.workspaceDefaults); Phase 1
# leert sie, ab Phase 2 bleibt die Sitzung erhalten.

cleanup() {
  local original_status=$?
  local cleanup_failed=0
  # Bei einem äußeren Abbruch darf nur der von diesem Runner gestartete
  # Phasenprozess beendet werden. Danach kann ein frischer App-Prozess die
  # persistierte Zwischenablage-Sicherung gefahrlos einspielen.
  if [ -n "${SOAK_PHASE_PID:-}" ] && kill -0 "$SOAK_PHASE_PID" 2>/dev/null; then
    kill -9 "$SOAK_PHASE_PID" 2>/dev/null || true
    wait "$SOAK_PHASE_PID" 2>/dev/null || true
  fi
  restore_soak_pasteboard cleanup || cleanup_failed=1
  # Bei Befunden oder einem Absturz die BEWEISE erhalten: Protokoll und
  # Phasenausgaben (mit Exception-Text und Stacktrace) überleben das
  # Aufräumen. Nur die Logs — die kopierten echten Dokumente nicht.
  if [ "${KEEP_EVIDENCE:-0}" -eq 1 ] || [ "$cleanup_failed" -eq 1 ]; then
    local evidence="${TMPDIR:-/tmp}/fastra-soak-befunde-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$evidence"
    cp "$LOG" "$WORK_DIR"/phase-*.out "$WORK_DIR"/pasteboard-restore-*.out \
       "$PASTEBOARD_BACKUP" "$evidence"/ 2>/dev/null || true
    echo "   Beweise gesichert: $evidence" >&2
  fi
  rm -rf "${WORK_ROOT:?}"
  if [ "$cleanup_failed" -eq 1 ] && [ "$original_status" -eq 0 ]; then
    echo "SOAK FAIL — externe Testdaten konnten nicht vollständig wiederhergestellt werden." >&2
    trap - EXIT
    exit 1
  fi
}

# Echte Dokumente KOPIEREN: Tippen, Sichern und die RTFD-Umwandlung (deren
# Ergebnis neben der Quelle landet) dürfen die Originale nie berühren.
REAL_DIR="$WORK_DIR/real"
if [ -n "${FASTRA_SOAK_RTFD:-}" ] && [ -e "$FASTRA_SOAK_RTFD" ]; then
  mkdir -p "$REAL_DIR"
  cp -R "$FASTRA_SOAK_RTFD" "$REAL_DIR/protokoll-import.rtfd"
fi
if [ -n "${FASTRA_SOAK_MD_DIR:-}" ] && [ -d "$FASTRA_SOAK_MD_DIR" ]; then
  mkdir -p "$REAL_DIR/markdown"
  cp -R "$FASTRA_SOAK_MD_DIR/." "$REAL_DIR/markdown/"
fi

# Das reale 4D-Projekt wird wie die übrigen echten Eingaben KOPIERT. Direkte
# Bearbeitung plus spätes `git checkout --` kann fremde Änderungen nicht
# atomar von Teständerungen trennen; selbst Hash-Prüfungen lassen zwischen
# Prüfung und Rücksetzen ein Datenverlustfenster. Die Kopie beseitigt diese
# Klasse vollständig.
SOAK_4D=""
SOAK_4D_METHOD=""
if [ -n "${FASTRA_SOAK_4D_PROJECT:-}" ] && [ -d "$FASTRA_SOAK_4D_PROJECT" ]; then
  SOAK_4D="$REAL_DIR/4d-project"
  mkdir -p "$SOAK_4D"
  # `-L` folgt auch Verzeichnis- und Datei-Symlinks. Ohne diesen Schalter
  # könnte die Testkopie beim Öffnen einer verlinkten Methode wieder in das
  # reale Fremdprojekt zeigen. Die Git-Daten selbst braucht das Szenario nicht.
  if ! /usr/bin/rsync -aL --exclude='.git' -- \
      "$FASTRA_SOAK_4D_PROJECT/" "$SOAK_4D/"; then
    echo "⚠ 4D-Projekt konnte nicht sicher kopiert werden — Szenario wird ausgelassen: $FASTRA_SOAK_4D_PROJECT" >&2
    rm -rf "$SOAK_4D"
    SOAK_4D=""
  elif find "$SOAK_4D" -type l -print -quit | grep -q .; then
    # `-L` sollte jeden Link als echte Datei oder echten Ordner kopieren. Falls
    # die Quelle während des Kopierens umgebaut wurde und trotzdem ein Link
    # übrig blieb, darf die App diese Kopie nicht öffnen und darüber wieder in
    # das Fremdprojekt schreiben.
    echo "⚠ 4D-Projektkopie enthält noch einen symbolischen Link — Szenario wird ausgelassen." >&2
    rm -rf "$SOAK_4D"
    SOAK_4D=""
  else
    echo "   4D-Projekt: isoliert kopiert nach $SOAK_4D"
  fi
fi

if [ -n "$SOAK_4D" ]; then
# Die größte echte Methode IN DER KOPIE wählen. `lstat` weist verbleibende
# Links ab; der kanonische Präfixvergleich verhindert jeden Ausbruch aus der
# isolierten Wurzel.
  SOAK_4D_METHOD=$(python3 - "$SOAK_4D" <<'PYEOF'
import os, stat, sys
root = os.path.realpath(sys.argv[1])
methods = os.path.join(root, "Project", "Sources", "Methods")
best, best_lines = "", -1
try:
    methods_info = os.lstat(methods)
except OSError:
    methods_info = None
if methods_info and stat.S_ISDIR(methods_info.st_mode):
    for entry in os.scandir(methods):
        full = entry.path
        resolved = os.path.realpath(full)
        inside = os.path.commonpath((root, resolved)) == root
        if entry.name.endswith(".4dm") and inside and entry.is_file(follow_symlinks=False):
            # Nach ZEILEN wählen, nicht nach Bytes: Eine lange echte Methode
            # (viele Zeilen Code) prüft Completion und Signaturhilfe besser
            # als eine Datentabelle aus wenigen Riesenzeilen.
            try:
                with open(full, "rb") as handle:
                    lines = handle.read().count(b"\n")
            except OSError:
                continue
            if lines > best_lines:
                best, best_lines = full, lines
print(best)
PYEOF
)
fi

echo "▶ Fastra Dauertest — $ROUNDS Aktionen je Phase, 3 Phasen"
echo "   Arbeitsverzeichnis: $WORK_DIR"
if [ -d "$REAL_DIR" ]; then echo "   Echte Dokumente: kopiert nach $REAL_DIR"; fi
if [ -n "$SOAK_4D" ]; then echo "   4D-Projekt (isolierte Kopie): $SOAK_4D"; fi
echo

SOAK_PHASE_PID=""

# Stellt eine von der App persistierte, itemgetreue Zwischenablage-Sicherung in
# einem kleinen eigenen App-Aufruf wieder her. Das deckt normale Fehler,
# App-Abstürze und den Timeout-Kill ab. Nicht abfangbar bleibt nur ein harter
# Abbruch des RUNNERS selbst (SIGKILL/Systemausfall) zwischen Clipboard-Änderung
# und diesem Schritt; dann bleibt die Sicherung im oben ausgegebenen WORK_DIR.
restore_soak_pasteboard() {
  local label="${1:-cleanup}"
  [ -f "$PASTEBOARD_BACKUP" ] || return 0
  local output="$WORK_DIR/pasteboard-restore-$label.out"
  "$BINARY" -selftest soakpasteboardrestore \
    -soakDir "$WORK_DIR" \
    -soakPhase 2 \
    -ApplePersistenceIgnoreState YES >"$output" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -gt 30 ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "   ✗ Zwischenablage-Wiederherstellung hängt seit ${waited}s" >&2
      return 1
    fi
  done
  wait "$pid"
  local status=$?
  if [ "$status" -ne 0 ] || [ -f "$PASTEBOARD_BACKUP" ]; then
    echo "   ✗ Zwischenablage-Wiederherstellung fehlgeschlagen (Status $status)" >&2
    tail -2 "$output" 2>/dev/null | sed 's/^/     /' >&2
    return 1
  fi
  return 0
}

# Erst ab hier können Phasen externe Zustände verändern. Beide
# Wiederherstellungsfunktionen sind nun definiert und stehen dem Trap auch bei
# einem Abbruch während der ersten Phase sicher zur Verfügung.
trap cleanup EXIT

run_phase() {
  local phase="$1"
  local label="$2"
  echo "→ Phase $phase: $label"
  # `-selftest soak` beendet die App am Ende selbst. Die Frist ist großzügig:
  # Der Lauf soll an einer echten Hängerei scheitern, nicht an Langsamkeit.
  local timeout=$(( ROUNDS * 3 + 120 ))
  local start
  start=$(date +%s)
  local findings_before
  findings_before=$(grep -c '^SOAK-BEFUND' "$LOG" 2>/dev/null)
  findings_before=${findings_before:-0}
  "$BINARY" -selftest soak \
    -soakPhase "$phase" \
    -soakRounds "$ROUNDS" \
    -soakDir "$WORK_DIR" \
    -soakLog "$LOG" \
    ${SOAK_4D:+-soak4DProject "$SOAK_4D"} \
    ${SOAK_4D_METHOD:+-soak4DMethod "$SOAK_4D_METHOD"} \
    >"$WORK_DIR/phase-$phase.out" 2>&1 &
  local pid=$!
  SOAK_PHASE_PID="$pid"
  local waited=0
  local timed_out=0
  local status=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( $(date +%s) - start ))
    if [ "$waited" -gt "$timeout" ]; then
      echo "   ✗ Phase $phase hängt seit ${waited}s — abgebrochen" >&2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "SOAK-BEFUND phase=$phase aktion=? invariante=Lauf endet kontrolliert detail=Zeitüberschreitung nach ${waited}s" >> "$LOG"
      timed_out=1
      status=124
      break
    fi
  done
  if [ "$timed_out" -eq 0 ]; then
    wait "$pid"
    status=$?
  fi
  SOAK_PHASE_PID=""
  echo "   Phase $phase beendet (Status $status, ${waited}s)"
  tail -2 "$WORK_DIR/phase-$phase.out" | sed 's/^/   /'
  local phase_failed=0
  # Jeder von null verschiedene Status ist ein gescheiterter Phasenlauf. Falls
  # `finish(false)` vor dem regulären Bericht beendet hat, die letzte
  # SELFTEST-Zeile als synthetischen Befund festhalten.
  if [ "$status" -ne 0 ]; then
    phase_failed=1
    KEEP_EVIDENCE=1
    local findings_after detail
    findings_after=$(grep -c '^SOAK-BEFUND' "$LOG" 2>/dev/null)
    findings_after=${findings_after:-0}
    if [ "$findings_after" -eq "$findings_before" ]; then
      detail=$(grep '^SELFTEST ' "$WORK_DIR/phase-$phase.out" 2>/dev/null | tail -1)
      detail=${detail:-"Exit-Status $status ohne SELFTEST-Abschlusszeile"}
      printf 'SOAK-BEFUND phase=%s aktion=? invariante=Phase endet kontrolliert detail=%s\n' \
        "$phase" "$detail" >> "$LOG"
    fi
  fi
  if ! restore_soak_pasteboard "phase-$phase"; then
    phase_failed=1
    KEEP_EVIDENCE=1
    echo "SOAK-BEFUND phase=$phase aktion=? invariante=Zwischenablage wird wiederhergestellt detail=Hilfsaufruf fehlgeschlagen" >> "$LOG"
  fi
  return "$phase_failed"
}

PHASES_FAILED=0
KEEP_EVIDENCE=0
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
  KEEP_EVIDENCE=1
  echo "SOAK FAIL — $PHASES_FAILED von 3 Phasen sind nicht durchgelaufen." >&2
  echo "Ausgaben der Phasen:" >&2
  for phase in 1 2 3; do
    echo "  ── Phase $phase ──" >&2
    tail -3 "$WORK_DIR/phase-$phase.out" 2>/dev/null | sed 's/^/    /' >&2
  done
  if [ "$FINDINGS" -gt 0 ]; then
    echo "Befunde im Report-Log: $FINDINGS" >&2
    grep '^SOAK-BEFUND' "$LOG" | sed 's/^/  /' >&2
  fi
  exit 1
fi

# Ebenso wertlos: Alle Phasen laufen, aber es wurde nichts geprüft.
if [ "$ACTIONS" -eq 0 ]; then
  echo "SOAK FAIL — kein einziger Prüfschritt ausgeführt. Der Testaufbau" >&2
  echo "greift nicht; ein grünes Ergebnis wäre hier bedeutungslos." >&2
  exit 1
fi

if [ "$FINDINGS" -gt 0 ]; then
  KEEP_EVIDENCE=1
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
