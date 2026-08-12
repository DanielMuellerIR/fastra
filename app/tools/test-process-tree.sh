#!/bin/bash
# Beendet genau die Prozessbäume, die ein Fastra-Test-Runner selbst gestartet
# hat. Der Helfer arbeitet zuerst mit TERM/CONT und setzt nach einer kurzen
# Frist KILL ein. Wiederverwendete Build-Dienste außerhalb dieser Bäume bleiben
# unangetastet.

FASTRA_TEST_TREE_PIDS=()
FASTRA_TEST_TREE_PID_TOKENS=()
FASTRA_TEST_TREE_GROUPS=()
FASTRA_TEST_STARTED_PID=""
FASTRA_TEST_PENDING_PID=""
FASTRA_TEST_PENDING_HANDSHAKE=""
FASTRA_TEST_PENDING_BUNDLE=""
FASTRA_TEST_STARTED_ROOTS=()
FASTRA_TEST_STARTED_GROUPS=()
FASTRA_TEST_STARTED_TOKENS=()

# Prüft den Selbsttestnamen als vollständiges Argument beziehungsweise als
# vollständigen Umgebungswert. Ein bloßer Teilstring wäre gefährlich:
# `coldopen` darf zum Beispiel niemals den getrennten Test `coldopenoff`
# beanspruchen und dessen Prozess später beenden.
fastra_test_command_names_selftest() {
    local command="$1"
    local test_name="$2"
    [[ " $command " == *" -selftest $test_name "* \
       || " $command " == *" FASTRA_SELFTEST=$test_name "* ]]
}

