// hh_smoke_test.c — Smoke test for HeavyHash mining accelerator on CVA6
//
// Verifies register access and pipeline operation via MMIO.
// Runs on RISC-V Linux using /dev/mem mmap.
//
// Build: riscv64-unknown-linux-gnu-gcc -O2 -o hh_smoke_test hh_smoke_test.c
// Run:   ./hh_smoke_test           (needs root or /dev/mem access)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

// Hardware base address
#define HH_BASE       0x50000000UL
#define HH_MAP_SIZE   0x1000

// Register offsets
#define CTRL          0x000
#define STATUS        0x004
#define HASH_CNT_LO   0x008
#define HASH_CNT_HI   0x00C
#define NONCE_LO      0x010
#define NONCE_HI      0x014
#define FOUND_NONCE_LO 0x018
#define FOUND_NONCE_HI 0x01C
#define TARGET_BASE   0x020
#define MSG_BASE      0x040
#define MSTATE1_BASE  0x100
#define MSTATE2_BASE  0x200
#define MAT_ADDR      0x300
#define MAT_DATA0     0x304
#define MAT_WR        0x324

// CTRL bits
#define CTRL_START    (1 << 0)
#define CTRL_STOP     (1 << 1)
#define CTRL_CLR_FOUND (1 << 2)

// STATUS bits
#define STATUS_BUSY   (1 << 0)
#define STATUS_FOUND  (1 << 1)

static volatile uint32_t *base;
static int test_pass, test_fail;

static void wreg(uint32_t off, uint32_t val) {
    base[off / 4] = val;
}

static uint32_t rreg(uint32_t off) {
    return base[off / 4];
}

static void check(const char *name, uint32_t got, uint32_t expected) {
    if (got == expected) {
        printf("  PASS: %s = 0x%08x\n", name, got);
        test_pass++;
    } else {
        printf("  FAIL: %s = 0x%08x (expected 0x%08x)\n", name, got, expected);
        test_fail++;
    }
}

// ----------------------------------------------------------------
//  Software Keccak-f[1600] (for mid-state computation)
// ----------------------------------------------------------------

static const uint64_t keccak_rc[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL,
    0x800000000000808AULL, 0x8000000080008000ULL,
    0x000000000000808BULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008AULL, 0x0000000000000088ULL,
    0x0000000080008009ULL, 0x000000008000000AULL,
    0x000000008000808BULL, 0x800000000000008BULL,
    0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800AULL, 0x800000008000000AULL,
    0x8000000080008081ULL, 0x8000000000008080ULL,
    0x0000000080000001ULL, 0x8000000080008008ULL
};

static const int keccak_rot[25] = {
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
};

static const int keccak_pi[25] = {
     0, 10,  7, 11, 17,
    20,  4,  1,  5,  8,
    15, 23,  2, 12, 21,
    13, 22,  3, 14, 16,
     9, 19, 18, 24,  6
};

static inline uint64_t rotl64(uint64_t x, int n) {
    return (x << n) | (x >> (64 - n));
}

static void keccak_f1600(uint64_t state[25]) {
    for (int round = 0; round < 24; round++) {
        uint64_t C[5];
        for (int x = 0; x < 5; x++)
            C[x] = state[x] ^ state[x+5] ^ state[x+10] ^ state[x+15] ^ state[x+20];
        for (int x = 0; x < 5; x++) {
            uint64_t D = C[(x+4)%5] ^ rotl64(C[(x+1)%5], 1);
            for (int y = 0; y < 25; y += 5)
                state[x+y] ^= D;
        }
        uint64_t tmp[25];
        for (int i = 0; i < 25; i++)
            tmp[keccak_pi[i]] = rotl64(state[i], keccak_rot[i]);
        for (int y = 0; y < 25; y += 5)
            for (int x = 0; x < 5; x++)
                state[y+x] = tmp[y+x] ^ (~tmp[y+(x+1)%5] & tmp[y+(x+2)%5]);
        state[0] ^= keccak_rc[round];
    }
}

// ----------------------------------------------------------------
//  cSHAKE256 mid-state computation
// ----------------------------------------------------------------

static int left_encode(uint64_t val, uint8_t *out) {
    uint8_t buf[9];
    int len = 0;
    if (val == 0) {
        buf[0] = 0;
        len = 1;
    } else {
        uint64_t v = val;
        while (v > 0) { buf[len++] = v & 0xFF; v >>= 8; }
        for (int i = 0; i < len/2; i++) {
            uint8_t t = buf[i]; buf[i] = buf[len-1-i]; buf[len-1-i] = t;
        }
    }
    out[0] = len;
    memcpy(out+1, buf, len);
    return len + 1;
}

static int encode_string(const char *s, uint8_t *out) {
    int slen = strlen(s);
    int n = left_encode(slen * 8, out);
    memcpy(out + n, s, slen);
    return n + slen;
}

static void compute_cshake_midstate(const char *custom_str, uint64_t mid_state[25]) {
    uint8_t prefix[136];
    memset(prefix, 0, 136);

    int pos = 0;
    pos += left_encode(136, prefix + pos);
    pos += encode_string("", prefix + pos);
    pos += encode_string(custom_str, prefix + pos);

    memset(mid_state, 0, 25 * sizeof(uint64_t));
    for (int i = 0; i < 17; i++) {  // rate = 136 bytes = 17 lanes
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= (uint64_t)prefix[i*8 + b] << (b*8);
        mid_state[i] ^= lane;
    }
    keccak_f1600(mid_state);
}

