#!/bin/bash

# `performance_run_is_qualified` entscheidet zentral über Baseline-Aufnahme.
# Nur vollständig grüne, sauber beendete Läufe auf sauberem und währenddessen
# unverändertem Stand dürfen aufgenommen werden (`BaselineQualificationTests`).
#   real_fail_count/env_fail_count/skip_count/not_run_count — vollständig grün?
#   cleanup_env_errors                                    — sauber beendet?
#   RUN_HEAD_START/END, RUN_BINARY_SHA_START/END           — Stand unverändert?
#   RUN_DIRTY_START/END                                   — Arbeitsbaum sauber?
#   FASTRA_PERFORMANCE_BASELINE_RUN                       — ausdrücklich gewollt?
# Bei Dirty-Werten ist leer der Erfolgsfall: `${VAR+gesetzt}` statt
# `${VAR:-…}`, das auch bei gesetztem leerem Wert den Ersatz verwenden würde.
performance_run_is_qualified() {
    [ "${real_fail_count:-1}" -eq 0 ] || return 1
    [ "${env_fail_count:-1}" -eq 0 ] || return 1
    [ "${skip_count:-1}" -eq 0 ] || return 1
    [ "${not_run_count:-0}" -eq 0 ] || return 1
    [ "${cleanup_env_errors:-0}" -eq 0 ] || return 1
    [ "${RUN_HEAD_START:-x}" = "${RUN_HEAD_END:-y}" ] || return 1
    [ "${RUN_BINARY_SHA_START:-x}" = "${RUN_BINARY_SHA_END:-y}" ] || return 1
    [ -n "${RUN_DIRTY_START+gesetzt}" ] && [ -z "$RUN_DIRTY_START" ] || return 1
    [ -n "${RUN_DIRTY_END+gesetzt}" ] && [ -z "$RUN_DIRTY_END" ] || return 1
    [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ] || return 1
    return 0
}

# Qualifikation für die Dauertest-Baseline, entsprechend
# der Prüfung für kurze Selbsttestläufe:
#   ROUNDS >= 60                                  — genug Arbeitsrunden?
#   FINDINGS, ENVIRONMENT_PHASES, ACTIONS          — vollständig grün?
#   SOAK_HEAD_START/END, SOAK_BINARY_SHA_START/END — Stand unverändert?
#   SOAK_DIRTY_START/END                           — Arbeitsbaum sauber?
#   FASTRA_PERFORMANCE_BASELINE_RUN                — ausdrücklich gewollt?
# Ergebniszahlen hier selbst prüfen, statt allein auf vorheriges Setzen von
# `SOAK_PERFORMANCE_RECORD_PENDING` nach `check_soak_result` zu vertrauen.
soak_run_is_qualified() {
  [ "${ROUNDS:-0}" -ge 60 ] || return 1
  [ "${FINDINGS:-1}" -eq 0 ] || return 1
  [ "${ENVIRONMENT_PHASES:-1}" -eq 0 ] || return 1
  [ "${ACTIONS:-0}" -gt 0 ] || return 1
  [ "${SOAK_HEAD_START:-x}" = "${SOAK_HEAD_END:-y}" ] || return 1
  [ "${SOAK_BINARY_SHA_START:-x}" = "${SOAK_BINARY_SHA_END:-y}" ] || return 1
  [ -n "${SOAK_DIRTY_START+gesetzt}" ] && [ -z "$SOAK_DIRTY_START" ] || return 1
  [ -n "${SOAK_DIRTY_END+gesetzt}" ] && [ -z "$SOAK_DIRTY_END" ] || return 1
  [ "${FASTRA_PERFORMANCE_BASELINE_RUN:-0}" = "1" ] || return 1
  return 0
}
