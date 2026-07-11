#!/usr/bin/env bash
# Bequemlichkeits-Wrapper: reicht an den echten Selbsttest-Runner in app/ durch.
exec "$(dirname "$0")/app/selftest.sh" "$@"
