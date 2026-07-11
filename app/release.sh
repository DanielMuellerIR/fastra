#!/usr/bin/env bash
# Fastra V1 — Release-Workflow
#
# Was dieses Skript tut (Reihenfolge):
#   1. Release-Build via build.sh (Xcode-Toolchain, alle Checkout-Patches)
#   2. App-Bundle code-signieren — entweder mit Developer-ID-Zertifikat (aus
#      Umgebungsvariable FASTRA_SIGN_IDENTITY) oder mit Ad-hoc-Signierung (-s -)
#      für lokale Tests ohne Apple-Konto.
#   3. DMG bauen via hdiutil — App + Alias auf /Applications, Volume-Name "Fastra",
#      Ausgabe in dist/Fastra-<version>.dmg.
#   4. Signatur des DMG-Inhalts verifizieren.
#   5. Notarisierung — läuft automatisch, WENN echt signiert wurde
#      (FASTRA_SIGN_IDENTITY gesetzt) und das Keychain-Profil vorhanden ist;
#      bei Ad-hoc-Signierung wird der Schritt sauber übersprungen.
#
# Ausgabe der letzten Zeile bei Erfolg:
#   RELEASE OK: <pfad-zum-dmg>
# Damit können KI-Agenten und CI-Skripte das Ergebnis maschinell lesen.
#
# Voraussetzungen:
#   - Xcode unter /Applications/Xcode.app (wie bei build.sh)
#   - Für echte Signierung: gültiges Developer-ID-Zertifikat im Schlüsselbund
#     und FASTRA_SIGN_IDENTITY gesetzt (z.B. in ~/.zshenv oder .envrc)
#   - Für Notarization: ein notarytool-Keychain-Profil (Default "notary",
#     über NOTARY_PROFILE überschreibbar), pro Mac einmalig eingerichtet via:
#       xcrun notarytool store-credentials "notary" \
#         --apple-id "<deine Apple-ID>" --team-id "<deine Team-ID>"
#     (KEIN --password-Argument — das Tool fragt interaktiv nach dem
#      App-Specific-Password; so landet es nie in Shell-History/Transkript)

set -e

# Skript läuft immer relativ zu seinem eigenen Verzeichnis — macht das Skript
# unabhängig vom Arbeitsverzeichnis, aus dem es aufgerufen wird.
cd "$(dirname "$0")"

echo "▶ Fastra Release-Build"
echo

# ─────────────────────────────────────────────────────────────────
# Schritt 1: Release-Build via build.sh
# ─────────────────────────────────────────────────────────────────
# build.sh übernimmt Toolchain-Switch, alle Checkout-Patches und das
# Bundle-Bauen. Mit dem Argument "release" baut es im Release-Modus
# (Optimierungen an, Debugging-Symbole separat).
echo "→ Schritt 1/5: Release-Build"
./build.sh release

# Pfad zum fertig gebauten App-Bundle (von build.sh erzeugt)
APP=".build/release/Fastra.app"

# Versionsnummer aus Info.plist lesen — wird für den DMG-Dateinamen gebraucht.
# /usr/libexec/PlistBuddy ist auf jedem macOS-System vorhanden.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
echo "   Version: $VERSION"
echo

# ─────────────────────────────────────────────────────────────────
# Schritt 2: Code-Signierung
# ─────────────────────────────────────────────────────────────────
# Zwei Modi:
#   a) FASTRA_SIGN_IDENTITY gesetzt → echte Signierung mit Developer-ID
#      (nötig für Notarization und Weitergabe an andere Macs)
#   b) nicht gesetzt → Ad-hoc-Signierung (nur für lokale Tests)
#
# WICHTIG: Die Identity wird NICHT in die Ausgabe geschrieben (Sicherheitsregel
# "Secrets im Terminal"). Das Skript meldet nur, ob die env-Variable gesetzt ist.
echo "→ Schritt 2/5: Code-Signierung"

# Entschlossenheit der Signierungsart prüfen
if [ -n "${FASTRA_SIGN_IDENTITY:-}" ]; then
  # Echte Signierung — Identity aus der Umgebungsvariable
  echo "   Identity aus Umgebungsvariable gesetzt → Developer-ID-Signierung"
  SIGN_IDENTITY="$FASTRA_SIGN_IDENTITY"
