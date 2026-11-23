#!/usr/bin/env bash
# Fastra — Dauertest über längere Sitzungen und App-Neustarts.
#
# Separat von `selftest.sh` manuell starten, etwa nach Änderungen an Fenster-,
# Sitzungs- oder Editorverhalten. Mehrere große Dokumente bleiben in mehreren
# Fenstern offen; wechselnde Aktionen prüfen nach jedem Schritt Invarianten.
#
# Aufruf:
#   ./soak-test.sh                  # 3 Phasen à 60 Aktionen
#   ./soak-test.sh --rounds 200      # längerer Lauf (etwa 30 min)
#   ./soak-test.sh --rounds 10       # Rauchprobe des Testaufbaus
#   ./soak-test.sh --fixtures-only  # ohne echte Dokumente/Projekte
#
# Optionale reale Quellen in der gitignorierten `soak-test.local` (Shell-Syntax):
#   FASTRA_SOAK_RTFD="…/Testprotokoll.rtfd"
#   FASTRA_SOAK_MD_DIR="…/Protokoll-Ordner"
#   FASTRA_SOAK_4D_PROJECT="…/projektwurzel"
# Der Runner kopiert die Quellen ins Arbeitsverzeichnis und folgt Symlinks,
# damit auch verlinkte Methoden und Komponenten dort als echte Dateien liegen.
# Originale werden nicht bearbeitet. Private Pfade, Inhalte und Namen dürfen
# nicht ins Repo gelangen.
#
# Exit-Codes:
#   0 = keine Invarianten-Verstöße
#   1 = Verstoß; Protokoll nennt Phase, Aktion und Invariante
#   2 = Umgebungsfehler, etwa fehlendes Bundle oder Fensterfokus

set -u

umask 077

cd "$(dirname "$0")"

# Dieselbe Sperre wie die kurzen Fenster-Selbsttests verhindert gegenseitigen
# Fokus- und Prozess-Eingriff auch über mehrere Worktrees hinweg.
# shellcheck source=tools/gui-test-lock.sh
. ./tools/gui-test-lock.sh
# Die Herkunft vor dem Sandbox-Helper merken; dieser setzt sonst /tmp ein.
SOAK_RUNS_INSIDE_TEST_FIXTURE=0
SOAK_FIXTURE_PARENT="${FASTRA_TEST_SANDBOX_PARENT:-}"
[ -z "${FASTRA_TEST_SANDBOX_PARENT+x}" ] || SOAK_RUNS_INSIDE_TEST_FIXTURE=1
# shellcheck source=tools/test-sandbox.sh
. ./tools/test-sandbox.sh
# shellcheck source=tools/test-process-tree.sh
. ./tools/test-process-tree.sh
# shellcheck source=tools/soak-process-state.sh
. ./tools/soak-process-state.sh
# shellcheck source=tools/performance-qualification.sh
. ./tools/performance-qualification.sh || exit 2
# shellcheck source=tools/test-evidence-retention.sh
. ./tools/test-evidence-retention.sh || exit 2

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

# Pfadvariablen wie beim kurzen Runner. Für Direktstarts ist das Binary
# maßgeblich; das Cleanup darf nicht ein separat angegebenes anderes Bundle
# abmelden. Der Standard bleibt der lokale Debug-Build.
configure_soak_app() {
  local bundle="${FASTRA_SELFTEST_APP_BUNDLE:-.build/debug/Fastra.app}"
  local binary="${FASTRA_SELFTEST_APP_BIN:-$bundle/Contents/MacOS/Fastra}"
  if [ ! -x "$binary" ]; then
    echo "SOAK: Umgebungsfehler — $binary fehlt. App-Pfad prüfen oder ./build.sh ausführen." >&2
    return 2
  fi
  BINARY="$(cd "$(dirname "$binary")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$binary")")" || return 2
  case "$BINARY" in
    */Contents/MacOS/Fastra)
      APP_BUNDLE_CANONICAL="${BINARY%/Contents/MacOS/Fastra}"
      ;;
    *)
      echo "SOAK: Umgebungsfehler — das Test-Binary muss in Contents/MacOS/Fastra eines App-Bundles liegen." >&2
      return 2
      ;;
  esac
}
configure_soak_app || exit 2

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

