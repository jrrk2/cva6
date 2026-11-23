# First Stage Bootloader for Ariane

The ROM brings the next stage into memory at `0x8000_0000` and jumps to it with the address of a
device tree in `a1`. Unless a key is hit on the serial line in the first ten seconds (update
mode: the image then comes over the serial line), the next stage comes from where the ROM was
built to take it (`--boot` of `./cook.py fpga-bootrom`, `BOOT` of the Makefile):

| boot | default for | source | code |
|---|---|---|---|
| `sd` | every board but the VC707 | the SD card | `gpt.c`, `sd.c`, `spi.c`, `dw_mmc.c` |
| `net` | vc707 (64 bit) | a TFTP server; the kernel's root file system is on NFS | `src/boot_net.c` |

## Booting from the network (VC707)

Nothing is read from a card. The ROM brings up the Ethernet MAC (`../legend-ethernet`), fetches
three files by TFTP and starts the first:

| File on the server | Loaded at | |
|---|---|---|
| `cva6/fw_jump.bin` | `0x8000_0000` | OpenSBI's `fw_jump` for the generic platform (under 2 MiB) |
| `cva6/Image` | `0x8020_0000` | an uncompressed Linux kernel with the `legend,eth` driver and NFS root built in (under 32 MiB) |
| `cva6/cva6-vc707.dtb` | `0x8600_0000` | optional: without it the device tree in the ROM is used |

The kernel command line is in the device tree and names the NFS root. If the link is down, the
server does not answer or a file is missing, the ROM says so on the serial line and tries again
every three seconds, so the board can be switched on before the server is ready.

The addresses are fixed when the ROM is built: they are options of `./cook.py fpga-bootrom`
(and variables of the Makefile, in capitals), whose defaults suit one particular network:

| Option | Default | |
|---|---|---|
| `--board-ip` | `192.168.1.51` | |
| `--eth-mac` | `00:18:3e:02:e3:7f` | also the `local-mac-address` in the device tree |
| `--tftp-server` | `192.168.1.176` | must be on the board's own network: there is no routing |
| `--tftp-dir` | `cva6` | directory of the three files on the server |
| `--nfs-server`, `--nfs-root` | the TFTP server, `/srv/nfs/cva6` | |
| `--gateway`, `--netmask` | `192.168.1.1`, `255.255.255.0` | only for the kernel command line |
| `--bootargs` | NFS root, `ip=` from the above | the whole kernel command line |

```bash
$ ./cook.py fpga-bootrom -t fpga_linux_cv64a6 -c <toolchain> --board vc707 \
    --board-ip 10.0.0.2 --tftp-server 10.0.0.1 --gateway 10.0.0.1
$ ./cook.py vivado-fpga-build -t fpga_linux_cv64a6 --board vc707
```

On the server (tftpd-hpa serving `/srv/tftp`, and an NFS export for the board):

```bash
$ sudo mkdir -p /srv/tftp/cva6
$ sudo cp fw_jump.bin Image /srv/tftp/cva6/
# only to change the device tree or the command line without a new bitstream:
$ sudo cp build/bootrom/vc707/rv64/cv64a6.dtb /srv/tftp/cva6/cva6-vc707.dtb
```

legend64's `linux/out/fw_jump.bin` and `linux/out/Image` are such a pair: that kernel has the
driver and takes everything else from the device tree.

The loader (the MAC driver, ARP and the TFTP client) is the one in legend64's boot monitor. It
runs from ROM here, so its rings, buffers and state are at fixed addresses in the last 2 MiB of
the gigabyte of memory (`0xbfe0_0000`), which nothing it loads reaches. `test/run.sh` runs it on
the build machine against a TFTP server, with a model of the MAC.

## How-To prepare SD card
The bootloader requires a GPT partition table so you first have to create one with gdisk.

```bash
$ sudo fdisk -l # search for the corresponding disk label (e.g. /dev/sdb)
$ sudo sgdisk --clear --new=1:2048:67583 --new=2 --typecode=1:3000 --typecode=2:8300 /dev/sdb # create a new gpt partition table and two partitions: 1st partition: 32mb (ONIE boot), second partition: rest (Linux root)
```

Now you have to make the linux kernel with the [ariane-sdk](https://github.com/pulp-platform/ariane-sdk):
```bash
$ cd /path/to/ariane-sdk
$ make bbl.bin # make the linux kernel with the ariane-sdk repository
```

Then the bbl+linux kernel image can get copied to the sd card with `dd`. __Careful:__  use the same disk label that you found before with `fdisk -l` but with a 1 in the end, e.g. `/dev/sdb` -> `/dev/sdb1`.
```bash
$ sudo dd if=bbl.bin of=/dev/sdb1 status=progress oflag=sync bs=1M
```

## Features

- uart
- spi
- sd card reading
- GPT partitions

## TODO

- file systems (fat16/fat32)
- elf loader
- zeroing of the `.bss` section of the second stage boot loader
