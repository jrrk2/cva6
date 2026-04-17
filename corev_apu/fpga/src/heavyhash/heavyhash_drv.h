// heavyhash_drv.h — C driver for HeavyHash mining accelerator
//
// Register interface for CVA6 software running on RISC-V Linux.
// Base address: 0x50000000 (same slot as former inference engine)
//
// Call hh_init() first to mmap the device. All other functions
// use the mapped pointer.

#ifndef HEAVYHASH_DRV_H
#define HEAVYHASH_DRV_H

#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

// Hardware base address and map size
#define HH_PHYS_BASE    0x50000000UL
#define HH_MAP_SIZE     0x1000

// Register offsets
#define HH_CTRL           0x000
#define HH_STATUS         0x004
#define HH_HASH_CNT_LO    0x008
#define HH_HASH_CNT_HI    0x00C
#define HH_NONCE_LO       0x010
#define HH_NONCE_HI       0x014
#define HH_FOUND_NONCE_LO 0x018
#define HH_FOUND_NONCE_HI 0x01C
#define HH_TARGET_BASE    0x020   // 8 x 32-bit words (256 bits)
#define HH_MSG_BASE       0x040   // 34 x 32-bit words (1088 bits)
#define HH_MSTATE1_BASE   0x100   // 50 x 32-bit words (1600 bits)
#define HH_MSTATE2_BASE   0x200   // 50 x 32-bit words (1600 bits)
#define HH_MAT_ADDR       0x300
#define HH_MAT_DATA0      0x304   // 8 x 32-bit staging words
#define HH_MAT_WR         0x324

// CTRL bits
#define HH_CTRL_START     (1 << 0)
#define HH_CTRL_STOP      (1 << 1)
#define HH_CTRL_CLR_FOUND (1 << 2)

// STATUS bits
#define HH_STATUS_BUSY    (1 << 0)
#define HH_STATUS_FOUND   (1 << 1)

// ----------------------------------------------------------------
//  Device handle
// ----------------------------------------------------------------
static volatile uint32_t *hh_base;

static inline int hh_init(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) return -1;
    void *p = mmap(NULL, HH_MAP_SIZE, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, HH_PHYS_BASE);
    close(fd);
    if (p == MAP_FAILED) return -1;
    hh_base = (volatile uint32_t *)p;
    return 0;
}

static inline void hh_cleanup(void) {
    if (hh_base) {
        munmap((void *)hh_base, HH_MAP_SIZE);
        hh_base = NULL;
    }
}

// ----------------------------------------------------------------
//  MMIO helpers
// ----------------------------------------------------------------
static inline void hh_write(uint32_t offset, uint32_t val) {
    hh_base[offset / 4] = val;
}

static inline uint32_t hh_read(uint32_t offset) {
    return hh_base[offset / 4];
}

// ----------------------------------------------------------------
//  High-level API
// ----------------------------------------------------------------

static inline void hh_write_mid_state(uint32_t base_offset, const uint32_t *state) {
    for (int i = 0; i < 50; i++)
        hh_write(base_offset + i * 4, state[i]);
}

static inline void hh_write_msg_block(const uint32_t *msg) {
    for (int i = 0; i < 34; i++)
        hh_write(HH_MSG_BASE + i * 4, msg[i]);
}

static inline void hh_write_target(const uint32_t *target) {
    for (int i = 0; i < 8; i++)
        hh_write(HH_TARGET_BASE + i * 4, target[i]);
}

static inline void hh_write_matrix_row(int row, const uint32_t *data) {
    hh_write(HH_MAT_ADDR, row);
    for (int i = 0; i < 8; i++)
        hh_write(HH_MAT_DATA0 + i * 4, data[i]);
    hh_write(HH_MAT_WR, 1);
}

static inline void hh_write_matrix(const uint32_t matrix[64][8]) {
    for (int r = 0; r < 64; r++)
        hh_write_matrix_row(r, matrix[r]);
}

static inline void hh_set_nonce(uint64_t nonce) {
    hh_write(HH_NONCE_LO, (uint32_t)(nonce & 0xFFFFFFFF));
    hh_write(HH_NONCE_HI, (uint32_t)(nonce >> 32));
}

static inline void hh_start(void) {
    hh_write(HH_CTRL, HH_CTRL_START);
}

static inline void hh_stop(void) {
    hh_write(HH_CTRL, HH_CTRL_STOP);
}

static inline void hh_clear_found(void) {
    hh_write(HH_CTRL, HH_CTRL_CLR_FOUND);
}

static inline int hh_is_busy(void) {
    return (hh_read(HH_STATUS) & HH_STATUS_BUSY) != 0;
}

static inline int hh_is_found(void) {
    return (hh_read(HH_STATUS) & HH_STATUS_FOUND) != 0;
}

static inline uint64_t hh_get_found_nonce(void) {
    uint64_t lo = hh_read(HH_FOUND_NONCE_LO);
    uint64_t hi = hh_read(HH_FOUND_NONCE_HI);
    return (hi << 32) | lo;
}

static inline uint64_t hh_get_hash_count(void) {
    uint64_t lo = hh_read(HH_HASH_CNT_LO);
    uint64_t hi = hh_read(HH_HASH_CNT_HI);
    return (hi << 32) | lo;
}

#endif // HEAVYHASH_DRV_H
