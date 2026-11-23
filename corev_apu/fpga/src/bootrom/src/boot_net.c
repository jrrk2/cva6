// SPDX-License-Identifier: Apache-2.0
// Network boot for the boards with legend64's Ethernet MAC (../../legend-ethernet): firmware,
// kernel and, if the server has one, a device tree are fetched by TFTP and the firmware is
// started. The kernel then mounts its root file system over NFS (the command line is in the
// device tree), so nothing is read from a card.
//
// The MAC driver, ARP and the TFTP client (RFC 1350, 2347, 2348) are those of legend64's boot
// monitor (fpga/sw/monitor.c there), which boots that SoC on the same board. What differs is
// where the state lives: this code runs from ROM, so everything it writes is at fixed addresses
// at the top of memory, clear of anything it loads.
#include <stdint.h>
#include <stddef.h>
#include "uart.h"
#include "boot.h"

// ---------------------------------------------------------------- configuration (see Makefile)
#ifndef BOARD_IP
#define BOARD_IP 192, 168, 1, 51
#endif
#ifndef TFTP_SERVER
#define TFTP_SERVER 192, 168, 1, 176
#endif
#ifndef TFTP_PORT
#define TFTP_PORT 69
#endif
#ifndef ETH_MAC
#define ETH_MAC 0x00, 0x18, 0x3e, 0x02, 0xe3, 0x7f
#endif
#ifndef TFTP_DIR
#define TFTP_DIR "cva6"
#endif
#ifndef TIMEBASE_HZ
#define TIMEBASE_HZ 25000000u       // mtime counts every second cycle of the 50 MHz clock
#endif

// what is loaded, and where: the addresses are the ones OpenSBI's fw_jump expects (the kernel
// 2 MiB above the firmware) and leave it room to move the device tree to 0x8220_0000
#define FW_ADDR     0x80000000UL
#define KERNEL_ADDR 0x80200000UL
#define DTB_ADDR    0x86000000UL
static const struct { const char *name; uintptr_t addr; uint32_t max; int optional; } boot_files[] = {
  {TFTP_DIR "/fw_jump.bin",    FW_ADDR,     KERNEL_ADDR - FW_ADDR, 0},
  {TFTP_DIR "/Image",          KERNEL_ADDR, 0x02000000,            0},
  {TFTP_DIR "/cva6-vc707.dtb", DTB_ADDR,    0x00010000,            1},  // else the one in this ROM
};

// ---------------------------------------------------------------- hardware
#ifndef HOST_TEST
#define REG32(a)   (*(volatile uint32_t *)(a))
#define MTIME      (*(volatile uint64_t *)0x0200bff8UL)
#define ETH(r)     REG32(0x30000000UL + (r))
#define NET_BASE   0xbfe00000UL     // the last 2 MiB of the VC707's gigabyte
#else
#include "host_test.h"
#endif
enum { E_CTRL = 0x00, E_STATUS = 0x04, E_MAC_LO = 0x10, E_MAC_HI = 0x14,
       E_RX_BASE = 0x20, E_RX_SIZE = 0x28, E_RX_TAIL = 0x30,
       E_TX_BASE = 0x40, E_TX_SIZE = 0x48, E_TX_TAIL = 0x50 };

#define RX_N       8
#define TX_N       4
struct desc { uint64_t addr; uint32_t len; uint32_t flags; };
#define RX_RING    ((volatile struct desc *)(NET_BASE))
#define TX_RING    ((volatile struct desc *)(NET_BASE + 0x100))
#define TX_BUF     ((uint8_t *)(NET_BASE + 0x8000 + 2))
#define RX_BUF(i)  (NET_BASE + 0x10000 + 2048UL * (i))

// Everything else this code writes. The ROM cannot hold variables, and the linker could not
// reach memory at 0x8000_0000 and above from code at 0x1_0000 anyway, so the state is one
// structure at a fixed address.
struct state {
  uint8_t  srv_mac[6];
  int      srv_known;
  uint32_t rx_next, rx_tail, tx_next;
  uint16_t port;                    // our UDP port, a new one for each transfer
  struct {
    int      active, done, failed;  // failed: 1, or 2 when the server said "file not found"
    uint16_t my_port, srv_port;     // the server answers from a port of its own choosing
    uint16_t next;                  // the data block expected
    uint32_t blksize;
    uint8_t  *dst;
    uint32_t got, max;
    int      progress;              // something arrived since the last look
  } tf;
};
#define S ((struct state *)(NET_BASE + 0x1000))

