// SPDX-License-Identifier: Apache-2.0
// Runs the boot ROM's network boot (../src/boot_net.c) on the build machine against a real TFTP
// server on the loopback interface. This file is a model of the MAC as the driver sees it
// (registers, descriptor rings, frames stored two bytes into the buffer) and of the network
// behind it: it answers the ARP request for the server and carries UDP datagrams to and from
// 127.0.0.1. Whatever was loaded is then written out for comparison. See run.sh.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "host_test.h"
#include "../src/boot.h"
#include "../src/uart.h"

uint8_t host_ram[0x200000] __attribute__((aligned(4096)));
const char _dtb[] = "the device tree in the ROM";

void init_uart(uint32_t freq, uint32_t baud) { (void)freq; (void)baud; }
void write_serial(char a) { putchar(a); fflush(stdout); }
void print_uart(const char *s) { fputs(s, stdout); fflush(stdout); }
uint8_t read_reg_u8(uintptr_t addr) { (void)addr; return 0x60; }

struct desc { uint64_t addr; uint32_t len; uint32_t flags; };
static uint32_t regs[64], rx_head, tx_head;
static const uint8_t srv_mac[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
static uint8_t board_mac[6], board_ip[4], srv_ip[4];
static uint8_t pending[8][1600];            // frames waiting for a receive descriptor
static int pending_len[8], n_pending;
static struct { int fd; uint16_t port; } socks[1024];
static int n_socks;
static unsigned long n_frames_tx, n_frames_rx, n_dropped;
static int drop_every;                       // lose every n-th datagram in each direction

uint32_t *host_reg(unsigned r) { return &regs[r / 4]; }

static struct desc *ring(unsigned base_reg, uint32_t i) {
  uintptr_t a = ((uintptr_t)host_ram & ~0xffffffffUL) | regs[base_reg / 4];
  if (a < (uintptr_t)host_ram) a += 1UL << 32;
  return (struct desc *)a + i;
}

static void queue(const uint8_t *f, int len) {
  if (n_pending == 8) { n_dropped++; return; }
  memcpy(pending[n_pending], f, len);
  pending_len[n_pending++] = len;
}

static void frame_out(const uint8_t *f, int len) {
  n_frames_tx++;
  if (len >= 42 && f[12] == 0x08 && f[13] == 0x06 && f[21] == 1) {
    memcpy(board_mac, f + 22, 6); memcpy(board_ip, f + 28, 4);
    if (!memcmp(f + 38, board_ip, 4)) return;            // the gratuitous one
    memcpy(srv_ip, f + 38, 4);
    uint8_t r[42];
    memcpy(r, board_mac, 6); memcpy(r + 6, srv_mac, 6);
    memcpy(r + 12, "\x08\x06\0\1\x08\0\6\4\0\2", 10);
    memcpy(r + 22, srv_mac, 6); memcpy(r + 28, srv_ip, 4);
    memcpy(r + 32, board_mac, 6); memcpy(r + 38, board_ip, 4);
    queue(r, 42);
  } else if (len >= 42 && f[12] == 0x08 && f[13] == 0x00 && f[23] == 17) {
    if (memcmp(f, srv_mac, 6)) { fprintf(stderr, "model: frame not addressed to the server\n"); exit(2); }
    uint16_t sport = f[34] << 8 | f[35], dport = f[36] << 8 | f[37];
    int n = (f[38] << 8 | f[39]) - 8, i;
    if (42 + n != len || (f[16] << 8 | f[17]) != 28 + n) { fprintf(stderr, "model: bad lengths\n"); exit(2); }
    uint32_t s = 0;
    for (int k = 14; k < 34; k += 2) s += f[k] << 8 | f[k + 1];
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    if (s != 0xffff) { fprintf(stderr, "model: bad IP header checksum\n"); exit(2); }
    for (i = 0; i < n_socks && socks[i].port != sport; i++) ;
    if (i == n_socks) {
      socks[i].fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
      socks[i].port = sport;
      n_socks++;
    }
    if (drop_every && n_frames_tx % drop_every == 0) { n_dropped++; return; }
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(dport), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    sendto(socks[i].fd, f + 42, n, 0, (struct sockaddr *)&to, sizeof to);
  }
}

static void from_network(void) {
  for (int i = 0; i < n_socks && n_pending < 8; i++) {
    uint8_t f[1600];
    struct sockaddr_in from;
    socklen_t fl = sizeof from;
    int n = recvfrom(socks[i].fd, f + 42, sizeof f - 42, 0, (struct sockaddr *)&from, &fl);
    if (n < 0) continue;
    if (drop_every && ++n_frames_rx % drop_every == 0) { n_dropped++; continue; }
    memcpy(f, board_mac, 6); memcpy(f + 6, srv_mac, 6); f[12] = 8; f[13] = 0;
    memset(f + 14, 0, 28);
    f[14] = 0x45; f[16] = (28 + n) >> 8; f[17] = 28 + n; f[22] = 64; f[23] = 17;
    memcpy(f + 26, srv_ip, 4); memcpy(f + 30, board_ip, 4);
    f[34] = ntohs(from.sin_port) >> 8; f[35] = ntohs(from.sin_port);
    f[36] = socks[i].port >> 8; f[37] = socks[i].port;
    f[38] = (8 + n) >> 8; f[39] = 8 + n;
    queue(f, 42 + n);
  }
}

// every look at the timer lets the model run
uint64_t host_mtime(void) {
  if (regs[0] & 0x100) { rx_head = tx_head = 0; regs[0] = 0; n_pending = 0; }
  regs[1] = 1;                                           // link up
  if (regs[0] & 2)
    while (tx_head != regs[0x50 / 4]) {
      struct desc *d = ring(0x40, tx_head);
      frame_out((const uint8_t *)d->addr, d->len);
      d->flags |= 1;
      tx_head = (tx_head + 1) % regs[0x48 / 4];
    }
  from_network();
  while ((regs[0] & 1) && n_pending && rx_head != regs[0x30 / 4]) {
    struct desc *d = ring(0x20, rx_head);
    if (d->addr & 7) { fprintf(stderr, "model: receive buffer not aligned\n"); exit(2); }
    memcpy((uint8_t *)d->addr + 2, pending[0], pending_len[0]);
    d->len = pending_len[0]; d->flags = 1;
    n_pending--;
    memmove(pending[0], pending[1], sizeof pending[0] * n_pending);
    memmove(pending_len, pending_len + 1, sizeof pending_len[0] * n_pending);
    rx_head = (rx_head + 1) % regs[0x28 / 4];
  }
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (ts.tv_sec * 1000000000ULL + ts.tv_nsec) / 40;  // 25 MHz
}

static void dump(const char *dir, const char *name, uintptr_t addr, size_t len) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  FILE *f = fopen(path, "wb");
  fwrite((void *)addr, 1, len, f);
  fclose(f);
}

// host_test <output directory> [lose every n-th datagram]
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (argc > 2) drop_every = atoi(argv[2]);
  // the memory the boot ROM loads into, at the addresses it has on the board
  void *m = mmap((void *)0x80000000UL, 0x7000000, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
  if (m != (void *)0x80000000UL) { perror("mmap"); return 2; }
  memset(m, 0xa5, 0x7000000);
  uintptr_t dtb = boot_load();
  if (regs[0] & 3) { fprintf(stderr, "the MAC was left running\n"); return 2; }
  printf("device tree: %s; frames sent %lu, model dropped %lu\n",
         dtb == (uintptr_t)_dtb ? "ROM" : dtb == 0x86000000UL ? "loaded" : "?", n_frames_tx, n_dropped);
  dump(argv[1], "fw", 0x80000000UL, 0x200000);
  dump(argv[1], "kernel", 0x80200000UL, 0x2000000);
  dump(argv[1], "dtb", 0x86000000UL, 0x10000);
  return dtb == (uintptr_t)_dtb ? 10 : 0;
}
