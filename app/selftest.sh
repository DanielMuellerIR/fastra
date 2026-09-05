#!/bin/bash
#
# selftest.sh — Runner für die In-App-Selbsttests von Fastra.
#
# Kapselt die komplette Aufruf-Prozedur, die sich als nicht-trivial
# herausgestellt hat (Stand 2026-06-11):
#
#   1. Selbsttests werden über `-selftest <name>` (NSArgumentDomain) oder
#      die Umgebungsvariable FASTRA_SELFTEST angefordert — NIEMALS über
#      ein positionales `--selftest-…`-Argument. AppKit interpretiert
#      unbekannte positionale Argumente als „zu öffnende Datei", und
#      SwiftUI erzeugt dann NIE das Hauptfenster (Root Cause des
#      „kein Hauptfenster"-Bugs, siehe ../docs/BUILD-AND-TEST.md).
#   2. `-ApplePersistenceIgnoreState YES` verhindert den modalen
#      „Fenster wiederherstellen?"-Dialog nach einem abgebrochenen Lauf.
#   3. Bei gesperrtem Bildschirm sind Fenster-Tests nicht aussagekräftig —
#      der Runner prüft das vorab und lässt dann nur die ausdrücklich
#      fensterlos markierten Tests zu. Die ausgelassenen Tests werden als
#      übersprungen ausgewiesen und erzwingen Exit 2; ein unvollständiger
#      Lauf darf nie als bestanden gelten.
#   4. Nur `cmdw` und `completion4d` brauchen die externe Aktivierung über
#      LaunchServices und System Events. `newwindow`, `projectinput` und
#      `help` laufen mit echten Fenstern, aber garantiert ohne globale
#      Aktivierung im Hintergrund. Andere Direktstarts behalten vorerst ihr
#      bisheriges Aktivierungsverhalten. Arbeitet während eines extern
#      aktivierten Tests jemand am Mac, kann dessen App den Fokus zurückholen;
#      der Test meldet dann einen Umgebungsfehler und der Runner Exit-Code 2.
#
# Aufruf:
#   ./selftest.sh                 # alle Tests
#   ./selftest.sh findbar jump    # nur diese Tests
#
# Exit-Codes (maschinenlesbar für AI-Agenten / CI):
#   0 = alle gelaufenen Tests PASS
#   1 = mindestens ein ECHTER FAIL (Funktionsfehler)
#   2 = kein echter FAIL, aber mindestens ein Umgebungs-FAIL/SKIP
#
# Pro Test wertet der Runner `SELFTEST-RESULT v=1 …` aus und gibt zusätzlich
# die lesbare `SELFTEST <name>: …`-Zeile weiter. Alte Bundles ohne
# Maschinenzeile bleiben über den bisherigen Parser kompatibel.

set -u
umask 077

cd "$(dirname "$0")"

# Gemeinsame, worktreeübergreifende Sperre für Fensterläufe.
# shellcheck source=tools/gui-test-lock.sh
. ./tools/gui-test-lock.sh
# shellcheck source=tools/test-sandbox.sh
. ./tools/test-sandbox.sh
# shellcheck source=tools/test-process-tree.sh
. ./tools/test-process-tree.sh

if [[ "${1:-}" == "--performance-status" ]]; then
    /usr/bin/python3 ./tools/selftest-performance.py status \
        --repository "$(cd .. && pwd -P)"
    exit $?
fi

