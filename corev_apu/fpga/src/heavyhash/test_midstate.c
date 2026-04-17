// Quick test to verify C mid-state computation matches Python
#include <stdio.h>
#include <stdint.h>
#include <string.h>

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
     0,  1, 62, 28, 27,  36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,  41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
};

static const int keccak_pi[25] = {
     0, 10, 20,  5, 15,  16,  1, 11, 21,  6,
     7, 17,  2, 12, 22,  23,  8, 18,  3, 13,
    14, 24,  9, 19,  4
};

static inline uint64_t rotl64(uint64_t x, int n) {
    if (n == 0) return x;
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
    memcpy(out + 1, buf, len);
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

    printf("  prefix bytes (%d used): ", pos);
    for (int i = 0; i < pos; i++) printf("%02x", prefix[i]);
    printf("\n");

    memset(mid_state, 0, 200);
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= (uint64_t)prefix[i*8 + b] << (b*8);
        mid_state[i] ^= lane;
    }
    keccak_f1600(mid_state);
}

int main() {
    uint64_t ms1[25], ms2[25];

    // Expected from Python
    uint64_t expected_ms1[25] = {
        0x113cff0da1f6d83dULL, 0x29bf8855b7027e3cULL,
        0x1e5f2e720efb44d2ULL, 0x1ba5a4a3f59869a0ULL,
        0x7b2fafca875e2d65ULL, 0x4aef61d629dce246ULL,
        0x183a981ead415b10ULL, 0x776bf60c789bc29cULL,
        0xf8ebf13388663140ULL, 0x2e651c3c43285ff0ULL,
        0x0f96070540f14a0eULL, 0x44e367875b299152ULL,
        0xec70f1a425b13715ULL, 0xe6c85d8f82e9da89ULL,
        0xb21a601f85b4b223ULL, 0x3485549064a36a46ULL,
        0x8f06dd1c7a2f851aULL, 0xc1a2021d563bb142ULL,
        0xba1de5e4451668e4ULL, 0xd102574105095f8dULL,
        0x89ca4e849bcecf4aULL, 0x48b09427a8742edbULL,
        0xb1fcce9ce78b5272ULL, 0x5d1129cf82afa5bcULL,
        0x02b97c786f824383ULL
    };

    uint64_t expected_ms2_0 = 0x3ad74c52b2248509ULL;

    printf("=== ProofOfWorkHash mid-state ===\n");
    compute_cshake_midstate("ProofOfWorkHash", ms1);
    int ok = 1;
    for (int i = 0; i < 25; i++) {
        int match = (ms1[i] == expected_ms1[i]);
        if (!match) ok = 0;
        printf("  state[%2d] = 0x%016lx %s (expected 0x%016lx)\n",
               i, ms1[i], match ? "OK" : "MISMATCH", expected_ms1[i]);
    }
    printf("  %s\n", ok ? "ALL MATCH" : "*** MISMATCH DETECTED ***");

    printf("\n=== HeavyHash mid-state ===\n");
    compute_cshake_midstate("HeavyHash", ms2);
    printf("  state[0] = 0x%016lx %s (expected 0x%016lx)\n",
           ms2[0], ms2[0] == expected_ms2_0 ? "OK" : "MISMATCH", expected_ms2_0);

    return ok ? 0 : 1;
}