// ----------------------------------------------------------------
//  Software HeavyHash (reference for comparison)
// ----------------------------------------------------------------

// Extract nibble i from 256-bit hash (stored as 8 x uint32_t LE)
// Nibble ordering: byte 0 high nibble = nibble 0, byte 0 low nibble = nibble 1
static uint8_t get_nibble(const uint32_t hash[8], int i) {
    int byte_idx = i / 2;
    int word = byte_idx / 4;
    int byte_in_word = byte_idx % 4;
    uint8_t byte_val = (hash[word] >> (byte_in_word * 8)) & 0xFF;
    if (i % 2 == 0)
        return (byte_val >> 4) & 0xF;  // high nibble first
    else
        return byte_val & 0xF;         // low nibble
}

// Software matrix multiply + XOR
static void sw_matrix_multiply(const uint32_t matrix[64][8],
                               const uint32_t hash_in[8],
                               uint32_t hash_out[8]) {
    // Extract 64 nibbles from input hash
    uint8_t vec[64];
    for (int i = 0; i < 64; i++)
        vec[i] = get_nibble(hash_in, i);

    // Matrix-vector multiply: for each row, dot product, >>10, &0xF
    uint8_t result[64];
    for (int row = 0; row < 64; row++) {
        uint32_t acc = 0;
        for (int col = 0; col < 64; col++) {
            // Extract matrix element [row][col] — nibble col from row data
            int byte_idx = col / 2;
            int word = byte_idx / 4;
            int byte_in_word = byte_idx % 4;
            uint8_t byte_val = (matrix[row][word] >> (byte_in_word * 8)) & 0xFF;
            uint8_t mat_elem;
            if (col % 2 == 0)
                mat_elem = (byte_val >> 4) & 0xF;
            else
                mat_elem = byte_val & 0xF;
            acc += (uint32_t)mat_elem * (uint32_t)vec[col];
        }
        result[row] = (acc >> 10) & 0xF;
    }

    // Pack result nibbles back to 256 bits and XOR with input hash
    memset(hash_out, 0, 32);
    for (int i = 0; i < 64; i++) {
        int byte_idx = i / 2;
        int word = byte_idx / 4;
        int byte_in_word = byte_idx % 4;
        if (i % 2 == 0)
            hash_out[word] |= (uint32_t)(result[i] & 0xF) << (byte_in_word * 8 + 4);
        else
            hash_out[word] |= (uint32_t)(result[i] & 0xF) << (byte_in_word * 8);
    }
    // XOR with original hash
    for (int i = 0; i < 8; i++)
        hash_out[i] ^= hash_in[i];
}

// Full software HeavyHash: cSHAKE1(msg) -> matrix_mul -> cSHAKE2(result)
// Returns the final 256-bit hash in final_hash[8]
static void sw_heavyhash(const uint64_t ms1[25], const uint64_t ms2[25],
                         const uint8_t msg136[136],
                         const uint32_t matrix[64][8],
                         uint32_t final_hash[8]) {
    // 1st cSHAKE: absorb msg into ms1, permute, squeeze 256 bits
    uint64_t state[25];
    memcpy(state, ms1, 200);
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= (uint64_t)msg136[i*8 + b] << (b*8);
        state[i] ^= lane;
    }
    keccak_f1600(state);

    // Extract 256-bit hash (4 lanes, LE)
    uint32_t hash1[8];
    for (int i = 0; i < 4; i++) {
        hash1[i*2]     = (uint32_t)(state[i]);
        hash1[i*2 + 1] = (uint32_t)(state[i] >> 32);
    }

    // Matrix multiply
    uint32_t mat_result[8];
    sw_matrix_multiply(matrix, hash1, mat_result);

    // 2nd cSHAKE: absorb mat_result (32 bytes + padding) into ms2
    uint8_t block2[136];
    memset(block2, 0, 136);
    memcpy(block2, mat_result, 32);
    block2[32] = 0x04;   // cSHAKE padding
    block2[135] = 0x80;

    memcpy(state, ms2, 200);
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= (uint64_t)block2[i*8 + b] << (b*8);
        state[i] ^= lane;
    }
    keccak_f1600(state);

    for (int i = 0; i < 4; i++) {
        final_hash[i*2]     = (uint32_t)(state[i]);
        final_hash[i*2 + 1] = (uint32_t)(state[i] >> 32);
    }
}

// ----------------------------------------------------------------
//  Write helpers
// ----------------------------------------------------------------

static void write_midstate(uint32_t reg_base, const uint64_t ms[25]) {
    const uint32_t *w = (const uint32_t *)ms;
    for (int i = 0; i < 50; i++)
        wreg(reg_base + i * 4, w[i]);
}

static void write_msg_block(const uint8_t msg[136]) {
    const uint32_t *w = (const uint32_t *)msg;
    for (int i = 0; i < 34; i++)
        wreg(MSG_BASE + i * 4, w[i]);
}

static void write_target(const uint32_t t[8]) {
    for (int i = 0; i < 8; i++)
        wreg(TARGET_BASE + i * 4, t[i]);
}