# Standardmäßig das frische Debug-Bundle prüfen. Der notarierte Installations-
# test kann beide Pfade ausdrücklich auf /Applications/Fastra.app setzen, ohne
# einen zweiten, abweichenden LaunchServices-Runner zu duplizieren.
APP_BIN="${FASTRA_SELFTEST_APP_BIN:-.build/debug/Fastra.app/Contents/MacOS/Fastra}"
APP_BUNDLE="${FASTRA_SELFTEST_APP_BUNDLE:-.build/debug/Fastra.app}"
OPEN_COMMAND="${FASTRA_TEST_OPEN_COMMAND:-/usr/bin/open}"
if [[ "$APP_BUNDLE" == /* ]]; then
    APP_BUNDLE_FOR_OPEN="$APP_BUNDLE"
else
    APP_BUNDLE_FOR_OPEN="$(pwd)/$APP_BUNDLE"
fi
# Explizite Sprache gilt nur für den Testprozess, nie für Nutzer-Einstellungen.
SELFTEST_LANGUAGE_ARGS=()
case "${FASTRA_SELFTEST_LANGUAGE:-}" in
    "") ;;
    de|en) SELFTEST_LANGUAGE_ARGS=(-AppleLanguages "($FASTRA_SELFTEST_LANGUAGE)") ;;
    *) echo "Selbsttest-Sprache muss de oder en sein." >&2; exit 2 ;;
esac

ALL_TESTS=(newwindow finderreopen welcomenew sessionrestore coldopen coldopenoff multisearch bgscroll findbar fields searchoptions projectinput tabswitch tabclosehit tabvisibility tabcompare softwrapprofiles softwrapmodes softwrapanchor selectionscroll selshort dragscroll dragnoscroll rightedge dirtyundo emojisplit emojipaste emojipreview tabscroll typescroll comment4d sighelp4d highlight highlight4d completion4d previewrender print xpath markdown markdownblanklines markdownjump markdownappearance mdimagewatch mdindent mddropcursor pasteindent jump ghosttext wordclick hscroll replaceall pilldrop navmatch textop joinundo colsel colselwrap colpaste gutterdim sidebarheader footerfit windowheight mdformat sidebarfilter sidebarstate tabflood githistory filediff macro4d macro4dengine tool4dhint tool4dlsp gototarget gototargetwin searchmark help mdassist search project localization updates git gitactions gitstagefolder gitpushbutton gitmultidiscard gitstickyheader diffwide markdownimport filemodes selsearch wildcard openscope loadperf contrast cmdw)
# `windows` bleibt als gezielter Diagnosemodus verfügbar, prüft aber keine
# Produktfunktion und startet deshalb nicht mehr in jedem Standardlauf.
# Fensterlose Tests — laufen auch bei gesperrtem Bildschirm aussagekräftig.
WINDOWLESS_TESTS=(search searchperf project projectperf localization markdownimport updates git gitactions filemodes selsearch wildcard openscope tool4dlsp macro4dengine)
# Nur diese Tests brauchen echten Vordergrundfokus. `newwindow`,
# `projectinput` und `help` bedienen ihre Fenster dagegen direkt im
# Testprozess und laufen wie `welcomenew` im Hintergrund.
FOCUS_REQUIRED_TESTS=(cmdw completion4d)
# Diese Fensterläufe sind so gebaut, dass sie ihre AppKit-Objekte direkt
# bedienen. Der Runner sperrt für sie auch produktive Aktivierungshelfer,
# damit sie die gerade benutzte App nicht verdrängen.
BACKGROUND_ACTIVATION_BLOCKED_TESTS=(newwindow finderreopen welcomenew projectinput help aboutshot)
# Weitere Namen ohne App-Aktivierung kann der Aufrufer per Umgebungsvariable
# nachreichen, etwa für einen Lauf neben einem arbeitenden Nutzer:
#   FASTRA_SELFTEST_NO_ACTIVATION="tabflood sessionrestore" ./selftest.sh tabflood
# Gilt nur für direkt gestartete Tests; `FOCUS_REQUIRED_TESTS` brauchen die
# Aktivierung und ignorieren die Liste. Ein Test, der ohne Aktivierung
# nicht auskommt, meldet dann einen Umgebungsfehler statt eines Erfolgs.
if [[ -n "${FASTRA_SELFTEST_NO_ACTIVATION:-}" ]]; then
    read -r -a extra_no_activation_tests <<< "$FASTRA_SELFTEST_NO_ACTIVATION"
    BACKGROUND_ACTIVATION_BLOCKED_TESTS+=("${extra_no_activation_tests[@]}")
fi
# Diese Tests starten das konfigurierte App-Bundle über LaunchServices. Für sie
# reicht ein vorhandenes separates Binary nicht: Der Bundle-Pfad muss ebenfalls
# auf genau diesen Teststand zeigen.
LAUNCH_SERVICES_TESTS=(coldopen coldopenoff "${FOCUS_REQUIRED_TESTS[@]}")

array_contains_exactly() {
    local needle="$1"
    local candidate=""
    shift
    for candidate in "$@"; do
        [ "$candidate" = "$needle" ] && return 0
    done
    return 1
}

emit_selftest_result() {
    printf 'SELFTEST-RESULT v=1 test=%s status=%s\n' "$1" "$2"
}

emit_locked_screen_skip() {
    emit_selftest_result "$1" "SKIP"
    echo "SELFTEST $1: SKIP — Bildschirm gesperrt (Umgebungsproblem)"
}

# Pro Test max. Wartezeit in Sekunden, bis die SELFTEST-Zeile da sein muss.
# (Fenster-Polling im Test selbst: bis 15 s; plus Puffer für App-Start.)
TIMEOUT_SECS=60
# Der print-Test druckt seriell sieben PDFs und wartet auf WebKit-Rendern,
# Hex-Abschnitt und zwei Blätter; seine internen Einzelfristen summieren sich
# auf weit über 60 s. Ein unter Last korrekt fortschreitender Lauf darf vom
# Runner nicht als Funktionsfehler beendet werden (Reviewfund 2026-08-18).
# Echte Hänger laufen weiterhin in diese Frist.
timeout_for_test() {
    case "$1" in
        print) echo 240 ;;
        cmdw)  echo 120 ;;
        *)     echo "$TIMEOUT_SECS" ;;
    esac
}
# Harte Schranke je System-Events-Aufruf. Ein erlaubter Aufruf antwortet in
# Millisekunden; wartet er länger, fehlt die Automation-Freigabe (s.
# activate_app).
ACTIVATE_TIMEOUT_SECS=4

# ── Vorbedingungen ───────────────────────────────────────────────────────

# Zu laufende Tests schon vor der Pfadprüfung bestimmen. Nur dann kann der
# Runner unterscheiden, ob der angeforderte Lauf LaunchServices benötigt.
STANDARD_RUN=0
if [[ $# -gt 0 ]]; then
    TESTS=("$@")
else
    STANDARD_RUN=1
    TESTS=("${ALL_TESTS[@]}")
fi
if [[ ! -x "$APP_BIN" ]]; then
    echo "✗ Kein Debug-Build gefunden ($APP_BIN). Erst ./build.sh laufen lassen." >&2
    exit 2
fi

NEEDS_APP_BUNDLE=0
for requested_test in "${TESTS[@]}"; do
    for launch_services_test in "${LAUNCH_SERVICES_TESTS[@]}"; do
        [[ "$requested_test" == "$launch_services_test" ]] && NEEDS_APP_BUNDLE=1
    done
done
if [[ $NEEDS_APP_BUNDLE -eq 1 ]]; then
    if [[ ! -d "$APP_BUNDLE_FOR_OPEN" || \
          ! -x "$APP_BUNDLE_FOR_OPEN/Contents/MacOS/Fastra" ]]; then
        echo "✗ LaunchServices-Test verlangt ein gültiges Fastra-Bundle ($APP_BUNDLE_FOR_OPEN)." >&2
        exit 2
    fi
fi

# Für Prozessabgleich und Direktstarts immer denselben kanonischen Pfad dieses
# konfigurierten Bundles verwenden. So kann der Aufräumpfad keine installierte
# Fastra-App oder einen Build aus einem anderen Worktree treffen.
absolute_executable_path() {
    local path="$1"
    local directory
    directory="$(dirname "$path")"
    if [[ "$directory" != /* ]]; then
        directory="$(pwd)/$directory"
    fi
    (cd "$directory" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

escape_process_pattern() {
    printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

APP_BIN_ABSOLUTE="$(absolute_executable_path "$APP_BIN")"
APP_BIN_BUNDLE_CANONICAL=""
case "$APP_BIN_ABSOLUTE" in
    */Contents/MacOS/Fastra)
        APP_BIN_BUNDLE_CANONICAL="$(dirname "$(dirname "$(dirname "$APP_BIN_ABSOLUTE")")")"
        ;;
esac
if [[ -x "$APP_BUNDLE_FOR_OPEN/Contents/MacOS/Fastra" ]]; then
    APP_BUNDLE_BIN_ABSOLUTE="$(absolute_executable_path "$APP_BUNDLE_FOR_OPEN/Contents/MacOS/Fastra")"
    APP_BUNDLE_CANONICAL="$(dirname "$(dirname "$(dirname "$APP_BUNDLE_BIN_ABSOLUTE")")")"
    APP_BUNDLE_FOR_OPEN="$APP_BUNDLE_CANONICAL"
else
    APP_BUNDLE_BIN_ABSOLUTE="$APP_BIN_ABSOLUTE"
    APP_BUNDLE_CANONICAL=""
fi
APP_PROCESS_PATTERNS=("^$(escape_process_pattern "$APP_BIN_ABSOLUTE")([[:space:]]|$)")
if [[ "$APP_BUNDLE_BIN_ABSOLUTE" != "$APP_BIN_ABSOLUTE" ]]; then
    APP_PROCESS_PATTERNS+=("^$(escape_process_pattern "$APP_BUNDLE_BIN_ABSOLUTE")([[:space:]]|$)")
fi
STARTED_PIDS=()
STARTED_PID_TOKENS=()
STARTED_APP_BUNDLES=()
CURRENT_TEST_NAME=""
# Der System-Events-Helfer ist ein eigenes Kind des Runners. Ein Signal darf
# ihn nicht nach dem Runner-Abbruch weiterlaufen und später noch den Fokus
# ändern lassen. PID und Startzeit-Token bleiben deshalb bis zum `wait`
# sichtbar für beide Cleanup-Traps.
ACTIVATION_PID=""
ACTIVATION_PID_TOKEN=""
ACTIVATION_STARTING=0
TRACKED_PID_BOOKING=0
RUNNER_DEFERRED_SIGNAL=""

# Gesperrter Bildschirm? Dann sind alle fensterbasierten Tests Umgebungs-
# rauschen (siehe ../docs/BUILD-AND-TEST.md, Umgebungs-Falle 2). Nur `search` ist dann
# aussagekräftig (fensterlos).
console_locked() {
    # Rein technische Runner-Integrationstests dürfen nicht vom zufälligen
    # Sperrstatus des Test-Macs abhängen. Produktläufe setzen diesen Hook nie.
    [ "${FASTRA_SELFTEST_TEST_CONSOLE_LOCKED:-0}" = "1" ] && return 0
    [ "${FASTRA_SELFTEST_TEST_CONSOLE_UNLOCKED:-0}" = "1" ] && return 1
    ioreg -n Root -d1 2>/dev/null | grep -q '"IOConsoleLocked" = Yes'
}

# Ausgelassene Tests werden weiter unten als Umgebungs-Skips gezählt. Das Array
# muss auch im Normalfall existieren: Unter `set -u` ist eine nie zugewiesene
# Variable ein Fehler.
SKIPPED_TESTS=()

if console_locked; then
    echo "⚠ Bildschirm ist gesperrt — Fenster-Selbsttests sind nicht aussagekräftig."
    FILTERED=()
    for t in "${TESTS[@]}"; do
        is_windowless=0
        for w in "${WINDOWLESS_TESTS[@]}"; do
            [[ "$t" == "$w" ]] && is_windowless=1
        done
        if [[ $is_windowless -eq 1 ]]; then
            FILTERED+=("$t")
        else
            # Jeder herausgefilterte Test ist ein ausgelassener Test und muss
            # als solcher gezählt werden. Ohne diese Buchhaltung endete ein
            # Lauf, der fast alles übersprungen hat, mit Exit 0 und galt
            # maschinenlesbar als vollständig bestanden.
            SKIPPED_TESTS+=("$t")
        fi
    done
    # Der Runner-Test stellt hier den Gegenfall ohne ausgelassene Tests her.
    # So prüft er gezielt die leere Skip-Liste unter macOS-bash 3.2.
    if [[ "${FASTRA_SELFTEST_TEST_EMPTY_SKIPPED:-0}" == "1" ]]; then
        FILTERED=()
        SKIPPED_TESTS=()
    fi
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        echo "  Keiner der angeforderten Tests ist fensterlos. Abbruch (Exit 2)."
        if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
            for t in "${SKIPPED_TESTS[@]}"; do
                emit_locked_screen_skip "$t"
            done
        fi
        exit 2
    fi
    echo "  Es läuft nur: ${FILTERED[*]}"
    TESTS=("${FILTERED[@]}")
fi

# Auch fensterlose Selbsttests starten dasselbe App-Binary und teilen dessen
# Aufräumpfad. Deshalb serialisiert die maschinenweite Sperre alle Runner;
# `swift test` bleibt davon unabhängig und kann weiter parallel arbeiten.
NEEDS_GUI_LOCK=1

# ── Hilfsfunktionen ──────────────────────────────────────────────────────

# Eine vom Runner direkt gestartete PID merken. LaunchServices gibt die App-PID
# nicht zurück; solche Starts werden ergänzend über den exakten Bundle-Pfad
# gefunden.
track_started_pid() {
    local pid="$1"
    local token index=0
    token="$(fastra_test_pid_token "$pid")"
    # `fastra_test_start_new_session` hat die Identität bereits vor dem
    # Freigeben des Handshakes gesichert. Ein sehr kurzes Ersatz-Binary kann
    # danach enden, bevor dieser zweite Aufruf von `ps` läuft. Dann die schon
    # gebundene Identität übernehmen; eine später wiederverwendete PID passt
    # wegen des alten Starttokens weiterhin nicht.
    if [ -z "$token" ]; then
        while [ "$index" -lt "${#FASTRA_TEST_STARTED_ROOTS[@]}" ]; do
            if [ "${FASTRA_TEST_STARTED_ROOTS[$index]}" = "$pid" ]; then
                token="${FASTRA_TEST_STARTED_TOKENS[$index]}"
                break
            fi
            index=$((index + 1))
        done
    fi
    [ -n "$token" ] || return 1
    append_tracked_pid "$pid" "$token"
}

# PID und Startzeit liegen aus Bash-3.2-Kompatibilitätsgründen in parallelen
# Arrays. Ein Signal darf den Runner nie zwischen beiden Anhängen beobachten:
# Der Trap merkt es während dieser Paarbuchung vor und räumt erst danach auf.
append_tracked_pid() {
    local pid="$1"
    local token="$2"
    local remember_group="${3:-0}"
    TRACKED_PID_BOOKING=1
    STARTED_PIDS+=("$pid")
    if [ -n "${FASTRA_TEST_TRACKED_PID_PRETOKEN_HOOK:-}" ]; then
        "$FASTRA_TEST_TRACKED_PID_PRETOKEN_HOOK" "$pid"
    fi
    STARTED_PID_TOKENS+=("$token")
    # LaunchServices kann zwischen PID-Buchung und Prozessgruppen-Erfassung ein
    # Signal liefern. Die Gruppe gehört deshalb noch zur selben atomaren
    # Buchung: Erst wenn auch sie feststeht, darf der vorgemerkte Cleanup laufen.
    if [ "$remember_group" -eq 1 ]; then
        fastra_test_root_was_started_by_runner "$pid" \
            || fastra_test_remember_process_group "$pid" \
            || true
    fi
    TRACKED_PID_BOOKING=0
    run_deferred_runner_signal
}

# Eine gemerkte PID gehört nur so lange diesem Lauf, wie auch ihre beim
# Erfassen gespeicherte Startzeit übereinstimmt. Der Binary-Pfad allein reicht
# nach einer PID-Wiederverwendung nicht als Besitzbeleg.
tracked_pid_is_owned() {
    local pid="$1"
    local index="$2"
    local token="${STARTED_PID_TOKENS[$index]:-}"
    [ -n "$token" ] && fastra_test_pid_matches_token "$pid" "$token"
}

# Ein Testprozess kann enden, nachdem er einen Kindprozess in seiner eigenen
# Prozessgruppe gestartet hat. Die Root-PID ist dann nicht mehr live, die beim
# Start gebundene Gruppe gehört aber weiterhin diesem Runner. Ohne diesen
# zweiten Besitzbeleg würde `kill_leftovers` die Root aus seiner Zielliste
# entfernen, bevor der Prozessbaum-Helfer die verwaisten Kinder erreicht.
tracked_process_tree_is_owned() {
    local pid="$1"
    local index="$2"
    local started_index=0
    local group=""
    if tracked_pid_is_owned "$pid" "$index" \
       && { pid_matches_configured_bundle "$pid" \
            || fastra_test_root_was_started_by_runner "$pid"; }; then
        return 0
    fi
    while [ "$started_index" -lt "${#FASTRA_TEST_STARTED_ROOTS[@]}" ]; do
        if [ "${FASTRA_TEST_STARTED_ROOTS[$started_index]}" = "$pid" ]; then
            group="${FASTRA_TEST_STARTED_GROUPS[$started_index]}"
            [ -n "$group" ] \
                && fastra_test_started_group_is_owned "$group" \
                && return 0
        fi
        started_index=$((started_index + 1))
    done
    return 1
}

# LaunchServices nur für Bundles aufräumen, die dieser Runner nachweislich
# gestartet hat. Direktstarts können absichtlich aus einem anderen Bundle als
# APP_BUNDLE stammen; deshalb wird der Pfad aus dem echten Executable gewonnen.
track_started_app_bundle() {
    local bundle="$1"
    local existing
    [ -n "$bundle" ] || return 0
    if [ "${#STARTED_APP_BUNDLES[@]}" -gt 0 ]; then
        for existing in "${STARTED_APP_BUNDLES[@]}"; do
            [ "$existing" = "$bundle" ] && return 0
        done
    fi
    STARTED_APP_BUNDLES+=("$bundle")
}

track_started_app_bundle_for_executable() {
    local executable="$1"
    case "$executable" in
        */Contents/MacOS/Fastra)
            track_started_app_bundle \
                "$(dirname "$(dirname "$(dirname "$executable")")")"
            ;;
    esac
}