static const uint8_t my_mac[6] = {ETH_MAC};
static const uint8_t my_ip[4] = {BOARD_IP};
static const uint8_t srv_ip[4] = {TFTP_SERVER};

static void putdec(uint32_t v) {
  char b[12];
  int n = 11;
  b[n] = 0;
  do { b[--n] = '0' + v % 10; v /= 10; } while (v);
  print_uart(b + n);
}
static uint32_t ms_since(uint64_t t0) { return (MTIME - t0) / (TIMEBASE_HZ / 1000); }

// ---------------------------------------------------------------- Ethernet
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static void eth_stop(void) { ETH(E_CTRL) = 0x100; }      // stop, ring positions to zero

static void eth_init(void) {
  eth_stop();
  for (int i = 0; i < RX_N; i++) { RX_RING[i].addr = RX_BUF(i); RX_RING[i].len = 0; RX_RING[i].flags = 0; }
  for (int i = 0; i < TX_N; i++) { TX_RING[i].addr = 0; TX_RING[i].len = 0; TX_RING[i].flags = 0; }
  ETH(E_MAC_LO) = my_mac[0] | my_mac[1] << 8 | my_mac[2] << 16 | (uint32_t)my_mac[3] << 24;
  ETH(E_MAC_HI) = my_mac[4] | my_mac[5] << 8;
  ETH(E_RX_BASE) = (uint32_t)(uintptr_t)RX_RING; ETH(E_RX_BASE + 4) = 0; ETH(E_RX_SIZE) = RX_N;
  ETH(E_TX_BASE) = (uint32_t)(uintptr_t)TX_RING; ETH(E_TX_BASE + 4) = 0; ETH(E_TX_SIZE) = TX_N;
  S->rx_next = 0; S->tx_next = 0; S->rx_tail = RX_N - 1;
  ETH(E_RX_TAIL) = S->rx_tail;
  ETH(E_CTRL) = 3;
}

// send the frame built in TX_BUF and wait until the hardware has taken it
static void eth_send(int len) {
  volatile struct desc *d = &TX_RING[S->tx_next];
  d->addr = (uintptr_t)TX_BUF; d->len = len; d->flags = 0;
  S->tx_next = (S->tx_next + 1) % TX_N;
  ETH(E_TX_TAIL) = S->tx_next;
  for (uint64_t t0 = MTIME; !(d->flags & 1) && ms_since(t0) < 100; ) ;
}

static void arp_send(int reply, const uint8_t *dst_mac, const uint8_t *dst_ip) {
  uint8_t *t = TX_BUF;
  for (int i = 0; i < 6; i++) { t[i] = reply ? dst_mac[i] : 0xff; t[6 + i] = my_mac[i]; }
  t[12] = 0x08; t[13] = 0x06; t[14] = 0; t[15] = 1; t[16] = 8; t[17] = 0; t[18] = 6; t[19] = 4; t[20] = 0; t[21] = reply ? 2 : 1;
  for (int i = 0; i < 6; i++) { t[22 + i] = my_mac[i]; t[32 + i] = reply ? dst_mac[i] : 0; }
  for (int i = 0; i < 4; i++) { t[28 + i] = my_ip[i]; t[38 + i] = dst_ip[i]; }
  eth_send(42);
}

static uint16_t ip_checksum(const uint8_t *p, int n) {
  uint32_t s = 0;
  for (int i = 0; i < n; i += 2) s += rd16(p + i);
  while (s >> 16) s = (s & 0xffff) + (s >> 16);
  return ~s;
}

// an IPv4/UDP frame to the server: the caller has put `n` bytes of payload at TX_BUF + 42
static void udp_send(uint16_t sport, uint16_t dport, int n) {
  uint8_t *t = TX_BUF;
  for (int i = 0; i < 6; i++) { t[i] = S->srv_mac[i]; t[6 + i] = my_mac[i]; }
  t[12] = 0x08; t[13] = 0x00;
  t[14] = 0x45; t[15] = 0; t[16] = (20 + 8 + n) >> 8; t[17] = 20 + 8 + n;
  t[18] = 0; t[19] = 0; t[20] = 0x40; t[21] = 0; t[22] = 64; t[23] = 17; t[24] = 0; t[25] = 0;
  for (int i = 0; i < 4; i++) { t[26 + i] = my_ip[i]; t[30 + i] = srv_ip[i]; }
  uint16_t ck = ip_checksum(t + 14, 20);
  t[24] = ck >> 8; t[25] = ck;
  t[34] = sport >> 8; t[35] = sport; t[36] = dport >> 8; t[37] = dport;
  t[38] = (8 + n) >> 8; t[39] = 8 + n; t[40] = 0; t[41] = 0;   // UDP checksum not used
  eth_send(42 + n);
}

