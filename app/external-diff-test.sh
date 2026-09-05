#!/bin/bash
# Echte Helfer-/LaunchServices-Tests unter derselben Sperre wie Selbsttests.
set -u
set -o pipefail
umask 077
cd "$(dirname "$0")"
. ./tools/gui-test-lock.sh
acquire_fastra_gui_test_lock || exit 2
TEST_PID=""
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [ -n "$TEST_PID" ]; then
        kill -TERM "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    release_fastra_gui_test_lock || result=2
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
python3 tools/external-diff-test.py "$@" &
TEST_PID=$!
wait "$TEST_PID"
RESULT=$?
TEST_PID=""
exit "$RESULT"
