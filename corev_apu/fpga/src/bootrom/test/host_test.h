// SPDX-License-Identifier: Apache-2.0
// boot_net.c on the build machine: the MAC's registers, the timer and the packet memory are
// those of a model (host_test.c) that carries the UDP datagrams over the loopback interface.
#pragma once
#include <stdint.h>
extern uint8_t host_ram[];
uint32_t *host_reg(unsigned r);
uint64_t host_mtime(void);
#define NET_BASE ((uintptr_t)host_ram)
#define ETH(r)   (*host_reg(r))
#define MTIME    host_mtime()