# Nur vollständig gebundene Fixtures dürfen den Produktzustand umleiten.
# Die private Elternwurzel trägt zugleich Sandbox, Saved State und Belege.
configure_product_state_overrides() {
  local domain="${FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN:-}"
  local saved_state="${FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR:-}"
  if [ "$SOAK_RUNS_INSIDE_TEST_FIXTURE" -eq 0 ]; then
    if [ -n "${FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN+x}${FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR+x}" ]; then
      echo "SOAK: Testfixture braucht einen expliziten privaten Sandbox-Elternordner." >&2
      return 2
    fi
    return 0
  fi
  if [ -z "$domain" ] || [ -z "$saved_state" ]; then
    echo "SOAK: Testfixture ohne Umlenkung der echten Einstellungen; beide State-Overrides müssen gesetzt sein." >&2
    return 2
  fi
  case "$SOAK_FIXTURE_PARENT" in /*) ;; *)
    echo "SOAK: Unsicherer Fixture-Elternordner; absoluter privater Ordner nötig." >&2
    return 2 ;;
  esac
  if [ ! -d "$SOAK_FIXTURE_PARENT" ] || [ -L "$SOAK_FIXTURE_PARENT" ] \
     || [ "$(stat -f '%u' "$SOAK_FIXTURE_PARENT" 2>/dev/null || true)" != "$UID" ] \
     || [ "$(cd "$SOAK_FIXTURE_PARENT" 2>/dev/null && pwd -P)" != "$SOAK_FIXTURE_PARENT" ]; then
    echo "SOAK: Unsicherer Fixture-Elternordner; eigener echter kanonischer Ordner nötig." >&2
    return 2
  fi
  if ! fastra_test_defaults_domain_is_safe "$domain"; then
    echo "SOAK: Unsichere Einstellungs-Domain für die Umlenkung (Testpräfix und UUID nötig)." >&2
    return 2
  fi
  case "$saved_state" in /*) ;; *)
    echo "SOAK: Unsicherer Saved-State-Ordner; absoluter Pfad nötig." >&2
    return 2 ;;
  esac
  local saved_name="${saved_state##*/}"
  if [ -z "$saved_name" ] || [ "$saved_name" = . ] || [ "$saved_name" = .. ] \
     || [ "$saved_state" != "$SOAK_FIXTURE_PARENT/$saved_name" ]; then
    echo "SOAK: Unsicherer Saved-State-Ordner; direkt unter dem Fixture-Elternordner nötig." >&2
    return 2
  fi
  # Diese Namen bearbeitet das bestehende Pruning schon vor dem Snapshot.
  case "$saved_name" in fastra-soak-run.*|fastra-soak-befunde-*)
    echo "SOAK: Unsicherer Saved-State-Ordner; Name ist für Sandbox oder Belege reserviert." >&2
    return 2 ;;
  esac
  if { [ -e "$saved_state" ] || [ -L "$saved_state" ]; } \
     && { [ ! -d "$saved_state" ] || [ -L "$saved_state" ] \
          || [ "$(stat -f '%u' "$saved_state" 2>/dev/null || true)" != "$UID" ]; }; then
    echo "SOAK: Unsicherer Saved-State-Ordner; eigener echter Ordner nötig." >&2
    return 2
  fi
  SOAK_PRODUCT_DEFAULTS_DOMAIN="$domain"
  SOAK_SAVED_STATE_PARENT="$SOAK_FIXTURE_PARENT"
  SOAK_SAVED_STATE_DIR="$saved_state"
}

