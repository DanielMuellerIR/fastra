#!/bin/bash
set -euo pipefail
# Aufruf: package-mac.sh <Probe-Binary> <ICU-78.3-Prefix> <C-Shim> <neues-Ziel>
probe="$1";icu="$2";shim="$3";target="$4"
[[ ! -e "$target" ]] || exit 64
app="$target/Probe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$probe" "$app/Contents/MacOS/Probe"
cp "$shim" "$app/Contents/Frameworks/libfastra_icu_probe.dylib"
for name in icui18n icuuc icudata; do cp -L "$icu/lib/lib$name.78.dylib" "$app/Contents/Frameworks/"; done
for lib in "$app/Contents/Frameworks/"*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
    for name in icui18n icuuc icudata; do
        old=$(otool -L "$lib" | awk -v name="lib$name.78.dylib" 'index($1,name) {print $1;exit}')
        [[ -z "$old" || "$old" == @rpath/* ]] || install_name_tool -change "$old" "@rpath/lib$name.78.dylib" "$lib"
    done
    codesign --force --sign - "$lib"
done
codesign --force --sign - "$app/Contents/MacOS/Probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.fastra.regex.decision</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$app"
