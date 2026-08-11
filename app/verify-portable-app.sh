#!/bin/bash
# Prüft ein gepacktes Fastra-Bundle so, wie es auf einem fremden Mac startet.
#
# SwiftPM erzeugt für jedes Ressourcenbundle neben dem portablen Suchpfad
# einen absoluten Fallback in `.build/<Konfiguration>`. Auf dem Build-Mac kann
# dieser Fallback einen falsch gepackten App-Bundle unbemerkt kaschieren. Für
# diesen Test werden deshalb alle Build-Ressourcen kurz ausgeblendet.

set -u
set -o pipefail
umask 077

if [[ $# -ne 2 ]]; then
    echo "Aufruf: $0 <Fastra.app> <Build-Ressourcenordner>" >&2
    exit 1
fi

APP="$1"
BUILD_RESOURCE_DIR="$2"
APP_BIN="$APP/Contents/MacOS/Fastra"

# Auch diese zwei fensterlosen App-Starts sind echte Selbsttests. Ohne die
# gemeinsame Sandbox legte jeder Build zwei leere `Fastra-<UUID>.plist` im
# echten Benutzerprofil an. Der äußere Nachlauf ist nötig, weil cfprefsd eine
# bereits geleerte Suite erst nach dem Ende des App-Prozesses erneut schreiben
# kann.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=tools/test-sandbox.sh
. "$SCRIPT_DIR/tools/test-sandbox.sh"
# shellcheck source=tools/test-process-tree.sh
. "$SCRIPT_DIR/tools/test-process-tree.sh"

if [[ ! -x "$APP_BIN" || ! -d "$BUILD_RESOURCE_DIR" ]]; then
    echo "✗ Portabilitätsprüfung: App oder Build-Ressourcenordner fehlt." >&2
    exit 1
fi

HIDDEN_DIR=""
ERR_FILE=""
MOVED_BUNDLES=()
APP_PID=""
FASTRA_TEST_DEFAULTS_REGISTRY=""

cleanup_on_exit() {
    local original_status=$?
    local cleanup_status=0
    local process_cleanup_failed=0
    local keep_sandbox=0
    trap - EXIT INT TERM
    if [[ -n "$APP_PID" ]]; then
        if ! terminate_fastra_test_process_trees "$APP_PID"; then
            cleanup_status=2
            process_cleanup_failed=1
            keep_sandbox=1
        fi
        wait "$APP_PID" 2>/dev/null || true
    fi
    # macOS liefert noch Bash 3.2. Dort gilt selbst ein deklariertes leeres
    # Array unter `set -u` bei der Expansion als ungebunden. Frühfehler vor
    # dem ersten verschobenen Bundle müssen trotzdem sicher aufräumen.
    if [[ ${#MOVED_BUNDLES[@]} -gt 0 ]]; then
        for bundle in "${MOVED_BUNDLES[@]}"; do
            if [[ -d "$HIDDEN_DIR/$(basename "$bundle")" ]]; then
                mv "$HIDDEN_DIR/$(basename "$bundle")" "$bundle" \
                    || { cleanup_status=2; keep_sandbox=1; }
            fi
        done
    fi
    if [[ "$process_cleanup_failed" -eq 0 ]]; then
        if ! purge_fastra_registered_test_defaults \
            "$FASTRA_TEST_DEFAULTS_REGISTRY"; then
            cleanup_status=2
            keep_sandbox=1
        fi
    fi
    if [[ "$keep_sandbox" -eq 0 ]]; then
        release_fastra_test_sandbox || cleanup_status=2
    else
        # Solange ein App-Prozess noch schreiben könnte oder die einzige
        # versteckte Bundle-Kopie nicht zurückgelegt wurde, darf die private
        # Sandbox nicht verschwinden.
        echo "  Private Portabilitäts-Sandbox zur Diagnose behalten: $FASTRA_TEST_SANDBOX" >&2
    fi
    if [[ "$cleanup_status" -ne 0 ]]; then
        echo "Portabilitätsprüfung: Aufräumen blieb unvollständig." >&2
    fi
    if [[ "$original_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
        exit 2
    fi
    exit "$original_status"
}

create_fastra_test_sandbox selftest-run || exit 2
# Ab hier besitzt der Prozess private Dateien. Jeder weitere Frühfehler muss
# deshalb durch denselben geprüften Aufräumpfad laufen.
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_SANDBOX/defaults-registry.txt"
: > "$FASTRA_TEST_DEFAULTS_REGISTRY" || exit 2
HIDDEN_DIR="$(mktemp -d "$FASTRA_TEST_TMPDIR/portable-resources.XXXXXX")" \
    || exit 2
ERR_FILE="$(mktemp "$FASTRA_TEST_TMPDIR/portable-start.XXXXXX")" || exit 2

for bundle in "$BUILD_RESOURCE_DIR"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    # Vor dem `mv` merken: Trifft ein Signal direkt nach dem erfolgreichen
    # Verschieben, kennt der EXIT-Trap die einzige Bundle-Kopie bereits. Bei
    # einem fehlgeschlagenen `mv` liegt sie weiter am Ursprung; der Trap sieht
    # im Zwischenordner nichts und fasst den Ursprung nicht an.
    MOVED_BUNDLES+=("$bundle")
    if ! mv "$bundle" "$HIDDEN_DIR/"; then
        echo "✗ Portabilitätsprüfung: Build-Ressourcen konnten nicht sicher ausgeblendet werden." >&2
        exit 2
    fi
done

if [[ ${#MOVED_BUNDLES[@]} -eq 0 ]]; then
    echo "✗ Portabilitätsprüfung: Keine SwiftPM-Ressourcenbundles gefunden." >&2
    exit 1
fi

# `localization` liest das Ressourcenbundle direkt. `search` geht zusätzlich
# durch die echte Ordnersuche und startet den gebündelten ripgrep-Prozess. So
# fällt auch ein einzelner vergessener `Bundle.module`-Zugriff auf, statt erst
# beim Nutzer auf einem anderen Mac zu crashen.
for SELFTEST_NAME in localization search; do
    # Getrennte Suiten verhindern, dass ein später cfprefsd-Flush des ersten
    # Prozesses in die gerade vom zweiten Prozess verwendete Domain fällt.
    PORTABLE_DEFAULTS_SUITE="Fastra-$(/usr/bin/uuidgen)"
    : > "$ERR_FILE"
    if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
    CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
    CFPREFERENCES_AVOID_DAEMON=1 \
    HOME="$FASTRA_TEST_CF_HOME" \
    FASTRA_SELFTEST_DEFAULTS_SUITE="$PORTABLE_DEFAULTS_SUITE" \
    FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
    FASTRA_SELFTEST="$SELFTEST_NAME" \
    fastra_test_start_new_session "$APP_BIN" -ApplePersistenceIgnoreState YES \
        >/dev/null 2>"$ERR_FILE"; then
        echo "✗ Portabilitätsprüfung: Selbsttest $SELFTEST_NAME ließ sich nicht sicher starten." >&2
        exit 2
    fi
    APP_PID="$FASTRA_TEST_STARTED_PID"

    # Ein kaputter Ressourcenpfad crasht sofort; ein anderer Start-Hänger darf
    # den Build ebenfalls nicht endlos blockieren. Beide Tests sind fensterlos.
    for _ in {1..150}; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if kill -0 "$APP_PID" 2>/dev/null; then
        echo "✗ Portabilitätsprüfung: Selbsttest $SELFTEST_NAME hängt länger als 15 Sekunden." >&2
        exit 1
    fi

    wait "$APP_PID"
    STATUS=$?
    # Der App-Prozess ist fertig, ein von ihm gestarteter Suchprozess könnte
    # aber seine Session noch am Leben halten. Die beim Start gemerkte Gruppe
    # bleibt auch ohne Leiter eindeutig und wird vor dem nächsten Lauf geleert.
    if ! terminate_fastra_test_process_trees "$APP_PID"; then
        echo "✗ Portabilitätsprüfung: Prozessgruppe von $SELFTEST_NAME blieb aktiv." >&2
        exit 2
    fi
    APP_PID=""

    if [[ $STATUS -ne 0 ]] \
        || ! grep -q "^SELFTEST $SELFTEST_NAME: PASS" "$ERR_FILE"; then
        echo "✗ Portabilitätsprüfung: Selbsttest $SELFTEST_NAME scheitert ohne lokalen Build-Fallback." >&2
        tail -20 "$ERR_FILE" >&2
        exit 1
    fi
done

echo "→ Portabilitätsprüfung: Ressourcen und Ordnersuche funktionieren ohne lokalen Build-Fallback"
