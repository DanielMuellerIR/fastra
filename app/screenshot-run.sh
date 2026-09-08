#!/bin/bash
# Erzeugt die deutschen und englischen README-Screenshots über den gemeinsamen
# Selbsttest-Runner: GUI-Sperre, Test-Sandbox und Aufräumen gelten auch hier.
# Aufruf: ./screenshot-run.sh [all|de|en] [all|search]
# `search` erneuert nur Wildcard- und RegEx-Suchmasken.
set -euo pipefail
cd "$(dirname "$0")"

LANGUAGE="${1:-all}"
SHOT_SET="${2:-all}"
case "$LANGUAGE" in
  all|de|en) ;;
  *) echo "Verwendung: $0 [all|de|en] [all|search]" >&2; exit 2 ;;
esac
case "$SHOT_SET" in
  all) SHOTS=(projectshot wildcardshot regexshot) ;;
  search) SHOTS=(wildcardshot regexshot) ;;
  *) echo "Verwendung: $0 [all|de|en] [all|search]" >&2; exit 2 ;;
esac

OUT="${FASTRA_SELFTEST_SCREENSHOT_DIR:-$(cd .. && pwd)/screenshots}"
generate_language() {
  FASTRA_SELFTEST_LANGUAGE="$1" FASTRA_SELFTEST_SCREENSHOT_DIR="$OUT" \
    ./selftest.sh "${SHOTS[@]}"
}
if [ "$LANGUAGE" = all ] || [ "$LANGUAGE" = de ]; then generate_language de; fi
if [ "$LANGUAGE" = all ] || [ "$LANGUAGE" = en ]; then generate_language en; fi
echo "README-Screenshots ($LANGUAGE, $SHOT_SET) in $OUT/"
