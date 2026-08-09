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
#   FASTRA_SOAK_4D_PROJECT="…/projektwurzel"  # wird DIREKT bearbeitet;
#                                             # muss ein Git-Projekt sein
#
# Das 4D-Projekt wird absichtlich am Ort bearbeitet (echtes Nutzungs-
# verhalten). Nach dem Lauf setzt das Skript ausschließlich die Dateien
# zurück, die der Lauf selbst verschmutzt hat; zuvor schon veränderte
# Dateien (fremder WIP) bleiben unangetastet. Inhalte, Namen oder Auszüge
# aus diesen Quellen dürfen nie ins Repo gelangen.
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

WORK_DIR="$(mktemp -d)/fastra-soak"
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
  # Danach das 4D-Projekt zurücksetzen (braucht die Merkdateien im
  # Arbeitsverzeichnis) und erst dann aufräumen. Läuft auch bei Abbruch.
  restore_4d_project || cleanup_failed=1
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
  rm -rf "$WORK_DIR"
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

# Das 4D-Projekt wird am Ort bearbeitet. Vorher den Schmutzstand merken,
# damit hinterher NUR die vom Lauf verschmutzten Dateien zurückgesetzt
# werden — fremder WIP bleibt unangetastet.
SOAK_4D=""
SOAK_4D_METHOD=""
SOAK_4D_RESTORED=0
DIRTY_BEFORE="$WORK_DIR/4d-dirty-before.txt"
if [ -n "${FASTRA_SOAK_4D_PROJECT:-}" ] && [ -d "$FASTRA_SOAK_4D_PROJECT" ]; then
  if git -C "$FASTRA_SOAK_4D_PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    SOAK_4D="$FASTRA_SOAK_4D_PROJECT"
    git -C "$SOAK_4D" status --porcelain=v1 -z | tr '\0' '\n' > "$DIRTY_BEFORE"
    # Die größte SAUBERE Methode wählen: In eine bereits verschmutzte Datei
    # (fremder WIP) darf der Lauf nicht tippen — ein Zurücksetzen würde dort
    # den WIP mitlöschen, also wird sie gar nicht erst geöffnet.
    SOAK_4D_METHOD=$(python3 - "$SOAK_4D" "$DIRTY_BEFORE" <<'PYEOF'
import os, sys
root, dirty_path = sys.argv[1], sys.argv[2]
dirty = set()
for line in open(dirty_path, encoding="utf-8", errors="replace").read().splitlines():
    if len(line) > 3:
        dirty.add(os.path.join(root, line[3:]))
methods = os.path.join(root, "Project", "Sources", "Methods")
best, best_lines = "", -1
if os.path.isdir(methods):
    for name in os.listdir(methods):
        full = os.path.join(methods, name)
        if name.endswith(".4dm") and full not in dirty and os.path.isfile(full):
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
    # Für die Warnung nach dem Lauf: Änderungszeiten der schon vorher
    # verschmutzten Dateien merken.
    python3 - "$SOAK_4D" "$DIRTY_BEFORE" > "$WORK_DIR/4d-dirty-mtimes.txt" <<'PYEOF'
import os, sys
root, dirty_path = sys.argv[1], sys.argv[2]
for line in open(dirty_path, encoding="utf-8", errors="replace").read().splitlines():
    if len(line) > 3:
        full = os.path.join(root, line[3:])
        try:
            print(f"{os.path.getmtime(full)}\t{line[3:]}")
        except OSError:
            pass
PYEOF
  else
    echo "⚠ 4D-Projekt ist kein Git-Repo — wird ausgelassen (kein Sicherheitsnetz): $FASTRA_SOAK_4D_PROJECT" >&2
  fi
fi

restore_4d_project() {
  [ "${SOAK_4D_RESTORED:-0}" -eq 0 ] || return 0
  [ -n "${SOAK_4D:-}" ] || return 0
  # Nur von der App unmittelbar vor einer eigenen Textmutation protokollierte
  # 4D-Pfade gehören nachweislich dem Lauf. Andere neue Änderungen können
  # parallel von Nutzer oder Werkzeug stammen: melden, niemals anfassen.
  if ! git -C "$SOAK_4D" status --porcelain=v1 -z \
      > "$WORK_DIR/4d-dirty-after.raw"; then
    echo "   ✗ 4D-Projektstatus für die Bereinigung nicht lesbar" >&2
    return 1
  fi
  tr '\0' '\n' < "$WORK_DIR/4d-dirty-after.raw" \
    > "$WORK_DIR/4d-dirty-after.txt"
  : > "$WORK_DIR/4d-touched.txt"
  local phase_output
  for phase_output in "$WORK_DIR"/phase-*.out; do
    [ -f "$phase_output" ] || continue
    sed -n 's/^SOAK-4D-DATEI: //p' "$phase_output" >> "$WORK_DIR/4d-touched.txt"
  done
  python3 - "$SOAK_4D" "$DIRTY_BEFORE" "$WORK_DIR/4d-dirty-after.txt" \
    "$WORK_DIR/4d-touched.txt" <<'PYEOF'
import os, subprocess, sys
root, before_path, after_path, touched_path = sys.argv[1:5]
def entries(path):
    result = {}
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        if len(line) > 3:
            result[line[3:]] = line[:2]
    return result
before, after = entries(before_path), entries(after_path)
fresh = [f for f in after if f not in before]
tracked = [f for f, st in after.items() if f in fresh and st not in ("??",)]
untracked = [f for f in fresh if after[f] == "??"]
root_abs = os.path.abspath(root)
owned = set()
invalid = []
for path in open(touched_path, encoding="utf-8", errors="replace").read().splitlines():
    touched_abs = os.path.abspath(path)
    try:
        if os.path.commonpath((root_abs, touched_abs)) == root_abs:
            owned.add(os.path.relpath(touched_abs, root_abs))
        else:
            invalid.append(path)
    except ValueError:
        invalid.append(path)

failed = bool(invalid)
restored_count = 0
for path in sorted(f for f in tracked if f in owned):
    restored = subprocess.run(
        ["git", "-C", root, "checkout", "--", path],
        capture_output=True, text=True, errors="replace")
    if restored.returncode == 0:
        restored_count += 1
    else:
        failed = True
        detail = (restored.stderr or restored.stdout).strip() or "ohne Git-Fehlertext"
        print(f"   ✗ 4D-Projekt: {path} nicht zurücksetzbar: {detail}",
              file=sys.stderr)
if restored_count:
    print(f"   4D-Projekt: {restored_count} test-eigene Datei(en) zurückgesetzt")

untouched = [f for f in tracked if f not in owned]
if untouched:
    print("   ⚠ 4D-Projekt: andere neue Änderung(en) bleiben unangetastet:")
    for f in untouched:
        print(f"     {f}")
if untracked:
    print("   ⚠ 4D-Projekt: neue, nicht versionierte Datei(en) bleiben unangetastet:")
    for f in untracked:
        print(f"     {f}")
for path in invalid:
    print(f"   ✗ 4D-Projekt: protokollierter Pfad liegt außerhalb des Repos: {path}",
          file=sys.stderr)
sys.exit(1 if failed else 0)
PYEOF
  local restore_status=$?
  # Schon vorher verschmutzte Dateien (fremder WIP) werden NIE zurückgesetzt.
  # Hat der Lauf eine davon dennoch verändert, nur ehrlich warnen.
  if [ -f "$WORK_DIR/4d-dirty-mtimes.txt" ]; then
    python3 - "$SOAK_4D" "$WORK_DIR/4d-dirty-mtimes.txt" <<'PYEOF'
import os, sys
root, mtimes_path = sys.argv[1], sys.argv[2]
for line in open(mtimes_path, encoding="utf-8", errors="replace").read().splitlines():
    stamp, _, rel = line.partition("\t")
    full = os.path.join(root, rel)
    try:
        if abs(os.path.getmtime(full) - float(stamp)) > 0.5:
            print(f"   ⚠ 4D-Projekt: {rel} war schon vorher verändert (WIP) und wurde "
                  "vom Lauf berührt — bitte selbst prüfen, NICHT automatisch zurückgesetzt.")
    except (OSError, ValueError):
        pass
PYEOF
  fi
  [ "$restore_status" -eq 0 ] || return "$restore_status"
  SOAK_4D_RESTORED=1
}

echo "▶ Fastra Dauertest — $ROUNDS Aktionen je Phase, 3 Phasen"
echo "   Arbeitsverzeichnis: $WORK_DIR"
if [ -d "$REAL_DIR" ]; then echo "   Echte Dokumente: kopiert nach $REAL_DIR"; fi
if [ -n "$SOAK_4D" ]; then echo "   4D-Projekt (am Ort): $SOAK_4D"; fi
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

EXTERNAL_RESTORE_FAILED=0
if ! restore_4d_project; then
  EXTERNAL_RESTORE_FAILED=1
  KEEP_EVIDENCE=1
  echo "SOAK-BEFUND phase=cleanup aktion=? invariante=4D-Testdatei wird wiederhergestellt detail=4D-Bereinigung fehlgeschlagen" >> "$LOG"
fi

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
if [ "$PHASES_FAILED" -gt 0 ] || [ "$EXTERNAL_RESTORE_FAILED" -gt 0 ]; then
  KEEP_EVIDENCE=1
  if [ "$PHASES_FAILED" -gt 0 ]; then
    echo "SOAK FAIL — $PHASES_FAILED von 3 Phasen sind nicht durchgelaufen." >&2
    echo "Ausgaben der Phasen:" >&2
    for phase in 1 2 3; do
      echo "  ── Phase $phase ──" >&2
      tail -3 "$WORK_DIR/phase-$phase.out" 2>/dev/null | sed 's/^/    /' >&2
    done
  fi
  if [ "$EXTERNAL_RESTORE_FAILED" -gt 0 ]; then
    echo "SOAK FAIL — test-eigene 4D-Dateien konnten nicht sicher zurückgesetzt werden." >&2
  fi
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