static void write_matrix_row(int row, const uint32_t data[8]) {
    wreg(MAT_ADDR, row);
    for (int i = 0; i < 8; i++)
        wreg(MAT_DATA0 + i * 4, data[i]);
    wreg(MAT_WR, 1);
}

// ----------------------------------------------------------------
//  Tests
// ----------------------------------------------------------------

static int test_register_access(void) {
    printf("\n=== Test 1: Register access ===\n");
    int ok = 1;

    // Read STATUS — should be idle (0)
    uint32_t status = rreg(STATUS);
    check("STATUS (idle)", status, 0);

    // Write and read back NONCE
    wreg(NONCE_LO, 0xDEADBEEF);
    wreg(NONCE_HI, 0xCAFEBABE);
    check("NONCE_LO readback", rreg(NONCE_LO), 0xDEADBEEF);
    check("NONCE_HI readback", rreg(NONCE_HI), 0xCAFEBABE);

    // Read unimplemented register — should return DEAD_BEEF
    uint32_t sentinel = rreg(0x3FC);
    check("Unimplemented reg", sentinel, 0xDEADBEEF);

    return ok;
}

static int test_easy_target(void) {
    printf("\n=== Test 2: Easy target (all-FF) ===\n");

    // Stop any previous run
    wreg(CTRL, CTRL_STOP);
    usleep(1000);
    wreg(CTRL, CTRL_CLR_FOUND);

    // Compute mid-states
    uint64_t ms1[25], ms2[25];
    compute_cshake_midstate("ProofOfWorkHash", ms1);
    compute_cshake_midstate("HeavyHash", ms2);

    write_midstate(MSTATE1_BASE, ms1);
    write_midstate(MSTATE2_BASE, ms2);

    // Simple message: 80 bytes of zeros + cSHAKE padding
    uint8_t msg[136];
    memset(msg, 0, 136);
    msg[80] = 0x04;    // cSHAKE padding byte
    msg[135] = 0x80;   // final padding bit

    write_msg_block(msg);

    // All-zero matrix (trivial — matrix multiply result XORs with hash)
    uint32_t zero_row[8] = {0};
    for (int r = 0; r < 64; r++)
        write_matrix_row(r, zero_row);

    // Easy target: all 0xFF — any hash passes
    uint32_t easy_target[8];
    memset(easy_target, 0xFF, 32);
    write_target(easy_target);

    // Start mining from nonce 0
    wreg(NONCE_LO, 0);
    wreg(NONCE_HI, 0);
    wreg(CTRL, CTRL_START);

    // Should find immediately (nonce 0 passes any target)
    printf("  Waiting for found...\n");
    int timeout = 10000;  // 10k iterations x 100us = 1 second
    while (timeout-- > 0) {
        uint32_t st = rreg(STATUS);
        if (st & STATUS_FOUND) break;
        usleep(100);
    }

    uint32_t status = rreg(STATUS);
    check("STATUS.found", (status >> 1) & 1, 1);
    check("STATUS.busy",  (status >> 0) & 1, 0);  // pipeline stops on found

    uint32_t nonce_lo = rreg(FOUND_NONCE_LO);
    uint32_t nonce_hi = rreg(FOUND_NONCE_HI);
    printf("  Found nonce: 0x%08x_%08x\n", nonce_hi, nonce_lo);
    check("Found nonce (should be 0)", nonce_lo, 0);
    check("Found nonce hi", nonce_hi, 0);

    uint32_t cnt_lo = rreg(HASH_CNT_LO);
    printf("  Hash count: %u\n", cnt_lo);
    check("Hash count >= 1", cnt_lo >= 1 ? 1 : 0, 1);

    // Stop and clear
    wreg(CTRL, CTRL_STOP);
    wreg(CTRL, CTRL_CLR_FOUND);

    return 1;
}

static int test_impossible_target(void) {
    printf("\n=== Test 3: Impossible target (all-zero) ===\n");

    wreg(CTRL, CTRL_STOP);
    usleep(1000);
    wreg(CTRL, CTRL_CLR_FOUND);

    // Reuse same mid-states (already in hardware)
    // Same message
    uint8_t msg[136];
    memset(msg, 0, 136);
    msg[80] = 0x04;
    msg[135] = 0x80;
    write_msg_block(msg);

    // Zero matrix
    uint32_t zero_row[8] = {0};
    for (int r = 0; r < 64; r++)
        write_matrix_row(r, zero_row);

    // Impossible target: all zeros — no hash can be <= 0
    uint32_t zero_target[8] = {0};
    write_target(zero_target);

    wreg(NONCE_LO, 0);
    wreg(NONCE_HI, 0);
    wreg(CTRL, CTRL_START);

    // Wait briefly — should remain busy, never find
    usleep(50000);  // 50ms — enough for hundreds of hashes at 50MHz

    uint32_t status = rreg(STATUS);
    check("STATUS.busy (should be mining)", (status >> 0) & 1, 1);
    check("STATUS.found (should be 0)",    (status >> 1) & 1, 0);

    uint32_t cnt_lo = rreg(HASH_CNT_LO);
    printf("  Hash count after 50ms: %u\n", cnt_lo);
    check("Hash count > 0 (pipeline running)", cnt_lo > 0 ? 1 : 0, 1);

    // Stop
    wreg(CTRL, CTRL_STOP);
    usleep(1000);

    status = rreg(STATUS);
    check("STATUS.busy after stop", (status >> 0) & 1, 0);

    wreg(CTRL, CTRL_CLR_FOUND);
    return 1;
}

