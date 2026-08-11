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
umask 077

cd "$(dirname "$0")"

# Dieselbe Sperre wie die kurzen Fenster-Selbsttests verhindert gegenseitigen
# Fokus- und Prozess-Eingriff auch über mehrere Worktrees hinweg.
# shellcheck source=tools/gui-test-lock.sh
. ./tools/gui-test-lock.sh
# shellcheck source=tools/test-sandbox.sh
. ./tools/test-sandbox.sh
# shellcheck source=tools/test-process-tree.sh
. ./tools/test-process-tree.sh
# shellcheck source=tools/soak-process-state.sh
. ./tools/soak-process-state.sh

ROUNDS=60
FIXTURES_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds)
      if [ $# -lt 2 ]; then
        echo "--rounds braucht eine positive ganze Zahl." >&2
        exit 2
      fi
      ROUNDS="$2"
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
case "$ROUNDS" in
  ''|*[!0-9]*)
    echo "Runden müssen eine positive ganze Zahl sein." >&2
    exit 2
    ;;
esac
if [ "$ROUNDS" -lt 1 ]; then
  echo "Runden müssen eine positive ganze Zahl sein." >&2
  exit 2
fi

# Private Pfade aus der lokalen, gitignorierten Konfiguration.
if [ "$FIXTURES_ONLY" -eq 0 ] && [ -f soak-test.local ]; then
  # shellcheck disable=SC1091
  . ./soak-test.local
fi
if [ "$FIXTURES_ONLY" -eq 1 ]; then
  # Auch geerbte Shell-Variablen dürfen einen ausdrücklich reinen Fixture-Lauf
  # nicht in einen Real-Daten-Lauf verwandeln oder falsch etikettieren.
  unset FASTRA_SOAK_RTFD FASTRA_SOAK_MD_DIR FASTRA_SOAK_4D_PROJECT
fi

APP=".build/debug/Fastra.app"
BINARY="$APP/Contents/MacOS/Fastra"
if [ ! -x "$BINARY" ]; then
  echo "SOAK: Umgebungsfehler — $BINARY fehlt. Erst ./build.sh ausführen." >&2
  exit 2
fi
BINARY_ABSOLUTE="$(cd "$(dirname "$BINARY")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$BINARY")")"
APP_BUNDLE_CANONICAL="$(cd "$APP" && pwd -P)"

SOAK_PRODUCT_DEFAULTS_DOMAIN="de.dm0.fastra"
SOAK_PRODUCT_DEFAULTS_BACKUP=""
SOAK_PRODUCT_DEFAULTS_EXISTED=0
SOAK_PRODUCT_DEFAULTS_SNAPSHOT_READY=0
SOAK_SAVED_STATE_PARENT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
SOAK_SAVED_STATE_PARENT="${SOAK_SAVED_STATE_PARENT%/}"
SOAK_SAVED_STATE_DIR="$SOAK_SAVED_STATE_PARENT/de.dm0.fastra.savedState"
SOAK_SAVED_STATE_BACKUP=""
SOAK_SAVED_STATE_EXISTED=0
SOAK_SAVED_STATE_SNAPSHOT_READY=0

foreign_fastra_process_is_running() {
  # Vor Snapshot und Restore darf überhaupt keine Fastra-Instanz laufen.
  # Ein gleicher Binary-Pfad beweist kein Eigentum dieses Runners.
  pgrep -f '/Fastra\.app/Contents/MacOS/Fastra([[:space:]]|$)' \
    >/dev/null 2>&1
}

