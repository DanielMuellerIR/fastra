#!/bin/bash
# Vergleichbare lokale Fastra-Baseline auf genau diesem Mac erfassen.

set -u
set -o pipefail

cd "$(dirname "$0")"

mode="${1:-standard}"
rounds="${2:-60}"

if [[ "$mode" == "status" ]]; then
    exec ./selftest.sh --performance-status
fi
if [[ "$mode" != "standard" && "$mode" != "long" ]]; then
    echo "Aufruf: ./performance-baseline.sh [standard|long [Runden]|status]" >&2
    exit 2
fi
if ! [[ "$rounds" =~ ^[0-9]+$ ]] || [[ "$rounds" -lt 1 ]]; then
    echo "Runden müssen eine positive ganze Zahl sein." >&2
    exit 2
fi
if [[ -n "$(git -C .. status --porcelain)" ]]; then
    echo "✗ Eine Baseline braucht einen sauberen Git-Stand." >&2
    exit 2
fi

start_head="$(git -C .. rev-parse HEAD)"

./build.sh || exit $?
./test.sh || exit $?
./localization-audit.sh || exit $?
FASTRA_PERFORMANCE_BASELINE_RUN=1 ./selftest.sh || exit $?

if [[ "$mode" == "long" ]]; then
    if [[ -n "${FASTRA_PROJECT_PERF_ROOT:-}" ]]; then
        ./selftest.sh projectperf || exit $?
    else
        echo "Hinweis: FASTRA_PROJECT_PERF_ROOT fehlt; projectperf wird ausgelassen."
    fi
    FASTRA_PERFORMANCE_BASELINE_RUN=1 ./soak-test.sh --rounds "$rounds" || exit $?
fi

end_head="$(git -C .. rev-parse HEAD)"
if [[ "$start_head" != "$end_head" || -n "$(git -C .. status --porcelain)" ]]; then
    echo "✗ Quellstand änderte sich während der Baseline; Messung ist nicht vergleichbar." >&2
    exit 2
fi

./selftest.sh --performance-status
