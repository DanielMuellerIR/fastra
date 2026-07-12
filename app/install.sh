#!/usr/bin/env bash
# Fastra — Installations-Workflow (notarisierter Build nach /Applications)
#
# Für den täglichen Einsatz gedacht: baut Fastra als Release, signiert mit
# Developer ID + Hardened Runtime, notarisiert bei Apple, stapelt das Ticket
# ans Bundle und installiert es nach /Applications. Danach startet die App
# ohne Gatekeeper-Meckern (auch auf anderen Macs).
#
# Ausgabe der letzten Zeile bei Erfolg:
#   INSTALL OK: /Applications/Fastra.app (<version>)
# Damit können KI-Agenten und CI-Skripte das Ergebnis maschinell lesen.
#
# Voraussetzungen:
#   - Xcode unter /Applications/Xcode.app (wie bei build.sh)
#   - Ein „Developer ID Application"-Zertifikat im Schlüsselbund (wird
#     automatisch gefunden; per FASTRA_SIGN_IDENTITY überschreibbar).
#   - Ein notarytool-Keychain-Profil. Der Name ist NICHT im Skript hinterlegt
#     (öffentliches Repo) — per Umgebungsvariable NOTARY_PROFILE übergeben oder
#     als Default „notary" anlegen:
#       xcrun notarytool store-credentials notary \
#         --apple-id "<apple-id>" --team-id "<team-id>"
#     (KEIN --password-Argument — das Tool fragt interaktiv nach dem
#      App-Specific-Password; so landet es nie in Shell-History/Transkript.)
#
# Aufruf:
#   ./install.sh                          # Default-Profil „notary"
#   NOTARY_PROFILE=<profil> ./install.sh  # anderes Keychain-Profil
#
# Schneller Test-Modus ohne Notarisierung (nur Developer-ID-signiert — läuft
# auf DIESEM Mac sofort, aber nicht garantiert gatekeeper-frei auf anderen):
#   ./install.sh --no-notarize

set -euo pipefail
cd "$(dirname "$0")"

NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./install.sh [--no-notarize]" >&2; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────
# Developer-ID-Identität ermitteln (public-safe: nichts Privates im Skript,
# wird zur Laufzeit aus dem Schlüsselbund gelesen).
# ─────────────────────────────────────────────────────────────────
SIGN_IDENTITY="${FASTRA_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "✗ Kein 'Developer ID Application'-Zertifikat im Schluesselbund gefunden." >&2
  echo "  Ohne Developer ID kann nicht signiert/notarisiert werden." >&2
  exit 1
fi
echo "→ Signatur-Identität: $SIGN_IDENTITY"

# ─────────────────────────────────────────────────────────────────
# 1. Release-Build (baut + strippt; signiert zunächst nur ad-hoc)
# ─────────────────────────────────────────────────────────────────
./build.sh release
APP=".build/release/Fastra.app"
[ -d "$APP" ] || { echo "✗ Build-Ergebnis fehlt: $APP" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────
# 2. Mit Developer ID + Hardened Runtime signieren (überschreibt die
#    Ad-hoc-Signatur aus build.sh). --options runtime ist Pflicht für die
#    Notarisierung; --timestamp bettet Apples Zeitstempel ein.
# ─────────────────────────────────────────────────────────────────
echo "→ Signiere Bundle mit Developer ID + Hardened Runtime…"
codesign --deep --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ─────────────────────────────────────────────────────────────────
# 3. Notarisieren (optional). Das Bundle wird als ZIP hochgeladen; --wait
#    blockiert bis Apples Prüfung fertig ist (typisch 1–10 Min).
# ─────────────────────────────────────────────────────────────────
if [ "$NOTARIZE" -eq 1 ]; then
  NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
  TMP="$(mktemp -d)"
  ZIP="$TMP/Fastra.zip"
  echo "→ Notarisiere via Profil '$NOTARY_PROFILE' (wartet auf Apple)…"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -rf "$TMP"
  # Ticket ans Bundle heften, damit es OFFLINE validiert (auch ohne Netz).
  echo "→ Staple das Notarisierungs-Ticket ans Bundle…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  echo "⚠ --no-notarize: nur Developer-ID-signiert (kein Notary-Ticket)."
fi

# ─────────────────────────────────────────────────────────────────
# 4. Nach /Applications installieren (vorhandene Version ersetzen).
#    Laufende Instanz vorher beenden, damit das Kopieren kein offenes
#    Binary trifft.
# ─────────────────────────────────────────────────────────────────
if pgrep -x Fastra >/dev/null 2>&1; then
  echo "→ Laufende Fastra-Instanz beenden"
  pkill -x Fastra || true
  sleep 1
fi
DEST="/Applications/Fastra.app"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# Nicht nur Signatur und Gatekeeper prüfen: Die tatsächlich installierte App
# muss ohne die absoluten SwiftPM-Build-Fallbacks starten. Genau dieses Gate
# verhindert, dass ein auf dem Build-Mac scheinbar funktionierendes Bundle auf
# einem anderen Mac bei `Bundle.module` sofort abstürzt.
./verify-portable-app.sh "$DEST" ".build/release"

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo
echo "INSTALL OK: $DEST ($VERSION)"
