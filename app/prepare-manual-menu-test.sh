#!/bin/bash
#
# Baut eine wegwerfbare, realistische Fixture für den gelegentlichen
# Computer-Use-Menüvolltest. Die Test-App bleibt im Projekt-Root, besitzt eine
# eigene Bundle-ID und darf niemals nach /Applications kopiert werden.

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$APP_DIR/Fastra.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Fehlt: $SOURCE_APP — zuerst ./build.sh ausführen." >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d "$APP_DIR/.fastra-menu-test.XXXXXX")"
TEST_APP="$TEST_ROOT/Fastra-MenuTest.app"
PROJECT="$TEST_ROOT/project"
REMOTE="$TEST_ROOT/remote.git"
BUNDLE_SUFFIX="$(basename "$TEST_ROOT" | sed 's/^.*\.//' | tr '[:upper:]' '[:lower:]')"
BUNDLE_ID="de.dm0.fastra.manual-menu-test.$BUNDLE_SUFFIX"

mkdir -p "$PROJECT/Project/Sources/Methods"
ditto "$SOURCE_APP" "$TEST_APP"

# Eigene macOS-Identität: Einstellungen, Fensterzustand und TCC-Zuordnung des
# manuellen Tests bleiben von der notarisierten Produkt-App getrennt.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleDisplayName Fastra Menütest" \
    "$TEST_APP/Contents/Info.plist"
codesign --force --deep --sign - "$TEST_APP" >/dev/null

printf '%s\n' \
    '# Menüvolltest' \
    '' \
    'beta' \
    'Alpha' \
    'gamma' \
    '' \
    'Text für **Markdown**, Links und Tabellen.' \
    > "$PROJECT/README.md"

printf '%s\n' \
    'zeta' \
    'alpha 10' \
    'alpha 2' \
    'Beta' \
    'alpha 2' \
    > "$PROJECT/sort-lines.txt"

printf '  eins\tzwei  \n\nDuplikat\nDuplikat\n„Zitat“\\nEscape\ncafé\n' \
    > "$PROJECT/text-operations.txt"

printf '%s\n' \
    '{"name":"Fastra","items":[3,1,2],"enabled":true}' \
    > "$PROJECT/valid.json"
printf '%s\n' '{"name": "kaputt", "items": [1, 2,}' \
    > "$PROJECT/invalid.json"

printf '%s\n' \
    '<root><item id="2">Beta</item><item id="1">Alpha</item></root>' \
    > "$PROJECT/valid.xml"
printf '%s\n' '<root><item>nicht geschlossen</root>' \
    > "$PROJECT/invalid.xml"

printf '%s\n' \
    'body {' \
    '  color: #222;' \
    '  margin: 0;' \
    '}' \
    > "$PROJECT/styles.css"

printf '%s\n' \
    '//%attributes = {}' \
    'C_TEXT($name)' \
    '$name:="Fastra:C123"' \
    > "$PROJECT/Project/Sources/Methods/Test_Menu.4dm"
printf '%s\n' '<project xmlns="http://www.4d.com/4DProject"></project>' \
    > "$PROJECT/MenuTest.4DProject"

printf 'binär\x00inhalt\n' > "$PROJECT/binary.dat"
printf '%s\n' 'Ausgangsstand' > "$PROJECT/git-changes.txt"
printf '%s\n' 'Fenster A' > "$PROJECT/session-a.txt"
printf '%s\n' 'Fenster B' > "$PROJECT/session-b.txt"

git init --bare -q "$REMOTE"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.name "Fastra Menu Test"
git -C "$PROJECT" config user.email "menu-test@invalid.example"
git -C "$PROJECT" add -A
git -C "$PROJECT" commit -q -m "Initial menu test fixture"
git -C "$PROJECT" remote add origin "$REMOTE"
git -C "$PROJECT" push -q -u origin main
git -C "$PROJECT" switch -q -c fixture-secondary
printf '%s\n' 'Nur auf dem zweiten Test-Branch' \
    > "$PROJECT/branch-only.txt"
git -C "$PROJECT" add branch-only.txt
git -C "$PROJECT" commit -q -m "Add secondary branch fixture"
git -C "$PROJECT" push -q -u origin fixture-secondary
git -C "$PROJECT" switch -q main

# Bewusst sowohl getrackte als auch unversionierte Änderungen: Diff, Commit
# und beide Stash-Varianten lassen sich ohne Nutzerdaten real bedienen.
printf '%s\n' 'Ungesicherte Git-Änderung' >> "$PROJECT/git-changes.txt"
printf '%s\n' 'Unversionierte Testdatei' > "$PROJECT/untracked.txt"

printf 'FASTRA_MENU_TEST_ROOT=%s\n' "$TEST_ROOT"
printf 'FASTRA_MENU_TEST_APP=%s\n' "$TEST_APP"
printf 'FASTRA_MENU_TEST_BUNDLE_ID=%s\n' "$BUNDLE_ID"
printf 'FASTRA_MENU_TEST_PROJECT=%s\n' "$PROJECT"
printf 'FASTRA_MENU_TEST_REMOTE=%s\n' "$REMOTE"
printf 'CLEANUP_AFTER_TEST=rm -rf %q\n' "$TEST_ROOT"