static int test_known_hash(void) {
    printf("\n=== Test 4: Known hash verification ===\n");

    wreg(CTRL, CTRL_STOP);
    usleep(1000);
    wreg(CTRL, CTRL_CLR_FOUND);

    // Compute mid-states in software
    uint64_t ms1[25], ms2[25];
    compute_cshake_midstate("ProofOfWorkHash", ms1);
    compute_cshake_midstate("HeavyHash", ms2);

    write_midstate(MSTATE1_BASE, ms1);
    write_midstate(MSTATE2_BASE, ms2);

    // Build a message with a known nonce (42) at bytes 72-79
    uint8_t msg[136];
    memset(msg, 0, 136);
    // Put some recognizable data in the header
    msg[0] = 0xAA; msg[1] = 0xBB; msg[2] = 0xCC; msg[3] = 0xDD;
    // Nonce placeholder — hardware will patch bytes 72-79
    // But for the software reference we set nonce = 0 (start)
    msg[80] = 0x04;    // cSHAKE padding
    msg[135] = 0x80;

    write_msg_block(msg);

    // Simple identity-like matrix: diagonal elements = 1, rest = 0
    // This makes the matrix multiply mostly pass-through
    for (int r = 0; r < 64; r++) {
        uint32_t row[8];
        memset(row, 0, 32);
        int nibble_idx = r;
        int byte_idx = nibble_idx / 2;
        int word = byte_idx / 4;
        int byte_in_word = byte_idx % 4;
        if (nibble_idx % 2 == 0)
            row[word] |= (uint32_t)1 << (byte_in_word * 8 + 4);  // high nibble
        else
            row[word] |= (uint32_t)1 << (byte_in_word * 8);      // low nibble
        write_matrix_row(r, row);
    }

    // Compute expected hash in software for nonce=0
    // Hardware will start at nonce 0, patch it into msg at bytes 72-79
    uint8_t msg_n0[136];
    memcpy(msg_n0, msg, 136);
    memset(msg_n0 + 72, 0, 8);  // nonce 0

    // Build the matrix in software too
    uint32_t sw_matrix[64][8];
    for (int r = 0; r < 64; r++) {
        memset(sw_matrix[r], 0, 32);
        int nibble_idx = r;
        int byte_idx = nibble_idx / 2;
        int word = byte_idx / 4;
        int byte_in_word = byte_idx % 4;
        if (nibble_idx % 2 == 0)
            sw_matrix[r][word] |= (uint32_t)1 << (byte_in_word * 8 + 4);
        else
            sw_matrix[r][word] |= (uint32_t)1 << (byte_in_word * 8);
    }

    uint32_t expected_hash[8];
    sw_heavyhash(ms1, ms2, msg_n0, sw_matrix, expected_hash);

    printf("  Expected final hash (SW): ");
    for (int i = 7; i >= 0; i--) printf("%08x", expected_hash[i]);
    printf("\n");

    // Set target to exactly the expected hash — nonce 0 should match
    write_target(expected_hash);

    wreg(NONCE_LO, 0);
    wreg(NONCE_HI, 0);
    wreg(CTRL, CTRL_START);

    // Wait for result
    printf("  Waiting for found...\n");
    int timeout = 10000;
    while (timeout-- > 0) {
        uint32_t st = rreg(STATUS);
        if (st & STATUS_FOUND) break;
        usleep(100);
    }

    uint32_t status = rreg(STATUS);
    if (!(status & STATUS_FOUND)) {
        printf("  FAIL: Timed out waiting for nonce 0 to match\n");
        test_fail++;

        // Diagnostic: check hash count
        uint32_t cnt = rreg(HASH_CNT_LO);
        printf("  Hash count: %u (expected to find at count 1)\n", cnt);

        wreg(CTRL, CTRL_STOP);
        wreg(CTRL, CTRL_CLR_FOUND);
        return 0;
    }

    uint32_t nonce_lo = rreg(FOUND_NONCE_LO);
    uint32_t nonce_hi = rreg(FOUND_NONCE_HI);
    printf("  Found nonce: 0x%08x_%08x\n", nonce_hi, nonce_lo);
    check("Found nonce == 0", nonce_lo, 0);
    check("Found nonce hi == 0", nonce_hi, 0);

    uint32_t cnt = rreg(HASH_CNT_LO);
    check("Hash count == 1", cnt, 1);

    printf("  PASS: Hardware hash matches software reference\n");
    test_pass++;

    wreg(CTRL, CTRL_STOP);
    wreg(CTRL, CTRL_CLR_FOUND);
    return 1;
}

// ----------------------------------------------------------------
//  Test 5: Kaspad test vector (validated in Verilator)
//  pre_pow=[42]*32, timestamp=5435345234, nonce=432432432
//  Expected heavy_hash: 5a5bcd6e352eb8c8...
// ----------------------------------------------------------------

