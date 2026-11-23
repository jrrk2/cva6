// Copyright OpenHW Group contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "uart.h"
#include "spi.h"
#include "sd.h"
#include "gpt.h"
#include "boot.h"

#ifdef PLAT_AGILEX
#include "bootrom_types.h"

/* Block copy of the SD card through the HPS SD/MMC controller, in dw_mmc.c */
u8_t sd_copy_mmc(void *dst, u64_t src_lba, u64_t blkcnt);
#endif

#define SECOND_CYCLES   CLOCK_FREQUENCY
#define WAIT_SECONDS    (10)

static inline uintptr_t get_cycle_count() {
    uintptr_t cycle;
    __asm__ volatile ("csrr %0, cycle" : "=r" (cycle));
    return cycle;
}

int update(uint8_t *dest)
{
    int i;
    uint32_t size = 0;

    print_uart("receiving boot image\r\nsize: ");
    for(i = 0; i < sizeof(uint32_t); i++) {
        while(!read_serial(&((uint8_t *) &size)[i]));
    }

    print_uart_int(size);
    print_uart("\r\nreceiving ");

    for(i = 0; i < size; i++) {
        while(!read_serial(&dest[i]));

        if(i % (size >> 4) == 0) {
            print_uart(".");
        }
    }

    print_uart(" done!\r\n");
    return 0;
}

int main()
{
    int i, ret = 0;
    uint8_t uart_res = 0;
    uintptr_t start;

    #ifndef PLAT_AGILEX
    init_uart(CLOCK_FREQUENCY, UART_BITRATE); //not needed in intel setup as UART IP is already configured via HW
    #endif 
    print_uart("Hello World!\r\n");

    // See if we should enter update mode
    print_uart("Hit any key to enter update mode ");
    for(i = 0; i < WAIT_SECONDS && !ret; i++) {
        print_uart(".");
        start = get_cycle_count();
        while(get_cycle_count() - start < SECOND_CYCLES) {
            ret = read_serial(&uart_res);
            if(ret) {
                break;
            }
        }
    }

    int res;
    uintptr_t dtb = (uintptr_t)_dtb;
    if(ret) {
        print_uart(" updating!\r\n");
        res = update((uint8_t *)0x80000000UL);
    } else {
        print_uart(" booting!\r\n");
        #if defined(BOOT_NET)
        dtb = boot_load(); // from the network; does not return until it has worked
        res = 0;
        #elif !defined(PLAT_AGILEX)
        res = gpt_find_boot_partition((uint8_t *)0x80000000UL, 2 * 16384); 
        #else 
            int start_block_fw_payload  = 0x32800; //payload at 100MB
            print_uart("I am Agilex 7! \r\n");

            print_uart("Loading fw_payload into memory address 0x80000000 \n");
            for (uint64_t i = 0; i < 15000; i++){
                res = sd_copy_mmc((uint8_t *)0x80000000UL + (i * 0x200), start_block_fw_payload + i, 1); // for now hardcoded, need to develop the code to find the file in the SD card

                if (res)
                {
                    print_uart("TRANSFER ERROR\n");
                    return res;
                }
		    }
        #endif 
    }

    if (res == 0)
    {
        // jump to the address with the hart id (0) in a0 and the device tree in a1
        #ifdef BOOT_NET
        while (!(read_reg_u8(UART_LINE_STATUS) & 0x40)) ; // let the last characters out
        #endif
        register uintptr_t a0 __asm__("a0") = 0;
        register uintptr_t a1 __asm__("a1") = dtb;
        __asm__ volatile(
            "li s0, 0x80000000;"
            "jr s0" : : "r"(a0), "r"(a1));
    }

    while (1)
    {
        // do nothing
    }
}

void handle_trap(void)
{
    // print_uart("trap\r\n");
}