snapshot_product_defaults() {
  foreign_fastra_process_is_running && {
    echo "SOAK: Umgebungsfehler — eine andere Fastra-App läuft." >&2
    return 2
  }
  SOAK_PRODUCT_DEFAULTS_BACKUP="$FASTRA_TEST_SANDBOX/product-defaults.plist"
  local read_error="$FASTRA_TEST_SANDBOX/product-defaults-read.err"
  if /usr/bin/defaults read "$SOAK_PRODUCT_DEFAULTS_DOMAIN" \
      >/dev/null 2>"$read_error"; then
    /usr/bin/defaults export "$SOAK_PRODUCT_DEFAULTS_DOMAIN" \
      "$SOAK_PRODUCT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 2
    SOAK_PRODUCT_DEFAULTS_EXISTED=1
  elif grep -Fq "Domain $SOAK_PRODUCT_DEFAULTS_DOMAIN does not exist" "$read_error"; then
    rm -f -- "$SOAK_PRODUCT_DEFAULTS_BACKUP"
  else
    echo "SOAK: Umgebungsfehler — Fastra-Einstellungen nicht sicher lesbar." >&2
    return 2
  fi
  SOAK_PRODUCT_DEFAULTS_SNAPSHOT_READY=1
}

restore_product_defaults() {
  [ "$SOAK_PRODUCT_DEFAULTS_SNAPSHOT_READY" -eq 1 ] || return 0
  foreign_fastra_process_is_running && return 2
  if [ "$SOAK_PRODUCT_DEFAULTS_EXISTED" -eq 1 ]; then
    /usr/bin/defaults import "$SOAK_PRODUCT_DEFAULTS_DOMAIN" \
      "$SOAK_PRODUCT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 2
    /usr/bin/defaults export "$SOAK_PRODUCT_DEFAULTS_DOMAIN" - 2>/dev/null \
      | /usr/bin/python3 -c \
          'import datetime,plistlib,sys
def same(a,b):
    if isinstance(a,datetime.datetime) and isinstance(b,datetime.datetime): return abs((a-b).total_seconds()) < 1
    if type(a) is not type(b): return False
    if isinstance(a,dict): return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
    if isinstance(a,list): return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
    return a==b
a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.loads(sys.stdin.buffer.read()); raise SystemExit(0 if same(a,b) else 1)' \
          "$SOAK_PRODUCT_DEFAULTS_BACKUP"
  else
    /usr/bin/defaults delete "$SOAK_PRODUCT_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
    local read_error="$FASTRA_TEST_SANDBOX/product-defaults-restore-read.err"
    if /usr/bin/defaults read "$SOAK_PRODUCT_DEFAULTS_DOMAIN" \
        >/dev/null 2>"$read_error"; then
      return 2
    fi
    grep -Fq "Domain $SOAK_PRODUCT_DEFAULTS_DOMAIN does not exist" "$read_error"
  fi
}

saved_state_path_is_safe() {
  [ -n "$SOAK_SAVED_STATE_PARENT" ] && [ "$1" = "$SOAK_SAVED_STATE_DIR" ]
}

remove_product_saved_state() {
  [ ! -e "$SOAK_SAVED_STATE_DIR" ] && return 0
  saved_state_path_is_safe "$SOAK_SAVED_STATE_DIR" || return 2
  [ -d "$SOAK_SAVED_STATE_DIR" ] && [ ! -L "$SOAK_SAVED_STATE_DIR" ] || return 2
  [ "$(stat -f '%u' "$SOAK_SAVED_STATE_DIR" 2>/dev/null || true)" = "$UID" ] || return 2
  find "$SOAK_SAVED_STATE_DIR" -depth -delete 2>/dev/null
}

snapshot_product_saved_state() {
  saved_state_path_is_safe "$SOAK_SAVED_STATE_DIR" || return 2
  SOAK_SAVED_STATE_BACKUP="$FASTRA_TEST_SANDBOX/product-saved-state"
  if [ -d "$SOAK_SAVED_STATE_DIR" ] && [ ! -L "$SOAK_SAVED_STATE_DIR" ]; then
    [ "$(stat -f '%u' "$SOAK_SAVED_STATE_DIR" 2>/dev/null || true)" = "$UID" ] || return 2
    /usr/bin/ditto "$SOAK_SAVED_STATE_DIR" "$SOAK_SAVED_STATE_BACKUP" \
      >/dev/null 2>&1 || return 2
    SOAK_SAVED_STATE_EXISTED=1
  fi
  SOAK_SAVED_STATE_SNAPSHOT_READY=1
}