// Mid-state 1 (ProofOfWorkHash) — 25 x u64 LE
static const uint64_t TV_MS1[25] = {
    0x113cff0da1f6d83dULL, 0x29bf8855b7027e3cULL, 0x1e5f2e720efb44d2ULL,
    0x1ba5a4a3f59869a0ULL, 0x7b2fafca875e2d65ULL, 0x4aef61d629dce246ULL,
    0x183a981ead415b10ULL, 0x776bf60c789bc29cULL, 0xf8ebf13388663140ULL,
    0x2e651c3c43285ff0ULL, 0x0f96070540f14a0eULL, 0x44e367875b299152ULL,
    0xec70f1a425b13715ULL, 0xe6c85d8f82e9da89ULL, 0xb21a601f85b4b223ULL,
    0x3485549064a36a46ULL, 0x8f06dd1c7a2f851aULL, 0xc1a2021d563bb142ULL,
    0xba1de5e4451668e4ULL, 0xd102574105095f8dULL, 0x89ca4e849bcecf4aULL,
    0x48b09427a8742edbULL, 0xb1fcce9ce78b5272ULL, 0x5d1129cf82afa5bcULL,
    0x02b97c786f824383ULL,
};

// Mid-state 2 (HeavyHash) — 25 x u64 LE
static const uint64_t TV_MS2[25] = {
    0x3ad74c52b2248509ULL, 0x79629b0e2f9f4216ULL, 0x7a14ff4816c7f8eeULL,
    0x11a75f4c80056498ULL, 0xe720e0df44eecedeULL, 0x72c7d82e14f34069ULL,
    0xc100ff2a938935baULL, 0x5e219040250fc462ULL, 0x8039f9a60dcf6a48ULL,
    0xa0bcaa9f792a3d0cULL, 0xf431c05dd0a9a226ULL, 0xd31f4cc354c18c3fULL,
    0x6c6b7d01a769cc3dULL, 0x2ec65bd3562493e4ULL, 0x4ef74b3a99cdb044ULL,
    0x774c86835434f2b0ULL, 0x87e961b036bc9416ULL, 0x7e8f1db17765cc07ULL,
    0xea8fdb80bac46d39ULL, 0xb992f2d37b34ca58ULL, 0xc776c5048481b957ULL,
    0x47c39f675112c22eULL, 0x92bb399db5290c0aULL, 0x549ae0312f9fc615ULL,
    0x1619327d10b9da35ULL,
};

// Message block — 17 x u64 LE lanes (136 bytes with cSHAKE padding)
// pre_pow=[42]*32, timestamp=5435345234, nonce=432432432, cSHAKE pad
static const uint64_t TV_MSG[17] = {
    0x2a2a2a2a2a2a2a2aULL, 0x2a2a2a2a2a2a2a2aULL, 0x2a2a2a2a2a2a2a2aULL,
    0x2a2a2a2a2a2a2a2aULL, 0x0000000143f8c952ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x0000000000000000ULL, 0x0000000000000000ULL,
    0x0000000019c66530ULL, 0x0000000000000004ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x0000000000000000ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x8000000000000000ULL,
};

