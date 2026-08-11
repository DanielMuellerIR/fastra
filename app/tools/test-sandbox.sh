#!/bin/bash
# Gemeinsame Wegwerf-Sandbox für Fastra-Testprozesse.
#
# Test-Fixtures und UserDefaults-Suiten landen sonst direkt im Benutzer-Temp-
# Ordner beziehungsweise in ~/Library/Preferences. Ein einziger abgebrochener
# Lauf kann dort hunderte UUID-Dateien hinterlassen. Die Runner setzen deshalb
# TMPDIR und CFFIXED_USER_HOME auf dieses eine, exakt bekannte Verzeichnis und
# entfernen es am Ende als Einheit. Wiederverwendbare Build-Caches liegen
# außerhalb und werden nicht berührt.

FASTRA_TEST_SANDBOX=""
FASTRA_TEST_SANDBOX_KIND=""
FASTRA_TEST_SANDBOX_PARENT="${FASTRA_TEST_SANDBOX_PARENT:-/tmp}"
FASTRA_TEST_TMPDIR=""
FASTRA_TEST_CF_HOME=""

fastra_test_sandbox_kind_is_allowed() {
    case "$1" in
        unit-tests|selftest-run|soak-run) return 0 ;;
        *) return 1 ;;
    esac
}

fastra_test_sandbox_directory_is_safe() {
    local directory="$1"
    local kind="$2"
    local owner
    fastra_test_sandbox_kind_is_allowed "$kind" || return 1
    case "$directory" in
        "$FASTRA_TEST_SANDBOX_PARENT"/fastra-"$kind".*) ;;
        *) return 1 ;;
    esac
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    owner=$(stat -f '%u' "$directory" 2>/dev/null || true)
    [ "$owner" = "$UID" ]
}

purge_stale_fastra_test_sandboxes() {
    local kind="$1"
    local now modified owner_pid owner_started current_started directory
    fastra_test_sandbox_kind_is_allowed "$kind" || return 2
    now=$(date +%s)
    for directory in "$FASTRA_TEST_SANDBOX_PARENT"/fastra-"$kind".*; do
        fastra_test_sandbox_directory_is_safe "$directory" "$kind" || continue
        modified=$(stat -f '%m' "$directory" 2>/dev/null || echo "$now")
        # Ein normaler Lauf räumt sofort auf. Diese Frist betrifft nur einen
        # Runner, der selbst per SIGKILL oder Rechnerausfall beendet wurde.
        [ $((now - modified)) -ge 86400 ] || continue
        owner_pid=$(sed -n '1p' "$directory/owner-pid" 2>/dev/null || true)
        owner_started=$(sed -n '1p' "$directory/owner-started" 2>/dev/null || true)
        if [[ "$owner_pid" =~ ^[0-9]+$ ]] && [ -n "$owner_started" ] \
           && kill -0 "$owner_pid" 2>/dev/null; then
            current_started=$(ps -p "$owner_pid" -o lstart= 2>/dev/null \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
            [ "$current_started" = "$owner_started" ] && continue
        fi
        rm -rf -- "$directory"
    done
}

create_fastra_test_sandbox() {
    local kind="$1"
    local directory
    if ! fastra_test_sandbox_kind_is_allowed "$kind"; then
        echo "Fastra-Test-Sandbox: unbekannte Art '$kind'." >&2
        return 2
    fi
    if [ ! -d "$FASTRA_TEST_SANDBOX_PARENT" ]; then
        echo "Fastra-Test-Sandbox: Elternordner fehlt." >&2
        return 2
    fi
    purge_stale_fastra_test_sandboxes "$kind" || return $?
    directory=$(mktemp -d "$FASTRA_TEST_SANDBOX_PARENT/fastra-$kind.XXXXXX") || return 2
    if ! fastra_test_sandbox_directory_is_safe "$directory" "$kind"; then
        echo "Fastra-Test-Sandbox: mktemp lieferte einen unerwarteten Pfad." >&2
        return 2
    fi
    local owner_started
    owner_started=$(ps -p $$ -o lstart= 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
    if [ -z "$owner_started" ] \
       || ! printf '%s\n' "$$" > "$directory/owner-pid" \
       || ! printf '%s\n' "$owner_started" > "$directory/owner-started" \
       || ! mkdir -p "$directory/tmp" "$directory/cfhome/Library/Preferences"; then
        rm -rf -- "$directory"
        echo "Fastra-Test-Sandbox: Verzeichnis konnte nicht vorbereitet werden." >&2
        return 2
    fi
    FASTRA_TEST_SANDBOX="$directory"
    FASTRA_TEST_SANDBOX_KIND="$kind"
    FASTRA_TEST_TMPDIR="$directory/tmp"
    FASTRA_TEST_CF_HOME="$directory/cfhome"
}

release_fastra_test_sandbox() {
    [ -n "$FASTRA_TEST_SANDBOX" ] || return 0
    if ! fastra_test_sandbox_directory_is_safe \
        "$FASTRA_TEST_SANDBOX" "$FASTRA_TEST_SANDBOX_KIND"; then
        echo "Fastra-Test-Sandbox: unsicherer Aufräumpfad; nichts entfernt." >&2
        return 2
    fi
    rm -rf -- "$FASTRA_TEST_SANDBOX" || return 2
    FASTRA_TEST_SANDBOX=""
    FASTRA_TEST_SANDBOX_KIND=""
    FASTRA_TEST_TMPDIR=""
    FASTRA_TEST_CF_HOME=""
}

fastra_test_defaults_domain_is_safe() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    case "$domain" in
        FastraTests.*|Fastra-*|fastra-*|fastra.tests.*|ff-*|search-jump-*|smart-paste-context-*) ;;
        *) return 1 ;;
    esac
    [[ "$domain" =~ [0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12} ]]
}