restore_product_saved_state() {
  [ "$SOAK_SAVED_STATE_SNAPSHOT_READY" -eq 1 ] || return 0
  foreign_fastra_process_is_running && return 2
  remove_product_saved_state || return 2
  if [ "$SOAK_SAVED_STATE_EXISTED" -eq 1 ]; then
    /usr/bin/ditto "$SOAK_SAVED_STATE_BACKUP" "$SOAK_SAVED_STATE_DIR" \
      >/dev/null 2>&1 || return 2
    diff -qr "$SOAK_SAVED_STATE_BACKUP" "$SOAK_SAVED_STATE_DIR" \
      >/dev/null 2>&1
  fi
}

# Diagnosebeweise sind nützlich, aber nicht unbegrenzt. Sie enthalten nur
# Logs und gegebenenfalls die itemgetreue Zwischenablage-Sicherung, niemals
# kopierte reale Dokumente. Die fünf jüngsten Läufe bleiben für die Auswertung.
prune_soak_evidence() {
  local parents=(/tmp)
  local inherited_tmp="${TMPDIR:-}"
  inherited_tmp="${inherited_tmp%/}"
  if [ -n "$inherited_tmp" ] && [ "$inherited_tmp" != "/tmp" ]; then
    parents+=("$inherited_tmp")
  fi
  local stale owner parent allowed
  # Die ersten Versionen des Runners legten Belege mit der normalen umask an.
  # Bevor bis zu fünf davon aufbewahrt werden, werden nur eigentümereigene,
  # echte Verzeichnisse auf private Rechte gehärtet.
  while IFS= read -r stale; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
    [ "$owner" = "$UID" ] || continue
    chmod 700 "$stale" 2>/dev/null || true
    find "$stale" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$stale" -type f -exec chmod 600 {} + 2>/dev/null || true
  done < <(find "${parents[@]}" -maxdepth 1 -type d \
      -name 'fastra-soak-befunde-*' -print 2>/dev/null)
  while IFS= read -r stale; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
    [ "$owner" = "$UID" ] || continue
    allowed=0
    for parent in "${parents[@]}"; do
      case "$stale" in "$parent"/fastra-soak-befunde-*) allowed=1 ;; esac
    done
    [ "$allowed" -eq 1 ] && rm -rf -- "$stale"
  done < <(
    find "${parents[@]}" -maxdepth 1 -type d -name 'fastra-soak-befunde-*' \
      -exec stat -f '%m %N' {} + 2>/dev/null \
      | sort -rn | sed -n '6,$s/^[0-9][0-9]* //p'
  )
}
early_cleanup() {
  local original_status=$?
  local failed=0
  trap - EXIT INT TERM
  if [[ "${FASTRA_TEST_PENDING_PID:-}" =~ ^[0-9]+$ ]]; then
    terminate_fastra_test_process_trees "$FASTRA_TEST_PENDING_PID" || failed=1
    wait "$FASTRA_TEST_PENDING_PID" 2>/dev/null || true
  fi
  release_fastra_gui_test_lock || failed=1
  release_fastra_test_sandbox || failed=1
  if [ "$failed" -eq 1 ] && [ "$original_status" -eq 0 ]; then
    echo "SOAK: frühes Aufräumen blieb unvollständig." >&2
    exit 2
  fi
  [ "$failed" -eq 0 ] || echo "SOAK: frühes Aufräumen blieb zusätzlich unvollständig." >&2
  exit "$original_status"
}

prune_soak_evidence

create_fastra_test_sandbox soak-run || exit 2
# Unmittelbar nach dem erfolgreichen mktemp gehört die Sandbox dem Trap. So
# kann auch ein Signal zwischen Einrichtung und GUI-Sperre nichts hinterlassen.
trap early_cleanup EXIT
# Sperre VOR jedem Snapshot des echten Nutzerzustands. Ein abgewiesener
# Parallelrunner darf weder Einstellungen anfassen noch für sein Cleanup einen
# eigenen Fastra-Hilfsprozess starten.
acquire_fastra_gui_test_lock || exit 2
snapshot_product_defaults || exit 2
snapshot_product_saved_state || exit 2
SOAK_DEFAULTS_SUITE="Fastra-$(/usr/bin/uuidgen)"
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_SANDBOX/defaults-registry.txt"
: > "$FASTRA_TEST_DEFAULTS_REGISTRY" || exit 2
WORK_ROOT="$FASTRA_TEST_SANDBOX"
WORK_DIR="$WORK_ROOT/fastra-soak"
LOG="$WORK_DIR/befunde.log"
PASTEBOARD_BACKUP="$WORK_DIR/pasteboard-backup.plist"
mkdir -p "$WORK_DIR"
: > "$LOG"
SOAK_APP_STARTED=0