# Startet den eigentlichen Test als Leiter einer eigenen Session/Prozessgruppe.
# Ein kleines Datei-Handshake hält den Helfer fest, bis der Runner PID,
# Startzeit und Prozessgruppe sicher notiert hat. SIGSTOP/SIGCONT eignet sich
# hier nicht: Trifft CONT vor dem noch ausstehenden STOP, bliebe der Test
# anschließend dauerhaft angehalten.
fastra_test_start_new_session() {
    local handshake ready go released token="" group="" tick=0
    # Ein zweiter Start vor der ausdrücklichen Übernahme des ersten wäre nicht
    # eindeutig aufzuräumen. Jeder Aufrufer muss nach eigener Buchhaltung
    # `fastra_test_adopt_started_session` ausführen.
    [ -z "$FASTRA_TEST_PENDING_PID" ] || return 2
    handshake=$(mktemp -d "${FASTRA_TEST_TMPDIR:?}/process-start.XXXXXX") \
        || return 2
    FASTRA_TEST_PENDING_HANDSHAKE="$handshake"
    ready="$handshake/ready"
    go="$handshake/go"
    released="$handshake/released"
    /usr/bin/python3 -c '
import os, sys, time
os.setsid()
ready, go, released = sys.argv[1], sys.argv[2], sys.argv[3]
parent = int(sys.argv[4])
# Die erwartete PID kommt vom Runner. Würde das Kind sie erst hier mit
# getppid() lesen, könnte ein bereits beendeter Runner unbemerkt PID 1 als
# vermeintlich gesunden Elternprozess festhalten.
if os.getppid() != parent:
    raise SystemExit(125)
with open(ready, "w", encoding="ascii") as handle:
    handle.write(str(os.getpid()))
    handle.flush()
    os.fsync(handle.fileno())
while not os.path.exists(go):
    # Stirbt der Runner genau zwischen fork() und dem Veröffentlichen von $!,
    # kann sein Trap diese PID noch nicht kennen. Dann beendet sich der Helfer
    # selbst, statt nach dem Löschen der Sandbox ewig auf `go` zu warten.
    if os.getppid() != parent or not os.path.isdir(os.path.dirname(ready)):
        raise SystemExit(125)
    time.sleep(0.01)
with open(released, "w", encoding="ascii") as handle:
    handle.write(str(os.getpid()))
    handle.flush()
    os.fsync(handle.fileno())
os.execvp(sys.argv[5], sys.argv[5:])
' "$ready" "$go" "$released" "$$" "$@" &
    FASTRA_TEST_PENDING_PID=$!
    FASTRA_TEST_STARTED_PID="$FASTRA_TEST_PENDING_PID"
    while [ "$tick" -lt 100 ]; do
        token=$(fastra_test_pid_token "$FASTRA_TEST_STARTED_PID")
        group=$(ps -p "$FASTRA_TEST_STARTED_PID" -o pgid= 2>/dev/null \
            | tr -d ' ' || true)
        [ -n "$token" ] && [ "$group" = "$FASTRA_TEST_STARTED_PID" ] \
            && [ -s "$ready" ] && break
        sleep 0.01
        tick=$((tick + 1))
    done
    if [ -z "$token" ] || [ "$group" != "$FASTRA_TEST_STARTED_PID" ] \
       || [ ! -s "$ready" ]; then
        if [ -n "$token" ] \
           && fastra_test_pid_matches_token "$FASTRA_TEST_STARTED_PID" "$token"; then
            kill -TERM "$FASTRA_TEST_STARTED_PID" 2>/dev/null || true
            sleep 0.05
            fastra_test_pid_matches_token "$FASTRA_TEST_STARTED_PID" "$token" \
                && kill -KILL "$FASTRA_TEST_STARTED_PID" 2>/dev/null || true
        fi
        wait "$FASTRA_TEST_STARTED_PID" 2>/dev/null || true
        rm -rf -- "$handshake"
        FASTRA_TEST_PENDING_PID=""
        FASTRA_TEST_PENDING_HANDSHAKE=""
        FASTRA_TEST_PENDING_BUNDLE=""
        FASTRA_TEST_STARTED_PID=""
        return 2
    fi
    FASTRA_TEST_STARTED_ROOTS+=("$FASTRA_TEST_STARTED_PID")
    FASTRA_TEST_STARTED_GROUPS+=("$group")
    FASTRA_TEST_STARTED_TOKENS+=("$token")
    if ! : > "$go"; then
        kill -TERM -"$group" 2>/dev/null || true
        wait "$FASTRA_TEST_STARTED_PID" 2>/dev/null || true
        rm -rf -- "$handshake"
        FASTRA_TEST_PENDING_PID=""
        FASTRA_TEST_PENDING_HANDSHAKE=""
        FASTRA_TEST_PENDING_BUNDLE=""
        FASTRA_TEST_STARTED_PID=""
        return 2
    fi
    tick=0
    while [ "$tick" -lt 100 ] && [ ! -s "$released" ]; do
        fastra_test_pid_matches_token "$FASTRA_TEST_STARTED_PID" "$token" \
            || break
        sleep 0.01
        tick=$((tick + 1))
    done
    if [ ! -s "$released" ]; then
        terminate_fastra_test_process_trees "$FASTRA_TEST_STARTED_PID" \
            >/dev/null 2>&1 || true
        wait "$FASTRA_TEST_STARTED_PID" 2>/dev/null || true
        rm -rf -- "$handshake"
        FASTRA_TEST_PENDING_PID=""
        FASTRA_TEST_PENDING_HANDSHAKE=""
        FASTRA_TEST_PENDING_BUNDLE=""
        FASTRA_TEST_STARTED_PID=""
        return 2
    fi
    # PENDING bleibt absichtlich gesetzt: Trifft jetzt ein Signal, kennt der
    # Trap den bereits freigegebenen Prozess noch. Erst nachdem der Aufrufer
    # seine eigenen PID-/Bundle-Felder gesetzt hat, bestätigt er die Übernahme.
    return 0
}

fastra_test_pending_start_was_released() {
    [ -n "$FASTRA_TEST_PENDING_HANDSHAKE" ] \
        && [ -s "$FASTRA_TEST_PENDING_HANDSHAKE/released" ]
}