remember_bundle_pids() {
    local pattern pid command existing already_tracked token
    for pattern in "${APP_PROCESS_PATTERNS[@]}"; do
        while IFS= read -r pid; do
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                # LaunchServices nennt die PID nicht. Deshalb nur den Prozess
                # erfassen, dessen Argumente beziehungsweise Umgebung genau
                # den aktuellen Selbsttest nennen. Ein Nutzer darf denselben
                # Debug-Build parallel manuell starten, ohne dass der Runner
                # ihn später als vermeintlichen Restprozess beendet.
                command=$(ps eww -p "$pid" -o command= 2>/dev/null || true)
                fastra_test_command_names_selftest \
                    "$command" "$CURRENT_TEST_NAME" || continue
                # Ein Signal kann direkt nach einem erfolgreichen `open`,
                # aber noch vor dessen normaler Nachbuchhaltung eintreffen.
                # Der exakte Bundle- und Testprozess ist der belastbare Beleg,
                # dass dieser Runner die spätere LS-Abmeldung besitzen darf.
                [ "${CURRENT_LAUNCH_MODE:-direct}" = "launchservices" ] \
                    && track_started_app_bundle "$APP_BUNDLE_CANONICAL"
                already_tracked=0
                if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
                    for existing in "${STARTED_PIDS[@]}"; do
                        [ "$existing" = "$pid" ] && already_tracked=1
                    done
                fi
                [ "$already_tracked" -eq 0 ] || continue
                token="$(fastra_test_pid_token "$pid")"
                [ -n "$token" ] || continue
                append_tracked_pid "$pid" "$token" 1
            fi
        done < <(pgrep -f "$pattern" 2>/dev/null || true)
    done
}

# Zuerst nur die selbst gestarteten PIDs beenden. Der Restabgleich ist bewusst
# auf den absoluten Binary-Pfad des konfigurierten Bundles beschränkt; das alte
# globale `Fastra.app/...`-Muster gefährdete andere Worktrees und Nutzerarbeit.
pid_matches_configured_bundle() {
    local pid="$1"
    local command pattern
    command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    for pattern in "${APP_PROCESS_PATTERNS[@]}"; do
        [[ "$command" =~ $pattern ]] && return 0
    done
    return 1
}

kill_leftovers() {
    local launch_scan_ticks="${1:-2}"
    local pid scan found index
    local app_targets=()
    # LaunchServices liefert die PID nicht atomar mit `open`. Ein Signal kann
    # deshalb zwischen dem Start und dem ersten normalen Ergebnis-Poll
    # eintreffen. Unmittelbar vor jedem Cleanup noch einmal testgenau nach dem
    # aktuellen Bundle und -selftest-Namen suchen und den Starttoken merken.
    if [ "${CURRENT_LAUNCH_MODE:-direct}" = "launchservices" ]; then
        scan=0
        while [ "$scan" -lt "$launch_scan_ticks" ]; do
            remember_bundle_pids
            found=0
            if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
                index=0
                while [ "$index" -lt "${#STARTED_PIDS[@]}" ]; do
                    pid="${STARTED_PIDS[$index]}"
                    if tracked_process_tree_is_owned "$pid" "$index"; then
                        found=1
                        break
                    fi
                    index=$((index + 1))
                done
            fi
            [ "$found" -eq 1 ] && break
            sleep 0.1
            scan=$((scan + 1))
        done
    fi
    # macOS liefert bash 3.2: Dort gilt ein LEERES Array unter `set -u` bei
    # `"${arr[@]}"` als unbound. Die Längenabfrage umgeht das gefahrlos.
    if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
        index=0
        while [ "$index" -lt "${#STARTED_PIDS[@]}" ]; do
            pid="${STARTED_PIDS[$index]}"
            # Zwischen Ergebniszeile und Cleanup kann die App bereits enden
            # und macOS die Nummer neu vergeben. Vor dem Signal deshalb den
            # Starttoken und Prozesspfad beziehungsweise die beim Start
            # gebundene, noch lebende Prozessgruppe erneut prüfen. So bleibt
            # ein Kind erreichbar, dessen Gruppenleiter bereits geendet hat.
            if tracked_process_tree_is_owned "$pid" "$index"; then
                app_targets+=("$pid")
            fi
            index=$((index + 1))
        done
    fi
    local had_pending=0
    if [[ "${FASTRA_TEST_PENDING_PID:-}" =~ ^[0-9]+$ ]]; then
        had_pending=1
        if fastra_test_pending_start_was_released \
           && [ -n "${FASTRA_TEST_PENDING_BUNDLE:-}" ]; then
            track_started_app_bundle "$FASTRA_TEST_PENDING_BUNDLE"
        fi
        app_targets+=("$FASTRA_TEST_PENDING_PID")
    fi
    if [ "${#app_targets[@]}" -eq 0 ]; then
        STARTED_PIDS=()
        STARTED_PID_TOKENS=()
        return 0
    fi
    if ! terminate_fastra_test_process_trees "${app_targets[@]}"; then
        echo "✗ Der vorherige Fastra-Testprozess oder ein Kindprozess ließ sich nicht beenden." >&2
        return 1
    fi
    for pid in "${app_targets[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    if [ "$had_pending" -eq 1 ]; then
        fastra_test_discard_pending_session || return 1
    fi
    STARTED_PIDS=()
    STARTED_PID_TOKENS=()
}

