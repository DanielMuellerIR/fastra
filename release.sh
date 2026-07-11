#!/usr/bin/env bash
# Bequemlichkeits-Wrapper: reicht an das echte Release-Skript in app/ durch.
exec "$(dirname "$0")/app/release.sh" "$@"