# Der App-/xctest-Prozess leert seine UserDefaults-Suiten selbst. cfprefsd
# legt beim Prozessende jedoch gelegentlich nochmals eine leere 42-Byte-Plist
# an. Erst der äußere Runner kann diese letzte Schreibbewegung sicher abwarten
# und genau die von seinem Prozess registrierten Domains entfernen.
purge_fastra_registered_test_defaults() {
    local registry="$1"
    local preferences="${FASTRA_TEST_PREFERENCES_DIRECTORY:-}"
    local real_preferences="${FASTRA_TEST_REAL_PREFERENCES_DIRECTORY:-$HOME/Library/Preferences}"
    local domain plist real_plist owner failed=0 pass
    [ -f "$registry" ] || return 0
    case "$registry" in "$FASTRA_TEST_SANDBOX"/*) ;; *) return 2 ;; esac
    # Der Nachlauf gehört in dieselbe CFFIXED_USER_HOME-Sandbox wie der
    # Testprozess. Ein Rückfall auf das echte ~/Library/Preferences wäre hier
    # besonders tückisch: `defaults delete` legt für eine dort nie vorhandene
    # UUID-Domain gelegentlich erst die leere 42-Byte-Plist an, die wir gerade
    # vermeiden wollen. Einen abweichenden Pfad gibt es nur als Test-Injektion.
    if [ -z "$preferences" ]; then
        [ -n "${FASTRA_TEST_CF_HOME:-}" ] || return 2
        preferences="$FASTRA_TEST_CF_HOME/Library/Preferences"
    fi

    # cfprefsd kann eine bereits geleerte 42-Byte-Plist erst NACH dem Ende des
    # App-Prozesses zurückschreiben. Drei gezielte Durchgänge mit insgesamt
    # 1,5 Sekunden Beobachtungszeit räumen auch diese letzte Schreibbewegung
    # ab. Das kostet einmal pro Runner Zeit, nicht einmal pro Test.
    for pass in 1 2 3; do
        [ "$pass" -eq 1 ] || sleep 0.5
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            if ! fastra_test_defaults_domain_is_safe "$domain"; then
                echo "Fastra-Test-Sandbox: unsichere Preferences-Domain in Registry." >&2
                failed=1
                continue
            fi
            # `defaults delete` selbst spricht wieder mit cfprefsd und kann
            # dadurch eine weitere verzögerte leere Plist anstoßen. Nur der
            # erste Durchgang leert die Domain logisch; die Nachläufe entfernen
            # ausschließlich die danach noch erscheinende Datei.
            if [ "$pass" -eq 1 ]; then
                CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
                CFPREFERENCES_AVOID_DAEMON=1 \
                HOME="$FASTRA_TEST_CF_HOME" \
                    /usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true
            fi
            plist="$preferences/$domain.plist"
            if [ -e "$plist" ]; then
                [ -f "$plist" ] && [ ! -L "$plist" ] || { failed=1; continue; }
                owner=$(stat -f '%u' "$plist" 2>/dev/null || true)
                [ "$owner" = "$UID" ] || { failed=1; continue; }
                /bin/unlink "$plist" 2>/dev/null || failed=1
            fi
            # CoreFoundation legte bei realen App-Prozessen einzelne Suite-
            # Plists trotz CFFIXED_USER_HOME im echten Preferences-Ordner an.
            # Dort niemals `defaults delete` aufrufen: Das würde cfprefsd erst
            # wieder zu einer verzögerten leeren Datei anregen. Nach Ende des
            # Testprozesses nur die exakt registrierte, sichere UUID-Datei
            # prüfen und entfernen.
            real_plist="$real_preferences/$domain.plist"
            if [ "$real_plist" != "$plist" ] && [ -e "$real_plist" ]; then
                [ -f "$real_plist" ] && [ ! -L "$real_plist" ] \
                    || { failed=1; continue; }
                owner=$(stat -f '%u' "$real_plist" 2>/dev/null || true)
                [ "$owner" = "$UID" ] || { failed=1; continue; }
                /bin/unlink "$real_plist" 2>/dev/null || failed=1
            fi
        done < "$registry"
    done
    sleep 0.5
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        fastra_test_defaults_domain_is_safe "$domain" || continue
        [ ! -e "$preferences/$domain.plist" ] || failed=1
        [ ! -e "$real_preferences/$domain.plist" ] || failed=1
    done < "$registry"
    [ "$failed" -eq 0 ]
}
