#!/bin/bash
set -euo pipefail
image=$(mktemp /results/fastra-exchange.XXXXXX.img)
loop_device=''
mount_root=/run/fastra-ext4
cleanup() {
    result=$?
    trap - EXIT INT TERM
    if mountpoint -q "$mount_root"; then umount "$mount_root" || result=90; fi
    if [[ -n "$loop_device" ]]; then
        associated=$(losetup --associated "$image" --noheadings --output NAME)
        if [[ "${associated// /}" == "$loop_device" ]]; then losetup -d "$loop_device" || result=91
        else result=92
        fi
    fi
    if [[ "$result" -eq 0 ]]; then
        [[ -z "$(losetup --associated "$image" --noheadings --output NAME)" ]] || exit 93
        rm -- "$image"
        printf '{"unmounted":true,"ownLoopDetached":true,"imageRemoved":true}\n' >/results/exchange-cleanup.json
    fi
    exit "$result"
}
trap cleanup EXIT INT TERM
truncate -s 64M "$image"
mkfs.ext4 -q -F -m 0 "$image"
for number in $(seq 0 15); do [[ -e /dev/loop$number ]] || mknod /dev/loop$number b 7 "$number"; done
loop_device=$(losetup --find --show "$image")
mkdir -p "$mount_root"
mount -t ext4 -o nodev,nosuid,noexec "$loop_device" "$mount_root"
chown nobody:nogroup "$mount_root"
findmnt -n -o FSTYPE --target "$mount_root" > /results/exchange-filesystem.txt
runuser -u nobody -- python3 /probe/exchange.py "$mount_root" > /results/exchange-ext4.json
runuser -u nobody -- python3 /probe/recovery.py "$mount_root" > /results/recovery-ext4.json
if [[ -n "${FASTRA_IO_TEST_BIN:-}" ]]; then
    runuser -u nobody -- env FASTRA_IO_TEST_ROOT="$mount_root" \
        FASTRA_IO_TEST_COMMAND="$FASTRA_IO_TEST_BIN" \
        timeout 60s "$FASTRA_IO_TEST_BIN" > /results/transaction-ext4.txt 2>&1
fi