# Eigene Defaults-Suite: Der Dauertest darf die echten Einstellungen des
# Nutzers nicht anfassen — er öffnet Fenster, ändert Formate und speichert.
# Die Testsuite waehlt die App selbst (SelfTest.workspaceDefaults); Phase 1
# leert sie, ab Phase 2 bleibt die Sitzung erhalten.

cleanup() {
  local original_status=$?
  local cleanup_failed=0
  local process_cleanup_failed=0
  local evidence_saved=1
  local recovery_backup_needed=0
  # Bei einem äußeren Abbruch darf nur der von diesem Runner gestartete
  # Phasenprozess beendet werden. Danach kann ein frischer App-Prozess die
  # persistierte Zwischenablage-Sicherung gefahrlos einspielen.
  local cleanup_pid
  local cleanup_targets=()
  if fastra_test_pending_start_was_released; then
    SOAK_APP_STARTED=1
  fi
  [ -n "${SOAK_PHASE_PID:-}" ] && cleanup_targets+=("$SOAK_PHASE_PID")
  if [[ "${FASTRA_TEST_PENDING_PID:-}" =~ ^[0-9]+$ ]]; then
    cleanup_targets+=("$FASTRA_TEST_PENDING_PID")
  fi
  if [ "${#SOAK_REMAINING_PIDS[@]}" -gt 0 ]; then
    cleanup_targets+=("${SOAK_REMAINING_PIDS[@]}")
  fi
  if [ "${#cleanup_targets[@]}" -gt 0 ]; then
    for cleanup_pid in "${cleanup_targets[@]}"; do
      if ! terminate_fastra_test_process_trees "$cleanup_pid"; then
        cleanup_failed=1
        remember_soak_cleanup_failure "$cleanup_pid"
        SOAK_PROCESS_CLEANUP_BLOCKED=1
      fi
      wait "$cleanup_pid" 2>/dev/null || true
    done
  fi
  if [ "$process_cleanup_failed" -eq 0 ] \
     && [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 0 ] \
     && [[ "${FASTRA_TEST_PENDING_PID:-}" =~ ^[0-9]+$ ]]; then
    fastra_test_discard_pending_session || {
      cleanup_failed=1
      process_cleanup_failed=1
    }
  fi
  if [ "$process_cleanup_failed" -eq 0 ] \
     && [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 0 ] \
     && [ "$SOAK_APP_STARTED" -eq 1 ]; then
    restore_soak_pasteboard cleanup || cleanup_failed=1
    # Der Clipboard-Helfer kann selbst einen nicht beendbaren Prozess melden.
    # Dann darf kein zweiter App-Helfer neben ihm starten.
    if soak_followup_is_safe; then
      purge_soak_defaults || cleanup_failed=1
    fi
  fi
  # Die beiden Hilfsaufrufe können selbst noch einen nicht beendbaren
  # Prozess melden. Im selben EXIT-Durchlauf genau diese Roots erneut prüfen.
  # Das gilt auch nach einem ersten Fehlschlag: Der Blocker verhindert zwar
  # neue Hilfsstarts, darf aber die vorhandene Nachräumchance nicht sperren.
  if [ "${#SOAK_REMAINING_PIDS[@]}" -gt 0 ]; then
    retry_soak_cleanup_failures || cleanup_failed=1
  fi
  if [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 1 ]; then
    cleanup_failed=1
    process_cleanup_failed=1
  fi
  if [ "$process_cleanup_failed" -eq 0 ]; then
    purge_fastra_registered_test_defaults "$FASTRA_TEST_DEFAULTS_REGISTRY" \
      || cleanup_failed=1
    if [ "$SOAK_APP_STARTED" -eq 1 ] \
       || fastra_test_pending_start_was_released; then
      unregister_fastra_test_bundle_from_launch_services \
        "$APP_BUNDLE_CANONICAL" || cleanup_failed=1
    fi
    if ! restore_product_defaults; then
      cleanup_failed=1
      recovery_backup_needed=1
    fi
    if ! restore_product_saved_state; then
      cleanup_failed=1
      recovery_backup_needed=1
    fi
  else
    # Solange ein alter App-/Hilfsprozess möglicherweise noch lebt, darf kein
    # neuer Fastra-Helfer starten und kein Preferences-Stand darunter
    # ausgetauscht werden. Die private Sandbox bleibt als Rettungsbeleg erhalten.
    recovery_backup_needed=1
  fi
  release_fastra_gui_test_lock || cleanup_failed=1
  # Bei Befunden oder einem Absturz die BEWEISE erhalten: Protokoll und
  # Phasenausgaben (mit Exception-Text und Stacktrace) überleben das
  # Aufräumen. Nur die Logs — die kopierten echten Dokumente nicht.
  if [ "${KEEP_EVIDENCE:-0}" -eq 1 ] || [ "$cleanup_failed" -eq 1 ] \
     || [ "$original_status" -ne 0 ]; then
    local evidence
    evidence=$(mktemp -d "/tmp/fastra-soak-befunde-$(date +%Y%m%d-%H%M%S).XXXXXX") \
      || evidence_saved=0
    if [ "$evidence_saved" -eq 1 ]; then
      cp -- "$LOG" "$evidence/befunde.log" || evidence_saved=0
      local candidate
      for candidate in "$WORK_DIR"/phase-*.out \
                       "$WORK_DIR"/pasteboard-restore-*.out \
                       "$WORK_DIR/defaults-purge.out" \
                       "$PASTEBOARD_BACKUP"; do
        [ -f "$candidate" ] || continue
        cp -- "$candidate" "$evidence/" || evidence_saved=0
      done
      # Nutzer-Preferences sind keine gewöhnliche Diagnose. Nur wenn ihre
      # Wiederherstellung selbst scheiterte, dient die private Kopie als
      # Recovery-Backup und darf den Runner überleben.
      if [ "$recovery_backup_needed" -eq 1 ] \
         && [ -f "$SOAK_PRODUCT_DEFAULTS_BACKUP" ]; then
        cp -- "$SOAK_PRODUCT_DEFAULTS_BACKUP" "$evidence/" || evidence_saved=0
      fi
    fi
    if [ "$evidence_saved" -eq 1 ]; then
      echo "   Beweise gesichert: $evidence" >&2
      prune_soak_evidence
    else
      [ -z "${evidence:-}" ] || rm -rf -- "$evidence"
      # Für eine manuelle Clipboard-Rettung bleibt die Sandbox privat liegen;
      # echte kopierte Arbeitsdokumente werden dafür nicht benötigt und dürfen
      # bei einem Kopier-/Plattenfehler nicht unbefristet Speicher belegen.
      [ -z "${REAL_DIR:-}" ] || rm -rf -- "$REAL_DIR"
      echo "   ✗ Beweise konnten nicht kopiert werden; private Sandbox bleibt erhalten:" >&2
      echo "     $WORK_ROOT" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$evidence_saved" -eq 1 ] && [ "$recovery_backup_needed" -eq 0 ]; then
    release_fastra_test_sandbox || cleanup_failed=1
  elif [ "$recovery_backup_needed" -eq 1 ]; then
    echo "   Private Sandbox mit Einstellungs-/Fenster-Sicherung bleibt erhalten:" >&2
    echo "     $WORK_ROOT" >&2
  fi
  trap - EXIT
  if [ "$cleanup_failed" -eq 1 ] && [ "$original_status" -eq 0 ]; then
    echo "SOAK FAIL — externe Testdaten konnten nicht vollständig wiederhergestellt werden." >&2
    exit 1
  elif [ "$cleanup_failed" -eq 1 ]; then
    echo "SOAK: Zusätzlich blieb das Aufräumen unvollständig." >&2
  fi
  exit "$original_status"
}

