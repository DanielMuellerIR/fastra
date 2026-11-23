#!/bin/bash

prune_selftest_evidence() {
    [ "${SELFTEST_RUNS_INSIDE_TEST_FIXTURE:-0}" -eq 0 ] || return 0
    local evidence_root="${1:?}"
    local stale owner backup
    while IFS= read -r stale; do
        [ -d "$stale" ] && [ ! -L "$stale" ] || continue
        owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
        [ "$owner" = "$UID" ] || continue
        # Rettungsbackups bleiben bis zur manuellen Klärung erhalten; auch
        # Symlinks und unlesbare Verzeichnisse sind kein Beleg für Abwesenheit.
        [ -r "$stale" ] && [ -x "$stale" ] || continue
        backup=$(find "$stale" -mindepth 1 -maxdepth 1 \
            -name 'pasteboard-backup.plist' -print 2>/dev/null) || continue
        [ -z "$backup" ] || continue
        case "$stale" in "$evidence_root"/fastra-selftest-befunde-*) rm -rf -- "$stale" ;; esac
    done < <(
        # macOS verlinkt /tmp. Nur diesem Startpfad folgen, keinem Kindlink.
        find -H "$evidence_root" -maxdepth 1 -type d -name 'fastra-selftest-befunde-*' \
            -exec stat -f '%m %N' {} + 2>/dev/null \
            | sort -rn | sed -n '6,$s/^[0-9][0-9]* //p'
    )
}

# Diagnosebeweise sind nützlich, aber nicht unbegrenzt. Sie enthalten nur
# Logs und bei gescheiterter Wiederherstellung Rettungssicherungen, niemals
# kopierte reale Dokumente. Die fünf jüngsten Läufe bleiben für die Auswertung.
prune_soak_evidence() {
  local system_root="${1:?}"
  local candidates=("$system_root")
  local inherited_tmp="${TMPDIR:-}"
  inherited_tmp="${inherited_tmp%/}"
  if [ "${SOAK_RUNS_INSIDE_TEST_FIXTURE:-0}" -eq 1 ]; then
    candidates=("$SOAK_FIXTURE_PARENT")
  elif [ -n "$inherited_tmp" ] && [ "$inherited_tmp" != "$system_root" ]; then
    candidates+=("$inherited_tmp")
  fi
  local parents=() candidate parent identity previous_identity=""
  # /tmp und TMPDIR können auf dasselbe Verzeichnis zeigen. In diesem Fall
  # darf es nur einmal in die Rangliste der fünf jüngsten Läufe eingehen.
  for candidate in "${candidates[@]}"; do
    parent=$(CDPATH= cd -P -- "$candidate" 2>/dev/null && pwd -P) || continue
    identity=$(stat -f '%d:%i' "$parent" 2>/dev/null) || continue
    [ "$identity" != "$previous_identity" ] || continue
    parents+=("$parent")
    previous_identity="$identity"
  done
  [ "${#parents[@]}" -gt 0 ] || return 0

  local stale owner allowed backup
  # Die ersten Versionen des Runners legten Belege mit der normalen umask an.
  # Bevor bis zu fünf davon aufbewahrt werden, werden nur eigentümereigene,
  # echte Verzeichnisse auf private Rechte gehärtet.
  while IFS= read -r stale; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
    [ "$owner" = "$UID" ] || continue
    chmod 700 "$stale" 2>/dev/null || true
    find "$stale" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$stale" -type f -exec chmod 600 {} + 2>/dev/null || true
  done < <(find "${parents[@]}" -maxdepth 1 -type d \
      -name 'fastra-soak-befunde-*' -print 2>/dev/null)
  while IFS= read -r stale; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    owner=$(stat -f '%u' "$stale" 2>/dev/null || true)
    [ "$owner" = "$UID" ] || continue
    # Rettungsbackups bleiben bis zur manuellen Klärung erhalten; auch
    # Symlinks und unlesbare Verzeichnisse sind kein Beleg für Abwesenheit.
    [ -r "$stale" ] && [ -x "$stale" ] || continue
    backup=$(find "$stale" -mindepth 1 -maxdepth 1 \
        \( -name 'pasteboard-backup.plist' -o -name 'product-defaults.plist' \
        -o -name 'product-saved-state' \) -print 2>/dev/null) || continue
    [ -z "$backup" ] || continue
    allowed=0
    for parent in "${parents[@]}"; do
      case "$stale" in "$parent"/fastra-soak-befunde-*) allowed=1 ;; esac
    done
    [ "$allowed" -eq 1 ] && rm -rf -- "$stale"
  done < <(
    find "${parents[@]}" -maxdepth 1 -type d -name 'fastra-soak-befunde-*' \
      -exec stat -f '%m %N' {} + 2>/dev/null \
      | sort -rn | sed -n '6,$s/^[0-9][0-9]* //p'
  )
}