// ---------------------------------------------------------------- TFTP client
enum { TFTP_BLKSIZE = 1400 };

static void tftp_ack(uint16_t block) {
  uint8_t *t = TX_BUF + 42;
  t[0] = 0; t[1] = 4; t[2] = block >> 8; t[3] = block;
  udp_send(S->tf.my_port, S->tf.srv_port, 4);
}

static void tftp_rrq(const char *name) {
  static const char opts[] = "octet\0blksize\0001400";       // mode, then the block size option
  uint8_t *t = TX_BUF + 42;
  int n = 0;
  t[n++] = 0; t[n++] = 1;
  do t[n++] = *name; while (*name++);
  for (unsigned i = 0; i < sizeof opts; i++) t[n++] = opts[i];
  udp_send(S->tf.my_port, TFTP_PORT, n);
}

// a UDP datagram from the server to the transfer's port: p is the TFTP packet, n its length
static void tftp_rx(const uint8_t *p, int n, uint16_t sport) {
  if (!S->tf.active || S->tf.done || S->tf.failed || n < 4) return;
  uint16_t op = rd16(p), block = rd16(p + 2);
  if (S->tf.srv_port && sport != S->tf.srv_port) return;
  if (op == 5) {                                            // error: code, then a message
    if (block != 1) {
      print_uart("server says: ");
      for (int i = 4; i < n && p[i]; i++) write_serial(p[i]);
    }
    S->tf.failed = block == 1 ? 2 : 1;
  } else if (op == 6 && S->tf.next == 1 && !S->tf.srv_port) {   // option acknowledgement
    S->tf.srv_port = sport;
    for (int i = 2; i + 8 < n; ) {                          // "blksize\0<digits>\0"
      int is_blk = p[i] == 'b' && p[i + 1] == 'l' && p[i + 2] == 'k';
      while (i < n && p[i]) i++;
      i++;
      uint32_t v = 0;
      while (i < n && p[i]) v = v * 10 + (p[i++] - '0');
      i++;
      if (is_blk && v >= 8 && v <= TFTP_BLKSIZE) S->tf.blksize = v;
    }
    tftp_ack(0);
    S->tf.progress = 1;
  } else if (op == 3) {
    if (!S->tf.srv_port) S->tf.srv_port = sport;            // a server without options: 512-byte blocks
    if (block == S->tf.next) {
      const uint8_t *src = p + 4;
      uint32_t len = n - 4;
      if (len > S->tf.max - S->tf.got) {
        print_uart("too large");
        S->tf.failed = 1;
        return;
      }
      uint8_t *dst = S->tf.dst + S->tf.got;
      for (uint32_t i = 0; i < len; i++) dst[i] = src[i];
      S->tf.got += len;
      S->tf.next++;
      S->tf.progress = 1;
      if (len < S->tf.blksize) S->tf.done = 1;
    }
    tftp_ack(S->tf.next - 1);                               // also repeats the last one for a duplicate
  }
}

// look at one received frame, if there is one: answer ARP, note the server's address, and pass
// the transfer's datagrams on
static void eth_poll(void) {
  volatile struct desc *d = &RX_RING[S->rx_next];
  if (!(d->flags & 1)) return;
  int len = d->len;
  const uint8_t *r = (const uint8_t *)(RX_BUF(S->rx_next) + 2);
  int for_me = len >= 34 && r[30] == my_ip[0] && r[31] == my_ip[1] && r[32] == my_ip[2] && r[33] == my_ip[3];
  if (len >= 42 && rd16(r + 12) == 0x0806 && rd16(r + 20) == 1 &&
      r[38] == my_ip[0] && r[39] == my_ip[1] && r[40] == my_ip[2] && r[41] == my_ip[3]) {
    arp_send(1, r + 22, r + 28);
  } else if (len >= 42 && rd16(r + 12) == 0x0806 && rd16(r + 20) == 2 &&
             r[28] == srv_ip[0] && r[29] == srv_ip[1] && r[30] == srv_ip[2] && r[31] == srv_ip[3]) {
    for (int i = 0; i < 6; i++) S->srv_mac[i] = r[22 + i];  // the reply to our request for the server
    S->srv_known = 1;
  } else if (for_me && rd16(r + 12) == 0x0800 && r[14] == 0x45 && r[23] == 17 && len >= 46 && S->tf.active &&
             rd16(r + 36) == S->tf.my_port && r[26] == srv_ip[0] && r[27] == srv_ip[1] && r[28] == srv_ip[2] && r[29] == srv_ip[3]) {
    int n = rd16(r + 38) - 8;
    if (n >= 4 && 42 + n <= len) tftp_rx(r + 42, n, rd16(r + 34));
  }
  // give the descriptor back
  d->flags = 0;
  S->rx_next = (S->rx_next + 1) % RX_N;
  S->rx_tail = (S->rx_tail + 1) % RX_N;
  ETH(E_RX_TAIL) = S->rx_tail;
}