# Wartet, bis die SELFTEST-Zeile in $1 auftaucht oder das Timeout reißt.
# $2: Frist in Sekunden (Standard: TIMEOUT_SECS; siehe timeout_for_test).
# Rückgabe: 0 = Ergebnis da; 1 = Timeout; 3 = der direkt gestartete
# Testprozess endete vorzeitig ohne Ergebnis-Zeile — sein Exit-Code steht
# dann in WAIT_FOR_RESULT_EXIT; 4 = der zuvor exakt erfasste
# LaunchServices-Prozess endete vorzeitig. Dessen Exit-Code kann der Runner
# nicht abfragen, weil `open` statt des App-Prozesses sein Kind ist.
WAIT_FOR_RESULT_EXIT=""
wait_for_result() {
    local errfile="$1"
    local timeout_secs="${2:-$TIMEOUT_SECS}"
    local waited_ticks=0
    local max_ticks=$((timeout_secs * 10))
    WAIT_FOR_RESULT_EXIT=""
    while [[ $waited_ticks -lt $max_ticks ]]; do
        if [ "${CURRENT_LAUNCH_MODE:-direct}" = "launchservices" ] \
           && [ "${#STARTED_PIDS[@]}" -eq 0 ]; then
            remember_bundle_pids
        fi
        if grep -q '^SELFTEST ' "$errfile" 2>/dev/null; then
            return 0
        fi
        if [ "${CURRENT_LAUNCH_MODE:-direct}" = "launchservices" ] \
           && [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
            local launch_pid launch_is_live=0 launch_index=0
            while [ "$launch_index" -lt "${#STARTED_PIDS[@]}" ]; do
                launch_pid="${STARTED_PIDS[$launch_index]}"
                if tracked_pid_is_owned "$launch_pid" "$launch_index" \
                   && fastra_test_pid_is_live "$launch_pid" \
                   && { pid_matches_configured_bundle "$launch_pid" \
                        || fastra_test_root_was_started_by_runner "$launch_pid"; }; then
                    launch_is_live=1
                    break
                fi
                launch_index=$((launch_index + 1))
            done
            if [ "$launch_is_live" -eq 0 ]; then
                # Die App schreibt Maschinen- und Begleitzeile in einem
                # gemeinsamen Block. Trotzdem nach dem beobachteten Ende ein
                # letztes Mal lesen, bevor der Prozessabbruch gewinnt.
                if grep -q '^SELFTEST ' "$errfile" 2>/dev/null; then
                    return 0
                fi
                return 4
            fi
        fi
        # Ein direkt gestarteter Testprozess ist unser eigenes Kind: Bis zum
        # `wait` bleibt er als Zombie stehen, seine PID kann also nicht neu
        # vergeben werden — die Prüfung fasst nie einen fremden Prozess an.
        # Ist er beendet, ohne eine Ergebnis-Zeile zu schreiben (Absturz,
        # Signal, früher exit), wäre jedes weitere Warten blind: Die volle
        # Frist käme als irreführender „Runner-Timeout" zurück — beim
        # print-Test vier Minuten (Reviewfund 2026-08-19). Stattdessen wird
        # der Exit-Code sofort eingesammelt und getrennt gemeldet.
        if [ "${CURRENT_LAUNCH_MODE:-direct}" = "direct" ] \
           && [ -n "${FASTRA_TEST_STARTED_PID:-}" ] \
           && ! fastra_test_pid_is_live "$FASTRA_TEST_STARTED_PID"; then
            # Die Ergebnis-Zeile kann unmittelbar vor dem Prozessende noch
            # geschrieben worden sein — einmal nachlesen, bevor der Tod zählt.
            if grep -q '^SELFTEST ' "$errfile" 2>/dev/null; then
                return 0
            fi
            wait "$FASTRA_TEST_STARTED_PID" 2>/dev/null
            WAIT_FOR_RESULT_EXIT=$?
            return 3
        fi
        sleep 0.1
        waited_ticks=$((waited_ticks + 1))
    done
    return 1
}

now_milliseconds() {
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

activation_process_is_owned() {
    local pid="$1"
    local token="$2"
    local parent=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [ -n "$token" ]; then
        fastra_test_pid_matches_token "$pid" "$token"
        return $?
    fi
    # Direkt nach dem Fork kann `ps` den Startzeit-Token noch nicht liefern.
    # Bis zum `wait` kann die Kind-PID nicht wiederverwendet werden; in diesem
    # kurzen Fenster ist die unveränderte Eltern-PID deshalb der sichere Beleg.
    parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
    [ "$parent" = "$$" ]
}

clear_activation_process() {
    ACTIVATION_PID=""
    ACTIVATION_PID_TOKEN=""
}

# Bash stellt ein Signal zwischen dem Fork eines Hintergrundprozesses und der
# folgenden `$!`-Zuweisung zu. In diesem winzigen Fenster ist der Helfer noch
# nicht in den Cleanup-Globals gebucht. Der Trap merkt das Signal deshalb vor
# und lässt `activate_once` erst PID und Starttoken übernehmen; unmittelbar
# danach läuft der normale Signal-Cleanup.
run_deferred_runner_signal() {
    local signal="${RUNNER_DEFERRED_SIGNAL:-}"
    if [ -n "$signal" ] \
       && [ "${ACTIVATION_STARTING:-0}" -eq 0 ] \
       && [ "${TRACKED_PID_BOOKING:-0}" -eq 0 ]; then
        RUNNER_DEFERRED_SIGNAL=""
        cleanup_on_signal "$signal"
    fi
}

handle_runner_signal() {
    local signal="$1"
    if [ "${ACTIVATION_STARTING:-0}" -eq 1 ] \
       || [ "${TRACKED_PID_BOOKING:-0}" -eq 1 ]; then
        RUNNER_DEFERRED_SIGNAL="$signal"
        return 0
    fi
    cleanup_on_signal "$signal"
}

terminate_activation_process() {
    local pid="${ACTIVATION_PID:-}"
    local token="${ACTIVATION_PID_TOKEN:-}"
    local tick=0
    [ -n "$pid" ] || return 0
    if ! activation_process_is_owned "$pid" "$token"; then
        # Ein bereits beendetes eigenes Kind nur noch einsammeln. Eine lebende
        # PID mit abweichender Identität gehört dagegen nicht mehr dem Runner.
        if ! fastra_test_pid_is_live "$pid"; then
            wait "$pid" 2>/dev/null || true
            clear_activation_process
            return 0
        fi
        echo "✗ Aktivierungsprozess hat eine fremde PID-Identität; kein Signal gesendet." >&2
        clear_activation_process
        return 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$tick" -lt 20 ] \
          && fastra_test_pid_is_live "$pid" \
          && activation_process_is_owned "$pid" "$token"; do
        sleep 0.05
        tick=$((tick + 1))
    done
    if fastra_test_pid_is_live "$pid" \
       && activation_process_is_owned "$pid" "$token"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    if fastra_test_pid_is_live "$pid" \
       && activation_process_is_owned "$pid" "$token"; then
        clear_activation_process
        return 1
    fi
    clear_activation_process
}

# Ein einzelner System-Events-Versuch mit harter Wanduhr-Schranke.
#
# Ohne Automation-Freigabe (typisch in einer ssh-Sitzung oder einem
# launchd-Job) wartet der Apple-Event UNBEGRENZT auf den TCC-Dialog, den dort
# niemand wegklickt — der Runner hing dadurch minutenlang, statt einen
# Umgebungs-FAIL zu melden (Befund 2026-07-26). Zwei Schranken, weil eine
# nicht genügt: `with timeout` deckt den regulären Apple-Event-Ablauf ab
# (Fehler -1712), der Kill danach jeden Fall, in dem der Aufruf schon vor dem
# Senden in der Autorisierung feststeckt.
#
# Angesprochen wird der Prozess über seine Unix-PID ($1), nicht über den Namen
# „Fastra": Der Aufräumpfad lässt andere Fastra-Builds (installierte App,
# anderer Worktree) bewusst laufen, und `first process whose name is "Fastra"`
# hätte davon einen beliebigen nach vorn geholt — der Test hätte dann ein
# fremdes Fenster aktiviert, dem Nutzer den Fokus gestohlen und anschließend
# einen irreführenden Umgebungsfehler gemeldet.
#
# Rückgabe: 0 = App ist vorn, 1 = regulär fehlgeschlagen (erneut versuchen
# sinnvoll), 2 = keine Antwort in der Frist (Freigabe fehlt, Aufgeben).
activate_once() {
    local target_pid="$1"
    local pid=""
    ACTIVATION_STARTING=1
    osascript -e 'with timeout of 3 seconds' \
              -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $target_pid) to true" \
              -e 'end timeout' >/dev/null 2>&1 &
    pid=$!
    # Der Hook liegt absichtlich nach dem Fork, aber vor der globalen
    # PID-Buchung. Nur der Integrationstest setzt ihn, um das Signalrennen
    # deterministisch statt per Zufall zu treffen.
    if [ -n "${FASTRA_TEST_ACTIVATION_PREBOOK_HOOK:-}" ]; then
        "$FASTRA_TEST_ACTIVATION_PREBOOK_HOOK" "$pid"
    fi
    ACTIVATION_PID="$pid"
    ACTIVATION_PID_TOKEN="$(fastra_test_pid_token "$ACTIVATION_PID")"
    ACTIVATION_STARTING=0
    run_deferred_runner_signal
    local waited=0
    local status=0
    while [[ $waited -lt $ACTIVATE_TIMEOUT_SECS ]]; do
        if ! fastra_test_pid_is_live "$pid"; then
            wait "$pid"
            status=$?
            clear_activation_process
            return "$status"
        fi
        sleep 1
        waited=$((waited + 1))
    done
    terminate_activation_process || true
    return 2
}

# PID des in dieser Runde gestarteten Test-Bundles: die zuletzt erfasste.
# `kill_leftovers` leert die Liste zu Beginn jeder Runde, es kann also nur ein
# Prozess dieser Runde darin stehen.
current_app_pid() {
    if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
        local index=$((${#STARTED_PIDS[@]} - 1))
        local pid="${STARTED_PIDS[$index]}"
        tracked_pid_is_owned "$pid" "$index" && printf '%s\n' "$pid"
    fi
}

# Holt die per `open` gestartete Test-App nach vorn (für Tests, die echten
# Fenster-Fokus brauchen). Mehrere Versuche, weil LaunchServices die App erst
# nach kurzer Zeit als Prozess anlegt — die PID wird deshalb in der Schleife
# nachgeholt. Best effort: bei aktiv benutztem Desktop gewinnt der
# Nutzer-Fokus trotzdem.
activate_app() {
    local errfile="$1"
    local target_pid=""
    for _ in 1 2 3 4 5 6 7 8; do
        # Schnelle Fehler oder Ergebnisse können schon während des
        # LaunchServices-Starts vorliegen. Dann darf der Runner weder weiter
        # warten noch den Fokus nachträglich anfordern.
        if grep -q '^SELFTEST ' "$errfile" 2>/dev/null; then
            return 0
        fi
        if [[ ! "$target_pid" =~ ^[0-9]+$ ]]; then
            remember_bundle_pids
            target_pid="$(current_app_pid)"
        fi
        if [[ ! "$target_pid" =~ ^[0-9]+$ ]]; then
            # Prozess noch nicht da — erst LaunchServices Zeit geben, dann
            # erneut nachsehen. Ohne diese Pause liefen alle Versuche durch,
            # bevor der Prozess überhaupt entstehen konnte.
            sleep 1
            continue
        fi
        activate_once "$target_pid"
        case $? in
            0) return 0 ;;
            2)
                # Keine Antwort heißt fehlende Freigabe, nicht „Fenster noch
                # nicht da": weitere Versuche liefen nur erneut in die Frist.
                # LaunchServices hat die App beim `open` schon selbst nach vorn
                # geholt; auf einem unbenutzten Mac genügt das. Fehlt der Fokus
                # wirklich, meldet der Test selbst einen Umgebungs-FAIL.
                echo "  (System Events antwortet nicht — Automation-Freigabe fehlt;" \
                     "Aktivierung bleibt bei LaunchServices)" >&2
                return 1
                ;;
        esac
        # Nur ein noch nicht auffindbarer Prozess oder ein regulär
        # fehlgeschlagener Aktivierungsversuch braucht eine Pause. Die schon
        # vor dem Aufruf gemerkte PID darf sofort aktiviert werden.
        sleep 1
    done
    if [[ ! "$target_pid" =~ ^[0-9]+$ ]]; then
        echo "  (Test-Bundle ist nicht als Prozess auffindbar — Aktivierung" \
             "bleibt bei LaunchServices)" >&2
    fi
    return 1
}

# Der echte LaunchServices-Kaltstart braucht eine schon vor dem App-Start
# vorhandene Datei. Nur dieses exakt bekannte mktemp-Verzeichnis wird danach
# aufgeräumt; kein breiter oder unaufgelöster Löschpfad.
coldopen_fixture_dir=""
coldopen_fixture_file=""
cleanup_coldopen_fixture() {
    if [[ -n "$coldopen_fixture_file" && -f "$coldopen_fixture_file" ]]; then
        rm -f -- "$coldopen_fixture_file"
    fi
    if [[ -n "$coldopen_fixture_dir" && -d "$coldopen_fixture_dir" ]]; then
        rmdir -- "$coldopen_fixture_dir" 2>/dev/null || true
    fi
    coldopen_fixture_dir=""
    coldopen_fixture_file=""
}

# Nach Crash oder Timeout liegt die itemgetreue Sicherung noch in der
# Runner-Sandbox. Ein frischer, fensterloser App-Aufruf spielt sie nur dann
# zurück, wenn der changeCount weiterhin den Test als letzten Schreiber
# ausweist. Neuere Nutzerinhalte bleiben dadurch unangetastet.
restore_selftest_pasteboard() {
    local backup="${SELFTEST_PASTEBOARD_DIR:-}/pasteboard-backup.plist"
    [ -n "${SELFTEST_PASTEBOARD_DIR:-}" ] && [ -f "$backup" ] || return 0
    local output="$FASTRA_TEST_TMPDIR/pasteboard-restore.out"
    FASTRA_TEST_PENDING_BUNDLE="$APP_BIN_BUNDLE_CANONICAL"
    if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
    CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
    CFPREFERENCES_AVOID_DAEMON=1 \
    HOME="$FASTRA_TEST_CF_HOME" \
    FASTRA_SELFTEST_DEFAULTS_SUITE="$SELFTEST_DEFAULTS_SUITE" \
    FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
    fastra_test_start_new_session "$APP_BIN_ABSOLUTE" -selftest soakpasteboardrestore \
        -soakDir "$SELFTEST_PASTEBOARD_DIR" \
        -soakPhase 2 \
        -ApplePersistenceIgnoreState YES >"$output" 2>&1; then
        echo "✗ Zwischenablage-Hilfsprozess ließ sich nicht sicher starten." >&2
        return 1
    fi
    local pid="$FASTRA_TEST_STARTED_PID"
    track_started_app_bundle_for_executable "$APP_BIN_ABSOLUTE"
    # Gehört ab jetzt zum Runner. Scheitert seine Terminierung, kann der
    # allgemeine Aufräumpfad dieselbe PID samt Starttoken erneut versuchen.
    if [ "${FASTRA_SELFTEST_TEST_HELPER_TRACK_FAILURE:-0}" = "1" ] \
       || ! track_started_pid "$pid"; then
        SELFTEST_PROCESS_CLEANUP_BLOCKED=1
        # Noch nicht übernehmen: Der atomare Pending-Handshake besitzt PID,
        # Starttoken und Prozessgruppe weiterhin. `kill_leftovers` beendet ihn
        # über genau diesen Pending-Beleg; `discard` allein würde nur die
        # Buchhaltung löschen und den Prozess weiterlaufen lassen.
        if kill_leftovers; then
            SELFTEST_PROCESS_CLEANUP_BLOCKED=0
        fi
        return 1
    fi
    fastra_test_adopt_started_session || {
        SELFTEST_PROCESS_CLEANUP_BLOCKED=1
        return 1
    }
    local tick=0
    while fastra_test_pid_is_live "$pid"; do
        sleep 0.1
        tick=$((tick + 1))
        if [ "$tick" -ge 300 ]; then
            if [ "${FASTRA_SELFTEST_TEST_HELPER_CLEANUP_FAILURE:-0}" = "1" ] \
               || ! terminate_fastra_test_process_trees "$pid"; then
                SELFTEST_PROCESS_CLEANUP_BLOCKED=1
                return 1
            fi
            wait "$pid" 2>/dev/null || true
            echo "✗ Zwischenablage-Wiederherstellung überschritt 30 s." >&2
            return 1
        fi
    done
    wait "$pid"
    local status=$?
    # Der Test-Hook simuliert ausschließlich den sonst kaum zuverlässig
    # erzeugbaren Fehlerpfad. Produktionsläufe setzen ihn nie.
    if [ "${FASTRA_SELFTEST_TEST_HELPER_CLEANUP_FAILURE:-0}" = "1" ] \
       || ! terminate_fastra_test_process_trees "$pid"; then
        SELFTEST_PROCESS_CLEANUP_BLOCKED=1
        return 1
    fi
    if [ "$status" -ne 0 ] || [ -f "$backup" ]; then
        echo "✗ Zwischenablage-Wiederherstellung fehlgeschlagen (Status $status)." >&2
        tail -2 "$output" 2>/dev/null | sed 's/^/  /' >&2
        return 1
    fi
    return 0
}

unregister_test_bundle_from_launch_services() {
    local bundle failed=0
    if fastra_test_pending_start_was_released \
       && [ -n "${FASTRA_TEST_PENDING_BUNDLE:-}" ]; then
        track_started_app_bundle "$FASTRA_TEST_PENDING_BUNDLE"
    fi
    [ "${#STARTED_APP_BUNDLES[@]}" -gt 0 ] || return 0
    for bundle in "${STARTED_APP_BUNDLES[@]}"; do
        unregister_fastra_test_bundle_from_launch_services "$bundle" \
            || failed=1
    done
    return "$failed"
}

PRODUCT_DEFAULTS_DOMAIN="de.dm0.fastra"
PRODUCT_DEFAULTS_BACKUP=""
PRODUCT_DEFAULTS_EXISTED=0
PRODUCT_DEFAULTS_SNAPSHOT_READY=0
PRODUCT_SAVED_STATE_PARENT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
PRODUCT_SAVED_STATE_PARENT="${PRODUCT_SAVED_STATE_PARENT%/}"
PRODUCT_SAVED_STATE_DIR="$PRODUCT_SAVED_STATE_PARENT/de.dm0.fastra.savedState"
PRODUCT_SAVED_STATE_BACKUP=""
PRODUCT_SAVED_STATE_EXISTED=0
PRODUCT_SAVED_STATE_SNAPSHOT_READY=0

foreign_fastra_process_is_running() {
    # Snapshot und Restore laufen nur, wenn alle runner-eigenen App-Prozesse
    # bereits beendet sind. Jede jetzt sichtbare Fastra-Instanz ist daher
    # fremd — auch wenn sie zufällig dasselbe Debug-Binary verwendet.
    pgrep -f '/Fastra\.app/Contents/MacOS/Fastra([[:space:]]|$)' \
        >/dev/null 2>&1
}

snapshot_product_defaults() {
    foreign_fastra_process_is_running && {
        echo "✗ Eine andere Fastra-App läuft. Echte Einstellungen können nicht sicher isoliert werden." >&2
        return 2
    }
    PRODUCT_DEFAULTS_BACKUP="$FASTRA_TEST_SANDBOX/product-defaults.plist"
    local read_error="$FASTRA_TEST_SANDBOX/product-defaults-read.err"
    if /usr/bin/defaults read "$PRODUCT_DEFAULTS_DOMAIN" \
        >/dev/null 2>"$read_error"; then
        /usr/bin/defaults export "$PRODUCT_DEFAULTS_DOMAIN" \
            "$PRODUCT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 2
        PRODUCT_DEFAULTS_EXISTED=1
    elif grep -Fq "Domain $PRODUCT_DEFAULTS_DOMAIN does not exist" "$read_error"; then
        PRODUCT_DEFAULTS_EXISTED=0
        rm -f -- "$PRODUCT_DEFAULTS_BACKUP"
    else
        echo "✗ Fastra-Einstellungen konnten nicht sicher gelesen werden." >&2
        return 2
    fi
    PRODUCT_DEFAULTS_SNAPSHOT_READY=1
}

restore_product_defaults() {
    [ "$PRODUCT_DEFAULTS_SNAPSHOT_READY" -eq 1 ] || return 0
    foreign_fastra_process_is_running && return 2
    if [ "$PRODUCT_DEFAULTS_EXISTED" -eq 1 ]; then
        [ -f "$PRODUCT_DEFAULTS_BACKUP" ] || return 2
        /usr/bin/defaults import "$PRODUCT_DEFAULTS_DOMAIN" \
            "$PRODUCT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 2
        # Semantischer Vergleich statt Binärhash: plist-Ausgabe darf ihre
        # interne Reihenfolge ändern, Schlüssel und Werte aber nicht.
        /usr/bin/defaults export "$PRODUCT_DEFAULTS_DOMAIN" - 2>/dev/null \
            | /usr/bin/python3 -c \
                'import datetime,plistlib,sys
def same(a,b):
    if isinstance(a,datetime.datetime) and isinstance(b,datetime.datetime): return abs((a-b).total_seconds()) < 1
    if type(a) is not type(b): return False
    if isinstance(a,dict): return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
    if isinstance(a,list): return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
    return a==b
a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.loads(sys.stdin.buffer.read()); raise SystemExit(0 if same(a,b) else 1)' \
                "$PRODUCT_DEFAULTS_BACKUP"
    else
        /usr/bin/defaults delete "$PRODUCT_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
        local read_error="$FASTRA_TEST_SANDBOX/product-defaults-restore-read.err"
        if /usr/bin/defaults read "$PRODUCT_DEFAULTS_DOMAIN" \
            >/dev/null 2>"$read_error"; then
            return 2
        fi
        grep -Fq "Domain $PRODUCT_DEFAULTS_DOMAIN does not exist" "$read_error"
    fi
}

product_saved_state_path_is_safe() {
    local path="$1"
    [ -n "$PRODUCT_SAVED_STATE_PARENT" ] \
        && [ "$path" = "$PRODUCT_SAVED_STATE_DIR" ]
}

remove_product_saved_state() {
    [ ! -e "$PRODUCT_SAVED_STATE_DIR" ] && return 0
    product_saved_state_path_is_safe "$PRODUCT_SAVED_STATE_DIR" || return 2
    [ -d "$PRODUCT_SAVED_STATE_DIR" ] && [ ! -L "$PRODUCT_SAVED_STATE_DIR" ] || return 2
    [ "$(stat -f '%u' "$PRODUCT_SAVED_STATE_DIR" 2>/dev/null || true)" = "$UID" ] \
        || return 2
    find "$PRODUCT_SAVED_STATE_DIR" -depth -delete 2>/dev/null
}

snapshot_product_saved_state() {
    product_saved_state_path_is_safe "$PRODUCT_SAVED_STATE_DIR" || return 2
    PRODUCT_SAVED_STATE_BACKUP="$FASTRA_TEST_SANDBOX/product-saved-state"
    if [ -d "$PRODUCT_SAVED_STATE_DIR" ] && [ ! -L "$PRODUCT_SAVED_STATE_DIR" ]; then
        [ "$(stat -f '%u' "$PRODUCT_SAVED_STATE_DIR" 2>/dev/null || true)" = "$UID" ] \
            || return 2
        /usr/bin/ditto "$PRODUCT_SAVED_STATE_DIR" "$PRODUCT_SAVED_STATE_BACKUP" \
            >/dev/null 2>&1 || return 2
        PRODUCT_SAVED_STATE_EXISTED=1
    fi
    # Erst ein vollständig erfolgreicher Snapshot darf den Restore scharf
    # stellen. Scheitert `ditto`, darf der EXIT-Trap das Original nie löschen.
    PRODUCT_SAVED_STATE_SNAPSHOT_READY=1
}

restore_product_saved_state() {
    [ "$PRODUCT_SAVED_STATE_SNAPSHOT_READY" -eq 1 ] || return 0
    foreign_fastra_process_is_running && return 2
    remove_product_saved_state || return 2
    if [ "$PRODUCT_SAVED_STATE_EXISTED" -eq 1 ]; then
        [ -d "$PRODUCT_SAVED_STATE_BACKUP" ] || return 2
        /usr/bin/ditto "$PRODUCT_SAVED_STATE_BACKUP" "$PRODUCT_SAVED_STATE_DIR" \
            >/dev/null 2>&1 || return 2
        diff -qr "$PRODUCT_SAVED_STATE_BACKUP" "$PRODUCT_SAVED_STATE_DIR" \
            >/dev/null 2>&1
    fi
}

prune_selftest_evidence() {
    local stale owner
    while IFS= read -r stale; do
        [ -d "$stale" ] && [ ! -L "$stale" ] || continue
        owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
        [ "$owner" = "$UID" ] || continue
        case "$stale" in /tmp/fastra-selftest-befunde-*) rm -rf -- "$stale" ;; esac
    done < <(
        find /tmp -maxdepth 1 -type d -name 'fastra-selftest-befunde-*' \
            -exec stat -f '%m %N' {} + 2>/dev/null \
            | sort -rn | sed -n '6,$s/^[0-9][0-9]* //p'
    )
}

SELFTEST_EVIDENCE_DIR=""
preserve_selftest_error() {
    local source="$1"
    local test_name="$2"
    if [ -z "$SELFTEST_EVIDENCE_DIR" ]; then
        SELFTEST_EVIDENCE_DIR=$(mktemp -d \
            "/tmp/fastra-selftest-befunde-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    fi
    if ! cp -- "$source" "$SELFTEST_EVIDENCE_DIR/$test_name.stderr"; then
        echo "  Diagnose konnte nicht kopiert werden; letzte Ausgabe:" >&2
        tail -20 "$source" 2>/dev/null | sed 's/^/    /' >&2
        return 1
    fi
    prune_selftest_evidence
    echo "  Diagnose: $SELFTEST_EVIDENCE_DIR/$test_name.stderr"
}

preserve_selftest_pasteboard_recovery() {
    local backup="${SELFTEST_PASTEBOARD_DIR:-}/pasteboard-backup.plist"
    [ -f "$backup" ] || return 0
    if [ -z "$SELFTEST_EVIDENCE_DIR" ]; then
        SELFTEST_EVIDENCE_DIR=$(mktemp -d \
            "/tmp/fastra-selftest-befunde-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    fi
    cp -- "$backup" "$SELFTEST_EVIDENCE_DIR/pasteboard-backup.plist" || return 1
    if [ -f "$FASTRA_TEST_TMPDIR/pasteboard-restore.out" ]; then
        cp -- "$FASTRA_TEST_TMPDIR/pasteboard-restore.out" \
            "$SELFTEST_EVIDENCE_DIR/pasteboard-restore.out" || return 1
    fi
    prune_selftest_evidence
    echo "  Zwischenablage-Sicherung: $SELFTEST_EVIDENCE_DIR" >&2
}

# Aufräumen auch bei Abbruch. Ohne Trap blieben nach einem Strg-C mitten in
# einem Test die per LaunchServices gestarteten Testprozesse mit sichtbaren
# Fenstern und die Kaltstart-Fixture liegen — der nächste Lauf traf dann auf
# eine fremde Ausgangslage. Bereinigt wird ausschließlich, was dieser Runner
# selbst erfasst hat: die gemerkten PIDs des konfigurierten Bundles und genau
# das eine mktemp-Fixture-Verzeichnis.
#
# Der Exit-Code des Abbruchs bleibt erhalten: Bei einem regulären Ende wird der
# vorliegende Status weitergereicht, bei einem Signal beendet sich der Runner
# selbst mit demselben Signal (der Aufrufer sieht also 128 + Signalnummer).
cleanup_on_exit() {
    local original_status=$?
    local sandbox_status=0
    local keep_sandbox=0
    local performance_copy=""
    trap - EXIT INT TERM
    local process_cleanup_failed=0
    if ! terminate_activation_process; then
        SELFTEST_CLEANUP_FAILED=1
        process_cleanup_failed=1
        keep_sandbox=1
    fi
    if ! kill_leftovers; then
        SELFTEST_CLEANUP_FAILED=1
        process_cleanup_failed=1
        keep_sandbox=1
    else
        SELFTEST_PROCESS_CLEANUP_BLOCKED=0
    fi
    if [ "$process_cleanup_failed" -eq 0 ]; then
        if ! restore_selftest_pasteboard; then
            SELFTEST_CLEANUP_FAILED=1
            preserve_selftest_pasteboard_recovery || keep_sandbox=1
        fi
        if [ "${SELFTEST_PROCESS_CLEANUP_BLOCKED:-0}" -eq 1 ]; then
            process_cleanup_failed=1
            keep_sandbox=1
        fi
    fi
    if [ "$process_cleanup_failed" -eq 0 ]; then
        purge_fastra_registered_test_defaults \
            "${FASTRA_TEST_DEFAULTS_REGISTRY:-}" || SELFTEST_CLEANUP_FAILED=1
        if ! restore_product_defaults; then
            SELFTEST_CLEANUP_FAILED=1
            keep_sandbox=1
        fi
        if ! restore_product_saved_state; then
            SELFTEST_CLEANUP_FAILED=1
            keep_sandbox=1
        fi
    else
        # Kein neuer App-Helfer und kein Preferences-Austausch, solange der
        # alte Prozessbaum möglicherweise noch schreibt.
        keep_sandbox=1
    fi
    cleanup_coldopen_fixture
    if [ "$process_cleanup_failed" -eq 0 ]; then
        unregister_test_bundle_from_launch_services || SELFTEST_CLEANUP_FAILED=1
    fi
    release_fastra_gui_test_lock || SELFTEST_CLEANUP_FAILED=1
    if [[ "${PERFORMANCE_RECORD_PENDING:-0}" -eq 1 \
          && -n "${PERFORMANCE_SAMPLES_FILE:-}" ]]; then
        performance_copy=$(mktemp "/tmp/fastra-performance-${UID}.XXXXXX") \
            || SELFTEST_CLEANUP_FAILED=1
        if [[ -n "$performance_copy" ]]; then
            cp -- "$PERFORMANCE_SAMPLES_FILE" "$performance_copy" \
                || SELFTEST_CLEANUP_FAILED=1
        fi
    fi
    if [[ -n "${PERFORMANCE_SAMPLES_FILE:-}" ]]; then
        rm -f -- "$PERFORMANCE_SAMPLES_FILE"
    fi
    if [ "$keep_sandbox" -eq 0 ]; then
        release_fastra_test_sandbox || sandbox_status=$?
    else
        echo "  Private Test-Sandbox zur manuellen Wiederherstellung behalten: $FASTRA_TEST_SANDBOX" >&2
        sandbox_status=2
    fi
    # Eine qualifizierte Messung darf erst nach vollständig erfolgreichem
    # Prozess-, Preferences-, Fenster- und Sandbox-Cleanup gespeichert werden.
    if [[ -n "$performance_copy" && "$sandbox_status" -eq 0 \
          && "${SELFTEST_CLEANUP_FAILED:-0}" -eq 0 ]]; then
        RUN_HEAD_END="$(git -C .. rev-parse HEAD 2>/dev/null || true)"
        RUN_BINARY_SHA_END="$(shasum -a 256 "$APP_BIN_ABSOLUTE" | awk '{print $1}')"
        RUN_DIRTY_END="$(git -C .. status --porcelain 2>/dev/null || true)"
        PERFORMANCE_QUALIFIED=""
        if [[ $real_fail_count -eq 0 && $env_fail_count -eq 0 && $skip_count -eq 0 \
              && "$RUN_HEAD_START" == "$RUN_HEAD_END" \
              && "$RUN_BINARY_SHA_START" == "$RUN_BINARY_SHA_END" \
              && -z "$RUN_DIRTY_START" && -z "$RUN_DIRTY_END" \
              && "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" == "1" ]]; then
            PERFORMANCE_QUALIFIED="--qualified"
        fi
        PERFORMANCE_RECORDER_STATUS=0
        /usr/bin/python3 ./tools/selftest-performance.py record-standard \
            --samples "$performance_copy" \
            --configuration "$PERFORMANCE_CONFIGURATION" \
            --head "$RUN_HEAD_START" \
            --binary-sha256 "$RUN_BINARY_SHA_START" \
            --repository "$(cd .. && pwd -P)" \
            ${PERFORMANCE_QUALIFIED:+--qualified} || PERFORMANCE_RECORDER_STATUS=$?
        if [[ $PERFORMANCE_RECORDER_STATUS -ne 0 \
              && "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" == "1" ]]; then
            echo "⚠ Lokale Performance-Baseline konnte nicht gespeichert werden."
            SELFTEST_CLEANUP_FAILED=1
        fi
    elif [[ "${PERFORMANCE_RECORD_PENDING:-0}" -eq 1 \
            && "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" == "1" ]]; then
        echo "⚠ Performance-Baseline wegen unvollständigem Cleanup nicht gespeichert."
        SELFTEST_CLEANUP_FAILED=1
    fi
    [[ -z "$performance_copy" ]] || rm -f -- "$performance_copy"
    if [[ "$sandbox_status" -ne 0 || "${SELFTEST_CLEANUP_FAILED:-0}" -ne 0 ]]; then
        echo "✗ Selbsttest-Aufräumen konnte nicht vollständig abgeschlossen werden." >&2
        [ "$original_status" -ne 0 ] || exit 2
    fi
    exit "$original_status"
}

cleanup_on_signal() {
    local signal="$1"
    trap - EXIT INT TERM
    local keep_sandbox=0
    local cleanup_failed=0
    local process_cleanup_failed=0
    if ! terminate_activation_process; then
        cleanup_failed=1
        process_cleanup_failed=1
        keep_sandbox=1
    fi
    # LaunchServices kann nach `open` mehrere Sekunden bis zur sichtbaren PID
    # brauchen. Der Signalpfad wartet bounded bis zu derselben 8-s-Frist wie
    # die Aktivierung, damit keine spät gestartete Test-App entkommt.
    if ! kill_leftovers 80; then
        cleanup_failed=1
        process_cleanup_failed=1
        keep_sandbox=1
    else
        SELFTEST_PROCESS_CLEANUP_BLOCKED=0
    fi
    if [ "$process_cleanup_failed" -eq 0 ]; then
        if ! restore_selftest_pasteboard; then
            preserve_selftest_pasteboard_recovery || keep_sandbox=1
            cleanup_failed=1
        fi
        if [ "${SELFTEST_PROCESS_CLEANUP_BLOCKED:-0}" -eq 1 ]; then
            process_cleanup_failed=1
            keep_sandbox=1
        fi
    fi
    if [ "$process_cleanup_failed" -eq 0 ]; then
        purge_fastra_registered_test_defaults \
            "${FASTRA_TEST_DEFAULTS_REGISTRY:-}" || cleanup_failed=1
        if ! restore_product_defaults; then
            keep_sandbox=1
            cleanup_failed=1
        fi
        if ! restore_product_saved_state; then
            keep_sandbox=1
            cleanup_failed=1
        fi
    else
        keep_sandbox=1
    fi
    cleanup_coldopen_fixture
    if [ "$process_cleanup_failed" -eq 0 ]; then
        unregister_test_bundle_from_launch_services || cleanup_failed=1
    fi
    release_fastra_gui_test_lock || cleanup_failed=1
    if [[ -n "${PERFORMANCE_SAMPLES_FILE:-}" ]]; then
        rm -f -- "$PERFORMANCE_SAMPLES_FILE"
    fi
    if [ "$keep_sandbox" -eq 0 ]; then
        release_fastra_test_sandbox || cleanup_failed=1
    else
        echo "  Private Test-Sandbox zur manuellen Wiederherstellung behalten: $FASTRA_TEST_SANDBOX" >&2
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
        echo "✗ Selbsttest-Aufräumen blieb beim Signal unvollständig." >&2
    fi
    trap - "$signal"
    kill -"$signal" $$
}

trap cleanup_on_exit EXIT
trap 'handle_runner_signal INT' INT
trap 'handle_runner_signal TERM' TERM

if [[ $NEEDS_GUI_LOCK -eq 1 ]]; then
    acquire_fastra_gui_test_lock || exit 2
fi
create_fastra_test_sandbox selftest-run || exit 2
snapshot_product_defaults || exit 2
snapshot_product_saved_state || exit 2
SELFTEST_PASTEBOARD_DIR="$FASTRA_TEST_SANDBOX/selftest-pasteboard"
mkdir -p "$SELFTEST_PASTEBOARD_DIR" || exit 2
SELFTEST_DEFAULTS_SUITE="Fastra-$(/usr/bin/uuidgen)"
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_SANDBOX/defaults-registry.txt"
: > "$FASTRA_TEST_DEFAULTS_REGISTRY" || exit 2
SELFTEST_CLEANUP_FAILED=0
SELFTEST_PROCESS_CLEANUP_BLOCKED=0
prune_selftest_evidence

# ── Testlauf ─────────────────────────────────────────────────────────────

# Liest das versionierte Ergebnisprotokoll der App. Sobald mindestens eine
# `SELFTEST-RESULT`-Zeile vorhanden ist, ist sie verbindlich: Unbekannte
# Versionen, Statuswerte, Testnamen oder beschädigte Zeilen werden zu einem
# echten Fehler. Nur alte Bundles ohne Maschinenzeile benutzen weiterhin die
# bisherige Begleitzeile.
SELFTEST_RESULT_STATUS=""
SELFTEST_PROTOCOL_ERROR=""
classify_selftest_result() {
    local expected_test="$1"
    local errfile="$2"
    local legacy_line="$3"
    local structured_line=""
    local candidate=""
    local candidate_rank=-1
    local highest_rank=-1
    local saw_structured=0
    local field1=""
    local field2=""
    local field3=""
    local field4=""
    local extra=""
    SELFTEST_RESULT_STATUS=""
    SELFTEST_PROTOCOL_ERROR=""

    while IFS= read -r structured_line; do
        [ -n "$structured_line" ] || continue
        saw_structured=1
        # Die vier Felder enthalten absichtlich keine freien Texte. `read`
        # vermeidet dabei sowohl Dateinamen-Expansion als auch eine Änderung
        # der Positionsparameter unter macOS-Bash 3.2.
        field1=""; field2=""; field3=""; field4=""; extra=""
        IFS=' ' read -r field1 field2 field3 field4 extra <<< "$structured_line"
        if [ -n "$extra" ] \
           || [ "$field1" != "SELFTEST-RESULT" ] \
           || [ "$field2" != "v=1" ] \
           || [ "$field3" != "test=$expected_test" ] \
           || [[ "$field4" != status=* ]]; then
            SELFTEST_PROTOCOL_ERROR="ungültige Ergebniszeile: $structured_line"
            continue
        fi
        candidate="${field4#status=}"
        case "$candidate" in
            PASS) candidate_rank=0 ;;
            SKIP) candidate_rank=1 ;;
            ENV)  candidate_rank=2 ;;
            FAIL) candidate_rank=3 ;;
            *)
                SELFTEST_PROTOCOL_ERROR="unbekannter Status in: $structured_line"
                continue
                ;;
        esac
        if [ "$candidate_rank" -gt "$highest_rank" ]; then
            highest_rank="$candidate_rank"
        fi
    done < <(grep '^SELFTEST-RESULT' "$errfile" 2>/dev/null || true)

    if [ -n "$SELFTEST_PROTOCOL_ERROR" ]; then
        SELFTEST_RESULT_STATUS="FAIL"
        return
    fi
    if [ "$saw_structured" -eq 1 ]; then
        case "$highest_rank" in
            0) SELFTEST_RESULT_STATUS="PASS" ;;
            1) SELFTEST_RESULT_STATUS="SKIP" ;;
            2) SELFTEST_RESULT_STATUS="ENV" ;;
            3) SELFTEST_RESULT_STATUS="FAIL" ;;
            *)
                SELFTEST_RESULT_STATUS="FAIL"
                SELFTEST_PROTOCOL_ERROR="Ergebniszeile enthält keinen gültigen Status"
                ;;
        esac
        return
    fi

    # Kompatibilität mit bereits installierten Bundles vor Protokollversion 1.
    if [[ "$legacy_line" == "SELFTEST $expected_test: PASS"* ]]; then
        SELFTEST_RESULT_STATUS="PASS"
    elif [[ "$legacy_line" == "SELFTEST $expected_test: SKIP"* ]]; then
        SELFTEST_RESULT_STATUS="SKIP"
    elif [[ "$legacy_line" == "SELFTEST $expected_test: "*"Umgebungsproblem"* ]]; then
        SELFTEST_RESULT_STATUS="ENV"
    else
        SELFTEST_RESULT_STATUS="FAIL"
    fi
}

