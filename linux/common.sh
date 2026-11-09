#!/usr/bin/env bash
# Gemeinsame Voraussetzungen; installiert niemals Systempakete.
fastra_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fastra_cache=${FASTRA_LINUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/fastra-linux}
icu_sha=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
fail() { echo "Fastra: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null || fail "Missing prerequisite: $1. See docs/BUILD-AND-TEST.md."; }
version() { python3 "$fastra_repo/tools/linux-package/identity.py" --version "$fastra_repo"; }
icu_archive() {
  need curl; need sha256sum
  mkdir -p "$fastra_cache/downloads"
  archive="$fastra_cache/downloads/icu4c-78.3-sources.tgz"
  if [[ ! -f $archive ]]; then
    local partial
    partial=$(mktemp "$fastra_cache/downloads/.icu.XXXXXX")
    trap 'rm -f -- "$partial"' EXIT
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz -o "$partial"
    printf '%s  %s\n' "$icu_sha" "$partial" | sha256sum --check --status
    mv -n -- "$partial" "$archive"
    rm -f -- "$partial"
    trap - EXIT
  fi
  printf '%s  %s\n' "$icu_sha" "$archive" | sha256sum --check --status || fail 'ICU archive checksum mismatch.'
}
prepare_icu() {
  if [[ -z ${icu:-} ]]; then
    need make; need c++; need flock
    icu="$fastra_cache/icu78.3-native/runtime"
    mkdir -p "$fastra_cache"
    exec {icu_lock}>"$fastra_cache/icu78.3-native.lock"
    flock "$icu_lock"
    if [[ ! -d $icu ]]; then
      icu_archive
      icu_work=$(mktemp -d "$fastra_cache/.icu-native.XXXXXX")
      trap 'rm -rf -- "$icu_work"' EXIT
      "$fastra_repo/tools/linux-package/build-icu.sh" "$archive" "$icu_work/build"
      mv -T -- "$icu_work/build" "$fastra_cache/icu78.3-native"
      rm -rf -- "$icu_work"
      trap - EXIT
    fi
    flock -u "$icu_lock"
  fi
  icu=$(realpath "$icu")
  [[ -f $icu/ICU-SOURCE-SHA256 && $(cat "$icu/ICU-SOURCE-SHA256") == "$icu_sha" ]] || fail 'Use an ICU 78.3 prefix produced by tools/linux-package/build-icu.sh.'
  [[ -f $icu/ICU-LICENSE ]] || fail 'ICU prefix lacks ICU-LICENSE.'
}
export_icu() {
  # Der inhaltsabhängige stabile Pfad verhindert veraltete Cargo-Auflösungen
  # und zugleich unnötige Neubauten bei unveränderter ICU.
  pcdir=$(python3 "$fastra_repo/tools/linux-package/icu-pkgconfig.py" "$icu" "$fastra_cache/pkgconfig")
  export PKG_CONFIG_PATH="$pcdir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$icu/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}
