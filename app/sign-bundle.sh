#!/usr/bin/env bash
# Signiert Fastras eingebettete Programme von innen nach außen.
# Aufruf: ./sign-bundle.sh <Fastra.app> <codesign-identity-oder-->

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Aufruf: ./sign-bundle.sh <Fastra.app> <codesign-identity-oder->" >&2
  exit 2
fi

APP="$1"
IDENTITY="$2"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

[ -d "$APP" ] || { echo "✗ App-Bundle fehlt: $APP" >&2; exit 1; }
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "✗ Sparkle.framework fehlt im App-Bundle." >&2; exit 1; }

# Ad-hoc-Builds brauchen weder Hardened Runtime noch einen Netz-Zeitstempel.
# Verteilbare Builds erhalten beides mit derselben Developer-ID auf jedem Ziel.
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

# SwiftPM-Ressourcen enthalten unter anderem ripgrep und PCRE2. Mach-O-Dateien
# dort müssen explizit signiert werden, weil sie nicht in Frameworks/Helpers
# liegen und eine äußere Signatur sie nicht automatisch korrekt behandelt.
while IFS= read -r -d '' embedded_file; do
  if file -b "$embedded_file" | grep -q 'Mach-O'; then
    codesign "${SIGN_ARGS[@]}" "$embedded_file"
  fi
done < <(find "$APP/Contents/Resources" -type f -print0)

# Sparkles eigene Helfer besitzen verschachtelte Signaturgrenzen. Reihenfolge:
# inneres Programm, Updater-App, Framework, Fastra-App. `--deep` wäre beim
# Signieren falsch; es bleibt ausschließlich der abschließenden Prüfung vorbehalten.
for target in \
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
  "$SPARKLE_FRAMEWORK"
do
  [ -e "$target" ] || { echo "✗ Sparkle-Signaturziel fehlt: $target" >&2; exit 1; }
  codesign "${SIGN_ARGS[@]}" "$target"
done

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
