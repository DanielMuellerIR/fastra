#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d /tmp/fastra-ffi.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
app="$scratch/build/Probe.app"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/MacOS" "$scratch/relocated"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.fastra.ffi.decision</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
rustc --crate-type cdylib -C panic=unwind "$base/probe.rs" -o "$app/Contents/Frameworks/libfastra_probe.dylib"
install_name_tool -id @rpath/libfastra_probe.dylib "$app/Contents/Frameworks/libfastra_probe.dylib"
swiftc "$base/main.swift" -import-objc-header "$base/probe.h" -L "$app/Contents/Frameworks" -lfastra_probe -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/Probe"
mv "$app" "$scratch/relocated/Probe.app"
rmdir "$scratch/build"
"$scratch/relocated/Probe.app/Contents/MacOS/Probe"
echo 'PASS relocated bundle, build directory absent'
