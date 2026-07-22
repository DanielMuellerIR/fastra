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
#      der Runner prüft das vorab und lässt dann nur `search` zu.
#   4. Die Tests `cmdw`, `newwindow`, `completion4d` und `help` brauchen ECHTEN Fenster-Fokus. macOS 26 verweigert
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
ALL_TESTS=(windows newwindow welcomenew sessionrestore coldopen multisearch findbar fields searchoptions tabswitch tabclosehit tabcompare softwrapprofiles softwrapmodes softwrapanchor selectionscroll highlight highlight4d completion4d previewrender xpath markdown markdownblanklines markdownjump markdownappearance jump ghosttext wordclick hscroll replaceall pilldrop navmatch textop joinundo colsel colselwrap colpaste gutterdim sidebarheader sidebarfilter filediff tool4dhint tool4dlsp gototarget searchmark help mdassist search project localization updates git gitactions filemodes selsearch wildcard openscope contrast cmdw)
# Fensterlose Tests — laufen auch bei gesperrtem Bildschirm aussagekräftig.
WINDOWLESS_TESTS=(search project localization updates git gitactions filemodes selsearch wildcard openscope tool4dlsp)
# Pro Test max. Wartezeit in Sekunden, bis die SELFTEST-Zeile da sein muss.
# (Fenster-Polling im Test selbst: bis 15 s; plus Puffer für App-Start.)
TIMEOUT_SECS=60

# ── Vorbedingungen ───────────────────────────────────────────────────────

if [[ ! -x "$APP_BIN" ]]; then
    echo "✗ Kein Debug-Build gefunden ($APP_BIN). Erst ./build.sh laufen lassen." >&2
    exit 1
fi

# Gesperrter Bildschirm? Dann sind alle fensterbasierten Tests Umgebungs-
# rauschen (siehe ../docs/BUILD-AND-TEST.md, Umgebungs-Falle 2). Nur `search` ist dann
# aussagekräftig (fensterlos).
console_locked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"IOConsoleLocked" = Yes'
}

# Zu laufende Tests: Argumente oder alle.
if [[ $# -gt 0 ]]; then
    TESTS=("$@")
else
    TESTS=("${ALL_TESTS[@]}")
fi

if console_locked; then
    echo "⚠ Bildschirm ist gesperrt — Fenster-Selbsttests sind nicht aussagekräftig."
    FILTERED=()
    for t in "${TESTS[@]}"; do
        for w in "${WINDOWLESS_TESTS[@]}"; do
            [[ "$t" == "$w" ]] && FILTERED+=("$t")
        done
    done
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        echo "  Keiner der angeforderten Tests ist fensterlos. Abbruch (Exit 2)."
        exit 2
    fi
    echo "  Es läuft nur: ${FILTERED[*]}"
    TESTS=("${FILTERED[@]}")
fi

# ── Hilfsfunktionen ──────────────────────────────────────────────────────

# Alle noch laufenden Fastra-Instanzen beenden (Reste verfälschen
# Aktivierung und System-Events-Abfragen).
kill_leftovers() {
    pkill -f 'Fastra.app/Contents/MacOS/Fastra' 2>/dev/null
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

# Holt die Fastra-App per System Events nach vorn (für Tests, die echten
# Fenster-Fokus brauchen). Mehrere Versuche, weil der Prozess erst nach
# dem ersten Fenster für System Events greifbar ist. Best effort — bei
# aktiv benutztem Desktop gewinnt der Nutzer-Fokus trotzdem.
activate_app() {
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "Fastra") to true' >/dev/null 2>&1; then
            return 0
        fi
    done
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

# ── Testlauf ─────────────────────────────────────────────────────────────

pass_count=0
real_fail_count=0
env_fail_count=0
summary=""

for t in "${TESTS[@]}"; do
    kill_leftovers
    errfile="$(mktemp /tmp/fastra-selftest-${t}.XXXXXX)"

    if [[ "$t" == "coldopen" ]]; then
        # Reale Kaltstart-Zustellung: LaunchServices öffnet eine existierende
        # Datei mit genau dem frisch gebauten Bundle. Der Testprozess legt
        # parallel vor seinem ersten Workspace eine abweichende alte Sitzung an.
        coldopen_fixture_dir="$(mktemp -d /tmp/fastra-selftest-coldopen.XXXXXX)"
        coldopen_fixture_file="$coldopen_fixture_dir/README.de.md"
        printf 'Explizit per LaunchServices geöffnet\n' > "$coldopen_fixture_file"
        open -g -n -a "$APP_BUNDLE_FOR_OPEN" \
            --stdout /dev/null --stderr "$errfile" \
            --env "FASTRA_SELFTEST=coldopen" \
            --env "FASTRA_COLDOPEN_FILE=$coldopen_fixture_file" \
            "$coldopen_fixture_file" \
            --args -ApplePersistenceIgnoreState YES
    elif [[ "$t" == "cmdw" || "$t" == "newwindow" || "$t" == "welcomenew" || "$t" == "completion4d" || "$t" == "help" ]]; then
        # Diese Tests prüfen echte Tastatur- oder Mausbedienung (bei
        # `completion4d` ⌃Leertaste, Pfeil und Klick) und brauchen daher
        # Fokus → via `open` starten und von außen aktivieren. Der
        # gemeinsame Aufräumpfad `kill_leftovers` beendet die Test-App nach
        # Ergebnis UND Timeout sofort, damit kein Fenster sichtbar bleibt.
        # starten (LaunchServices) und von außen aktivieren.
        open -n "$APP_BUNDLE" --stdout /dev/null --stderr "$errfile" \
            --args -selftest "$t" -ApplePersistenceIgnoreState YES
        activate_app
    else
        # Alle anderen Tests laufen ohne echten Fokus → Binary direkt.
        "$APP_BIN" -selftest "$t" -ApplePersistenceIgnoreState YES \
            >/dev/null 2>"$errfile" &
    fi

    if ! wait_for_result "$errfile"; then
        echo "SELFTEST $t: FAIL — keine Ergebnis-Zeile binnen ${TIMEOUT_SECS}s (Runner-Timeout)"
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
    elif [[ "$line" == *"Umgebungsproblem"* ]]; then
        # Vom Test selbst als Umgebungsproblem ausgewiesen (z.B. Fokus
        # wurde vom aktiv arbeitenden Nutzer zurückgeholt) — gesondert
        # zählen, damit echte Funktionsfehler nicht untergehen.
        env_fail_count=$((env_fail_count + 1))
        summary+="⚠ $t (Umgebung)\n"
    else
        real_fail_count=$((real_fail_count + 1))
        summary+="✗ $t\n"
    fi
    cleanup_coldopen_fixture
done

kill_leftovers
cleanup_coldopen_fixture

# ── Zusammenfassung ──────────────────────────────────────────────────────

echo ""
echo "── Selbsttest-Zusammenfassung ──"
printf "%b" "$summary"
echo "PASS: $pass_count · echte FAILs: $real_fail_count · Umgebungs-FAILs: $env_fail_count"

if [[ $real_fail_count -gt 0 ]]; then
    exit 1
elif [[ $env_fail_count -gt 0 ]]; then
    exit 2
fi
exit 0
