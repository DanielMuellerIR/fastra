#!/usr/bin/env bash
# Bequemlichkeits-Wrapper: Der vollständige Release-, Notarisierungs- und
# Installationsablauf bleibt in app/, damit dort alle relativen Pfade stimmen.
# Argumente und Umgebungsvariablen wie NOTARY_PROFILE werden unverändert
# durchgereicht.
exec "$(dirname "$0")/app/install.sh" "$@"