# Echte Dokumente KOPIEREN: Tippen, Sichern und die RTFD-Umwandlung (deren
# Ergebnis neben der Quelle landet) dürfen die Originale nie berühren.
REAL_DIR="$WORK_DIR/real"
SOAK_RTFD_COPIED=0
SOAK_MD_COPIED=0
if [ -n "${FASTRA_SOAK_RTFD:-}" ] && [ -e "$FASTRA_SOAK_RTFD" ]; then
  mkdir -p "$REAL_DIR"
  if cp -R "$FASTRA_SOAK_RTFD" "$REAL_DIR/protokoll-import.rtfd"; then
    SOAK_RTFD_COPIED=1
  fi
fi
if [ -n "${FASTRA_SOAK_MD_DIR:-}" ] && [ -d "$FASTRA_SOAK_MD_DIR" ]; then
  mkdir -p "$REAL_DIR/markdown"
  if cp -R "$FASTRA_SOAK_MD_DIR/." "$REAL_DIR/markdown/"; then
    SOAK_MD_COPIED=1
  fi
fi

# Das reale 4D-Projekt wird wie die übrigen echten Eingaben KOPIERT. Direkte
# Bearbeitung plus spätes `git checkout --` kann fremde Änderungen nicht
# atomar von Teständerungen trennen; selbst Hash-Prüfungen lassen zwischen
# Prüfung und Rücksetzen ein Datenverlustfenster. Die Kopie beseitigt diese
# Klasse vollständig.
SOAK_4D=""
SOAK_4D_METHOD=""
SOAK_4D_COPIED=0
if [ -n "${FASTRA_SOAK_4D_PROJECT:-}" ] && [ -d "$FASTRA_SOAK_4D_PROJECT" ]; then
  SOAK_4D="$REAL_DIR/4d-project"
  mkdir -p "$SOAK_4D"
  # `-L` folgt auch Verzeichnis- und Datei-Symlinks. Ohne diesen Schalter
  # könnte die Testkopie beim Öffnen einer verlinkten Methode wieder in das
  # reale Fremdprojekt zeigen. Die Git-Daten selbst braucht das Szenario nicht.
  if ! /usr/bin/rsync -aL --exclude='.git' -- \
      "$FASTRA_SOAK_4D_PROJECT/" "$SOAK_4D/"; then
    echo "⚠ 4D-Projekt konnte nicht sicher kopiert werden — Szenario wird ausgelassen." >&2
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
    SOAK_4D_COPIED=1
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

