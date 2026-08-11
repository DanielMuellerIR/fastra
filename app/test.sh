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

cleanup() {
    local original_status=$?
    local cleanup_status=0
    local process_cleanup_failed=0
    trap - EXIT INT TERM
    local target="${TEST_PROCESS_PID:-${FASTRA_TEST_PENDING_PID:-}}"
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        if ! terminate_fastra_test_process_trees "$target"; then
            cleanup_status=2
            process_cleanup_failed=1
        fi
        wait "$target" 2>/dev/null || true
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
    fi
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        exit 2
    fi
    exit "$original_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

create_fastra_test_sandbox unit-tests || exit 2
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_SANDBOX/defaults-registry.txt"
: > "$FASTRA_TEST_DEFAULTS_REGISTRY" || exit 2

# HOME bleibt unverändert, damit SwiftPM- und Git-Caches wiederverwendet
# werden. Benannte UserDefaults-Suiten meldet der Testcode dem äußeren Runner;
# er entfernt deren letzte cfprefsd-Plists erst nach dem Prozessende.
if ! TMPDIR="$FASTRA_TEST_TMPDIR/" \
CFFIXED_USER_HOME="$FASTRA_TEST_CF_HOME" \
CFPREFERENCES_AVOID_DAEMON=1 \
FASTRA_TEST_DEFAULTS_REGISTRY="$FASTRA_TEST_DEFAULTS_REGISTRY" \
fastra_test_start_new_session swift test "$@"; then
    echo "Unit-Tests: eigener Testprozess ließ sich nicht sicher starten." >&2
    exit 2
fi
TEST_PROCESS_PID="$FASTRA_TEST_STARTED_PID"
wait "$TEST_PROCESS_PID"
test_status=$?
exit "$test_status"
