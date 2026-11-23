XLEN ?= 64
CROSSCOMPILE ?= riscv-none-elf-

ifeq ($(BOARD), nexys_video)
DRAM_SIZE_64 ?= 0x20000000 #512MB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 25000000 #25MHz
HALF_CLOCK_FREQUENCY ?= 12500000 #12.5MHz
UART_BITRATE ?= 57600
HAS_ETHERNET ?= 0
else ifeq ($(PLATFORM), PLAT_AGILEX)
DRAM_SIZE_64 ?= 0x40000000 #1GB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 100000000 #100MHz
HALF_CLOCK_FREQUENCY ?= 50000000 #50MHz
UART_BITRATE ?= 115200
HAS_ETHERNET ?= 1
else
DRAM_SIZE_64 ?= 0x40000000 #1GB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 50000000 #50MHz
HALF_CLOCK_FREQUENCY ?= 25000000 #25MHz
UART_BITRATE ?= 115200
HAS_ETHERNET ?= 1
endif

# Where the next stage comes from: sd (the card) or net (TFTP, for the board with legend64's
# Ethernet MAC; the kernel then takes its root file system over NFS). See README.md.
ifeq ($(BOARD), vc707)
BOOT ?= net
else
BOOT ?= sd
endif

# Network boot. The ROM asks TFTP_SERVER for $(TFTP_DIR)/fw_jump.bin, $(TFTP_DIR)/Image and
# $(TFTP_DIR)/cva6-vc707.dtb; without the last it hands on the device tree built in here, whose
# kernel command line is BOOTARGS.
BOARD_IP    ?= 192.168.1.51
NETMASK     ?= 255.255.255.0
GATEWAY     ?= 192.168.1.1
ETH_MAC     ?= 00:18:3e:02:e3:7f
TFTP_SERVER ?= 192.168.1.176
TFTP_DIR    ?= cva6
NFS_SERVER  ?= $(TFTP_SERVER)
NFS_ROOT    ?= /srv/nfs/cva6
BOOTARGS    ?= console=ttyS0,$(strip $(UART_BITRATE)) earlycon root=/dev/nfs nfsroot=$(NFS_SERVER):$(NFS_ROOT),vers=3,tcp,rsize=32768,wsize=32768 rw ip=$(BOARD_IP)::$(GATEWAY):$(NETMASK):cva6:eth0:off
comma := ,
empty :=
space := $(empty) $(empty)

ifeq ($(CC),cc)
  CC = $(RISCV)/bin/${CROSSCOMPILE}gcc
  OBJCOPY = $(RISCV)/bin/$(CROSSCOMPILE)objcopy
endif
SED = sed
PLATFORM_DEFINES = -DCLOCK_FREQUENCY=$(CLOCK_FREQUENCY) -DUART_BITRATE=$(UART_BITRATE) -D$(PLATFORM)  -DXLEN=$(XLEN)

ifeq ($(BOOT), net)
PLATFORM_DEFINES += -DBOOT_NET -DTIMEBASE_HZ=$(strip $(HALF_CLOCK_FREQUENCY)) \
	-DBOARD_IP=$(subst .,$(comma),$(BOARD_IP)) -DTFTP_SERVER=$(subst .,$(comma),$(TFTP_SERVER)) \
	-DETH_MAC=0x$(subst :,$(comma)0x,$(ETH_MAC)) '-DTFTP_DIR="$(TFTP_DIR)"'
endif

ifeq ($(XLEN), 64)
CFLAGS = $(PLATFORM_DEFINES) -Os -ggdb -march=rv64im_zicsr -mabi=lp64 -Wall -mcmodel=medany -mexplicit-relocs -ffreestanding
else
CFLAGS = $(PLATFORM_DEFINES) -O2 -ggdb  -march=rv32im_zicsr -mabi=ilp32 -W -Wall -mcmodel=medany -mexplicit-relocs -fno-builtin -ffreestanding
endif

