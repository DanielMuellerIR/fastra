#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
icu=${FASTRA_ICU_PREFIX:-}
args=()
while (($#)); do
  case $1 in
    --help|-h) cat <<'EOF'
Usage: ./build.sh [--release] [--icu-prefix DIRECTORY] [-- CARGO_OPTIONS...]
Builds all three Linux executables; defaults to debug. ICU 78.3 is built in the private
user cache if --icu-prefix / FASTRA_ICU_PREFIX is absent. Requires Rust, C/C++,
make, pkg-config, GTK4 >=4.12, GtkSourceView >=5.6 and WebKitGTK 6 >=2.40 headers.
No system packages are installed. Cache: FASTRA_LINUX_CACHE or ~/.cache/fastra-linux.
EOF
      exit 0 ;;
    --icu-prefix) (($# >= 2)) || fail '--icu-prefix needs a directory'; icu=$2; shift 2 ;;
    --release|release) args+=(--release); shift ;;
    --) shift; args+=("$@"); break ;;
    *) fail "Unknown option $1; see --help." ;;
  esac
done
[[ $(uname -m) == x86_64 ]] || fail 'The Linux build is currently verified for x86_64 only.'
need cargo; need pkg-config; need python3
for spec in 'gtk4 4.12' 'gtksourceview-5 5.6' 'webkitgtk-6.0 2.40'; do
  read -r package minimum <<< "$spec"
  pkg-config --atleast-version="$minimum" "$package" || fail "Missing development package: $package >= $minimum. Install the distribution development headers."
done
prepare_icu
export_icu
[[ $(pkg-config --modversion icu-i18n) == 78.3 ]] || fail 'ICU pkg-config does not resolve to 78.3.'
cd "$fastra_repo"
cargo build --locked -p fastra-linux -p fastra-control -p fastra-diff-helper "${args[@]}"