pass_count=0
real_fail_count=0
env_fail_count=0
skip_count=0
summary=""
PERFORMANCE_SAMPLES_FILE="$(mktemp "$FASTRA_TEST_TMPDIR/performance.XXXXXX")"
RUN_HEAD_START="$(git -C .. rev-parse HEAD 2>/dev/null || true)"
RUN_BINARY_SHA_START="$(shasum -a 256 "$APP_BIN_ABSOLUTE" | awk '{print $1}')"
RUN_DIRTY_START="$(git -C .. status --porcelain 2>/dev/null || true)"
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -n "${FASTRA_SELFTEST_BUILD_CONFIGURATION:-}" ]]; then
    PERFORMANCE_BUILD="$FASTRA_SELFTEST_BUILD_CONFIGURATION"
elif [[ "$APP_BIN" == ".build/debug/"* || "$APP_BIN" == *"/.build/debug/"* ]]; then
    PERFORMANCE_BUILD="debug"
elif [[ "$APP_BIN" == ".build/release/"* || "$APP_BIN" == *"/.build/release/"* \
       || "$APP_BIN_ABSOLUTE" == "/Applications/"* ]]; then
    PERFORMANCE_BUILD="release"
else
    # Ein ausdrücklich umgebogenes Bundle unbekannter Bauart bekommt eine
    # eigene Gruppe und wird weder mit Debug noch Release verglichen.
    PERFORMANCE_BUILD="custom"
