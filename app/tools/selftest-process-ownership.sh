#!/bin/bash

# Die Besitzprüfungen des Selbsttest-Runners verwenden test-process-tree.sh.

# Eine gemerkte PID gehört nur so lange diesem Lauf, wie auch ihre beim
# Erfassen gespeicherte Startzeit übereinstimmt. Der Binary-Pfad allein reicht
# nach einer PID-Wiederverwendung nicht als Besitzbeleg.
tracked_pid_is_owned() {
    local pid="$1"
    local index="$2"
    local token="${STARTED_PID_TOKENS[$index]:-}"
    [ -n "$token" ] && fastra_test_pid_matches_token "$pid" "$token"
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
    # KILL bestätigt nur die Signalannahme. Ein Kernel-Hänger darf weder
    # das folgende wait blockieren noch seine Eigentumsmarke verlieren.
    tick=0
    while [ "$tick" -lt 20 ] \
          && fastra_test_pid_is_live "$pid" \
          && activation_process_is_owned "$pid" "$token"; do
        sleep 0.05
        tick=$((tick + 1))
    done
    if fastra_test_pid_is_live "$pid"; then
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    clear_activation_process
}