foreign_fastra_process_is_running() {
  # Vor Snapshot und Restore darf überhaupt keine Fastra-Instanz laufen.
  # Ein gleicher Binary-Pfad beweist kein Eigentum dieses Runners.
  pgrep -f '/[^/]+\.app/Contents/MacOS/Fastra([[:space:]]|$)' \
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
    # `defaults import` führt zusammen. Nur im Lauf neu entstandene Schlüssel
    # nach dem Import löschen. Nicht zuerst die gesamte Domain leeren, weil ein
    # Abbruch vor dem Import leere Einstellungen hinterließe.
    local added_key
    while IFS= read -r -d '' added_key; do
      /usr/bin/defaults delete "$SOAK_PRODUCT_DEFAULTS_DOMAIN" "$added_key" >/dev/null 2>&1 || return 2
    done < <(/usr/bin/defaults export "$SOAK_PRODUCT_DEFAULTS_DOMAIN" - 2>/dev/null \
      | /usr/bin/python3 -c 'import plistlib,sys
a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.loads(sys.stdin.buffer.read())
sys.stdout.write("".join(k+"\0" for k in b if k not in a))' "$SOAK_PRODUCT_DEFAULTS_BACKUP")
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

early_cleanup() {
  local original_status=$?
  trap ':' INT TERM
  local failed=0
  trap - EXIT
  if [[ "${FASTRA_TEST_PENDING_PID:-}" =~ ^[0-9]+$ ]]; then
    cleanup_soak_process "$FASTRA_TEST_PENDING_PID" || failed=1
  fi
  release_fastra_gui_test_lock || failed=1
  if [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 0 ]; then
    release_fastra_test_sandbox || failed=1
  else
    echo "SOAK: private Sandbox bleibt wegen ungeklärtem Prozessende erhalten:" >&2
    echo "  $FASTRA_TEST_SANDBOX" >&2
  fi
  if [ "$failed" -eq 1 ] && [ "$original_status" -eq 0 ]; then
    echo "SOAK: frühes Aufräumen blieb unvollständig." >&2
    exit 2
  fi
  [ "$failed" -eq 0 ] || echo "SOAK: frühes Aufräumen blieb zusätzlich unvollständig." >&2
  exit "$original_status"
}

configure_product_state_overrides || exit 2
prune_soak_evidence /tmp

create_fastra_test_sandbox soak-run || exit 2
# Unmittelbar nach dem erfolgreichen mktemp gehört die Sandbox dem Trap. So
# kann auch ein Signal zwischen Einrichtung und GUI-Sperre nichts hinterlassen.
trap early_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Sperre vor jedem Snapshot des echten Nutzerzustands. Ein abgewiesener
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
  # Ein weiteres Signal darf die Wiederherstellung nicht unterbrechen. Ein
  # gefangener Trap lässt Kindprozesse weiterhin auf ihr eigenes TERM reagieren.
  trap ':' INT TERM
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
      # Derselbe Helfer wie beim Phasenende: Nach fehlgeschlagenem Abbruch
      # nicht warten, sondern den Prozess für den Recovery-Pfad behalten.
      cleanup_soak_process "$cleanup_pid" || cleanup_failed=1
    done
  fi
  # Erst die Nachräumchance, dann die Wiederherstellungen. Vorher standen
  # `fastra_test_discard_pending_session` und `restore_soak_pasteboard` davor:
  # Scheiterte der erste `cleanup_soak_process` nur vorübergehend, setzte das
  # `SOAK_PROCESS_CLEANUP_BLOCKED`, beide Blöcke fielen aus — und
  # `retry_soak_cleanup_failures` räumte die Sperre gleich danach wieder ab.
  # Die Zwischenablage des Nutzers blieb dann mit Testinhalt überschrieben,
  # während die Sicherung mit der Sandbox gelöscht wurde. Die Blöcke dahinter
  # bekamen ihre zweite Chance seit jeher (Kommentar unten).
  if [ "${#SOAK_REMAINING_PIDS[@]}" -gt 0 ]; then
    retry_soak_cleanup_failures || cleanup_failed=1
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
  # Bei Befunden oder einem Absturz die Beweise erhalten: Protokoll und
  # Phasenausgaben (mit Exception-Text und Stacktrace) überleben das
  # Aufräumen. Nur die Logs — die kopierten echten Dokumente nicht.
  if [ "${KEEP_EVIDENCE:-0}" -eq 1 ] || [ "$cleanup_failed" -eq 1 ] \
     || [ "$original_status" -ne 0 ]; then
    local evidence evidence_parent=/tmp
    if [ "${SOAK_RUNS_INSIDE_TEST_FIXTURE:-0}" -eq 1 ]; then
      evidence_parent="$SOAK_FIXTURE_PARENT"
    fi
    evidence=$(mktemp -d "$evidence_parent/fastra-soak-befunde-$(date +%Y%m%d-%H%M%S).XXXXXX") \
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
      # Recovery-Backup und darf den Runner und die Belegrotation überleben.
      if [ "$recovery_backup_needed" -eq 1 ] \
         && [ -f "$SOAK_PRODUCT_DEFAULTS_BACKUP" ]; then
        cp -- "$SOAK_PRODUCT_DEFAULTS_BACKUP" "$evidence/" || evidence_saved=0
      fi
    fi
    if [ "$evidence_saved" -eq 1 ]; then
      echo "   Beweise gesichert: $evidence" >&2
      prune_soak_evidence /tmp
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
  # Erst nach Wiederherstellung von Prozessen, Defaults, Saved State,
  # Zwischenablage, GUI-Sperre und Sandbox darf der Lauf in die lokale
  # Performance-Historie eingehen.
  if [ "${SOAK_PERFORMANCE_RECORD_PENDING:-0}" -eq 1 ] \
     && [ "$cleanup_failed" -eq 0 ]; then
    SOAK_HEAD_END=$(git -C .. rev-parse HEAD 2>/dev/null || true)
    SOAK_BINARY_SHA_END=$(shasum -a 256 "$BINARY" | awk '{print $1}')
    SOAK_DIRTY_END=$(git -C .. status --porcelain 2>/dev/null || true)
    SOAK_QUALIFIED=""
    if soak_run_is_qualified; then
      SOAK_QUALIFIED="--qualified"
    fi
    SOAK_RECORDER_STATUS=0
    /usr/bin/python3 ./tools/selftest-performance.py record-soak \
      --profile "$SOAK_PROFILE" \
      --head "$SOAK_HEAD_START" \
      --binary-sha256 "$SOAK_BINARY_SHA_START" \
      --rounds "$ROUNDS" \
      --actions "$ACTIONS" \
      --wall-ms "$SOAK_WALL_MS" \
      ${SOAK_QUALIFIED:+--qualified} || SOAK_RECORDER_STATUS=$?
    if [ "$SOAK_RECORDER_STATUS" -ne 0 ] \
       && [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ]; then
      echo "SOAK: Umgebungsfehler — lokale Performance-Baseline konnte nicht gespeichert werden." >&2
      cleanup_failed=1
    fi
  elif [ "${SOAK_PERFORMANCE_RECORD_PENDING:-0}" -eq 1 ] \
       && [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ]; then
    echo "SOAK: Performance-Baseline wegen unvollständigem Cleanup nicht gespeichert." >&2
  fi
  trap - EXIT
  if [ "$cleanup_failed" -eq 1 ] && [ "$original_status" -eq 0 ]; then
    echo "SOAK: Umgebungsfehler — externe Testdaten konnten nicht vollständig wiederhergestellt werden." >&2
    exit 2
  elif [ "$cleanup_failed" -eq 1 ]; then
    echo "SOAK: Zusätzlich blieb das Aufräumen unvollständig." >&2
  fi
  exit "$original_status"
}

# Echte Dokumente kopieren: Tippen, Sichern und die RTFD-Umwandlung (deren
# Ergebnis neben der Quelle landet) dürfen die Originale nie berühren.
REAL_DIR="$WORK_DIR/real"
SOAK_RTFD_COPIED=0
SOAK_MD_COPIED=0
if [ -n "${FASTRA_SOAK_RTFD:-}" ] && [ -d "$FASTRA_SOAK_RTFD" ]; then
  mkdir -p "$REAL_DIR"
  if copy_fastra_test_directory_resolving_symlinks \
      "$FASTRA_SOAK_RTFD" "$REAL_DIR/protokoll-import.rtfd"; then
    SOAK_RTFD_COPIED=1
  else
    echo "⚠ RTFD konnte nicht sicher kopiert werden — Szenario wird ausgelassen." >&2
    rm -rf "$REAL_DIR/protokoll-import.rtfd"
  fi
fi
if [ -n "${FASTRA_SOAK_MD_DIR:-}" ] && [ -d "$FASTRA_SOAK_MD_DIR" ]; then
  mkdir -p "$REAL_DIR"
  if copy_fastra_test_directory_resolving_symlinks \
      "$FASTRA_SOAK_MD_DIR" "$REAL_DIR/markdown"; then
    SOAK_MD_COPIED=1
  else
    echo "⚠ Markdown-Ordner konnte nicht sicher kopiert werden — Szenario wird ausgelassen." >&2
    rm -rf "$REAL_DIR/markdown"
  fi
fi

# Das reale 4D-Projekt wird wie die übrigen echten Eingaben kopiert. Direkte
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
# Die größte echte Methode in der Kopie wählen. `lstat` weist verbleibende
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
# Abbruch des Runners selbst (SIGKILL/Systemausfall) zwischen Clipboard-Änderung
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
  # `-selftest soak` beendet die App selbst. Großzügig auf eigene
  # Schleifendurchläufe statt Wanduhrzeit begrenzen, damit fremde Last keine
  # regulär fortschreitende Phase abbricht.
  local timeout=$(( ROUNDS * 3 + 120 ))
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
    waited=$(( waited + 1 ))
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
  # Exit 2 ist Umgebung. Ein echter Befund dieser Phase behält auch dann
  # Vorrang. Fehlt der reguläre Bericht, bleibt die letzte Abschlusszeile als
  # synthetischer Eintrag mit der passenden Kategorie erhalten.
  if [ "$status" -ne 0 ]; then
    phase_failed=1
    KEEP_EVIDENCE=1
    local findings_after detail prefix=SOAK-BEFUND
    findings_after=$(grep -c '^SOAK-BEFUND' "$LOG" 2>/dev/null)
    findings_after=${findings_after:-0}
    if [ "$status" -eq 2 ] && [ "$findings_after" -eq "$findings_before" ]; then
      phase_failed=2
      prefix=SOAK-UMGEBUNG
    fi
    if [ "$findings_after" -eq "$findings_before" ] \
       && { [ "$prefix" = SOAK-BEFUND ] \
            || ! grep -q "^SOAK-UMGEBUNG phase=$phase " "$LOG"; }; then
      detail=$(grep '^SELFTEST ' "$WORK_DIR/phase-$phase.out" 2>/dev/null | tail -1)
      detail=${detail:-"Exit-Status $status ohne SELFTEST-Abschlusszeile"}
      printf '%s phase=%s aktion=? invariante=Phase endet kontrolliert detail=%s\n' \
        "$prefix" "$phase" "$detail" >> "$LOG"
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

run_counted_phase() {
  local status=0
  run_phase "$@" || status=$?
  case "$status" in
    0) ;;
    2) ENVIRONMENT_PHASES=$((ENVIRONMENT_PHASES + 1)) ;;
    *) PHASES_FAILED=$((PHASES_FAILED + 1)) ;;
  esac
}

