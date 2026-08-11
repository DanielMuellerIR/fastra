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
#   4. Die Tests `cmdw`, `newwindow`, `welcomenew`, `completion4d`,
#      `projectinput` und `help` brauchen ECHTEN Fenster-Fokus. macOS 26 verweigert
#      einem im Hintergrund gestarteten Prozess die Selbst-Aktivierung
#      (kooperative Aktivierung) — der Runner holt die App deshalb von
#      außen per System Events nach vorn. Arbeitet gleichzeitig jemand
#      aktiv am Mac, holt sich dessen App den Fokus sofort zurück → der
#      Test meldet dann einen Umgebungs-FAIL („Umgebungsproblem"), keinen
#      Funktionsfehler. Der Runner weist das gesondert aus (Exit-Code 2).
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
# Pro Test gibt der Runner die originale `SELFTEST <name>: PASS/FAIL`-Zeile
# der App weiter; am Ende steht eine Zusammenfassung.

set -u

cd "$(dirname "$0")"

# Standardmäßig das frische Debug-Bundle prüfen. Der notarierte Installations-
# test kann beide Pfade ausdrücklich auf /Applications/Fastra.app setzen, ohne
# einen zweiten, abweichenden LaunchServices-Runner zu duplizieren.
APP_BIN="${FASTRA_SELFTEST_APP_BIN:-.build/debug/Fastra.app/Contents/MacOS/Fastra}"
APP_BUNDLE="${FASTRA_SELFTEST_APP_BUNDLE:-.build/debug/Fastra.app}"
if [[ "$APP_BUNDLE" == /* ]]; then
    APP_BUNDLE_FOR_OPEN="$APP_BUNDLE"
else
    APP_BUNDLE_FOR_OPEN="$(pwd)/$APP_BUNDLE"
fi
ALL_TESTS=(windows newwindow welcomenew sessionrestore coldopen coldopenoff multisearch bgscroll findbar fields searchoptions projectinput tabswitch tabclosehit tabcompare softwrapprofiles softwrapmodes softwrapanchor selectionscroll selshort dragscroll dragnoscroll rightedge dirtyundo emojisplit emojipaste emojipreview tabscroll typescroll comment4d sighelp4d highlight highlight4d completion4d previewrender xpath markdown markdownblanklines markdownjump markdownappearance mdimagewatch pasteindent jump ghosttext wordclick hscroll replaceall pilldrop navmatch textop joinundo colsel colselwrap colpaste gutterdim sidebarheader footerfit windowheight mdformat sidebarfilter filediff tool4dhint tool4dlsp gototarget gototargetwin searchmark help mdassist search project localization updates git gitactions gitstagefolder gitpushbutton gitmultidiscard gitstickyheader diffwide markdownimport filemodes selsearch wildcard openscope contrast cmdw)
# Fensterlose Tests — laufen auch bei gesperrtem Bildschirm aussagekräftig.
WINDOWLESS_TESTS=(search project projectperf localization markdownimport updates git gitactions filemodes selsearch wildcard openscope tool4dlsp)
# Diese Tests starten das konfigurierte App-Bundle über LaunchServices. Für sie
# reicht ein vorhandenes separates Binary nicht: Der Bundle-Pfad muss ebenfalls
# auf genau diesen Teststand zeigen.
LAUNCH_SERVICES_TESTS=(coldopen coldopenoff cmdw newwindow welcomenew completion4d projectinput help)
# Pro Test max. Wartezeit in Sekunden, bis die SELFTEST-Zeile da sein muss.
# (Fenster-Polling im Test selbst: bis 15 s; plus Puffer für App-Start.)
TIMEOUT_SECS=60
# Harte Schranke je System-Events-Aufruf. Ein erlaubter Aufruf antwortet in
# Millisekunden; wartet er länger, fehlt die Automation-Freigabe (s.
# activate_app).
ACTIVATE_TIMEOUT_SECS=4

# ── Vorbedingungen ───────────────────────────────────────────────────────

# Zu laufende Tests schon vor der Pfadprüfung bestimmen. Nur dann kann der
# Runner unterscheiden, ob der angeforderte Lauf LaunchServices benötigt.
if [[ $# -gt 0 ]]; then
    TESTS=("$@")
else
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
if [[ -x "$APP_BUNDLE_FOR_OPEN/Contents/MacOS/Fastra" ]]; then
    APP_BUNDLE_BIN_ABSOLUTE="$(absolute_executable_path "$APP_BUNDLE_FOR_OPEN/Contents/MacOS/Fastra")"
else
    APP_BUNDLE_BIN_ABSOLUTE="$APP_BIN_ABSOLUTE"
fi
APP_PROCESS_PATTERNS=("^$(escape_process_pattern "$APP_BIN_ABSOLUTE")([[:space:]]|$)")
if [[ "$APP_BUNDLE_BIN_ABSOLUTE" != "$APP_BIN_ABSOLUTE" ]]; then
    APP_PROCESS_PATTERNS+=("^$(escape_process_pattern "$APP_BUNDLE_BIN_ABSOLUTE")([[:space:]]|$)")
fi
STARTED_PIDS=()

# Gesperrter Bildschirm? Dann sind alle fensterbasierten Tests Umgebungs-
# rauschen (siehe ../docs/BUILD-AND-TEST.md, Umgebungs-Falle 2). Nur `search` ist dann
# aussagekräftig (fensterlos).
console_locked() {
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
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        echo "  Keiner der angeforderten Tests ist fensterlos. Abbruch (Exit 2)."
        exit 2
    fi
    echo "  Es läuft nur: ${FILTERED[*]}"
    TESTS=("${FILTERED[@]}")
fi

# ── Hilfsfunktionen ──────────────────────────────────────────────────────

# Eine vom Runner direkt gestartete PID merken. LaunchServices gibt die App-PID
# nicht zurück; solche Starts werden ergänzend über den exakten Bundle-Pfad
# gefunden.
track_started_pid() {
    STARTED_PIDS+=("$1")
}

remember_bundle_pids() {
    local pattern pid
    for pattern in "${APP_PROCESS_PATTERNS[@]}"; do
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && STARTED_PIDS+=("$pid")
        done < <(pgrep -f "$pattern" 2>/dev/null || true)
    done
}

# Zuerst nur die selbst gestarteten PIDs beenden. Der Restabgleich ist bewusst
# auf den absoluten Binary-Pfad des konfigurierten Bundles beschränkt; das alte
# globale `Fastra.app/...`-Muster gefährdete andere Worktrees und Nutzerarbeit.
kill_leftovers() {
    local pid pattern
    # macOS liefert bash 3.2: Dort gilt ein LEERES Array unter `set -u` bei
    # `"${arr[@]}"` als unbound. Die Längenabfrage umgeht das gefahrlos.
    if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
        for pid in "${STARTED_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    for pattern in "${APP_PROCESS_PATTERNS[@]}"; do
        pkill -f "$pattern" 2>/dev/null || true
    done
    STARTED_PIDS=()
    sleep 1
}

# Wartet, bis die SELFTEST-Zeile in $1 auftaucht oder das Timeout reißt.
wait_for_result() {
    local errfile="$1"
    local waited=0
    while [[ $waited -lt $TIMEOUT_SECS ]]; do
        if grep -q '^SELFTEST ' "$errfile" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
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
    osascript -e 'with timeout of 3 seconds' \
              -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $target_pid) to true" \
              -e 'end timeout' >/dev/null 2>&1 &
    local pid=$!
    local waited=0
    while [[ $waited -lt $ACTIVATE_TIMEOUT_SECS ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            return $?
        fi
        sleep 1
        waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 2
}

# PID des in dieser Runde gestarteten Test-Bundles: die zuletzt erfasste.
# `kill_leftovers` leert die Liste zu Beginn jeder Runde, es kann also nur ein
# Prozess dieser Runde darin stehen.
current_app_pid() {
    if [ "${#STARTED_PIDS[@]}" -gt 0 ]; then
        printf '%s\n' "${STARTED_PIDS[${#STARTED_PIDS[@]} - 1]}"
    fi
}

# Holt die per `open` gestartete Test-App nach vorn (für Tests, die echten
# Fenster-Fokus brauchen). Mehrere Versuche, weil LaunchServices die App erst
# nach kurzer Zeit als Prozess anlegt — die PID wird deshalb in der Schleife
# nachgeholt. Best effort: bei aktiv benutztem Desktop gewinnt der
# Nutzer-Fokus trotzdem.
activate_app() {
    local target_pid=""
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if [[ ! "$target_pid" =~ ^[0-9]+$ ]]; then
            remember_bundle_pids
            target_pid="$(current_app_pid)"
        fi
        if [[ ! "$target_pid" =~ ^[0-9]+$ ]]; then
            # Prozess noch nicht da — nächster Versuch.
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
    trap - EXIT INT TERM
    kill_leftovers
    cleanup_coldopen_fixture
    exit "$original_status"
}

cleanup_on_signal() {
    local signal="$1"
    trap - EXIT INT TERM
    kill_leftovers
    cleanup_coldopen_fixture
    trap - "$signal"
    kill -"$signal" $$
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal TERM' TERM

# ── Testlauf ─────────────────────────────────────────────────────────────

pass_count=0
real_fail_count=0
env_fail_count=0
skip_count=0
summary=""

# Wegen gesperrtem Bildschirm ausgelassene Fenstertests sofort ausweisen — je
# eine maschinenlesbare Zeile im gewohnten `SELFTEST <name>:`-Format. Sie
# zwingen am Ende Exit 2: Der Lauf ist unvollständig, nicht bestanden.
# macOS liefert bash 3.2: Ein leeres Array unter `set -u` erst über die Länge
# prüfen, sonst gilt "${arr[@]}" als unbound.
if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
    for t in "${SKIPPED_TESTS[@]}"; do
        echo "SELFTEST $t: SKIP — Bildschirm gesperrt (Umgebungsproblem)"
        summary+="⚠ $t (übersprungen: Bildschirm gesperrt)\n"
        skip_count=$((skip_count + 1))
    done
fi

for t in "${TESTS[@]}"; do
    kill_leftovers
    errfile="$(mktemp /tmp/fastra-selftest-${t}.XXXXXX)"

    if [[ "$t" == "coldopen" || "$t" == "coldopenoff" ]]; then
        # Reale Kaltstart-Zustellung: LaunchServices öffnet eine existierende
        # Datei mit genau dem frisch gebauten Bundle. Der Testprozess legt
        # parallel vor seinem ersten Workspace eine abweichende alte Sitzung an.
        coldopen_fixture_dir="$(mktemp -d /tmp/fastra-selftest-coldopen.XXXXXX)"
        coldopen_fixture_file="$coldopen_fixture_dir/README.de.md"
        printf 'Explizit per LaunchServices geöffnet\n' > "$coldopen_fixture_file"
        open -g -n -a "$APP_BUNDLE_FOR_OPEN" \
            --stdout /dev/null --stderr "$errfile" \
            --env "FASTRA_SELFTEST=$t" \
            --env "FASTRA_COLDOPEN_FILE=$coldopen_fixture_file" \
            "$coldopen_fixture_file" \
            --args -ApplePersistenceIgnoreState YES
        remember_bundle_pids
    elif [[ "$t" == "cmdw" || "$t" == "newwindow" || "$t" == "welcomenew" || "$t" == "completion4d" || "$t" == "projectinput" || "$t" == "help" ]]; then
        # Diese Tests prüfen echte Tastatur- oder Mausbedienung (bei
        # `completion4d` ⌃Leertaste, Pfeil und Klick; bei `projectinput`
        # die Eingabe ins native Filterfeld) und brauchen daher
        # Fokus → via `open` starten und von außen aktivieren. Der
        # gemeinsame Aufräumpfad `kill_leftovers` beendet die Test-App nach
        # Ergebnis UND Timeout sofort, damit kein Fenster sichtbar bleibt.
        # starten (LaunchServices) und von außen aktivieren.
        open -n "$APP_BUNDLE_FOR_OPEN" --stdout /dev/null --stderr "$errfile" \
            --args -selftest "$t" -ApplePersistenceIgnoreState YES
        remember_bundle_pids
        activate_app
        remember_bundle_pids
    else
        # Alle anderen Tests laufen ohne echten Fokus → Binary direkt.
        "$APP_BIN_ABSOLUTE" -selftest "$t" -ApplePersistenceIgnoreState YES \
            >/dev/null 2>"$errfile" &
        track_started_pid "$!"
    fi

    if ! wait_for_result "$errfile"; then
        echo "SELFTEST $t: FAIL — keine Ergebnis-Zeile binnen ${TIMEOUT_SECS}s (Runner-Timeout)"
        # Beim Timeout bleibt die stderr-Datei zur Diagnose liegen —
        # der Pfad wird dafür sichtbar genannt.
        echo "  stderr: $errfile"
        summary+="✗ $t (Timeout)\n"
        real_fail_count=$((real_fail_count + 1))
        kill_leftovers
        cleanup_coldopen_fixture
        continue
    fi

    line="$(grep '^SELFTEST ' "$errfile" | tail -1)"
    echo "$line"

    if [[ "$line" == *": PASS"* ]]; then
        pass_count=$((pass_count + 1))
        summary+="✓ $t\n"
        rm -f -- "$errfile"
    elif [[ "$line" == *"Umgebungsproblem"* ]]; then
        # Vom Test selbst als Umgebungsproblem ausgewiesen (z.B. Fokus
        # wurde vom aktiv arbeitenden Nutzer zurückgeholt) — gesondert
        # zählen, damit echte Funktionsfehler nicht untergehen.
        env_fail_count=$((env_fail_count + 1))
        summary+="⚠ $t (Umgebung)\n"
        rm -f -- "$errfile"
    else
        real_fail_count=$((real_fail_count + 1))
        summary+="✗ $t\n"
        # Bei echten FAILs bleibt die stderr-Datei zur Diagnose liegen.
        echo "  stderr: $errfile"
    fi
    cleanup_coldopen_fixture
done

kill_leftovers
cleanup_coldopen_fixture

# ── Zusammenfassung ──────────────────────────────────────────────────────

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