# Stellt eine von der App persistierte, itemgetreue Zwischenablage-Sicherung in
# einem kleinen eigenen App-Aufruf wieder her. Das deckt normale Fehler,
# App-Abstürze und den Timeout-Kill ab. Nicht abfangbar bleibt nur ein harter
# Abbruch des RUNNERS selbst (SIGKILL/Systemausfall) zwischen Clipboard-Änderung
# und diesem Schritt; dann bleibt die Sicherung im oben ausgegebenen WORK_DIR.
restore_soak_pasteboard() {
  local label="${1:-cleanup}"
  [ -f "$PASTEBOARD_BACKUP" ] || return 0
  local output="$WORK_DIR/pasteboard-restore-$label.out"
  FASTRA_TEST_PENDING_BUNDLE="$APP_BUNDLE_CANONICAL"
  if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
  CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
  CFPREFERENCES_AVOID_DAEMON=1 \
  HOME="$FASTRA_TEST_CF_HOME" \
  FASTRA_SELFTEST_DEFAULTS_SUITE="$SOAK_DEFAULTS_SUITE" \
  FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
  fastra_test_start_new_session "$BINARY" -selftest soakpasteboardrestore \
    -soakDir "$WORK_DIR" \
    -soakPhase 2 \
    -ApplePersistenceIgnoreState YES >"$output" 2>&1; then
    echo "   ✗ Zwischenablage-Hilfsprozess ließ sich nicht sicher starten" >&2
    return 1
  fi
  local pid="$FASTRA_TEST_STARTED_PID"
  SOAK_PHASE_PID="$pid"
  adopt_soak_process "$pid" || return 1
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -gt 30 ]; then
      cleanup_soak_process "$pid" || true
      echo "   ✗ Zwischenablage-Wiederherstellung hängt seit ${waited}s" >&2
      return 1
    fi
  done
  wait "$pid"
  local status=$?
  cleanup_soak_process "$pid" || return 1
  if [ "$status" -ne 0 ] || [ -f "$PASTEBOARD_BACKUP" ]; then
    echo "   ✗ Zwischenablage-Wiederherstellung fehlgeschlagen (Status $status)" >&2
    tail -2 "$output" 2>/dev/null | sed 's/^/     /' >&2
    return 1
  fi
  return 0
}

