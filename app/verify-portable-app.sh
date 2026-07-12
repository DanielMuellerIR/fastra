#!/bin/bash
# Prüft ein gepacktes Fastra-Bundle so, wie es auf einem fremden Mac startet.
#
# SwiftPM erzeugt für jedes Ressourcenbundle neben dem portablen Suchpfad
# einen absoluten Fallback in `.build/<Konfiguration>`. Auf dem Build-Mac kann
# dieser Fallback einen falsch gepackten App-Bundle unbemerkt kaschieren. Für
# diesen Test werden deshalb alle Build-Ressourcen kurz ausgeblendet.

set -u

if [[ $# -ne 2 ]]; then
    echo "Aufruf: $0 <Fastra.app> <Build-Ressourcenordner>" >&2
    exit 1
fi

APP="$1"
BUILD_RESOURCE_DIR="$2"
APP_BIN="$APP/Contents/MacOS/Fastra"

if [[ ! -x "$APP_BIN" || ! -d "$BUILD_RESOURCE_DIR" ]]; then
    echo "✗ Portabilitätsprüfung: App oder Build-Ressourcenordner fehlt." >&2
    exit 1
fi

HIDDEN_DIR="$(mktemp -d /tmp/fastra-portable-resources.XXXXXX)"
ERR_FILE="$(mktemp /tmp/fastra-portable-start.XXXXXX)"
MOVED_BUNDLES=()
APP_PID=""

restore_resources() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    for bundle in "${MOVED_BUNDLES[@]}"; do
        if [[ -d "$HIDDEN_DIR/$(basename "$bundle")" ]]; then
            mv "$HIDDEN_DIR/$(basename "$bundle")" "$bundle"
        fi
    done
    rm -rf "$HIDDEN_DIR"
    rm -f "$ERR_FILE"
}
trap restore_resources EXIT INT TERM

for bundle in "$BUILD_RESOURCE_DIR"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    MOVED_BUNDLES+=("$bundle")
    mv "$bundle" "$HIDDEN_DIR/"
done

if [[ ${#MOVED_BUNDLES[@]} -eq 0 ]]; then
    echo "✗ Portabilitätsprüfung: Keine SwiftPM-Ressourcenbundles gefunden." >&2
    exit 1
fi

FASTRA_SELFTEST=localization "$APP_BIN" -ApplePersistenceIgnoreState YES \
    >/dev/null 2>"$ERR_FILE" &
APP_PID=$!

# Ein kaputter Ressourcenpfad crasht sofort; ein anderer Start-Hänger darf den
# Build aber ebenfalls nicht endlos blockieren. Der fensterlose Test braucht
# normalerweise deutlich unter einer Sekunde.
for _ in {1..150}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if kill -0 "$APP_PID" 2>/dev/null; then
    echo "✗ Portabilitätsprüfung: installierter Start hängt länger als 15 Sekunden." >&2
    exit 1
fi

wait "$APP_PID"
STATUS=$?
APP_PID=""

if [[ $STATUS -ne 0 ]] || ! grep -q '^SELFTEST localization: PASS' "$ERR_FILE"; then
    echo "✗ Portabilitätsprüfung: Fastra startet ohne lokalen Build-Fallback nicht." >&2
    tail -20 "$ERR_FILE" >&2
    exit 1
fi

echo "→ Portabilitätsprüfung: Start ohne lokalen Build-Fallback erfolgreich"