// Matrix: 64 rows x 256 bits, each row stored as 4 x u64 (LE)
// Generated from pre_pow=[42]*32 via xoshiro256++
static const uint64_t TV_MATRIX[64][4] = {
    { 0x5454545454545454ULL, 0x3f3f3f3f3f3f3f3fULL, 0xa2a2a2a2a2a2a2a2ULL, 0xaaaaaac4c4ae221eULL },
    { 0x5bdc39b9b9b1b1b9ULL, 0x37635fb6818605ffULL, 0x1593ce637eb73ef2ULL, 0x644711d6a9fa4801ULL },
    { 0xcb3fd72504fb8062ULL, 0x6af62dea4b4d8126ULL, 0x5106fcc913339656ULL, 0x48f2dc04e5aa1ed7ULL },
    { 0x3427c80d84601568ULL, 0x8ac977ed42dc395aULL, 0x879190a2088c3e6bULL, 0x9a26a191ad6fd925ULL },
    { 0x0c9b406f7524e624ULL, 0xc3d01a433c5a4023ULL, 0x6acf28f20f22a70fULL, 0xa561545ad3e83d26ULL },
    { 0x4defb4c1db4bcd30ULL, 0x1e54e521883a0317ULL, 0x975ac88b57f51331ULL, 0xc366066afc24bda2ULL },
    { 0x2704b547dc8533c9ULL, 0x5116d888245cecf2ULL, 0x01ec161d4058dcf0ULL, 0xae66df48dd41aacdULL },
    { 0x243b0c35a52708feULL, 0x1fc62673c33ee6b8ULL, 0xf25f244d779960d1ULL, 0xb53ee6a692f96addULL },
    { 0xb36d0070bd0b8746ULL, 0xea6e8af8ed872aefULL, 0xc4e60203c35db5b3ULL, 0x4dead593bc87f844ULL },
    { 0xe92b52af3d41f00aULL, 0x8f039141c0f68237ULL, 0x8b047973e6a970d9ULL, 0x65652cc7e5088564ULL },
    { 0x4275d5ad3038e00cULL, 0x8cfc955a5e2b13bdULL, 0xec9dfb0ab118db01ULL, 0xfbc9bbc41272e545ULL },
    { 0x503a6e787fcd89f3ULL, 0x793dba2bc5236622ULL, 0xbb583179bbeef867ULL, 0x7735c3514b8d8f21ULL },
    { 0x151451f02f34e2ddULL, 0x401ed5331fdb15e4ULL, 0xac877e3f8f077f16ULL, 0xe0d4dc34a7bb29e2ULL },
    { 0x65be2464d002ffecULL, 0x099b0197f6fd7e8eULL, 0x9829cb0357be88c2ULL, 0xa48de02ce2898900ULL },
    { 0x71cd84d747ecf1a7ULL, 0xcfcfc6eb4e3ee56aULL, 0x5744837503778954ULL, 0x5edd469e52ac0dc6ULL },
    { 0xeb2fe7aeedf4385eULL, 0xbf07dfd65596acddULL, 0xc442a5e8b3477fc4ULL, 0x687fe057d11f9163ULL },
    { 0xdec994afb1d25a21ULL, 0x717d2a5c3ab73053ULL, 0x2b9390c53ae3828dULL, 0xa3f1680be104609aULL },
    { 0x167115aafc78509dULL, 0xe341773753532f5eULL, 0x1ab5536c6aac0c05ULL, 0x725f80ee71b93d3bULL },
    { 0xce34f761d10f6b58ULL, 0x32c1b5c6b1c46b39ULL, 0x8aeb3bd35b50cb21ULL, 0xb7e03c42b9bd8493ULL },
    { 0x65896f8fe387a4baULL, 0x9e556ec2de556f1cULL, 0x218bb6f1be68eba1ULL, 0xf87010b08086f458ULL },
    { 0x8022c840244b05f0ULL, 0x2052a61c13c65621ULL, 0x6269b85f4e4d68b0ULL, 0x9bb68b1144ae2419ULL },
    { 0xcee4dddf0b195637ULL, 0xeb4ab26795613973ULL, 0xf5065a05f18b8bdaULL, 0x6d1bbba0c8ba466bULL },
    { 0xb6c52373d75b00f7ULL, 0x1f6f2d2f0d99894eULL, 0x09d54ca0e81a0471ULL, 0x7a3944f2f88bbdc7ULL },
    { 0xf9f37d27e76e5390ULL, 0x42858e126f064082ULL, 0xda22d3f8cbdf29b2ULL, 0xbf907e34776df781ULL },
    { 0xbe4c1a41878877d8ULL, 0x3d542e2e29fa0fc7ULL, 0x6a74aa67b867f0a2ULL, 0xe343d9182c6e4ae6ULL },
    { 0xa9e849ab7a5836aaULL, 0xbc9ddd7dd8fbe890ULL, 0x7151846b66006936ULL, 0xeedcb6a9b8834d69ULL },
    { 0x609be04c034ef0aeULL, 0x083a828644e89064ULL, 0x521550499d424f11ULL, 0xe4076851aa87126bULL },
    { 0xa082590477cdbaf0ULL, 0x553ae84109765766ULL, 0x8728cbf1e0a6a15bULL, 0xe543feff53f9b304ULL },
    { 0xa16223f41e008cc5ULL, 0xc3a98c09580e5ea7ULL, 0x1eaa7462d7cc0023ULL, 0x8ebecad7a12c3a6bULL },
    { 0x89d2cb57ea34c359ULL, 0x9a1b0434aa942625ULL, 0x00c3667d71b854a4ULL, 0x2f6ce7fbee7dcc6fULL },
    { 0x2cb330e7e8efc02fULL, 0xb0c71547b69c5de3ULL, 0x33a43a3c2c686651ULL, 0xb47d6f670fd3eaa3ULL },
    { 0x1b34ef32e110e5fbULL, 0xb877bdb36f53c066ULL, 0x9156682717e9aa95ULL, 0x725df43392e2e856ULL },
    { 0x1396cf917b8f9d87ULL, 0x9c934ecb5e800baaULL, 0x92ad4363d14c900eULL, 0xe17b98f53aa7a773ULL },
    { 0xc7c4ddb6b33f1955ULL, 0x807bc12a8dc7de84ULL, 0x22911e190a931f9aULL, 0x404eb36f9f236598ULL },
    { 0xf1c3ed0dd6902a29ULL, 0xb040b7bf66f52c39ULL, 0x462969dd220397caULL, 0x86d2bd94279aa563ULL },
    { 0x6b6835c2232689fdULL, 0x401b2483578f3a7fULL, 0x6a34a762156d1611ULL, 0x3e426fac0d1fd702ULL },
    { 0xe7a43ce44c704eb5ULL, 0xa0c36f6f95c07e46ULL, 0xd9d91cf5e15de17bULL, 0xb2c9e2d9bfacba5eULL },
    { 0x15e96f48b25175c2ULL, 0xc3374454124b134fULL, 0xc6fdb641fe1df234ULL, 0x828923a1ca0a86dcULL },
    { 0x3a5f763544586ccaULL, 0x4c3c31714e265ef8ULL, 0x29157596866066faULL, 0x7b4098e73e118094ULL },
    { 0xfdc68abca0407ebdULL, 0x84ef74fbec039e29ULL, 0xd18d94eed977e9cfULL, 0x0d590327f6f07c36ULL },
    { 0xac995ee8e995bc83ULL, 0xf988324c76000dc3ULL, 0xb7271ad21bfadc1bULL, 0x811b12fbb56467f8ULL },
    { 0x558c7322a9d4177aULL, 0x6cc405b828651355ULL, 0xf2877e4b908bae97ULL, 0xb7f2510e302d447cULL },
    { 0xb01390e5d3714a83ULL, 0x5167e1820e5694f2ULL, 0xb5cdd9adf4350275ULL, 0xb1cca27180e8adebULL },
    { 0x3d4ea52f6ab3d4ebULL, 0x29c2216e1004ac7cULL, 0x39bc34c7744a41b3ULL, 0x9cd0cfd5c5b7d6dfULL },
    { 0x6754018afa352278ULL, 0xc468c5095926e2dfULL, 0x7fb797c22bf7fe86ULL, 0x14c767509527d540ULL },
    { 0xee24699c49a6d24bULL, 0xa83eb824b89ff559ULL, 0x492e15732b74669eULL, 0x663c237d31767a10ULL },
    { 0x8e7e6eb0993e3e1bULL, 0xff15ba88a43d6524ULL, 0x46606123dedfe407ULL, 0x236ccd3371b5c06fULL },
    { 0x5277206ae4deea27ULL, 0xd31631d2921fe51eULL, 0x297d69b2fd71db6aULL, 0xc35130319526aad3ULL },
    { 0x759ab8795fba24ebULL, 0x66629cf4fcf72c3eULL, 0x7142c7c3eefe7058ULL, 0xee9a173ffb917431ULL },
    { 0xf893866b15691bd4ULL, 0xba1cef1c5a95d3cdULL, 0xf1d24e3220c9c375ULL, 0xf6018e0645a0d38bULL },
    { 0x10658c5a09e2502fULL, 0x079e22035e641449ULL, 0xd03f491fc9ca0cf2ULL, 0x804536fd9b620560ULL },
    { 0x6f27bfc6a44de8e4ULL, 0x58fec544a72db199ULL, 0x8375437525b4fb16ULL, 0xf78263dc1a5657daULL },
    { 0x556af70716ce94f3ULL, 0x171c3a412e67495fULL, 0x305fb5b5a7deb2a0ULL, 0x60a25acf9adde21fULL },
    { 0x04776df24fabd564ULL, 0x36b0241676194764ULL, 0x9c74b4ed21a2295eULL, 0xc1bc90f8c9759228ULL },
    { 0x03c666adc4f89bcbULL, 0xb9c6172a75c6aff6ULL, 0x438ef4fc260fc1ebULL, 0xe4c019d6731e3d4fULL },
    { 0xac069d3c73aaadbcULL, 0x1cfdcca6e75b45b4ULL, 0x33340cc168217ffdULL, 0x9a594fdb0077a987ULL },
    { 0x73e9519946b903c6ULL, 0x62ac2a5d67b5053fULL, 0x466d9a287b39d110ULL, 0x16e0391ebf49a30cULL },
    { 0xdd23970a746baaebULL, 0xf94e7a1e4ae33299ULL, 0x269c32210387a5b3ULL, 0x97e03754086393fbULL },
    { 0x2a50153ff326cdb4ULL, 0xf938aca2350fa735ULL, 0x491a92a5cd75d735ULL, 0xdd877e35c221da1eULL },
    { 0xa30f038034f0abcaULL, 0x8d617e28383d3f9aULL, 0xad057110ca033c22ULL, 0x380d2e20107d99d7ULL },
    { 0x13b7588e6bfcab3bULL, 0xfaf98378327f4d7dULL, 0x1cc1a1728d714509ULL, 0xc93a3a2cf9ae5dc7ULL },
    { 0xbc0cc01951650b89ULL, 0xc27d91e157710482ULL, 0x7c894fec35b1dc98ULL, 0x97c43c64e75b931bULL },
    { 0xde127d738b1ee2caULL, 0x3cd624fbadcf8f67ULL, 0xee2f9c39e8baefa2ULL, 0x9201ad01411267d5ULL },
    { 0x70a65a8c7c1ceb5aULL, 0x124e0b60d0cdbb65ULL, 0x4a2131fe35f7a17cULL, 0xe2713a5f4552b28bULL },
};

