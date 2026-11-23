// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>

// Network boot (BOOT=net in the Makefile, boot_net.c): fetches the next stage by TFTP, puts it
// at the start of memory (0x8000_0000) and returns the address of the device tree to hand it.
// Does not return until that has worked.
uintptr_t boot_load(void);

extern const char _dtb[];           // the device tree in the ROM (startup.S)