# Die drei Phasen teilen absichtlich eine Suite. Nach dem letzten Prozess —
# oder nach einem Abbruch — entfernt ein eigener App-Aufruf diese Domain samt
# Plist über dieselbe verifizierte Routine wie die Unit-Tests.
purge_soak_defaults() {
  local output="$WORK_DIR/defaults-purge.out"
  FASTRA_TEST_PENDING_BUNDLE="$APP_BUNDLE_CANONICAL"
  if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
  CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
  CFPREFERENCES_AVOID_DAEMON=1 \
  HOME="$FASTRA_TEST_CF_HOME" \
  FASTRA_SELFTEST_DEFAULTS_SUITE="$SOAK_DEFAULTS_SUITE" \
  FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
  fastra_test_start_new_session "$BINARY" -selftest soakdefaultspurge \
    -soakPhase 2 \
    -ApplePersistenceIgnoreState YES >"$output" 2>&1; then
    echo "   ✗ Preferences-Hilfsprozess ließ sich nicht sicher starten" >&2
    return 1
  fi
  local pid="$FASTRA_TEST_STARTED_PID"
  SOAK_PHASE_PID="$pid"
  adopt_soak_process "$pid" || return 1
  local waited=0
  while fastra_test_pid_is_live "$pid"; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -ge 300 ]; then
      cleanup_soak_process "$pid" || true
      echo "   ✗ Test-Preferences-Aufräumen überschritt 30 s" >&2
      return 1
    fi
  done
  wait "$pid"
  local status=$?
  cleanup_soak_process "$pid" || return 1
  if [ "$status" -ne 0 ]; then
    echo "   ✗ Test-Preferences-Aufräumen fehlgeschlagen (Status $status)" >&2
    tail -2 "$output" 2>/dev/null | sed 's/^/     /' >&2
    return 1
  fi
  return 0
}

