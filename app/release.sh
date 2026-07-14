#!/usr/bin/env bash
# Fastra V1 — Release-Workflow
#
# Was dieses Skript tut (Reihenfolge):
#   1. Release-Build via build.sh (Xcode-Toolchain, alle Checkout-Patches)
#   2. App-Bundle code-signieren — entweder mit Developer-ID-Zertifikat (aus
#      Umgebungsvariable FASTRA_SIGN_IDENTITY) oder mit Ad-hoc-Signierung (-s -)
#      für lokale Tests ohne Apple-Konto.
#   3. DMG bauen via hdiutil — App + Alias auf /Applications, Volume-Name "Fastra",
#      mit Hintergrundbild (src/DmgBackground.png) und Finder-Icon-Layout,
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
#
# Aufruf:
#   ./release.sh                      # kompletter Release-Flow
#   ./release.sh --no-finder-layout   # ohne AppleScript-Finder-Layout (headless)

set -e

# Skript läuft immer relativ zu seinem eigenen Verzeichnis — macht das Skript
# unabhängig vom Arbeitsverzeichnis, aus dem es aufgerufen wird.
cd "$(dirname "$0")"

# ─────────────────────────────────────────────────────────────────
# Argumente
# ─────────────────────────────────────────────────────────────────
# --no-finder-layout: überspringt in Schritt 3 das AppleScript-Finder-Layout
#   (Fenstergröße, Icon-Positionen, Hintergrundbild einstellen). Nützlich auf
#   Headless-/CI-Maschinen ohne GUI-Finder — das DMG funktioniert trotzdem,
#   das Fenster sieht beim Öffnen nur schlichter aus.
FINDER_LAYOUT=1
for arg in "$@"; do
  case "$arg" in
    --no-finder-layout)
      FINDER_LAYOUT=0
      ;;
    *)
      echo "Unbekannte Option: $arg" >&2
      echo "Aufruf: ./release.sh [--no-finder-layout]" >&2
      exit 1
      ;;
  esac
done

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

# SwiftPM legt ausführbare Ressourcen nicht in den üblichen Bundle-Verzeichnissen
# `Frameworks` oder `Helpers` ab. `codesign --deep` erkennt solche Mach-O-Dateien
# deshalb nicht zuverlässig. Wir signieren sie vor dem äußeren App-Bundle einzeln;
# sonst lehnt Apples Notarisierung beispielsweise das gebündelte `rg` und seine
# PCRE2-Dylib trotz lokal erfolgreicher `codesign --verify`-Prüfung ab.
echo "   Eingebettete Mach-O-Dateien signieren"
while IFS= read -r -d '' embedded_file; do
  if file -b "$embedded_file" | grep -q 'Mach-O'; then
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$SIGN_IDENTITY" \
      "$embedded_file"
  fi
done < <(find "$APP/Contents/Resources" -type f -print0)

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
# Schritt 3: DMG bauen — mit Hintergrundbild und Finder-Layout
# ─────────────────────────────────────────────────────────────────
# Ablauf:
#   a) Hintergrundbild als HiDPI-TIFF aufbereiten (1x + 2x kombiniert)
#   b) Beschreibbares (RW-)DMG erzeugen und mounten
#   c) App-Bundle, /Applications-Alias und verstecktes .background-Verzeichnis
#      auf das gemountete Volume kopieren
#   d) Finder per AppleScript das Fenster-Layout einstellen lassen
#      (Fenstergröße, Icon-Positionen, Hintergrundbild) — die Einstellungen
#      landen in der .DS_Store des Volumes und bleiben im fertigen DMG erhalten
#   e) RW-DMG aushängen und in ein komprimiertes read-only DMG konvertieren

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

# Temporäres Arbeitsverzeichnis für alle Zwischenprodukte
# (RW-DMG, skalierte Hintergrundbilder, kombiniertes TIFF)
DMG_STAGING=$(mktemp -d)
RW_DMG="$DMG_STAGING/fastra_rw.dmg"
VOL_NAME="Fastra"
MOUNT_DIR="/Volumes/$VOL_NAME"

# Aufräumen garantieren — auch bei Fehler (trap auf EXIT): erst ein evtl.
# noch gemountetes Volume aushängen, dann das Arbeitsverzeichnis löschen
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true; rm -rf "$DMG_STAGING"' EXIT

echo "   Arbeitsverzeichnis: $DMG_STAGING"

