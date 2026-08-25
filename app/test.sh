#!/bin/bash
# Unit-Test-Runner mit isoliertem Temp- und Preferences-Verzeichnis.

set -u
set -o pipefail
umask 077

cd "$(dirname "$0")"

# shellcheck source=tools/test-sandbox.sh
. ./tools/test-sandbox.sh
# shellcheck source=tools/test-process-tree.sh
. ./tools/test-process-tree.sh

TEST_PROCESS_PID=""
SERIAL_INTEGRATION_FILTER='[Gg]itIntegration|[Ss]erialRunnerIntegration'
RUN_FAST_PHASE=1
RUN_SERIAL_INTEGRATION_PHASE=1
FAST_PHASE_PARALLEL=1
SWIFT_TEST_ARGUMENTS=()
CALLER_FILTER_PATTERNS=()
PHASE_ENVIRONMENT_ERROR=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fast-only)
            if [ "$RUN_FAST_PHASE" -eq 0 ]; then
                echo "Unit-Tests: --fast-only und --serial-integration-only schließen sich aus." >&2
                exit 2
            fi
            RUN_SERIAL_INTEGRATION_PHASE=0
            ;;
        --serial-integration-only)
            if [ "$RUN_SERIAL_INTEGRATION_PHASE" -eq 0 ]; then
                echo "Unit-Tests: --fast-only und --serial-integration-only schließen sich aus." >&2
                exit 2
            fi
            RUN_FAST_PHASE=0
            ;;
        --parallel)
            # Die schnelle Phase darf der Aufrufer ausdrücklich parallelisieren.
            # Die reale Git-Phase bleibt unabhängig davon immer seriell.
            FAST_PHASE_PARALLEL=1
            ;;
        --no-parallel)
            # Nützlich für Diagnosen: Damit wird auch die schnelle Phase seriell.
            FAST_PHASE_PARALLEL=0
            ;;
        --filter)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "Unit-Tests: --filter braucht einen regulären Ausdruck." >&2
                exit 2
            fi
            CALLER_FILTER_PATTERNS+=("$2")
            shift
            ;;
        --filter=*)
            filter_pattern="${1#--filter=}"
            if [ -z "$filter_pattern" ]; then
                echo "Unit-Tests: --filter braucht einen regulären Ausdruck." >&2
                exit 2
            fi
            CALLER_FILTER_PATTERNS+=("$filter_pattern")
            ;;
        *)
            SWIFT_TEST_ARGUMENTS+=("$1")
            ;;
    esac
    shift
done

requested_phases=$((RUN_FAST_PHASE + RUN_SERIAL_INTEGRATION_PHASE))
run_phases=0
passed_phases=0
failed_phases=0
environment_errors=0
overall_status=0