else
  # Ad-hoc-Signierung: -s - = kein Zertifikat, nur lokale Integrität
  # Gatekeeper blockiert dieses Bundle auf anderen Macs — nur für eigene Tests.
  echo "   ⚠ FASTRA_SIGN_IDENTITY nicht gesetzt → Ad-hoc-Signierung (-s -)"
  echo "     Das Bundle läuft NUR auf diesem Mac und nur für lokale Tests."
  echo "     Für Weitergabe und Notarization: Developer-ID in FASTRA_SIGN_IDENTITY setzen."
  SIGN_IDENTITY="-"
fi

# --deep: signiert alle Frameworks und Hilfsprogramme im Bundle rekursiv.
# --force: überschreibt eine vorhandene Signatur (z.B. nach erneutem build.sh).
# --options runtime: Hardened Runtime aktivieren — Pflicht für Notarization.
# --timestamp: Zeitstempel-Service von Apple einbetten (erfordert Internetzugang
#   bei echter Signierung; bei Ad-hoc mit - wird --timestamp ignoriert).
codesign \
  --deep \
  --force \
  --verify \
  --verbose=2 \
  --options runtime \
  --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP"

echo "   ✔ Bundle signiert: $APP"
echo

# ─────────────────────────────────────────────────────────────────
# Schritt 3: DMG bauen
# ─────────────────────────────────────────────────────────────────
# Ablauf:
#   a) Temporäres Verzeichnis als "Vorlage" für den DMG-Inhalt anlegen
#   b) App-Bundle hineinkopieren
#   c) Symbolischen Link auf /Applications anlegen (Drag-to-install-UI im Finder)
#   d) hdiutil create baut den DMG aus dem Verzeichnis
#   e) Temporäres Verzeichnis aufräumen

echo "→ Schritt 3/5: DMG bauen"

# Ausgabeverzeichnis anlegen (relative Pfade, niemals /Users/<name>/... hardkodieren)
DIST_DIR="dist"
mkdir -p "$DIST_DIR"

# Endpfad des fertigen DMG — Dateiname enthält die Version für klare Benennung
DMG_PATH="$DIST_DIR/Fastra-${VERSION}.dmg"

# Bereits vorhandenes DMG entfernen (hdiutil will keine bestehende Datei
# überschreiben — ohne dieses rm schlägt der Build bei zweitem Durchlauf fehl)
if [ -f "$DMG_PATH" ]; then
  echo "   Vorhandenes DMG entfernen: $DMG_PATH"
  rm -f "$DMG_PATH"
fi

# Temporäres Staging-Verzeichnis als DMG-Vorlage
DMG_STAGING=$(mktemp -d)
# Aufräumen garantieren — auch bei Fehler (trap auf EXIT)
trap 'rm -rf "$DMG_STAGING"' EXIT

echo "   Staging-Verzeichnis: $DMG_STAGING"

# App ins Staging-Verzeichnis kopieren (cp -R: Bundle-Struktur vollständig)
cp -R "$APP" "$DMG_STAGING/Fastra.app"

# Symbolischen Link auf /Applications anlegen — Nutzer ziehen die App
# per Drag & Drop aus dem DMG-Fenster in den Applications-Ordner
ln -s /Applications "$DMG_STAGING/Applications"

# DMG erzeugen:
#   -volname: Name des eingehängten Volumes (erscheint auf dem Desktop)
#   -srcfolder: Inhalt des DMG (= unser Staging-Verzeichnis)
#   -ov: bestehende Datei überschreiben (extra Sicherheit, rm oben reicht
#        normalerweise, aber -ov schadet nicht)
#   -format UDZO: komprimiertes DMG (gzip) — kleinere Datei
hdiutil create \
  -volname "Fastra" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "   ✔ DMG gebaut: $DMG_PATH"
echo

# ─────────────────────────────────────────────────────────────────
# Schritt 4: Signatur des DMG verifizieren
# ─────────────────────────────────────────────────────────────────
# Prüft, ob das App-Bundle im fertigen DMG noch die korrekte Signatur trägt.
# (hdiutil packt nur — die Signatur im Bundle bleibt erhalten.)
echo "→ Schritt 4/5: Signatur verifizieren"