fi
PERFORMANCE_CONFIGURATION="${PERFORMANCE_BUILD}-mixed-macos${OS_MAJOR}"

# Wegen gesperrtem Bildschirm ausgelassene Fenstertests sofort ausweisen — je
# eine maschinenlesbare Zeile im gewohnten `SELFTEST <name>:`-Format. Sie
# zwingen am Ende Exit 2: Der Lauf ist unvollständig, nicht bestanden.
# macOS liefert bash 3.2: Ein leeres Array unter `set -u` erst über die Länge
# prüfen, sonst gilt "${arr[@]}" als unbound.
if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
    for t in "${SKIPPED_TESTS[@]}"; do
        emit_locked_screen_skip "$t"
        summary+="⚠ $t (übersprungen: Bildschirm gesperrt)\n"
        skip_count=$((skip_count + 1))
    done
fi

for t in "${TESTS[@]}"; do
    CURRENT_TEST_NAME="$t"
    safe_test_name=$(printf '%s' "$t" | tr -c 'A-Za-z0-9._-' '_')
    [ -n "$safe_test_name" ] || safe_test_name="unknown"
    iteration_started="$(now_milliseconds)"
    if ! kill_leftovers; then
        emit_selftest_result "$t" "ENV"
        echo "SELFTEST $t: Umgebungsproblem — vorheriger Testprozess läuft weiter"
        summary+="⚠ $t (Aufräumen fehlgeschlagen)\n"
        env_fail_count=$((env_fail_count + 1))
        break
    fi
    if ! restore_selftest_pasteboard; then
        emit_selftest_result "$t" "ENV"
        echo "SELFTEST $t: Umgebungsproblem — Zwischenablage konnte nicht zurückgegeben werden"
        summary+="⚠ $t (Zwischenablage-Aufräumen fehlgeschlagen)\n"
        env_fail_count=$((env_fail_count + 1))
        SELFTEST_CLEANUP_FAILED=1
        break
    fi
    cleanup_finished="$(now_milliseconds)"
    errfile="$(mktemp "$FASTRA_TEST_TMPDIR/$safe_test_name.stderr.XXXXXX")"
    selftest_activation=1
    if array_contains_exactly "$t" "${BACKGROUND_ACTIVATION_BLOCKED_TESTS[@]}"; then
        selftest_activation=0
    fi

    launch_started="$(now_milliseconds)"
    launch_mode="direct"
    CURRENT_LAUNCH_MODE="direct"
    if [[ "$t" == "coldopen" || "$t" == "coldopenoff" ]]; then
        launch_mode="launchservices"
        CURRENT_LAUNCH_MODE="launchservices"
        # Reale Kaltstart-Zustellung: LaunchServices öffnet eine existierende
        # Datei mit genau dem frisch gebauten Bundle. Der Testprozess legt
        # parallel vor seinem ersten Workspace eine abweichende alte Sitzung an.
        coldopen_fixture_dir="$(mktemp -d "$FASTRA_TEST_TMPDIR/coldopen.XXXXXX")"
        coldopen_fixture_file="$coldopen_fixture_dir/README.de.md"
        printf 'Explizit per LaunchServices geöffnet\n' > "$coldopen_fixture_file"
        if ! "$OPEN_COMMAND" -g -n -a "$APP_BUNDLE_FOR_OPEN" \
            --stdout /dev/null --stderr "$errfile" \
            --env "FASTRA_SELFTEST=$t" \
            --env "FASTRA_COLDOPEN_FILE=$coldopen_fixture_file" \
            --env "TMPDIR=$FASTRA_TEST_TMPDIR/" \
            --env "CFFIXED_USER_HOME=$FASTRA_TEST_CF_HOME" \
            --env "CFPREFERENCES_AVOID_DAEMON=1" \
            --env "HOME=$FASTRA_TEST_CF_HOME" \
            --env "FASTRA_SELFTEST_DEFAULTS_SUITE=$SELFTEST_DEFAULTS_SUITE" \
            --env "FASTRA_TEST_DEFAULTS_REGISTRY=$FASTRA_TEST_DEFAULTS_REGISTRY" \
            --env "FASTRA_SELFTEST_PASTEBOARD_DIR=$SELFTEST_PASTEBOARD_DIR" \
            --env "FASTRA_SELFTEST_ALLOW_ACTIVATION=0" \
            "$coldopen_fixture_file" \
            --args -ApplePersistenceIgnoreState YES; then
            emit_selftest_result "$t" "ENV"
            echo "SELFTEST $t: Umgebungsproblem — LaunchServices-Start fehlgeschlagen"
            summary+="⚠ $t (Start fehlgeschlagen)\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
        track_started_app_bundle "$APP_BUNDLE_CANONICAL"
        remember_bundle_pids
    elif array_contains_exactly "$t" "${FOCUS_REQUIRED_TESTS[@]}"; then
        launch_mode="launchservices"
        CURRENT_LAUNCH_MODE="launchservices"
        # Diese Tests prüfen echte Tastatur- oder Mausbedienung und brauchen
        # daher Fokus → via `open` starten und von außen aktivieren. Der
        # gemeinsame Aufräumpfad `kill_leftovers` beendet die Test-App nach
        # Ergebnis UND Timeout sofort, damit kein Fenster sichtbar bleibt.
        # starten (LaunchServices) und von außen aktivieren.
        if ! "$OPEN_COMMAND" -n "$APP_BUNDLE_FOR_OPEN" --stdout /dev/null --stderr "$errfile" \
            --env "TMPDIR=$FASTRA_TEST_TMPDIR/" \
            --env "CFFIXED_USER_HOME=$FASTRA_TEST_CF_HOME" \
            --env "CFPREFERENCES_AVOID_DAEMON=1" \
            --env "HOME=$FASTRA_TEST_CF_HOME" \
            --env "FASTRA_SELFTEST_DEFAULTS_SUITE=$SELFTEST_DEFAULTS_SUITE" \
            --env "FASTRA_TEST_DEFAULTS_REGISTRY=$FASTRA_TEST_DEFAULTS_REGISTRY" \
            --env "FASTRA_SELFTEST_PASTEBOARD_DIR=$SELFTEST_PASTEBOARD_DIR" \
            --env "FASTRA_SELFTEST_ALLOW_ACTIVATION=1" \
            --args -selftest "$t" -ApplePersistenceIgnoreState YES ${SELFTEST_LANGUAGE_ARGS[@]+"${SELFTEST_LANGUAGE_ARGS[@]}"}; then
            emit_selftest_result "$t" "ENV"
            echo "SELFTEST $t: Umgebungsproblem — LaunchServices-Start fehlgeschlagen"
            summary+="⚠ $t (Start fehlgeschlagen)\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
        track_started_app_bundle "$APP_BUNDLE_CANONICAL"
        remember_bundle_pids
        activate_app "$errfile"
        remember_bundle_pids
    else
        # Alle anderen Tests starten das Binary direkt. Nur die ausdrücklich
        # hintergrundfähigen Namen bekommen dabei ein Aktivierungsverbot.
        FASTRA_TEST_PENDING_BUNDLE="$APP_BIN_BUNDLE_CANONICAL"
        if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
        CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
        CFPREFERENCES_AVOID_DAEMON=1 \
        HOME="$FASTRA_TEST_CF_HOME" \
        FASTRA_SELFTEST_DEFAULTS_SUITE="$SELFTEST_DEFAULTS_SUITE" \
        FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
        FASTRA_SELFTEST_PASTEBOARD_DIR="$SELFTEST_PASTEBOARD_DIR" \
        FASTRA_SELFTEST_ALLOW_ACTIVATION="$selftest_activation" \
        fastra_test_start_new_session "$APP_BIN_ABSOLUTE" \
            -selftest "$t" -ApplePersistenceIgnoreState YES ${SELFTEST_LANGUAGE_ARGS[@]+"${SELFTEST_LANGUAGE_ARGS[@]}"} \
            >/dev/null 2>"$errfile"; then
            emit_selftest_result "$t" "ENV"
            echo "SELFTEST $t: Umgebungsproblem — Testprozess ließ sich nicht sicher starten"
            summary+="⚠ $t (Start fehlgeschlagen)\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
        track_started_app_bundle_for_executable "$APP_BIN_ABSOLUTE"
        if ! track_started_pid "$FASTRA_TEST_STARTED_PID"; then
            emit_selftest_result "$t" "ENV"
            echo "SELFTEST $t: Umgebungsproblem — Startidentität konnte nicht gesichert werden"
            summary+="⚠ $t (Startidentität fehlt)\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
        if ! fastra_test_adopt_started_session; then
            emit_selftest_result "$t" "ENV"
            echo "SELFTEST $t: Umgebungsproblem — Prozessübernahme fehlgeschlagen"
            summary+="⚠ $t (Startübernahme fehlgeschlagen)\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
    fi

    test_timeout_secs="$(timeout_for_test "$t")"
    wait_result=0
    wait_for_result "$errfile" "$test_timeout_secs" || wait_result=$?
    if [ "$wait_result" -ne 0 ]; then
        result_finished="$(now_milliseconds)"
        if [ "$wait_result" -eq 3 ]; then
            # Früher Tod des Testprozesses: sofort und mit echtem Exit-Code
            # gemeldet, statt die restliche Frist blind abzuwarten.
            emit_selftest_result "$t" "FAIL"
            echo "SELFTEST $t: FAIL — Testprozess endete vorzeitig ohne Ergebnis-Zeile (Exit ${WAIT_FOR_RESULT_EXIT:-unbekannt})"
            summary+="✗ $t (vorzeitig beendet, Exit ${WAIT_FOR_RESULT_EXIT:-?})\n"
            fail_kind="CRASH"
        elif [ "$wait_result" -eq 4 ]; then
            # LaunchServices ist Elternprozess der App; der Runner kennt
            # deshalb keinen Exit-Code. Prozessidentität und frühes Ende sind
            # dennoch belegt und dürfen nicht als Wanduhr-Timeout erscheinen.
            emit_selftest_result "$t" "FAIL"
            echo "SELFTEST $t: FAIL — LaunchServices-Testprozess endete vorzeitig ohne Ergebnis-Zeile"
            summary+="✗ $t (LaunchServices-Prozess vorzeitig beendet)\n"
            fail_kind="CRASH"
        else
            emit_selftest_result "$t" "FAIL"
            echo "SELFTEST $t: FAIL — keine Ergebnis-Zeile binnen ${test_timeout_secs}s (Runner-Timeout)"
            summary+="✗ $t (Timeout)\n"
            fail_kind="TIMEOUT"
        fi
        real_fail_count=$((real_fail_count + 1))
        cleanup_ms=$((cleanup_finished - iteration_started))
        launch_ms=$((result_finished - launch_started))
        total_ms=$((result_finished - iteration_started))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$t" "$fail_kind" "-1" "$launch_ms" "$total_ms" "$cleanup_ms" \
            "$launch_mode" >> "$PERFORMANCE_SAMPLES_FILE"
        echo "PERFORMANCE $t cleanup_ms=$cleanup_ms launch_to_result_ms=$launch_ms app_ms=-1 total_ms=$total_ms"
        if ! kill_leftovers 80; then
            summary+="⚠ Runner-Aufräumen nach $t fehlgeschlagen\n"
            env_fail_count=$((env_fail_count + 1))
            break
        fi
        # Erst nach TERM/KILL und wait kopieren: Kindprozesse dürfen ihre
        # letzte Diagnose beim Beenden noch vollständig flushen.
        preserve_selftest_error "$errfile" "$safe_test_name" \
            || SELFTEST_CLEANUP_FAILED=1
        if ! restore_selftest_pasteboard; then
            summary+="⚠ Zwischenablage-Aufräumen nach $t fehlgeschlagen\n"
            env_fail_count=$((env_fail_count + 1))
            SELFTEST_CLEANUP_FAILED=1
            break
        fi
        cleanup_coldopen_fixture
        continue
    fi

    line="$(grep '^SELFTEST ' "$errfile" | tail -1)"
    result_finished="$(now_milliseconds)"
    app_ms="$(sed -n 's/^SELFTEST-METRIC test=[^ ]* app_ms=\([0-9][0-9]*\)$/\1/p' "$errfile" | tail -1)"
    app_ms="${app_ms:--1}"
    classify_selftest_result "$t" "$errfile" "$line"
    performance_status="$SELFTEST_RESULT_STATUS"
    if [ -n "$SELFTEST_PROTOCOL_ERROR" ]; then
        emit_selftest_result "$t" "FAIL"
        echo "SELFTEST $t: FAIL — Protokollfehler: $SELFTEST_PROTOCOL_ERROR"
    else
        # Der Runner gibt genau einen kanonischen Maschinenstatus weiter. Das
        # gilt auch für alte Bundles, deren Begleitzeile noch ausgewertet wird.
        emit_selftest_result "$t" "$performance_status"
        echo "$line"
    fi

    case "$performance_status" in
        PASS)
            pass_count=$((pass_count + 1))
            summary+="✓ $t\n"
            rm -f -- "$errfile"
            ;;
        SKIP)
            skip_count=$((skip_count + 1))
            summary+="⚠ $t (übersprungen)\n"
            rm -f -- "$errfile"
            ;;
        ENV)
            env_fail_count=$((env_fail_count + 1))
            summary+="⚠ $t (Umgebung)\n"
            rm -f -- "$errfile"
            ;;
        *)
            performance_status="FAIL"
            real_fail_count=$((real_fail_count + 1))
            summary+="✗ $t\n"
            preserve_selftest_error "$errfile" "$safe_test_name" \
                || SELFTEST_CLEANUP_FAILED=1
            ;;
    esac
    cleanup_ms=$((cleanup_finished - iteration_started))
    launch_ms=$((result_finished - launch_started))
    total_ms=$((result_finished - iteration_started))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$t" "$performance_status" "$app_ms" "$launch_ms" "$total_ms" \
        "$cleanup_ms" "$launch_mode" >> "$PERFORMANCE_SAMPLES_FILE"
    echo "PERFORMANCE $t cleanup_ms=$cleanup_ms launch_to_result_ms=$launch_ms app_ms=$app_ms total_ms=$total_ms"
    cleanup_coldopen_fixture
done

if ! kill_leftovers; then
    summary+="⚠ Abschließendes Runner-Aufräumen fehlgeschlagen\n"
    env_fail_count=$((env_fail_count + 1))
fi
cleanup_coldopen_fixture

# ── Zusammenfassung ──────────────────────────────────────────────────────

[[ $STANDARD_RUN -eq 1 ]] && PERFORMANCE_RECORD_PENDING=1

echo ""
echo "── Selbsttest-Zusammenfassung ──"
printf "%b" "$summary"
echo "PASS: $pass_count · echte FAILs: $real_fail_count · Umgebungs-FAILs: $env_fail_count · übersprungen: $skip_count"

if [[ $real_fail_count -gt 0 ]]; then
    exit 1
elif [[ $env_fail_count -gt 0 || $skip_count -gt 0 ]]; then
    exit 2
fi
exit 0