fastra_test_adopt_started_session() {
    [ -n "$FASTRA_TEST_PENDING_PID" ] || return 2
    fastra_test_pending_start_was_released || return 2
    fastra_test_discard_pending_session
}

fastra_test_discard_pending_session() {
    local handshake="$FASTRA_TEST_PENDING_HANDSHAKE"
    if [ -n "$handshake" ]; then
        case "$handshake" in
            "$FASTRA_TEST_TMPDIR"/process-start.*) ;;
            *) return 2 ;;
        esac
        if [ -e "$handshake" ] || [ -L "$handshake" ]; then
            [ -d "$handshake" ] && [ ! -L "$handshake" ] || return 2
        fi
    fi
    # Die Prozess-PID gehört ab jetzt entweder bereits der Buchhaltung des
    # Aufrufers oder wurde im Cleanup vollständig beendet. Globals VOR dem
    # externen `rm` leeren: Trifft dort ein Signal, ist ein zweiter Discard
    # ein harmloser No-op statt eines falschen Cleanup-Blockers.
    FASTRA_TEST_PENDING_PID=""
    FASTRA_TEST_PENDING_HANDSHAKE=""
    FASTRA_TEST_PENDING_BUNDLE=""
    [ -z "$handshake" ] || [ ! -e "$handshake" ] \
        || rm -rf -- "$handshake" || return 2
}

fastra_test_pid_token() {
    ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//' || true
}

# LaunchServices liefert die PID nicht beim Start. Sobald der Runner sie über
# den exakten Bundlepfad gefunden hat, kann er eine eigene Prozessgruppe
# nachträglich ebenso sicher merken — aber nur, wenn die App selbst ihr Leiter
# ist. Eine fremde/geteilte Gruppe wird niemals pauschal signalisiert.
fastra_test_remember_process_group() {
    local root="$1" token group
    token=$(fastra_test_pid_token "$root")
    group=$(ps -p "$root" -o pgid= 2>/dev/null | tr -d ' ' || true)
    [ -n "$token" ] && [ "$group" = "$root" ] || return 1
    FASTRA_TEST_STARTED_ROOTS+=("$root")
    FASTRA_TEST_STARTED_GROUPS+=("$group")
    FASTRA_TEST_STARTED_TOKENS+=("$token")
}

fastra_test_tree_append_unique_pid() {
    local value="$1"
    local existing token
    if [ "${#FASTRA_TEST_TREE_PIDS[@]}" -gt 0 ]; then
        for existing in "${FASTRA_TEST_TREE_PIDS[@]}"; do
            [ "$existing" = "$value" ] && return 0
        done
    fi
    token=$(fastra_test_pid_token "$value")
    [ -n "$token" ] || return 0
    FASTRA_TEST_TREE_PIDS+=("$value")
    FASTRA_TEST_TREE_PID_TOKENS+=("$token")
}

fastra_test_tree_append_unique_group() {
    local value="$1"
    local existing
    if [ "${#FASTRA_TEST_TREE_GROUPS[@]}" -gt 0 ]; then
        for existing in "${FASTRA_TEST_TREE_GROUPS[@]}"; do
            [ "$existing" = "$value" ] && return 0
        done
    fi
    FASTRA_TEST_TREE_GROUPS+=("$value")
}

fastra_test_tree_collect() {
    local parent="$1"
    local runner_group="$2"
    local child
    fastra_test_tree_append_unique_pid "$parent"
    while IFS= read -r child; do
        [[ "$child" =~ ^[0-9]+$ ]] || continue
        fastra_test_tree_collect "$child" "$runner_group"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
}

fastra_test_pid_matches_token() {
    local wanted_pid="$1"
    local wanted_token="$2"
    [ "$(fastra_test_pid_token "$wanted_pid")" = "$wanted_token" ]
}