CCASFLAGS = -mcmodel=medany -mexplicit-relocs
LDFLAGS = -nostdlib -nodefaultlibs -nostartfiles

INCLUDES = -I./ -I./src

ifeq ($(BOOT), net)
SRCS_C = src/main.c src/uart.c src/boot_net.c src/string.c
else
SRCS_C = src/main.c src/uart.c src/spi.c src/sd.c src/gpt.c src/dw_mmc.c src/bouncebuf.c
endif
SRCS_ASM = startup.S
OBJS_C = $(SRCS_C:.c=.o)
OBJS_S = $(SRCS_ASM:.S=.o)

MAIN = bootrom_$(XLEN).elf
MAIN_BIN = $(MAIN:.elf=.bin)
MAIN_IMG = $(MAIN:.elf=.img)
MAIN_SV = $(MAIN:.elf=.sv)

ifeq ($(PLATFORM), PLAT_AGILEX)
DTB = cv$(XLEN)a6_agilex.dtb
else
DTB = cv$(XLEN)a6.dtb
endif

ifeq ($(HAS_ETHERNET), 1)
SED_DELETE_OPT = -e "/DELETE_ETH/d"
else
SED_DELETE_OPT =
endif
# the Ethernet node: legend64's MAC on the VC707, lowRISC's on the other boards
ifeq ($(BOARD), vc707)
SED_DELETE_OPT += -e "/LOWRISC_ETH/d"
else
SED_DELETE_OPT += -e "/LEGEND_ETH/d"
endif
# the kernel command line, for a ROM that boots from the network
ifeq ($(BOOT), net)
SED_DELETE_OPT += -e 's|KERNEL_BOOTARGS|$(BOOTARGS)|'
else
SED_DELETE_OPT += -e "/KERNEL_BOOTARGS/d"
endif
SED_DELETE_OPT += -e "s/LOCAL_MAC_ADDRESS/$(subst :,$(space),$(ETH_MAC))/"

#.PHONY: clean

$(MAIN): $(DTB) $(OBJS_C) $(OBJS_S) linker.lds
	$(CC) $(CFLAGS) $(LDFLAGS) $(INCLUDES) -Tlinker.lds $(OBJS_S) $(OBJS_C) -o $(MAIN)
	@echo "LD    >= $(MAIN)"
	@echo "BOOTROM PLATFORM IS : $(PLATFORM)"

%.img: %.bin
	dd if=$< of=$@ bs=128

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.o: %.c
	@echo "CC    <= $<"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $<  -o $@

%.o: %.S
	@echo "CC    <= $<"
	@$(CC) $(CFLAGS) $(CCASFLAGS) $(INCLUDES) -c $<  -o $@

%.dts: %.dts.in
	$(SED) -e "s/DRAM_SIZE_64/$(DRAM_SIZE_64)/g" \
	       -e "s/DRAM_SIZE_32/$(DRAM_SIZE_32)/g" \
	       -e "s/HALF_CLOCK_FREQUENCY/$(HALF_CLOCK_FREQUENCY)/g" \
	       -e "s/CLOCK_FREQUENCY/$(CLOCK_FREQUENCY)/g" \
	       -e "s/UART_BITRATE/$(UART_BITRATE)/g" \
	       $(SED_DELETE_OPT) $< > $@
	cat $@

%.dtb: %.dts
	dtc -I dts $< -O dtb -o cv$(XLEN)a6.dtb

%.sv: %.img
	@echo "PYTHON >= $(MAIN_SV)"
	./gen_rom.py $<

clean:
	$(RM) src/*.o $(OBJS_S) $(MAIN) $(MAIN_BIN) $(MAIN_IMG) *.dtb *.dts *.sv
	rm -f ./bootrom_32.h ./bootrom_64.h

all: $(MAIN) $(MAIN_BIN) $(MAIN_IMG) $(MAIN_SV)
	@echo "zero stage bootloader has been compiled!"

# DO NOT DELETE THIS LINE -- make depend needs it
