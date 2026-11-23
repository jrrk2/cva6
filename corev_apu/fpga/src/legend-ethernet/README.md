# Ethernet for the VC707

The VC707's gigabit Ethernet: the descriptor-ring MAC of the legend64 project, which moves
packets to and from main memory by itself (DMA) and does the checksums, over SGMII to the
board's Marvell PHY. It replaces the RGMII ports and constraints the VC707 build used to
carry, which matched nothing on that board. The other boards keep lowRISC's Ethernet
(`../ariane-ethernet`).

| File | |
|---|---|
| `legend_eth_axi.sv` | the peripheral: registers on AXI at `0x3000_0000`, interrupt (PLIC source 3), DMA memory port, SGMII pins |
| `legend_eth.sv` | rings, FIFOs, DMA and checksum engines; register map and descriptor format in its header |
| `legend_sgmii.sv` | joins the PHY and the byte-stream MAC |
| `legend_eth_mac_1g.sv`, `legend_axis_gmii_rx.sv`, `legend_axis_gmii_tx.sv`, `legend_lfsr.sv` | the byte-stream MAC: Alex Forencich's verilog-ethernet (MIT), as carried by lowRISC's ariane-ethernet, the transmit side with legend64's inter-frame gap correction. The modules have a `legend_` prefix here because the build also reads lowRISC's copies |
| `liteeth_sgmii_phy.v` | generated: LiteEth's 1000BASE-X/SGMII PCS on a GTX transceiver (EnjoyDigital and contributors, BSD 2-Clause) |
| `linux/legend_eth.c` | the Linux driver (GPL-2.0), unchanged from legend64 |

The legend64 files are Apache-2.0. `legend_eth.sv` differs from legend64's in one place: a
request on its memory port stays there until granted.

## Coherence with the data cache

The driver hands the MAC addresses in ordinary memory and does no cache maintenance, so the MAC's
reads and writes have to agree with what the core sees through its data cache. They do because
they go through that cache: the MAC's memory port is connected to the core's **device port**
(`DevicePortEn` and `ypb_dev_req_i`/`ypb_dev_rsp_o` on `cva6`), which makes the device one more
requester of the HPDcache, next to the core's own loads and stores.

* **The MAC writes** (received frames, descriptor status) are stores in the cache: a line the
  core holds is updated in place, and the MAC is told that its write is done when the cache has
  answered it, so by the time it raises an interrupt or moves a ring position the core reads
  the new data.
* **The MAC reads** (frames to send, descriptors) are loads in the cache: they see what the
  core has stored, whether that is still in the cache or its write buffer or already in memory.
  This holds for every write policy of the cache, write-back included.
* The glue is in `ariane_xilinx.sv` (`gen_legend_dma`): one request at a time, physically
  addressed.

The debug module's system bus access still writes memory behind the cache, as on the other
boards.

`corev_apu/tb/tb_dcache_dev_port` tests both directions on the core.

## Building

    ./cook.py fpga-bootrom -t fpga_linux_cv64a6 -c <toolchain> --board vc707
    ./cook.py vivado-fpga-build -t fpga_linux_cv64a6 --board vc707

The ROM boots from the network through this MAC: firmware and kernel by TFTP, root file system
on NFS; the addresses are options of `fpga-bootrom` (`../bootrom/README.md`). Its device tree
names this MAC:

    eth: ethernet@30000000 {
      compatible = "legend,eth";
      interrupt-parent = <&PLIC0>;
      interrupts = <3>;
      local-mac-address = [00 18 3e 02 e3 7f];
      reg = <0x0 0x30000000 0x0 0x1000>;
    };

The sources are read by the build of every board (`corev_apu/fpga/Flist.cva6_fpga`); only the
VC707's 64-bit top instantiates them.

## Linux

Add `linux/legend_eth.c` to the kernel as `drivers/net/ethernet/legend/legend_eth.c` with

    # drivers/net/ethernet/legend/Kconfig
    config LEGEND_ETH
    	tristate "legend64 native descriptor-ring Ethernet MAC (legend,eth)"
    	depends on OF && HAS_IOMEM && HAS_DMA

    # drivers/net/ethernet/legend/Makefile
    obj-$(CONFIG_LEGEND_ETH) += legend_eth.o

a `source` line in `drivers/net/ethernet/Kconfig` and `obj-$(CONFIG_LEGEND_ETH) += legend/` in
`drivers/net/ethernet/Makefile`, and set `CONFIG_LEGEND_ETH=y`. It was written against Linux
6.18.
