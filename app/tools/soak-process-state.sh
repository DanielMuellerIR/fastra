#!/bin/bash
# Gemeinsamer, direkt testbarer Prozesszustand des Soak-Runners. Der aufrufende
# Runner muss tools/test-process-tree.sh vorher laden.

SOAK_PHASE_PID=""
SOAK_REMAINING_PIDS=()
SOAK_PROCESS_CLEANUP_BLOCKED=0
SOAK_ABORT_FOLLOWING_PHASES=0

remember_soak_cleanup_failure() {
  local pid="$1"
  local existing
  if [ "${#SOAK_REMAINING_PIDS[@]}" -gt 0 ]; then
    for existing in "${SOAK_REMAINING_PIDS[@]}"; do
      [ "$existing" = "$pid" ] && return 0
    done
  fi
  SOAK_REMAINING_PIDS+=("$pid")
}

cleanup_soak_process() {
  local pid="$1"
  if ! terminate_fastra_test_process_trees "$pid"; then
    remember_soak_cleanup_failure "$pid"
    SOAK_PROCESS_CLEANUP_BLOCKED=1
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  # Erst nach verifiziertem Prozessende die globale Eigentumsmarke lösen.
  # Ein Signal während `fastra_test_adopt_started_session` sieht die PID damit
  # auch dann noch, wenn dessen Pending-Felder bereits geleert wurden.
  [ "${SOAK_PHASE_PID:-}" != "$pid" ] || SOAK_PHASE_PID=""
  return 0
}

retry_soak_cleanup_failures() {
  local pid
  local failed=0
  local retry_pids=()
  [ "${#SOAK_REMAINING_PIDS[@]}" -gt 0 ] || return 0
  retry_pids=("${SOAK_REMAINING_PIDS[@]}")
  SOAK_REMAINING_PIDS=()
  SOAK_PROCESS_CLEANUP_BLOCKED=0
  for pid in "${retry_pids[@]}"; do
    if ! terminate_fastra_test_process_trees "$pid"; then
      remember_soak_cleanup_failure "$pid"
      SOAK_PROCESS_CLEANUP_BLOCKED=1
      failed=1
      continue
    fi
    wait "$pid" 2>/dev/null || true
    [ "${SOAK_PHASE_PID:-}" != "$pid" ] || SOAK_PHASE_PID=""
  done
  return "$failed"
}

adopt_soak_process() {
  local pid="$1"
  fastra_test_adopt_started_session && return 0
  echo "   ✗ Testprozess konnte nicht sicher übernommen werden" >&2
  # Der Prozess ist bereits freigegeben. Deshalb sofort anhand der VOR der
  # Übernahme global gesetzten PID beenden; kein Folgelauf darf diese Marke
  # überschreiben. Auch bei erfolgreichem Kill ist der Testaufbau ungültig.
  cleanup_soak_process "$pid" || true
  SOAK_ABORT_FOLLOWING_PHASES=1
  return 1
}

soak_followup_is_safe() {
  [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 0 ] \
    && [ "$SOAK_ABORT_FOLLOWING_PHASES" -eq 0 ]
}