// Wait up to `ms` for *flag, serving the network meanwhile. Returns 0 when the flag is set,
// 1 on time-out.
static int wait_for(const int *flag, uint32_t ms) {
  uint64_t t0 = MTIME;
  while (!(flag && *flag)) {
    eth_poll();
    if (ms_since(t0) >= ms) return 1;
  }
  return 0;
}

// 0: fetched; 1: failed; 2: the server has no such file
static int tftp_get(const char *name, uintptr_t addr, uint32_t max) {
  print_uart("  "); print_uart(name); print_uart(": ");
  for (unsigned i = 0; i < sizeof S->tf; i++) ((uint8_t *)&S->tf)[i] = 0;
  S->tf.my_port = ++S->port; S->tf.next = 1; S->tf.blksize = 512; S->tf.dst = (uint8_t *)addr; S->tf.max = max;
  S->tf.active = 1;
  uint64_t t0 = MTIME;
  int tries = 0;
  tftp_rrq(name);
  while (!S->tf.done && !S->tf.failed) {
    S->tf.progress = 0;
    // Nothing for a while: say it again. The wait is longer than a server's own second, so that
    // after a lost block the server's repeat comes first; a repeated acknowledgement makes some
    // servers start their wait afresh, and two equal waits can then keep each other waiting.
    if (wait_for(&S->tf.progress, 1500)) {
      if (++tries == 6) break;
      if (S->tf.srv_port) tftp_ack(S->tf.next - 1); else tftp_rrq(name);
    } else tries = 0;
  }
  S->tf.active = 0;
  if (S->tf.done) {
    putdec(S->tf.got); print_uart(" bytes in "); putdec(ms_since(t0)); print_uart(" ms\r\n");
    return 0;
  }
  print_uart(S->tf.failed == 2 ? "not on the server\r\n" : S->tf.failed ? "\r\n" : "no answer\r\n");
  return S->tf.failed == 2 ? 2 : 1;
}

// one attempt; the device tree's address, or 0
static uintptr_t net_boot(void) {
  for (unsigned i = 0; i < sizeof *S; i++) ((uint8_t *)S)[i] = 0;
  S->port = 0x6c00 + ((uint32_t)MTIME & 0xfff);             // not the ports of the boot before
  eth_init();
  for (uint64_t t0 = MTIME; !(ETH(E_STATUS) & 1); )
    if (ms_since(t0) >= 5000) { print_uart("  no Ethernet link\r\n"); return 0; }
  arp_send(0, 0, my_ip);                                    // gratuitous ARP announces the address
  for (int i = 0; i < 4 && !S->srv_known; i++) {
    arp_send(0, 0, srv_ip);
    wait_for(&S->srv_known, 500);
  }
  if (!S->srv_known) { print_uart("  no ARP reply from the server\r\n"); return 0; }
  uintptr_t dtb = (uintptr_t)_dtb;
  for (unsigned i = 0; i < sizeof boot_files / sizeof boot_files[0]; i++) {
    int r = tftp_get(boot_files[i].name, boot_files[i].addr, boot_files[i].max);
    if (r == 0 && boot_files[i].addr == DTB_ADDR) dtb = DTB_ADDR;
    else if (r == 2 && boot_files[i].optional) print_uart("  using the device tree in the boot ROM\r\n");
    else if (r) return 0;
  }
  return dtb;
}

uintptr_t boot_load(void) {
  for (;;) {
    print_uart("TFTP boot from ");
    for (int i = 0; i < 4; i++) { putdec(srv_ip[i]); if (i < 3) write_serial('.'); }
    print_uart("\r\n");
    uintptr_t dtb = net_boot();
    eth_stop();                                             // no DMA into memory the next stage owns
    if (dtb) return dtb;
    print_uart("  trying again in 3 s\r\n");
    for (uint64_t t0 = MTIME; ms_since(t0) < 3000; ) ;
  }
}
