#!/bin/bash

# Gemeinsame Sperre für alle Fastra-Fenstertests dieses Macs. Sie liegt bewusst
# außerhalb eines Worktrees: Zwei parallele Runner würden sich sonst Fokus,
# Defaults und App-Prozesse streitig machen und sowohl Funktion als auch Zeiten
# verfälschen.
FASTRA_GUI_LOCK_DIR="${FASTRA_GUI_LOCK_DIR:-/tmp/fastra-gui-tests-${UID}.lock}"
FASTRA_GUI_LOCK_HELD=0

fastra_gui_lock_pid_token() {
    ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' || true
}

write_fastra_gui_lock_owner() {
    local token
    token=$(fastra_gui_lock_pid_token "$$")
    [ -n "$token" ] || return 2
    printf '%s\n%s\n' "$$" "$token" > "$FASTRA_GUI_LOCK_DIR/pid"
}

acquire_fastra_gui_test_lock() {
    local owner=""
    local owner_token=""
    local directory_owner=""
    local modified=""
    local now=""
    if mkdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null; then
        if ! write_fastra_gui_lock_owner; then
            echo "✗ Besitzer der Fenster-Test-Sperre konnte nicht gespeichert werden." >&2
            rm -f -- "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true
            rmdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null || true
            return 2
        fi
        FASTRA_GUI_LOCK_HELD=1
        return 0
    fi

    if [ ! -d "$FASTRA_GUI_LOCK_DIR" ] || [ -L "$FASTRA_GUI_LOCK_DIR" ]; then
        echo "✗ Fenster-Test-Sperre ist kein echtes Verzeichnis: $FASTRA_GUI_LOCK_DIR" >&2
        return 2
    fi
    directory_owner=$(stat -f '%u' "$FASTRA_GUI_LOCK_DIR" 2>/dev/null || true)
    if [ "$directory_owner" != "$UID" ]; then
        echo "✗ Fenster-Test-Sperre gehört einem anderen Nutzer: $FASTRA_GUI_LOCK_DIR" >&2
        return 2
    fi
    if [ -f "$FASTRA_GUI_LOCK_DIR/pid" ] && [ ! -L "$FASTRA_GUI_LOCK_DIR/pid" ]; then
        owner=$(sed -n '1p' "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true)
        owner_token=$(sed -n '2p' "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true)
    fi
    if [[ "$owner" =~ ^[0-9]+$ ]] && [ -n "$owner_token" ] \
       && [ "$(fastra_gui_lock_pid_token "$owner")" = "$owner_token" ]; then
        echo "✗ Ein anderer Fastra-Fenstertest läuft bereits (PID $owner)." >&2
        return 2
    fi

    # Zwischen dem atomaren mkdir und dem Schreiben der PID liegt ein winziges
    # Fenster. Eine zweite Instanz darf die neue Sperre darin nicht als verwaist
    # löschen. Erst ein mindestens zehn Sekunden altes Verzeichnis ohne gültige
    # lebende PID wird übernommen; ein regulärer Erwerb schreibt sie sofort.
    if [[ ! "$owner" =~ ^[0-9]+$ || -z "$owner_token" ]]; then
        modified=$(stat -f '%m' "$FASTRA_GUI_LOCK_DIR" 2>/dev/null || true)
        now=$(date +%s)
        if [[ "$modified" =~ ^[0-9]+$ ]] && [ $((now - modified)) -lt 10 ]; then
            echo "✗ Eine Fastra-Fenster-Test-Sperre wird gerade eingerichtet." >&2
            return 2
        fi
    fi

    # Nur eine nachweislich verwaiste, exakt bekannte Sperre übernehmen. Kein
    # rekursives Löschen: Unerwarteter Inhalt bleibt als sichtbarer Fehler stehen.
    rm -f -- "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true
    if ! rmdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null; then
        echo "✗ Verwaiste Fenster-Test-Sperre ist nicht leer: $FASTRA_GUI_LOCK_DIR" >&2
        return 2
    fi
    if ! mkdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null; then
        echo "✗ Fenster-Test-Sperre wurde gleichzeitig übernommen. Erneut versuchen." >&2
        return 2
    fi
    if ! write_fastra_gui_lock_owner; then
        echo "✗ Besitzer der übernommenen Fenster-Test-Sperre konnte nicht gespeichert werden." >&2
        rm -f -- "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null || true
        return 2
    fi
    FASTRA_GUI_LOCK_HELD=1
}

release_fastra_gui_test_lock() {
    [ "$FASTRA_GUI_LOCK_HELD" -eq 1 ] || return 0
    local owner=""
    local owner_token=""
    owner=$(sed -n '1p' "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true)
    owner_token=$(sed -n '2p' "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$owner" != "$$" ] \
       || [ "$owner_token" != "$(fastra_gui_lock_pid_token "$$")" ]; then
        echo "✗ Fenster-Test-Sperre gehört beim Freigeben nicht mehr diesem Runner." >&2
        return 2
    fi
    rm -f -- "$FASTRA_GUI_LOCK_DIR/pid" 2>/dev/null || return 2
    rmdir "$FASTRA_GUI_LOCK_DIR" 2>/dev/null || return 2
    FASTRA_GUI_LOCK_HELD=0
}