cleanup() {
    local original_status=$?
    local final_status=$original_status
    local cleanup_status=0
    local process_cleanup_failed=0
    local cleanup_pid
    local cleanup_targets=()
    trap - EXIT INT TERM

    # Ein vollständiger Lauf besitzt zwei nacheinander gestartete
    # Prozessgruppen. Beide bleiben bis zum äußeren Abschluss vermerkt, damit
    # auch ein zwischen den Phasen abgebrochener Runner nur seine eigenen
    # Kindprozesse beendet.
    if [ "${#FASTRA_TEST_STARTED_ROOTS[@]}" -gt 0 ]; then
        cleanup_targets=("${FASTRA_TEST_STARTED_ROOTS[@]}")
    elif [[ "${TEST_PROCESS_PID:-${FASTRA_TEST_PENDING_PID:-}}" =~ ^[0-9]+$ ]]; then
        cleanup_targets=("${TEST_PROCESS_PID:-${FASTRA_TEST_PENDING_PID:-}}")
    fi
    if [ "${#cleanup_targets[@]}" -gt 0 ]; then
        if ! terminate_fastra_test_process_trees "${cleanup_targets[@]}"; then
            cleanup_status=2
            process_cleanup_failed=1
        fi
        for cleanup_pid in "${cleanup_targets[@]}"; do
            wait "$cleanup_pid" 2>/dev/null || true
        done
        [ "$process_cleanup_failed" -ne 0 ] || TEST_PROCESS_PID=""
    fi
    if [ "$process_cleanup_failed" -eq 0 ]; then
        if ! purge_fastra_registered_test_defaults \
            "${FASTRA_TEST_DEFAULTS_REGISTRY:-}"; then
            cleanup_status=2
        fi
        release_fastra_test_sandbox || cleanup_status=$?
    else
        echo "Unit-Tests: Prozessbaum lebt möglicherweise weiter; " \
             "Preferences und private Sandbox bleiben unangetastet." >&2
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        echo "Unit-Tests: Test-Sandbox konnte nicht entfernt werden." >&2
        # Ein Funktionsfehler bleibt der maßgebliche Ausgang. Exit 2 darf nur
        # einen ansonsten grünen Lauf als Umgebungsproblem kennzeichnen.
        if [ "$final_status" -eq 0 ]; then
            final_status=2
        fi
        environment_errors=$((environment_errors + 1))
    fi
    if [ "$final_status" -eq 2 ] && [ "$environment_errors" -eq 0 ]; then
        # Dazu gehören Fehler, die schon beim Anlegen der Sandbox entstehen.
        environment_errors=1
    fi
    echo "FASTRA_TEST_SUMMARY requested_phases=$requested_phases run_phases=$run_phases passed_phases=$passed_phases failed_phases=$failed_phases environment_errors=$environment_errors exit=$final_status"
    exit "$final_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

create_fastra_test_sandbox unit-tests || exit 2
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_SANDBOX/defaults-registry.txt"
: > "$FASTRA_TEST_DEFAULTS_REGISTRY" || exit 2

run_swift_test_phase() {
    local phase="$1"
    local phase_parallel="$2"
    local started_seconds="$SECONDS"
    local raw_status=0
    local phase_status=0
    local cleanup_failed=0
    local phase_arguments=()
    PHASE_ENVIRONMENT_ERROR=0

    if [ "$phase" = "fast" ]; then
        if [ "$phase_parallel" -eq 1 ]; then
            phase_arguments=(--parallel --skip "$SERIAL_INTEGRATION_FILTER")
        else
            phase_arguments=(--no-parallel --skip "$SERIAL_INTEGRATION_FILTER")
        fi
        # Mehrere Filter bleiben getrennt. Swift vereinigt sie wie beim
        # direkten Aufruf; benannte Gruppen und Rückverweise beeinflussen so
        # keinen benachbarten regulären Ausdruck.
        if [ "${#CALLER_FILTER_PATTERNS[@]}" -gt 0 ]; then
            for filter_pattern in "${CALLER_FILTER_PATTERNS[@]}"; do
                phase_arguments+=(--filter "$filter_pattern")
            done
        fi
    else
        # Reale Git-Prozesse, temporäre Repositories und lokale Remotes teilen
        # sich Systemressourcen. Auch die Runner-Regressionen starten selbst
        # Prozessgruppen und Cleanup-Läufe. Diese Phase bleibt deshalb
        # unabhängig von den Aufruferargumenten immer seriell.
        phase_arguments=(--no-parallel)
        if [ "${#CALLER_FILTER_PATTERNS[@]}" -gt 0 ]; then
            # Die Vereinigung einzelner Schnittmengen ist gleich der
            # Schnittmenge des Phasenmarkers mit der Filtervereinigung. Jeder
            # Aufruferausdruck bleibt eine eigene Regex, damit gleichnamige
            # Capture-Gruppen in zwei Filtern weiterhin zulässig sind.
            for filter_pattern in "${CALLER_FILTER_PATTERNS[@]}"; do
                phase_arguments+=(
                    --filter
                    "^(?=.*(?:$SERIAL_INTEGRATION_FILTER))(?=.*(?:$filter_pattern)).*$"
                )
            done
        else
            phase_arguments+=(--filter "$SERIAL_INTEGRATION_FILTER")
        fi
    fi
    if [ "${#SWIFT_TEST_ARGUMENTS[@]}" -gt 0 ]; then
        phase_arguments+=("${SWIFT_TEST_ARGUMENTS[@]}")
    fi

    echo "FASTRA_TEST_PHASE phase=$phase event=start parallel=$phase_parallel"
    # HOME bleibt unverändert, damit SwiftPM- und Git-Caches wiederverwendet
    # werden. Beide Phasen teilen sich dieselbe private Test-Sandbox.
    if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
    CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
    CFPREFERENCES_AVOID_DAEMON=1 \
    FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
    fastra_test_start_new_session swift test "${phase_arguments[@]}"; then
        PHASE_ENVIRONMENT_ERROR=1
        echo "Unit-Tests: Testphase '$phase' ließ sich nicht sicher starten." >&2
        echo "FASTRA_TEST_PHASE phase=$phase event=end status=environment exit=2 elapsed_seconds=$((SECONDS - started_seconds))"
        return 2
    fi
    TEST_PROCESS_PID="$FASTRA_TEST_STARTED_PID"
    if ! fastra_test_adopt_started_session; then
        PHASE_ENVIRONMENT_ERROR=1
        echo "Unit-Tests: Testphase '$phase' konnte ihren Prozess nicht übernehmen." >&2
        echo "FASTRA_TEST_PHASE phase=$phase event=end status=environment exit=2 elapsed_seconds=$((SECONDS - started_seconds))"
        return 2
    fi

    wait "$TEST_PROCESS_PID"
    raw_status=$?

    # Erst wenn auch verwaiste Enkel derselben Prozessgruppe beendet sind,
    # darf die nächste Phase beginnen. So überlappt kein schneller Testprozess
    # mit der seriellen Git-Integration.
    if ! terminate_fastra_test_process_trees "$TEST_PROCESS_PID"; then
        cleanup_failed=1
        PHASE_ENVIRONMENT_ERROR=1
    fi
    wait "$TEST_PROCESS_PID" 2>/dev/null || true
    [ "$cleanup_failed" -ne 0 ] || TEST_PROCESS_PID=""

    if [ "$raw_status" -ne 0 ]; then
        # Der eigentliche Testbefund gewinnt auch dann, wenn sein Prozessbaum
        # anschließend nicht vollständig aufgeräumt werden konnte.
        phase_status=1
        if [ "$cleanup_failed" -ne 0 ]; then
            echo "Unit-Tests: Prozessbaum der Testphase '$phase' lebt möglicherweise weiter." >&2
        fi
        echo "FASTRA_TEST_PHASE phase=$phase event=end status=failed exit=1 raw_exit=$raw_status cleanup_environment=$cleanup_failed elapsed_seconds=$((SECONDS - started_seconds))"
    elif [ "$cleanup_failed" -ne 0 ]; then
        phase_status=2
        echo "Unit-Tests: Prozessbaum der Testphase '$phase' lebt möglicherweise weiter." >&2
        echo "FASTRA_TEST_PHASE phase=$phase event=end status=environment exit=2 elapsed_seconds=$((SECONDS - started_seconds))"
    else
        echo "FASTRA_TEST_PHASE phase=$phase event=end status=passed exit=0 elapsed_seconds=$((SECONDS - started_seconds))"
    fi
    return "$phase_status"
}

if [ "$RUN_FAST_PHASE" -eq 1 ]; then
    run_swift_test_phase fast "$FAST_PHASE_PARALLEL"
    phase_status=$?
    run_phases=$((run_phases + 1))
    if [ "$PHASE_ENVIRONMENT_ERROR" -ne 0 ]; then
        environment_errors=$((environment_errors + 1))
    fi
    if [ "$phase_status" -eq 0 ]; then
        passed_phases=$((passed_phases + 1))
    elif [ "$phase_status" -eq 1 ]; then
        failed_phases=$((failed_phases + 1))
        overall_status=1
    else
        if [ "$PHASE_ENVIRONMENT_ERROR" -eq 0 ]; then
            environment_errors=$((environment_errors + 1))
        fi
        if [ "$overall_status" -eq 0 ]; then
            overall_status=2
        fi
    fi
fi

if [ "$RUN_SERIAL_INTEGRATION_PHASE" -eq 1 ] \
   && [ "$overall_status" -ne 2 ] \
   && [ "$PHASE_ENVIRONMENT_ERROR" -eq 0 ]; then
    run_swift_test_phase serial-integration 0
    phase_status=$?
    run_phases=$((run_phases + 1))
    if [ "$PHASE_ENVIRONMENT_ERROR" -ne 0 ]; then
        environment_errors=$((environment_errors + 1))
    fi
    if [ "$phase_status" -eq 0 ]; then
        passed_phases=$((passed_phases + 1))
    elif [ "$phase_status" -eq 1 ]; then
        failed_phases=$((failed_phases + 1))
        overall_status=1
    else
        if [ "$PHASE_ENVIRONMENT_ERROR" -eq 0 ]; then
            environment_errors=$((environment_errors + 1))
        fi
        if [ "$overall_status" -eq 0 ]; then
            overall_status=2
        fi
    fi
fi

exit "$overall_status"