# Erst ab hier können Phasen externe Zustände verändern. Beide
# Wiederherstellungsfunktionen sind nun definiert und stehen dem Trap auch bei
# einem Abbruch während der ersten Phase sicher zur Verfügung.
trap cleanup EXIT
SOAK_STARTED_MS=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000')
SOAK_HEAD_START=$(git -C .. rev-parse HEAD 2>/dev/null || true)
SOAK_BINARY_SHA_START=$(shasum -a 256 "$BINARY" | awk '{print $1}')
SOAK_DIRTY_START=$(git -C .. status --porcelain 2>/dev/null || true)

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
  FASTRA_TEST_PENDING_BUNDLE="$APP_BUNDLE_CANONICAL"
  if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
  CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
  CFPREFERENCES_AVOID_DAEMON=1 \
  HOME="$FASTRA_TEST_CF_HOME" \
  FASTRA_SELFTEST_DEFAULTS_SUITE="$SOAK_DEFAULTS_SUITE" \
  FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
  fastra_test_start_new_session "$BINARY" -selftest soak \
    -soakPhase "$phase" \
    -soakRounds "$ROUNDS" \
    -soakDir "$WORK_DIR" \
    -soakLog "$LOG" \
    ${SOAK_4D:+-soak4DProject "$SOAK_4D"} \
    ${SOAK_4D_METHOD:+-soak4DMethod "$SOAK_4D_METHOD"} \
    >"$WORK_DIR/phase-$phase.out" 2>&1; then
    echo "   ✗ Phase $phase ließ sich nicht in einer eigenen Prozessgruppe starten" >&2
    return 1
  fi
  local pid="$FASTRA_TEST_STARTED_PID"
  SOAK_APP_STARTED=1
  SOAK_PHASE_PID="$pid"
  adopt_soak_process "$pid" || return 1
  local waited=0
  local timed_out=0
  local status=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( $(date +%s) - start ))
    if [ "$waited" -gt "$timeout" ]; then
      echo "   ✗ Phase $phase hängt seit ${waited}s — abgebrochen" >&2
      if cleanup_soak_process "$pid"; then
        status=124
      else
        status=125
      fi
      echo "SOAK-BEFUND phase=$phase aktion=? invariante=Lauf endet kontrolliert detail=Zeitüberschreitung nach ${waited}s" >> "$LOG"
      timed_out=1
      break
    fi
  done
  if [ "$timed_out" -eq 0 ]; then
    wait "$pid"
    status=$?
    # Der App-Prozess kann sein Ergebnis schon geschrieben haben, während ein
    # von ihm gestartetes Kind in derselben Prozessgruppe weiterlebt.
    cleanup_soak_process "$pid" || status=125
  fi
  if [ "$status" -ne 125 ]; then
    SOAK_PHASE_PID=""
  fi
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
  # Ein Status 125 heißt: Der alte Prozessbaum kann noch leben. In dieser
  # Lage weder einen Clipboard-Helfer noch die nächste Phase parallel starten;
  # der EXIT-Trap bekommt sofort die alleinige Nachräumchance.
  if [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 1 ]; then
    KEEP_EVIDENCE=1
    echo "SOAK-BEFUND phase=$phase aktion=? invariante=Prozessbaum endet vollständig detail=Cleanup blieb unvollständig; Folgephasen gestoppt" >> "$LOG"
    return 1
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
soak_followup_is_safe || exit 1
run_phase 2 "nach Neustart: Sitzung prüfen und weiterarbeiten"  || PHASES_FAILED=$((PHASES_FAILED + 1))
soak_followup_is_safe || exit 1
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
  KEEP_EVIDENCE=1
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

SOAK_FINISHED_MS=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000')
SOAK_HEAD_END=$(git -C .. rev-parse HEAD 2>/dev/null || true)
SOAK_BINARY_SHA_END=$(shasum -a 256 "$BINARY" | awk '{print $1}')
SOAK_DIRTY_END=$(git -C .. status --porcelain 2>/dev/null || true)
SOAK_PROFILE="fixtures-only"
if [ "$FIXTURES_ONLY" -eq 0 ]; then
  SOAK_PROFILE="real-rtfd${SOAK_RTFD_COPIED}-md${SOAK_MD_COPIED}-4d${SOAK_4D_COPIED}"
fi
SOAK_QUALIFIED=""
if [ "$ROUNDS" -ge 60 ] && [ "$SOAK_HEAD_START" = "$SOAK_HEAD_END" ] \
   && [ "$SOAK_BINARY_SHA_START" = "$SOAK_BINARY_SHA_END" ] \
   && [ -z "$SOAK_DIRTY_START" ] && [ -z "$SOAK_DIRTY_END" ] \
   && [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ]; then
  SOAK_QUALIFIED="--qualified"
fi
SOAK_RECORDER_STATUS=0
/usr/bin/python3 ./tools/selftest-performance.py record-soak \
  --profile "$SOAK_PROFILE" \
  --head "$SOAK_HEAD_START" \
  --binary-sha256 "$SOAK_BINARY_SHA_START" \
  --rounds "$ROUNDS" \
  --actions "$ACTIONS" \
  --wall-ms "$((SOAK_FINISHED_MS - SOAK_STARTED_MS))" \
  ${SOAK_QUALIFIED:+--qualified} || SOAK_RECORDER_STATUS=$?
if [ "$SOAK_RECORDER_STATUS" -ne 0 ] \
   && [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ]; then
  echo "SOAK: Umgebungsfehler — lokale Performance-Baseline konnte nicht gespeichert werden." >&2
  exit 2
fi
echo "SOAK OK — $ACTIONS Aktionen, keine Invarianten-Verstöße."
exit 0