fastra_test_root_was_started_by_runner() {
    local wanted_root="$1" index=0 current
    while [ "$index" -lt "${#FASTRA_TEST_STARTED_ROOTS[@]}" ]; do
        if [ "${FASTRA_TEST_STARTED_ROOTS[$index]}" = "$wanted_root" ]; then
            current=$(fastra_test_pid_token "$wanted_root")
            [ -z "$current" ] && return 0
            [ "$current" = "${FASTRA_TEST_STARTED_TOKENS[$index]}" ] && return 0
            return 1
        fi
        index=$((index + 1))
    done
    return 1
}

# Die neue Session erhält atomar PGID == Start-PID. Solange ein verwaistes
# Kind in dieser Gruppe lebt, kann macOS diese Nummer nicht für eine neue
# Prozessgruppe wiederverwenden. Ist der Leiter schon beendet, bleibt die beim
# Start gemerkte Gruppe deshalb noch eindeutig diesem Runner zugeordnet.
fastra_test_started_group_is_owned() {
    local wanted_group="$1" index=0 root token
    while [ "$index" -lt "${#FASTRA_TEST_STARTED_GROUPS[@]}" ]; do
        if [ "${FASTRA_TEST_STARTED_GROUPS[$index]}" = "$wanted_group" ]; then
            root="${FASTRA_TEST_STARTED_ROOTS[$index]}"
            token="${FASTRA_TEST_STARTED_TOKENS[$index]}"
            if fastra_test_pid_matches_token "$root" "$token"; then
                return 0
            fi
            # PID bereits frei: Eine noch lebende gleichnamige Gruppe gehört
            # weiterhin zur gestarteten Session. Eine wiederverwendete PID mit
            # anderem Starttoken wäre dagegen kein sicherer Treffer.
            if ! kill -0 "$root" 2>/dev/null && fastra_test_group_is_live "$wanted_group"; then
                return 0
            fi
        fi
        index=$((index + 1))
    done
    return 1
}

fastra_test_pid_is_live() {
    local pid="$1"
    local state
    state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || true)
    [ -n "$state" ] && [[ "$state" != Z* ]]
}

fastra_test_group_is_live() {
    local group="$1"
    ps -axo pgid=,stat= 2>/dev/null \
        | awk -v wanted="$group" '$1 == wanted && $2 !~ /^Z/ { found=1 } END { exit !found }'
}

