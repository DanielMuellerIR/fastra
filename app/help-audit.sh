#!/bin/zsh
# help-audit.sh — Pflege-Wächter der Fastra-Hilfe (Etappe 4 Wunschpaket
# 2026-07b), commit-basiert nach dem Muster von localization-audit.sh:
#
# Die Markerdatei `app/help-reviewed-commit` hält den zuletzt HILFE-GEPRÜFTEN
# Commit. Dieses Skript listet alle produktrelevanten Commits (Pfad
# `app/Sources/`) seit dem Marker samt berührten Dateien. Die inhaltliche
# Bewertung („gehört das in die Hilfe?") ist bewusst keine Skript-, sondern
# LLM-/Menschen-Arbeit — siehe Regel in AGENTS.md.
#
# Verhalten:
#   ./help-audit.sh            Normallauf: nur Hinweis, Exit 0.
#   ./help-audit.sh --release  Release-/Bump-Modus: HARTER FEHLER (Exit 1),
#                              wenn der Marker nicht fortgeschrieben wurde.
#
# Testbar: FASTRA_HELP_AUDIT_ROOT zeigt auf ein (Fixture-)Repo-Root mit
# demselben Layout (app/Sources/, app/help-reviewed-commit).
set -euo pipefail

release=0
[[ "${1:-}" == "--release" ]] && release=1

root="${FASTRA_HELP_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"

marker_file="app/help-reviewed-commit"
if [[ ! -f "$marker_file" ]]; then
    echo "HELP AUDIT: FAIL — Markerdatei $marker_file fehlt" >&2
    exit 1
fi
marker="$(head -n1 "$marker_file" | tr -d '[:space:]')"
if [[ -z "$marker" ]] || ! git cat-file -e "${marker}^{commit}" 2>/dev/null; then
    echo "HELP AUDIT: FAIL — Marker »$marker« ist kein Commit dieses Repos" >&2
    exit 1
fi

pending="$(git log --oneline "${marker}..HEAD" -- app/Sources/ || true)"
if [[ -z "$pending" ]]; then
    echo "HELP AUDIT: PASS — Hilfe bis Commit ${marker:0:12} geprüft, keine produktrelevanten Änderungen danach."
    exit 0
fi

count="$(printf '%s\n' "$pending" | wc -l | tr -d ' ')"
echo "HELP AUDIT: $count produktrelevante(r) Commit(s) seit dem letzten Hilfe-Check (${marker:0:12}):"
printf '%s\n' "$pending" | sed 's/^/  /'
echo "Berührte Pfade unter app/Sources/:"
git diff --name-only "${marker}..HEAD" -- app/Sources/ | sed 's/^/  /'

if [[ $release -eq 1 ]]; then
    echo "HELP AUDIT: FAIL (Release-Modus) — Hilfe prüfen/aktualisieren und $marker_file fortschreiben." >&2
    exit 1
fi
echo "Hinweis: Hilfe prüfen (app/Sources/Fastra/Resources/Help/) und Marker fortschreiben."
exit 0
