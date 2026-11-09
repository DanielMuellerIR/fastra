#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d /tmp/fastra-uniffi.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
export CARGO_TARGET_DIR="$scratch/target"
cargo build --locked --manifest-path "$base/Cargo.toml"
lib="$CARGO_TARGET_DIR/debug/libfastra_uniffi_decision_probe.dylib"
"$CARGO_TARGET_DIR/debug/bindgen" generate --library "$lib" --language swift --out-dir "$scratch/generated"
app="$scratch/build/Probe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$scratch/relocated"
cp "$lib" "$app/Contents/Frameworks/"
install_name_tool -id @rpath/libfastra_uniffi_decision_probe.dylib "$app/Contents/Frameworks/libfastra_uniffi_decision_probe.dylib"
swiftc -parse-as-library "$base/client.swift" "$scratch/generated/fastra_uniffi_decision_probe.swift" -Xcc -fmodule-map-file="$scratch/generated/fastra_uniffi_decision_probeFFI.modulemap" -I "$scratch/generated" -L "$app/Contents/Frameworks" -lfastra_uniffi_decision_probe -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/Probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.fastra.uniffi.decision</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Frameworks/libfastra_uniffi_decision_probe.dylib"
codesign --force --sign - "$app"
mv "$app" "$scratch/relocated/Probe.app"
rmdir "$scratch/build"
"$scratch/relocated/Probe.app/Contents/MacOS/Probe"
echo 'PASS UniFFI relocated bundle, build directory absent'
