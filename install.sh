#!/usr/bin/env bash
# Plattformspezifische Abläufe bleiben in den jeweiligen Unterverzeichnissen.
case $(uname -s) in
  Linux) exec "$(dirname "$0")/linux/install.sh" "$@" ;;
  Darwin) exec "$(dirname "$0")/app/install.sh" "$@" ;;
  *) echo 'Fastra supports macOS and Linux.' >&2; exit 2 ;;
esac