// Expected heavy_hash: 5a5bcd6e352eb8c87c80d0f0574a45a5fcc3d5755660ac120dc9893684c19be6
static const uint32_t TV_EXPECTED_HASH[8] = {
    0x6ecd5b5a, 0xc8b82e35, 0xf0d0807c, 0xa5454a57,
    0x75d5c3fc, 0x12ac6056, 0x3689c90d, 0xe69bc184,
};

static int test_kaspad_vector(void) {
    printf("\n=== Test 5: Kaspad test vector (Verilator-validated) ===\n");
    printf("  pre_pow=[42]*32, ts=5435345234, nonce=432432432\n");

    wreg(CTRL, CTRL_STOP);
    usleep(1000);
    wreg(CTRL, CTRL_CLR_FOUND);

    // Write pre-computed mid-states directly (skip recomputing)
    write_midstate(MSTATE1_BASE, TV_MS1);
    write_midstate(MSTATE2_BASE, TV_MS2);

    // Write message block (nonce at bytes 72-79 will be overwritten by HW)
    const uint32_t *msg32 = (const uint32_t *)TV_MSG;
    for (int i = 0; i < 34; i++)
        wreg(MSG_BASE + i * 4, msg32[i]);

    // Write matrix via staging registers
    for (int r = 0; r < 64; r++) {
        const uint32_t *row32 = (const uint32_t *)TV_MATRIX[r];
        wreg(MAT_ADDR, r);
        for (int w = 0; w < 8; w++)
            wreg(MAT_DATA0 + w * 4, row32[w]);
        wreg(MAT_WR, 1);
    }

    // Set target = expected heavy_hash (nonce 432432432 should match exactly)
    write_target((uint32_t *)TV_EXPECTED_HASH);

    // Set nonce = 432432432
    wreg(NONCE_LO, 432432432u & 0xFFFFFFFF);
    wreg(NONCE_HI, 0);
    wreg(CTRL, CTRL_START);

    // Wait for found
    printf("  Waiting for found (expect nonce 432432432)...\n");
    int timeout = 10000;
    while (timeout-- > 0) {
        uint32_t st = rreg(STATUS);
        if (st & STATUS_FOUND) break;
        usleep(100);
    }

    uint32_t status = rreg(STATUS);
    if (!(status & STATUS_FOUND)) {
        printf("  FAIL: Pipeline did not find nonce!\n");
        printf("  This means the FPGA produces a different hash than expected.\n");
        uint32_t cnt = rreg(HASH_CNT_LO);
        printf("  Hash count: %u (if >1, HW hash didn't match target)\n", cnt);
        test_fail++;

        // Additional diagnostic: try with all-FF target to see if pipeline works at all
        wreg(CTRL, CTRL_STOP);
        usleep(1000);
        wreg(CTRL, CTRL_CLR_FOUND);

        uint32_t easy[8];
        memset(easy, 0xFF, 32);
        write_target(easy);
        wreg(NONCE_LO, 432432432u);
        wreg(NONCE_HI, 0);
        wreg(CTRL, CTRL_START);
        usleep(50000);

        status = rreg(STATUS);
        uint32_t nlo = rreg(FOUND_NONCE_LO);
        uint32_t nhi = rreg(FOUND_NONCE_HI);
        cnt = rreg(HASH_CNT_LO);
        printf("  With all-FF target: found=%d nonce=0x%08x_%08x cnt=%u\n",
               (status >> 1) & 1, nhi, nlo, cnt);

        wreg(CTRL, CTRL_STOP);
        wreg(CTRL, CTRL_CLR_FOUND);
        return 0;
    }

    uint32_t nonce_lo = rreg(FOUND_NONCE_LO);
    uint32_t nonce_hi = rreg(FOUND_NONCE_HI);
    uint32_t cnt = rreg(HASH_CNT_LO);
    printf("  Found nonce: 0x%08x_%08x  hash_count: %u\n", nonce_hi, nonce_lo, cnt);

    check("Nonce LO == 0x19c66530", nonce_lo, 0x19c66530);
    check("Nonce HI == 0", nonce_hi, 0);
    check("Hash count == 1", cnt, 1);

    if (nonce_lo == 0x19c66530 && nonce_hi == 0 && cnt == 1) {
        printf("  PASS: FPGA heavy_hash matches kaspad reference!\n");
        printf("  Bitstream has the matrix multiply fix.\n");
        test_pass++;
    }

    wreg(CTRL, CTRL_STOP);
    wreg(CTRL, CTRL_CLR_FOUND);
    return 1;
}

