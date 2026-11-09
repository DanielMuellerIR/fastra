#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
key=${FASTRA_SIGNING_KEY:-}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  echo 'Usage: ./linux/sign.sh --key FULL_OPENPGP_FINGERPRINT PACKAGE_DIRECTORY'
  echo 'Verifies relative SHA256SUMS, signs it locally, then runs gpg --verify.'
  exit 0
fi
if [[ ${1:-} == --key ]]; then (($# >= 2)) || fail '--key requires a fingerprint'; key=$2; shift 2; fi
[[ $# == 1 && $key =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] || fail 'Provide one package directory and an explicit full signing fingerprint.'
need gpg; need python3
packages=$(realpath "$1")
python3 "$fastra_repo/tools/linux-package/verify.py" --checksums "$packages"
[[ ! -e $packages/SHA256SUMS.asc ]] || fail 'Signature already exists; refusing to replace it.'
partial=$(mktemp "$packages/.signature.XXXXXX")
trap 'rm -f -- "$partial"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
gpg --armor --detach-sign --local-user "$key!" --output "$partial" --yes "$packages/SHA256SUMS"
gpg --verify "$partial" "$packages/SHA256SUMS"
mv -T -n -- "$partial" "$packages/SHA256SUMS.asc"
[[ ! -e $partial ]] || fail 'Signature appeared during signing; refusing to replace it.'
echo 'OpenPGP checksum signature verified.'
