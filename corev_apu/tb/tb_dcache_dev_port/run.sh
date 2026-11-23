#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build and run the test of the data cache's device port with Verilator (5.x, with --timing).
#   corev_apu/tb/tb_dcache_dev_port/run.sh [seeds, default 4]
# Needs riscv64-unknown-elf-gcc on the path (or CROSSCOMPILE) and verilator (or VERILATOR).
# TARGET_CFG chooses the target (default fpga_linux_cv64a6; any 64-bit one with the cache
# subsystem and AXI).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../.."
V=${VERILATOR:-verilator}
X=${CROSSCOMPILE:-riscv64-unknown-elf-}
export CVA6_REPO_DIR=$PWD TARGET_CFG=${TARGET_CFG:-fpga_linux_cv64a6}
export HPDCACHE_DIR=$PWD/core/cache_subsystem/hpdcache
out=build/$TARGET_CFG/tb_dcache_dev_port
mkdir -p $out

${X}gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -Wl,-Ttext=0x80000000 -o $out/prog.elf $here/prog.S
${X}objcopy -O binary $out/prog.elf $out/prog.bin
python3 -c "
d = open('$out/prog.bin', 'rb').read(); d += b'\0' * (-len(d) % 8)
open('$out/prog.hex', 'w').write('\n'.join('%016x' % int.from_bytes(d[i:i+8], 'little') for i in range(0, len(d), 8)) + '\n')"

$V --binary --timing verilator_config.vlt -f config/target/$TARGET_CFG/Flist.cva6 \
   +incdir+corev_apu/register_interface/include \
   corev_apu/tb/ariane_axi_pkg.sv corev_apu/tb/axi_intf.sv corev_apu/tb/ariane_soc_pkg.sv \
   corev_apu/src/ariane.sv corev_apu/axi_mem_if/src/axi2mem.sv $here/tb_dcache_dev_port.sv \
   --top-module tb_dcache_dev_port --unroll-count 256 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
   -O2 -j 8 --Mdir $out/obj -o ../tb > $out/build.log 2>&1 || { grep -A8 '%Error' $out/build.log | head -40; exit 1; }

cd $out
fail=0
rm -f run.log
for s in $(seq 1 ${1:-4}); do ./tb +verilator+seed+$s | grep -E '^(PASS|FAIL|ERROR)' | tee -a run.log | grep -q '^PASS' || fail=1; tail -1 run.log; done
./tb +nostall +verilator+seed+1 | grep -E '^(PASS|FAIL)' | grep -q '^PASS' && echo "PASS (memory answers at once)" || fail=1
./tb +behind +verilator+seed+1 | grep -q '^FAIL A' && echo "PASS (a device that writes behind the cache fails the test, as it must)" || fail=1
exit $fail