# DMG temporär einhängen, Bundle prüfen, wieder aushängen
VERIFY_MOUNT=$(mktemp -d)
# Zweiten Aufräum-Trap hängen — hdiutil detach läuft bei EXIT
# (das ursprüngliche "rm -rf $DMG_STAGING" bleibt im Trap und wird
#  ebenfalls ausgeführt — Shell-Traps akkumulieren sich)
trap 'hdiutil detach "$VERIFY_MOUNT" -quiet 2>/dev/null || true; rm -rf "$DMG_STAGING"' EXIT

hdiutil attach "$DMG_PATH" -mountpoint "$VERIFY_MOUNT" -quiet -nobrowse

# codesign --verify gibt Fehler aus und setzt Exit-Code ≠ 0 bei ungültiger Signatur
codesign --verify --deep --strict "$VERIFY_MOUNT/Fastra.app" \
  && echo "   ✔ Signatur im DMG gültig" \
  || { echo "✗ FEHLER: Signaturprüfung gescheitert — DMG nicht verwenden." >&2; exit 1; }

hdiutil detach "$VERIFY_MOUNT" -quiet

echo

# ─────────────────────────────────────────────────────────────────
# Schritt 5: Notarization — automatisch, wenn echt signiert wurde
# ─────────────────────────────────────────────────────────────────
# Läuft NUR, wenn in Schritt 2 mit einer echten Developer-ID signiert wurde
# (FASTRA_SIGN_IDENTITY gesetzt). Ad-hoc-Bundles können nicht notarisiert
# werden — dann wird dieser Schritt übersprungen.
#
# Das notarytool-Keychain-Profil ist PRO MAC eingerichtet (Schlüsselbund wird
# nicht über Macs gesynct). Default-Profilname "notary" wird
# projektübergreifend wiederverwendet; über die Umgebungsvariable
# NOTARY_PROFILE überschreibbar. Einmalig je Mac angelegt via:
#   xcrun notarytool store-credentials "notary" \
#     --apple-id "<deine Apple-ID>" --team-id "<deine Team-ID>"
#   (fragt interaktiv nach dem App-Specific-Password — landet so nie in der
#    Shell-History; Team-ID ist nicht geheim.)
echo "→ Schritt 5/5: Notarisierung"

# Profilname: Umgebungsvariable hat Vorrang, sonst der projektweite Default.
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

if [ "$SIGN_IDENTITY" = "-" ]; then
  # Ad-hoc signiert → Notarisierung technisch nicht möglich, sauber überspringen.
  echo "   ⚠ Ad-hoc-Signierung → Notarisierung übersprungen."
  echo "     Für ein verteilbares, notarisiertes DMG: FASTRA_SIGN_IDENTITY setzen."
else
  # Apple verlangt, dass auch das DMG selbst signiert ist (nicht nur das Bundle
  # darin), bevor es notarisiert wird. --timestamp bettet Apples Zeitstempel ein.
  echo "   DMG selbst signieren (Voraussetzung für Notarisierung)"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

  # Hochladen + auf Apples Prüfung warten (--wait, typ. 1-10 Min). notarytool
  # notarisiert den DMG-Inhalt rekursiv mit. Profil liefert die Credentials —
  # KEIN Passwort als Argument (Sicherheitsregel "Secrets im Terminal").
  echo "   notarytool submit (Profil: $NOTARY_PROFILE) — wartet auf Apple…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  # Staple-Ticket ins DMG heften → läuft danach auch offline ohne Gatekeeper-
  # Warnung, und validate bestätigt, dass das Ticket sitzt.
  echo "   Staple-Ticket einbetten + prüfen"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  echo "   ✔ DMG notarisiert + gestapelt"
fi
echo

# ─────────────────────────────────────────────────────────────────
# Abschluss — maschinenlesbare Ausgabe für KI-Agenten und CI
# ─────────────────────────────────────────────────────────────────
# Die letzte Zeile ist bewusst strukturiert:
#   "RELEASE OK: <pfad>" — ein Grep auf "RELEASE OK:" reicht zum Auswerten.
#   "RELEASE FAIL:" würde bei einem frühen exit 1 gar nicht erscheinen,
#   der Exit-Code ist das zuverlässige Fehlersignal.
echo "────────────────────────────────────────────────────────────"
echo "RELEASE OK: $DMG_PATH"