# Aufruf: terminate_fastra_test_process_trees PID [PID ...]
# Rückgabe 2 bedeutet, dass die eigene Prozessgruppe nicht sicher feststellbar
# war. In diesem Fall werden absichtlich nur die exakten PIDs signalisiert;
# ein Gruppensignal könnte sonst den Runner oder seine aufrufende Shell treffen.
terminate_fastra_test_process_trees() {
    local runner_group root group pid tick live group_signals=1 index token
    runner_group=$(ps -p $$ -o pgid= 2>/dev/null | tr -d ' ' || true)
    if ! [[ "$runner_group" =~ ^[0-9]+$ ]] || [ "$runner_group" -le 1 ]; then
        group_signals=0
        runner_group=""
    fi
    FASTRA_TEST_TREE_PIDS=()
    FASTRA_TEST_TREE_PID_TOKENS=()
    FASTRA_TEST_TREE_GROUPS=()
    for root in "$@"; do
        [[ "$root" =~ ^[0-9]+$ ]] || continue
        # Eine gespeicherte Root-PID kann nach schnellem Prozessende bereits
        # neu vergeben sein. Erst die beim START gemerkte Startzeit prüfen;
        # ein fremder neuer Prozess darf weder gesammelt noch signalisiert
        # werden. Eine noch lebende alte Prozessgruppe bleibt separat sicher
        # über ihren gespeicherten Leiter gebunden.
        if fastra_test_root_was_started_by_runner "$root"; then
            token=$(fastra_test_pid_token "$root")
            if [ -n "$token" ]; then
                fastra_test_tree_collect "$root" "$runner_group"
            fi
        else
            index=0
            local known_root=0
            while [ "$index" -lt "${#FASTRA_TEST_STARTED_ROOTS[@]}" ]; do
                [ "${FASTRA_TEST_STARTED_ROOTS[$index]}" = "$root" ] \
                    && known_root=1
                index=$((index + 1))
            done
            [ "$known_root" -eq 0 ] \
                && fastra_test_tree_collect "$root" "$runner_group"
        fi
        index=0
        while [ "$index" -lt "${#FASTRA_TEST_STARTED_ROOTS[@]}" ]; do
            if [ "${FASTRA_TEST_STARTED_ROOTS[$index]}" = "$root" ]; then
                group="${FASTRA_TEST_STARTED_GROUPS[$index]}"
                [ "$group" != "$runner_group" ] \
                    && fastra_test_tree_append_unique_group "$group"
            fi
            index=$((index + 1))
        done
    done

    if [ "$group_signals" -eq 1 ] && [ "${#FASTRA_TEST_TREE_GROUPS[@]}" -gt 0 ]; then
        for group in "${FASTRA_TEST_TREE_GROUPS[@]}"; do
            if fastra_test_started_group_is_owned "$group"; then
                kill -TERM -"$group" 2>/dev/null || true
                kill -CONT -"$group" 2>/dev/null || true
            fi
        done
    fi
    if [ "${#FASTRA_TEST_TREE_PIDS[@]}" -gt 0 ]; then
        index=0
        while [ "$index" -lt "${#FASTRA_TEST_TREE_PIDS[@]}" ]; do
            pid="${FASTRA_TEST_TREE_PIDS[$index]}"
            token="${FASTRA_TEST_TREE_PID_TOKENS[$index]}"
            if fastra_test_pid_matches_token "$pid" "$token"; then
                kill -TERM "$pid" 2>/dev/null || true
                kill -CONT "$pid" 2>/dev/null || true
            fi
            index=$((index + 1))
        done
    fi

    tick=0
    while [ "$tick" -lt 40 ]; do
        live=0
        if [ "${#FASTRA_TEST_TREE_PIDS[@]}" -gt 0 ]; then
            for pid in "${FASTRA_TEST_TREE_PIDS[@]}"; do
                fastra_test_pid_is_live "$pid" && live=1
            done
        fi
        if [ "$group_signals" -eq 1 ] && [ "${#FASTRA_TEST_TREE_GROUPS[@]}" -gt 0 ]; then
            for group in "${FASTRA_TEST_TREE_GROUPS[@]}"; do
                fastra_test_group_is_live "$group" && live=1
            done
        fi
        if [ "$live" -eq 0 ]; then
            [ "$group_signals" -eq 1 ] && return 0
            return 2
        fi
        if [ "$tick" -eq 20 ]; then
            if [ "$group_signals" -eq 1 ] && [ "${#FASTRA_TEST_TREE_GROUPS[@]}" -gt 0 ]; then
                for group in "${FASTRA_TEST_TREE_GROUPS[@]}"; do
                    fastra_test_started_group_is_owned "$group" \
                        && kill -KILL -"$group" 2>/dev/null || true
                done
            fi
            if [ "${#FASTRA_TEST_TREE_PIDS[@]}" -gt 0 ]; then
                index=0
                while [ "$index" -lt "${#FASTRA_TEST_TREE_PIDS[@]}" ]; do
                    pid="${FASTRA_TEST_TREE_PIDS[$index]}"
                    token="${FASTRA_TEST_TREE_PID_TOKENS[$index]}"
                    fastra_test_pid_matches_token "$pid" "$token" \
                        && kill -KILL "$pid" 2>/dev/null || true
                    index=$((index + 1))
                done
            fi
        fi
        sleep 0.05
        tick=$((tick + 1))
    done
    [ "$group_signals" -eq 1 ] || return 2
    return 1
}
