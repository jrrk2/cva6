#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Host test of the boot ROM's network boot: boot_net.c with a model of the MAC, against a TFTP
# server on the loopback interface.
#   run.sh <tftpd> <fw_jump.bin> <Image>
# <tftpd> is a command taking a directory and a port, for example legend64's
# fpga/scripts/tftpd.py. The two images can be any files (under 2 MiB and 32 MiB).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tftpd=$1; fw=$2; kernel=$3
port=${PORT:-6969}
w=$(mktemp -d)
trap 'kill $srv 2>/dev/null || true; rm -rf "$w"' EXIT
mkdir -p "$w/srv/cva6" "$w/out"
cp "$fw" "$w/srv/cva6/fw_jump.bin"; cp "$kernel" "$w/srv/cva6/Image"
gcc -O2 -Wall -DHOST_TEST -DTFTP_PORT=$port -I"$here" -I"$here/../src" -o "$w/host_test" \
    "$here/host_test.c" "$here/../src/boot_net.c"
"$tftpd" "$w/srv" $port >"$w/tftpd.log" 2>&1 &
srv=$!
sleep 0.5

check() {  # <expected exit status> <what the device tree should be> [lose every n-th]
  rc=0; "$w/host_test" "$w/out" ${3:-} || rc=$?
  [ $rc = "$1" ] || { echo "FAIL: exit status $rc, expected $1"; exit 1; }
  cmp -n "$(stat -c %s "$fw")" "$fw" "$w/out/fw"
  cmp -n "$(stat -c %s "$kernel")" "$kernel" "$w/out/kernel"
  # nothing written past the end of either
  [ "$(tail -c +$(( $(stat -c %s "$kernel") + 1 )) "$w/out/kernel" | tr -d '\245' | wc -c)" = 0 ]
  [ "$(tail -c +$(( $(stat -c %s "$fw") + 1 )) "$w/out/fw" | tr -d '\245' | wc -c)" = 0 ]
  [ -z "$2" ] || cmp -n "$(stat -c %s "$2")" "$2" "$w/out/dtb"
}

echo "== no device tree on the server"
check 10 ""
echo "== device tree on the server"
head -c 2675 /dev/urandom > "$w/srv/cva6/cva6-vc707.dtb"
check 0 "$w/srv/cva6/cva6-vc707.dtb"
echo "== every 400th datagram lost in each direction (takes about a minute)"
check 0 "$w/srv/cva6/cva6-vc707.dtb" 400
echo "== a kernel that is a whole number of blocks"
kernel="$w/blocks"; head -c $((1400 * 300)) /dev/urandom > "$kernel"; cp "$kernel" "$w/srv/cva6/Image"
check 0 "$w/srv/cva6/cva6-vc707.dtb"
echo "== a firmware that is too large is refused, and the boot is tried again"
head -c $((0x200001)) /dev/urandom > "$w/srv/cva6/fw_jump.bin"
timeout 3 "$w/host_test" "$w/out" > "$w/log" || true
grep -q "too large" "$w/log" && grep -q "trying again" "$w/log" || { cat "$w/log"; echo FAIL; exit 1; }
echo PASS