# a) Hintergrundbild aufbereiten: Der Finder zeigt auf Retina-Displays nur
#    dann ein scharfes Bild, wenn das TIFF BEIDE Auflösungen enthält
#    (1x = 600×420 Punkte bei 72 dpi, 2x = 1200×840 Pixel bei 144 dpi).
#    sips skaliert die Quelle auf beide Größen, tiffutil kombiniert sie zu
#    einem Multi-Resolution-TIFF (-cathidpicheck prüft das 1x/2x-Verhältnis).
echo "   Hintergrundbild aufbereiten (1x + 2x → HiDPI-TIFF)"
sips -s format png -s dpiWidth 72  -s dpiHeight 72  -z 420 600 \
  src/DmgBackground.png --out "$DMG_STAGING/DmgBg_1x.png" >/dev/null
sips -s format png -s dpiWidth 144 -s dpiHeight 144 -z 840 1200 \
  src/DmgBackground.png --out "$DMG_STAGING/DmgBg_2x.png" >/dev/null
tiffutil -cathidpicheck "$DMG_STAGING/DmgBg_1x.png" "$DMG_STAGING/DmgBg_2x.png" \
  -out "$DMG_STAGING/DmgBackground.tiff"

# b) Beschreibbares DMG erzeugen und mounten. Die Größe (200m) ist bewusst
#    großzügig — beim Konvertieren (Schritt e) wird ohnehin auf die echte
#    Größe komprimiert. Hängt von einem früheren, abgebrochenen Lauf noch
#    ein "Fastra"-Volume, erst aushängen — sonst schlägt der Mount fehl.
if [ -d "$MOUNT_DIR" ]; then
  echo "   Altes Volume von früherem Lauf aushängen: $MOUNT_DIR"
  hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
fi
hdiutil create -size 200m -fs HFS+ -volname "$VOL_NAME" -ov -quiet "$RW_DMG"
hdiutil attach -readwrite -noverify -noautoopen -quiet \
  -mountpoint "$MOUNT_DIR" "$RW_DMG"

# c) Inhalt aufs Volume: App-Bundle (cp -R: Bundle-Struktur vollständig),
#    Symlink auf /Applications als Drag-&-Drop-Installationsziel und das
#    Hintergrundbild in einem versteckten Verzeichnis (Punkt-Präfix —
#    der Finder blendet es aus, das Bild bleibt aber referenzierbar)
cp -R "$APP" "$MOUNT_DIR/Fastra.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir "$MOUNT_DIR/.background"
cp "$DMG_STAGING/DmgBackground.tiff" "$MOUNT_DIR/.background/DmgBackground.tiff"

# d) Finder-Layout per AppleScript: Icon-Ansicht, Fenster 600×420 Punkte
#    (= Größe des 1x-Hintergrundbilds), Icons auf die im Bild gezeichneten
#    Slots setzen. Öffnet kurz ein Finder-Fenster — mit --no-finder-layout
#    überspringbar (z.B. headless), das DMG bleibt voll funktionsfähig.
if [ "$FINDER_LAYOUT" = "1" ]; then
  echo "   Finder-Layout einstellen (Fenster, Icon-Positionen, Hintergrund)"
  osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:DmgBackground.tiff"
        -- Icons auf die Slots im Hintergrundbild setzen
        set position of item "Fastra.app" of container window to {150, 300}
        set position of item "Applications" of container window to {450, 300}
        -- Fensterrechteck {links, oben, rechts, unten} → 600×420 Punkte.
        -- Mit Read-back-Retry: der Finder übernimmt ein einmaliges
        -- "set bounds" nicht zuverlässig (erbt sonst die Größe eines
        -- vorhandenen Fensters) — deshalb setzen, zurücklesen, ggf.
        -- wiederholen, bis die Zielgröße wirklich anliegt.
        repeat with i from 1 to 5
            set the bounds of container window to {200, 120, 800, 540}
            delay 1
            if (bounds of container window) = {200, 120, 800, 540} then exit repeat
        end repeat
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
else
  echo "   ⚠ --no-finder-layout gesetzt → Finder-Layout übersprungen"
fi

# e) Aushängen und konvertieren:
#    -format UDZO: komprimiertes read-only DMG (gzip) — kleinere Datei;
#    zlib-level=9 = maximale Kompression. Das kurze sleep gibt dem Finder
#    Zeit, die .DS_Store fertig zu schreiben, bevor ausgehängt wird.
sleep 2
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach -force "$MOUNT_DIR"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG_PATH"

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
