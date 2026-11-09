#!/bin/bash
set -euo pipefail
# Eigener headless Prüfaufbau, kein Produkt-Installations- oder Notarisierungspfad.
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 || $# != 3 ]]; then
    echo "Usage on arm64 macOS: $0 SOURCE_REPO ICU78.3_PREFIX NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
source_repo=$(cd "$1" && pwd)
icu=$(cd "$2" && pwd)
[[ ! -e $3 ]] || { echo 'Output must not exist.' >&2; exit 2; }
mkdir -p "$3"
out=$(cd "$3" && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export RUSTUP_HOME="$out/rustup" CARGO_HOME="$out/cargo" RUSTUP_TOOLCHAIN=1.99.1
export CARGO_TARGET_DIR="$out/target" MACOSX_DEPLOYMENT_TARGET=14.0
export PKG_CONFIG_PATH="$out/development/lib/pkgconfig"
export RUSTFLAGS="--remap-path-prefix=$out=/usr/src/fastra-ffi-check"
rustup toolchain install 1.99.1 --profile minimal --no-self-update
export PATH="$RUSTUP_HOME/toolchains/1.99.1-aarch64-apple-darwin/bin:$PATH"
rustc -Vv > "$out/rust-version.txt"
swiftc --version > "$out/swift-version.txt"
mkdir -p "$out/source" "$out/development/include" "$out/development/lib/pkgconfig"
tar -C "$source_repo" -cf - Cargo.toml Cargo.lock rust-toolchain.toml crates tools/ffi \
    tools/linux-probes/regex/cases.json | tar -xf - -C "$out/source"
cp -R "$icu/include/." "$out/development/include/"
for part in i18n uc data; do
    cp -L "$icu/lib/libicu${part}.78.dylib" "$out/development/lib/"
    ln -s "libicu${part}.78.dylib" "$out/development/lib/libicu${part}.dylib"
done
for name in icu-i18n icu-uc; do
    cat > "$out/development/lib/pkgconfig/$name.pc" <<EOF
prefix=$out/development
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $name
Description: Private verified ICU 78.3 test prefix
Version: 78.3
Libs: -L\${libdir} -licui18n -licuuc -licudata
Cflags: -I\${includedir}
EOF
done
[[ $(pkg-config --modversion icu-i18n) == 78.3 ]]
grep -q 'U_ICU_VERSION "78.3"' "$out/development/include/unicode/uvernum.h"
cd "$out/source"
find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done > "$out/source-sha256.txt"
export DYLD_LIBRARY_PATH="$out/development/lib"
cargo test --locked -p fastra-core -p fastra-ffi
cargo build --locked -p fastra-ffi --features bindgen
library="$out/target/debug/libfastra_ffi.dylib"
"$out/target/debug/fastra-bindgen" generate --library "$library" --language swift --out-dir "$out/generated"
app="$out/build/Probe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$library" "$app/Contents/Frameworks/"
cp "$out/development/lib/"*.78.dylib "$app/Contents/Frameworks/"
swiftc -parse-as-library -target arm64-apple-macos14.0 tools/ffi/client.swift "$out/generated/fastra_ffi.swift" \
    -Xcc -fmodule-map-file="$out/generated/fastra_ffiFFI.modulemap" -I "$out/generated" \
    -L "$app/Contents/Frameworks" -lfastra_ffi \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/Probe"
for library in "$app/Contents/Frameworks/"*.dylib; do
    install_name_tool -id "@rpath/$(basename "$library")" "$library"
    for part in i18n uc data; do
        name="libicu${part}.78.dylib"
        old=$(otool -L "$library" | awk -v name="$name" 'index($1,name) {print $1;exit}')
        [[ -z $old || $old == @rpath/* ]] || install_name_tool -change "$old" "@rpath/$name" "$library"
    done
    codesign --force --sign - "$library"
done
old=$(otool -L "$app/Contents/MacOS/Probe" | awk '/libfastra_ffi.dylib/ {print $1;exit}')
[[ -n $old ]]
[[ $old == @rpath/* ]] || install_name_tool -change "$old" @rpath/libfastra_ffi.dylib "$app/Contents/MacOS/Probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.fastra.ffi.check</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/Probe"
codesign --force --sign - "$app"
mkdir "$out/relocated"
mv "$app" "$out/relocated/Probe.app"
# Nur eigene Verzeichnisse verbergen; bestehende Toolchains/ICU bleiben unangetastet.
mv "$out/target" "$out/target.hidden"
mv "$out/development" "$out/development.hidden"
unset DYLD_LIBRARY_PATH PKG_CONFIG_PATH
app="$out/relocated/Probe.app"
codesign --verify --deep --strict "$app"
{
    otool -L "$app/Contents/MacOS/Probe"
    for library in "$app/Contents/Frameworks/"*.dylib; do otool -L "$library"; done
} > "$out/bundle-links.txt"
{
    for library in "$app/Contents/MacOS/Probe" "$app/Contents/Frameworks/"*.dylib; do
        otool -l "$library" | awk '/cmd LC_RPATH/ {rpath=1;next} rpath && /path / {print $2;rpath=0}'
    done
} > "$out/bundle-rpaths.txt"
if grep -Ev '^@loader_path(/|$)|^@executable_path(/|$)|^/usr/lib(/|$)|^/System/Library(/|$)' "$out/bundle-rpaths.txt"; then
    echo 'Bundle has a non-system absolute runtime search path.' >&2
    exit 1
fi
if grep -E '/(opt/homebrew|private/tmp|tmp|Users)/' "$out/bundle-links.txt" | grep -v ':$'; then
    echo 'Bundle dependency still references a non-system absolute path.' >&2
    exit 1
fi
DYLD_PRINT_LIBRARIES=1 "$app/Contents/MacOS/Probe" > "$out/client-result.txt" 2> "$out/dyld-libraries.txt"
for library in fastra_ffi icui18n icuuc icudata; do
    grep -E "/relocated/Probe.app/Contents/Frameworks/lib${library}(\.78)?\.dylib" "$out/dyld-libraries.txt" > /dev/null
done
cat "$out/client-result.txt"
echo "PASS native relocated FFI bundle: $app"
if [[ ${FASTRA_KEEP_FFI_BUILD:-0} != 1 ]]; then
    rm -rf "$out/source" "$out/target.hidden" "$out/development.hidden" "$out/rustup" "$out/cargo" "$out/build"
fi
