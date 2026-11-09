#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: $0 STAGED_RUNTIME VERSION NEW_OUTPUT_DIRECTORY" >&2
  exit 2
fi
stage=$(realpath "$1")
version=$2
out=$(realpath -m "$3")
[[ $version =~ ^[0-9][0-9a-zA-Z.+~:-]*$ ]] || exit 2
[[ ! -e $out ]] || { echo 'Output must not exist.' >&2; exit 2; }
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
mkdir -p "$out/deb/DEBIAN" "$out/deb/opt" "$out/deb/usr/bin" "$out/deb/usr/share/applications" "$out/deb/usr/share/icons/hicolor/256x256/apps"
cp -a "$stage" "$out/deb/opt/fastra"
ln -s /opt/fastra/bin/fastra "$out/deb/usr/bin/fastra"
ln -s /opt/fastra/bin/fastra-control "$out/deb/usr/bin/fastra-control"
ln -s /opt/fastra/bin/fastra-diff "$out/deb/usr/bin/fastra-diff"
cp "$stage/share/applications/fastra.desktop" "$out/deb/usr/share/applications/"
cp "$stage/share/icons/hicolor/256x256/apps/fastra.png" "$out/deb/usr/share/icons/hicolor/256x256/apps/"
cat > "$out/deb/DEBIAN/control" <<EOF
Package: fastra
Version: $version
Section: editors
Priority: optional
Architecture: amd64
Maintainer: Fastra contributors
Depends: libc6 (>= 2.39), libgcc-s1, libstdc++6, libgtk-4-1 (>= 4.12), libgtksourceview-5-0 (>= 5.6), libwebkitgtk-6.0-4 (>= 2.40), bubblewrap, util-linux, imagemagick, librsvg2-bin, librsvg2-common, poppler-utils
Description: Native search and replacement editor with previews
 Review matches and proposed changes before writing files.
EOF
find "$out/deb" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group --build "$out/deb" "$out/fastra_${version}_amd64.deb"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  -C "$(dirname "$stage")" -cf - "$(basename "$stage")" | gzip -n > "$out/fastra-${version}-linux-x86_64.tar.gz"
python3 "$(dirname "$0")/zip.py" "$stage" "$out/fastra-${version}-linux-x86_64.zip" "$SOURCE_DATE_EPOCH"
(cd "$out" && sha256sum -- *.deb *.tar.gz *.zip > SHA256SUMS)
tools=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
archive_sha=$(sha256sum "$out/fastra-${version}-linux-x86_64.tar.gz")
archive_sha=${archive_sha%% *}
sed -e "s/^pkgver=.*/pkgver=$version/" \
  -e "s/REPLACE_WITH_VERIFIED_ARTIFACT_SHA256/$archive_sha/" "$tools/PKGBUILD" > "$out/PKGBUILD"