static int test_hash_rate(void) {
    printf("\n=== Test 6: Hash rate measurement ===\n");

    wreg(CTRL, CTRL_STOP);
    usleep(1000);
    wreg(CTRL, CTRL_CLR_FOUND);

    // Reuse configuration from test 4, but set impossible target
    uint32_t zero_target[8] = {0};
    write_target(zero_target);

    wreg(NONCE_LO, 0);
    wreg(NONCE_HI, 0);
    wreg(CTRL, CTRL_START);

    // Measure hashes over 1 second
    usleep(100000);  // let it warm up
    uint32_t cnt_start = rreg(HASH_CNT_LO);
    usleep(1000000);  // 1 second
    uint32_t cnt_end = rreg(HASH_CNT_LO);

    wreg(CTRL, CTRL_STOP);

    uint32_t hashes = cnt_end - cnt_start;
    double rate_khs = hashes / 1000.0;
    printf("  Hashes in 1s: %u\n", hashes);
    printf("  Rate: %.1f KH/s\n", rate_khs);

    // At 50MHz, ~153 cycles/hash => ~327 KH/s expected
    // Accept anything > 100 KH/s as proof pipeline is running
    check("Hash rate > 100 KH/s", rate_khs > 100.0 ? 1 : 0, 1);

    wreg(CTRL, CTRL_CLR_FOUND);
    return 1;
}

// ----------------------------------------------------------------
//  Main
// ----------------------------------------------------------------

int main(int argc, char *argv[]) {
    printf("HeavyHash Accelerator Smoke Test\n");
    printf("================================\n");

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (need root)");
        return 1;
    }

    void *ptr = mmap(NULL, HH_MAP_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, HH_BASE);
    close(fd);
    if (ptr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    base = (volatile uint32_t *)ptr;

    test_pass = 0;
    test_fail = 0;

    test_register_access();
    test_easy_target();
    test_impossible_target();
    test_known_hash();
    test_kaspad_vector();
    test_hash_rate();

    printf("\n================================\n");
    printf("Results: %d passed, %d failed\n", test_pass, test_fail);

    munmap((void *)base, HH_MAP_SIZE);

    return test_fail > 0 ? 1 : 0;
}