PHASES_FAILED=0
ENVIRONMENT_PHASES=0
KEEP_EVIDENCE=0
run_counted_phase 1 "Dokumente anlegen, drei Fenster öffnen, arbeiten"
soak_followup_is_safe || exit 1
run_counted_phase 2 "nach Neustart: Sitzung prüfen und weiterarbeiten"
soak_followup_is_safe || exit 1
run_counted_phase 3 "nach zweitem Neustart: abschließende Runde"

echo
echo "────────────────────────────────────────────────────────────"
# `grep -c` zählt 0 und liefert Status 1 — ohne `|| true` bricht `set -e`-artiges
# Verhalten ab, und ein zusätzliches `echo 0` erzeugte hier eine zweite Zeile,
# an der der Vergleich unten scheiterte.
FINDINGS=$(grep -c "^SOAK-BEFUND" "$LOG" 2>/dev/null | head -1)
FINDINGS=${FINDINGS:-0}
ACTIONS=$(awk -F'aktionen=' '/^SOAK-ZUSAMMENFASSUNG/{split($2,a," "); s+=a[1]} END{print s+0}' "$LOG")

check_soak_result() {
  # Ein Lauf, dessen Phasen gar nicht durchliefen, darf nie grün melden. Der
  # erste Probelauf tat genau das: Alle drei Phasen brachen sofort ab, und das
  # Skript meldete trotzdem „SOAK OK". Ein Test, der bei kaputtem Aufbau Erfolg
  # meldet, ist schlimmer als keiner.
  if [ "$PHASES_FAILED" -gt 0 ]; then
    KEEP_EVIDENCE=1
    # Beide Zähler nennen: Ein gemischter Lauf (eine Phase FAIL, eine Phase
    # Umgebung) erreicht nur diesen Zweig. Mit „$PHASES_FAILED von 3" allein
    # las sich das, als seien die beiden anderen Phasen durchgelaufen — und
    # die Umgebungszeilen blieben unsichtbar, weil sie erst weiter unten
    # ausgegeben werden.
    incomplete=$((PHASES_FAILED + ENVIRONMENT_PHASES))
    echo "SOAK FAIL — $incomplete von 3 Phasen sind nicht durchgelaufen" \
         "($PHASES_FAILED Fehler, $ENVIRONMENT_PHASES Umgebung)." >&2
    echo "Ausgaben der Phasen:" >&2
    for phase in 1 2 3; do
      echo "  ── Phase $phase ──" >&2
      tail -3 "$WORK_DIR/phase-$phase.out" 2>/dev/null | sed 's/^/    /' >&2
    done
    if [ "$FINDINGS" -gt 0 ]; then
      echo "Befunde im Report-Log: $FINDINGS" >&2
      grep '^SOAK-BEFUND' "$LOG" | sed 's/^/  /' >&2
    fi
    if [ "$ENVIRONMENT_PHASES" -gt 0 ]; then
      grep '^SOAK-UMGEBUNG' "$LOG" | sed 's/^/  /' >&2
    fi
    return 1
  fi

  if [ "$FINDINGS" -gt 0 ]; then
    KEEP_EVIDENCE=1
    echo "SOAK FAIL — $FINDINGS Invarianten-Verstoß(e) bei $ACTIONS Aktionen:"
    echo
    grep "^SOAK-BEFUND" "$LOG" | sed 's/^/  /'
    echo
    echo "Jede Zeile nennt Phase, die AUSLÖSENDE Aktion und die verletzte"
    echo "Invariante. Bei Zustandsfehlern ist die Aktion die wichtigste Spur."
    return 1
  fi

  if [ "$ENVIRONMENT_PHASES" -gt 0 ]; then
    KEEP_EVIDENCE=1
    echo "SOAK ENV — $ENVIRONMENT_PHASES von 3 Phasen durch Umgebung unvollständig." >&2
    grep '^SOAK-UMGEBUNG' "$LOG" | sed 's/^/  /' >&2
    return 2
  fi

  # Ebenso wertlos: Alle Phasen laufen, aber es wurde nichts geprüft.
  if [ "$ACTIONS" -eq 0 ]; then
    KEEP_EVIDENCE=1
    echo "SOAK FAIL — kein einziger Prüfschritt ausgeführt. Der Testaufbau" >&2
    echo "greift nicht; ein grünes Ergebnis wäre hier bedeutungslos." >&2
    return 1
  fi

  return 0
}

check_soak_result
result=$?
[ "$result" -eq 0 ] || exit "$result"

SOAK_FINISHED_MS=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000')
SOAK_PROFILE="fixtures-only"
if [ "$FIXTURES_ONLY" -eq 0 ]; then
  SOAK_PROFILE="real-rtfd${SOAK_RTFD_COPIED}-md${SOAK_MD_COPIED}-4d${SOAK_4D_COPIED}"
fi
SOAK_WALL_MS="$((SOAK_FINISHED_MS - SOAK_STARTED_MS))"
SOAK_PERFORMANCE_RECORD_PENDING=1
echo "SOAK OK — $ACTIONS Aktionen, keine Invarianten-Verstöße."
exit 0
