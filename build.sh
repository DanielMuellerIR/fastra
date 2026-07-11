#!/usr/bin/env bash
# Bequemlichkeits-Wrapper: reicht an das echte Build-Skript in app/ durch.
# (Die Skripte selbst bleiben in app/, weil sie dort mit relativen Pfaden
# arbeiten und überall so dokumentiert sind.)
exec "$(dirname "$0")/app/build.sh" "$@"
