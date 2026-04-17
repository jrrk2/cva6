// kaspa_miner.c — Kaspa stratum mining client for CVA6 + HeavyHash FPGA
//
// Connects to a Kaspa mining pool via stratum JSON-RPC, receives work,
// configures the FPGA mining accelerator, and submits shares.
//
// Build: riscv64-unknown-linux-gnu-gcc -O2 -o kaspa_miner kaspa_miner.c
// Run:   ./kaspa_miner <pool_host> <pool_port> <wallet_address>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>

#include "heavyhash_drv.h"

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

    memset(mid_state, 0, 200);
    for (int i = 0; i < 17; i++) {
        uint64_t lane = 0;
        for (int b = 0; b < 8; b++)
            lane |= (uint64_t)prefix[i*8 + b] << (b*8);
        mid_state[i] ^= lane;
    }
    keccak_f1600(mid_state);
}

// ----------------------------------------------------------------
//  Matrix generation (xoshiro256++ seeded from PrePowHash)
// ----------------------------------------------------------------

typedef struct { uint64_t s[4]; } xoshiro_state;

static uint64_t xoshiro_next(xoshiro_state *st) {
    uint64_t *s = st->s;
    uint64_t result = rotl64(s[0] + s[3], 23) + s[0];
    uint64_t t = s[1] << 17;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl64(s[3], 45);
    return result;
}

static void generate_matrix(const uint8_t prepow_hash[32],
                            uint32_t matrix[64][8]) {
    xoshiro_state xs;
    memcpy(xs.s, prepow_hash, 32);

    for (int row = 0; row < 64; row++) {
        memset(matrix[row], 0, 32);
        for (int col = 0; col < 64; col += 16) {
            uint64_t r = xoshiro_next(&xs);
            for (int k = 0; k < 16 && (col + k) < 64; k++) {
                uint8_t nibble = (r >> (k * 4)) & 0xF;
                int bit_pos = (col + k) * 4;
                matrix[row][bit_pos / 32] |= (uint32_t)nibble << (bit_pos % 32);
            }
        }
    }
}

// ----------------------------------------------------------------
//  Hex utilities
// ----------------------------------------------------------------

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int hex_decode(const char *hex, uint8_t *out, int max_bytes) {
    int len = 0;
    while (hex[0] && hex[1] && len < max_bytes) {
        int h = hex_val(hex[0]), l = hex_val(hex[1]);
        if (h < 0 || l < 0) break;
        out[len++] = (h << 4) | l;
        hex += 2;
    }
    return len;
}

static void hex_encode(const uint8_t *data, int len, char *out) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < len; i++) {
        out[i*2]     = hex[data[i] >> 4];
        out[i*2 + 1] = hex[data[i] & 0xF];
    }
    out[len * 2] = '\0';
}

// ----------------------------------------------------------------
//  Minimal JSON field extraction (no allocations, no library)
// ----------------------------------------------------------------

// Find a string value for "key":"value" — returns pointer into buf, writes len
static const char *json_get_str(const char *json, const char *key,
                                int *out_len) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':') p++;
    if (*p != '"') return NULL;
    p++;
    const char *end = strchr(p, '"');
    if (!end) return NULL;
    *out_len = end - p;
    return p;
}

// Find the "params" array and extract positional string elements
// params_out[i] points into json, lens[i] is the length
static int json_get_params(const char *json, const char *params_out[],
                           int lens[], int max_params) {
    const char *p = strstr(json, "\"params\"");
    if (!p) return 0;
    p += 8;
    while (*p == ' ' || *p == ':') p++;
    if (*p != '[') return 0;
    p++;

    int count = 0;
    while (*p && *p != ']' && count < max_params) {
        while (*p == ' ' || *p == ',') p++;
        if (*p == '"') {
            p++;
            const char *end = strchr(p, '"');
            if (!end) break;
            params_out[count] = p;
            lens[count] = end - p;
            count++;
            p = end + 1;
        } else if (*p == 'n' && strncmp(p, "null", 4) == 0) {
            params_out[count] = NULL;
            lens[count] = 0;
            count++;
            p += 4;
        } else if (*p == 't' && strncmp(p, "true", 4) == 0) {
            params_out[count] = p;
            lens[count] = 4;
            count++;
            p += 4;
        } else if (*p == 'f' && strncmp(p, "false", 5) == 0) {
            params_out[count] = p;
            lens[count] = 5;
            count++;
            p += 5;
        } else {
            // number or other — skip to next comma or ]
            const char *start = p;
            while (*p && *p != ',' && *p != ']') p++;
            params_out[count] = start;
            lens[count] = p - start;
            count++;
        }
    }
    return count;
}

// Extract "method":"value"
static int json_get_method(const char *json, char *method, int maxlen) {
    int len;
    const char *val = json_get_str(json, "method", &len);
    if (!val || len >= maxlen) return -1;
    memcpy(method, val, len);
    method[len] = '\0';
    return 0;
}

// Extract "id":N  (integer)
static int json_get_id(const char *json) {
    const char *p = strstr(json, "\"id\"");
    if (!p) return -1;
    p += 4;
    while (*p == ' ' || *p == ':') p++;
    if (*p == 'n') return -1;  // null
    return atoi(p);
}

// ----------------------------------------------------------------
//  TCP connection + line-buffered I/O
// ----------------------------------------------------------------

static volatile int g_running = 1;

static void sigint_handler(int sig) {
    (void)sig;
    g_running = 0;
}

static int tcp_connect(const char *host, int port) {
    struct hostent *he = gethostbyname(host);
    if (!he) { fprintf(stderr, "DNS lookup failed: %s\n", host); return -1; }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    memcpy(&sa.sin_addr, he->h_addr, he->h_length);

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }

    int flag = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
    return fd;
}

static int tcp_send(int fd, const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    if (n <= 0) return -1;
    buf[n++] = '\n';
    return (int)write(fd, buf, n);
}

// Line-buffered reader
typedef struct {
    int    fd;
    char   buf[8192];
    int    len;
} line_reader_t;

static void lr_init(line_reader_t *lr, int fd) {
    lr->fd  = fd;
    lr->len = 0;
}

// Returns a complete line (without \n) or NULL if none available.
// Non-blocking: call after poll() says data is ready.
static char *lr_getline(line_reader_t *lr) {
    // Check for a complete line already in buffer
    char *nl = memchr(lr->buf, '\n', lr->len);
    if (!nl) {
        // Try to read more
        int space = sizeof(lr->buf) - lr->len - 1;
        if (space <= 0) {
            // Buffer full with no newline — discard
            lr->len = 0;
            return NULL;
        }
        int n = read(lr->fd, lr->buf + lr->len, space);
        if (n <= 0) return NULL;
        lr->len += n;
        nl = memchr(lr->buf, '\n', lr->len);
        if (!nl) return NULL;
    }

    *nl = '\0';
    // Strip \r if present
    if (nl > lr->buf && *(nl-1) == '\r') *(nl-1) = '\0';

    // The line is at lr->buf[0..nl)
    static char line[8192];
    int line_len = nl - lr->buf;
    memcpy(line, lr->buf, line_len + 1);

    // Shift remainder
    int remaining = lr->len - (nl - lr->buf + 1);
    if (remaining > 0)
        memmove(lr->buf, nl + 1, remaining);
    lr->len = remaining;

    return line;
}

// ----------------------------------------------------------------
//  Mining state
// ----------------------------------------------------------------

typedef struct {
    char     job_id[64];
    uint8_t  prepow_hash[32];
    uint8_t  timestamp[8];
    uint32_t matrix[64][8];
    uint8_t  msg_template[136];  // ready for hardware (with cSHAKE padding)
    int      valid;
} mining_job_t;

typedef struct {
    uint32_t target[8];         // 256-bit target (LE)
    double   difficulty;
    int      target_valid;
} mining_target_t;

static mining_job_t    g_job;
static mining_target_t g_target;
static uint64_t        g_midstate1[25];
static uint64_t        g_midstate2[25];
static int             g_midstates_ready;
static uint64_t        g_nonce_base;    // pool-assigned nonce prefix
static int             g_debug_mode = 0;   // -d flag: finish current job before switching
static int             g_submit_id = 10;

// ----------------------------------------------------------------
//  Difficulty to target conversion
//  target = 2^255 / difficulty  (Kaspa convention — max target is 2^255)
// ----------------------------------------------------------------

static void difficulty_to_target(double diff, uint32_t target[8]) {
    // target = floor(2^255 / diff), stored as 256-bit LE (target[0] = LSW)
    memset(target, 0, 32);
    if (diff <= 0.0) {
        memset(target, 0xFF, 32);
        return;
    }

    // Use frexp to decompose: diff = frac * 2^exp  where 0.5 <= frac < 1.0
    // Then 2^255 / diff = (1/frac) * 2^(255-exp)
    // 1/frac is in range (1.0, 2.0], so we get a mantissa with MSB at bit (255-exp)
    int exp;
    double frac = frexp(diff, &exp);
    int msb_pos = 255 - exp;  // bit position of MSB in result

    if (msb_pos < 0) return;           // difficulty impossibly high
    if (msb_pos >= 256) {              // difficulty < 1
        memset(target, 0xFF, 32);
        return;
    }

    // Get 53 significant bits of mantissa (double precision)
    // inv_frac in (1.0, 2.0], scale to get top 52 fractional bits
    double inv_frac = 1.0 / frac;
    uint64_t mantissa = (uint64_t)(inv_frac * 4503599627370496.0);  // * 2^52
    // mantissa now has MSB at bit 52 (value in [2^52, 2^53))

    // Place mantissa so that bit 52 of mantissa lands at msb_pos of target
    // i.e., shift left by (msb_pos - 52) bits
    int shift = msb_pos - 52;
    uint8_t *tp = (uint8_t *)target;  // LE byte array

    if (shift >= 0) {
        int byte_shift = shift / 8;
        int bit_shift  = shift % 8;
        // Write 8 bytes of mantissa (LE) into target at byte_shift offset
        for (int i = 0; i < 8; i++) {
            uint8_t b = (uint8_t)(mantissa >> (i * 8));
            int pos = i + byte_shift;
            if (pos < 32)
                tp[pos] |= (uint8_t)(b << bit_shift);
            if (bit_shift > 0 && pos + 1 < 32)
                tp[pos + 1] |= (uint8_t)(b >> (8 - bit_shift));
        }
    } else {
        // shift < 0: right-shift mantissa
        mantissa >>= (uint64_t)(-shift);
        target[0] = (uint32_t)(mantissa);
        target[1] = (uint32_t)(mantissa >> 32);
    }
}

// ----------------------------------------------------------------
//  Stratum message handlers
// ----------------------------------------------------------------

static void handle_subscribe_result(const char *json) {
    // Response to our subscribe — check for errors
    const char *err = strstr(json, "\"error\"");
    if (err) {
        const char *null_check = err + 7;
        while (*null_check == ' ' || *null_check == ':') null_check++;
        if (*null_check != 'n') {  // not null
            fprintf(stderr, "Subscribe error: %s\n", json);
            return;
        }
    }
    printf("Subscribed to pool\n");
}

static void handle_set_difficulty(const char *json) {
    const char *params[4];
    int lens[4];
    int n = json_get_params(json, params, lens, 4);
    if (n < 1 || !params[0]) {
        fprintf(stderr, "Bad set_difficulty: %s\n", json);
        return;
    }

    // Difficulty may be a number (not quoted)
    char tmp[64];
    int l = lens[0] < 63 ? lens[0] : 63;
    memcpy(tmp, params[0], l);
    tmp[l] = '\0';
    g_target.difficulty = atof(tmp);

    difficulty_to_target(g_target.difficulty, g_target.target);
    g_target.target_valid = 1;

    if (g_debug_mode) {
        printf("Difficulty: %.4f\n", g_target.difficulty);
        printf("Target: %08x %08x %08x %08x %08x %08x %08x %08x\n",
               g_target.target[7], g_target.target[6],
               g_target.target[5], g_target.target[4],
               g_target.target[3], g_target.target[2],
               g_target.target[1], g_target.target[0]);
    }
}

static void handle_set_extranonce(const char *json) {
    const char *params[4];
    int lens[4];
    int n = json_get_params(json, params, lens, 4);
    if (n < 1 || !params[0]) return;

    // Extranonce is a hex prefix for the nonce
    uint8_t prefix_bytes[8];
    memset(prefix_bytes, 0, 8);
    char tmp[64];
    int l = lens[0] < 63 ? lens[0] : 63;
    memcpy(tmp, params[0], l);
    tmp[l] = '\0';
    int prefix_len = hex_decode(tmp, prefix_bytes, 8);

    // Place prefix in the high bytes of the nonce
    g_nonce_base = 0;
    for (int i = 0; i < prefix_len; i++)
        g_nonce_base |= (uint64_t)prefix_bytes[i] << (56 - i * 8);

    printf("Nonce prefix: 0x%016lx (%d bytes)\n",
           (unsigned long)g_nonce_base, prefix_len);
}

static void handle_notify(const char *json, int sock) {
    const char *params[4];
    int lens[4];
    int n = json_get_params(json, params, lens, 4);
    if (n < 2 || !params[0] || !params[1]) {
        fprintf(stderr, "Bad notify: %s\n", json);
        return;
    }

    // params[0] = job ID
    int jlen = lens[0] < 63 ? lens[0] : 63;
    memcpy(g_job.job_id, params[0], jlen);
    g_job.job_id[jlen] = '\0';

    // params[1] = header hash (prepow_hash + timestamp as hex)
    // Expected: 32 bytes prepow + 8 bytes timestamp = 40 bytes = 80 hex chars
    char hex_buf[256];
    int hlen = lens[1] < 255 ? lens[1] : 255;
    memcpy(hex_buf, params[1], hlen);
    hex_buf[hlen] = '\0';

    uint8_t header_data[40];
    int decoded = hex_decode(hex_buf, header_data, 40);
    if (decoded < 32) {
        fprintf(stderr, "Header hash too short: %d bytes\n", decoded);
        return;
    }

    memcpy(g_job.prepow_hash, header_data, 32);
    if (decoded >= 40)
        memcpy(g_job.timestamp, header_data + 32, 8);
    else
        memset(g_job.timestamp, 0, 8);

    // Compute mid-states if not done yet (they're constant per cSHAKE domain)
    if (!g_midstates_ready) {
        compute_cshake_midstate("ProofOfWorkHash", g_midstate1);
        compute_cshake_midstate("HeavyHash", g_midstate2);
        hh_write_mid_state(HH_MSTATE1_BASE, (const uint32_t *)g_midstate1);
        hh_write_mid_state(HH_MSTATE2_BASE, (const uint32_t *)g_midstate2);
        g_midstates_ready = 1;
        printf("Mid-states computed and loaded\n");
    }

    // Build 136-byte message template
    // Bytes 0-31: prepow_hash, 32-39: timestamp, 40-71: zero, 72-79: nonce placeholder
    memset(g_job.msg_template, 0, 136);
    memcpy(g_job.msg_template, g_job.prepow_hash, 32);
    memcpy(g_job.msg_template + 32, g_job.timestamp, 8);
    // Nonce at bytes 72-79 is patched by hardware
    // cSHAKE256 padding
    g_job.msg_template[80] = 0x04;
    g_job.msg_template[135] = 0x80;

    // Generate matrix from prepow_hash
    generate_matrix(g_job.prepow_hash, g_job.matrix);

    // Stop current mining
    hh_stop();
    usleep(100);
    hh_clear_found();

    // Load new work into hardware
    hh_write_msg_block((const uint32_t *)g_job.msg_template);
    hh_write_matrix(g_job.matrix);

    if (g_target.target_valid)
        hh_write_target(g_target.target);

    // Start mining from a random nonce so we don't always search
    // the same range (jobs change every ~1s, only ~346K attempts each)
    uint64_t start_nonce = g_nonce_base;
    if (start_nonce == 0) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        start_nonce = ((uint64_t)ts.tv_sec << 32) ^ ((uint64_t)ts.tv_nsec * 2654435761ULL);
    }
    hh_set_nonce(start_nonce);
    hh_start();

    g_job.valid = 1;
    if (g_debug_mode) {
        printf("Job %s: mining started (nonce=0x%016lx, target_valid=%d, busy=%d)\n",
               g_job.job_id, (unsigned long)start_nonce,
               g_target.target_valid, hh_is_busy());
        printf("  prepow: ");
        for (int i = 0; i < 8; i++) printf("%02x", g_job.prepow_hash[i]);
        printf("...\n");
    }
}

static void handle_submit_result(const char *json) {
    int id = json_get_id(json);
    const char *result = strstr(json, "\"result\"");
    if (result && strstr(result, "true")) {
        printf("Share %d accepted\n", id);
    } else {
        // Try to extract error message
        int len;
        const char *err_str = json_get_str(json, "error", &len);
        if (err_str)
            printf("Share %d rejected: %.*s\n", id, len, err_str);
        else
            printf("Share %d rejected: %s\n", id, json);
    }
}

static void submit_share(int sock, uint64_t nonce) {
    // Encode nonce as hex (big-endian byte order for the pool)
    uint8_t nonce_be[8];
    for (int i = 0; i < 8; i++)
        nonce_be[i] = (nonce >> (56 - i * 8)) & 0xFF;

    char nonce_hex[17];
    hex_encode(nonce_be, 8, nonce_hex);

    tcp_send(sock,
        "{\"id\":%d,\"method\":\"mining.submit\","
        "\"params\":[\"%s\",\"%s\",\"%s\"]}",
        g_submit_id++, "worker", g_job.job_id, nonce_hex);

    printf(">>> FOUND nonce 0x%016lx (%s) for job %s\n",
           (unsigned long)nonce, nonce_hex, g_job.job_id);
}

// ----------------------------------------------------------------
//  Stratum message dispatch
// ----------------------------------------------------------------

// (g_debug_mode moved earlier)
static int g_shares_submitted = 0;

// Check hardware for found nonce, submit if found. Returns winning nonce+1, or 0 if not found.
static uint64_t check_and_submit_found(int sock) {
    if (!g_job.valid) return 0;
    if (hh_is_found()) {
        uint64_t nonce = hh_get_found_nonce();
        uint64_t hashes = hh_get_hash_count();
        printf("*** FOUND *** nonce=0x%016lx hashes=%lu\n",
               (unsigned long)nonce, (unsigned long)hashes);
        submit_share(sock, nonce);
        g_shares_submitted++;
        hh_clear_found();
        return nonce + 1;
    }
    return 0;
}

static void dispatch_message(const char *json, int sock) {
    char method[64];

    if (g_debug_mode > 1)
        printf("[recv] %s\n", json);

    if (json_get_method(json, method, sizeof(method)) == 0) {
        // It's a request/notification from the pool
        if (strcmp(method, "mining.notify") == 0) {
            if (g_debug_mode && g_job.valid) {
                // Check for found FIRST — hardware may have just finished
                uint64_t next = check_and_submit_found(sock);
                if (next) {
                    // Found! Don't restart — let new job take over below
                } else if (hh_is_busy()) {
                    printf("[debug] Deferring new job — waiting for current nonce scan to finish/find\n");
                    return;  // skip this template, keep mining current job
                }
            }
            handle_notify(json, sock);
        } else if (strcmp(method, "mining.set_difficulty") == 0) {
            handle_set_difficulty(json);
        } else if (strcmp(method, "mining.set_extranonce") == 0) {
            handle_set_extranonce(json);
        } else {
            fprintf(stderr, "Unknown method: %s\n", method);
        }
    } else {
        // It's a response to one of our requests
        int id = json_get_id(json);
        if (id == 1) {
            handle_subscribe_result(json);
        } else if (id >= 10) {
            handle_submit_result(json);
        }
    }
}

// ----------------------------------------------------------------
//  Main
// ----------------------------------------------------------------

int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);  // unbuffered output

    // Parse optional -d / -dd flag
    int argi = 1;
    while (argi < argc && argv[argi][0] == '-') {
        if (strcmp(argv[argi], "-d") == 0)
            g_debug_mode = 1;
        else if (strcmp(argv[argi], "-dd") == 0)
            g_debug_mode = 2;
        argi++;
    }

    if (argc - argi < 3) {
        fprintf(stderr, "Usage: %s [-d|-dd] <pool_host> <pool_port> <wallet_address>\n"
                        "  -d   Debug: finish nonce scan before switching jobs\n"
                        "  -dd  Verbose: also print all received messages\n",
                argv[0]);
        return 1;
    }

    const char *host   = argv[argi];
    int         port   = atoi(argv[argi + 1]);
    const char *wallet = argv[argi + 2];

    signal(SIGINT,  sigint_handler);
    signal(SIGTERM, sigint_handler);
    signal(SIGPIPE, SIG_IGN);

    // Initialize FPGA
    if (hh_init() < 0) {
        fprintf(stderr, "Failed to map FPGA registers (need root)\n");
        return 1;
    }
    hh_stop();
    hh_clear_found();

    printf("Kaspa HeavyHash FPGA Miner\n");
    printf("Pool: %s:%d\n", host, port);
    printf("Wallet: %s\n", wallet);
    if (g_debug_mode)
        printf("Debug mode: %d (defer new jobs until scan completes)\n", g_debug_mode);

    // Connect to pool
    int sock = tcp_connect(host, port);
    if (sock < 0) {
        hh_cleanup();
        return 1;
    }
    printf("Connected\n");

    // Set non-blocking so lr_getline doesn't hang on read()
    fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK);

    // Subscribe
    tcp_send(sock,
        "{\"id\":1,\"method\":\"mining.subscribe\","
        "\"params\":[\"cva6-kaspa/0.1\",null,\"%s\",null]}",
        wallet);

    line_reader_t lr;
    lr_init(&lr, sock);

    // Tracking
    struct timespec ts_start;
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    double mono_start = ts_start.tv_sec + ts_start.tv_nsec * 1e-9;
    double mono_last = mono_start;

    // Main loop
    printf("Entering main loop...\n");
    fflush(stdout);
    while (g_running) {
        // IMPORTANT: Check hardware FIRST, before processing network messages.
        // When hardware finds a nonce it enters P_FOUND (busy=0, found=1).
        // If we process network first, dispatch sees !busy, doesn't defer,
        // and handle_notify calls hh_clear_found() — losing the winning nonce.
        // Check for found nonce (also checked inside dispatch before job switch)
        if (g_job.valid) {
            uint64_t next = check_and_submit_found(sock);
            if (next) {
                // Found and submitted — restart mining from next nonce
                hh_set_nonce(next);
                hh_start();
            } else if (!hh_is_busy()) {
                uint64_t hashes = hh_get_hash_count();
                printf("!!! HW STOPPED (not found, not busy) hashes=%lu\n",
                       (unsigned long)hashes);
                g_job.valid = 0;
            }
        }

        struct pollfd pfd = { .fd = sock, .events = POLLIN };
        int ret = poll(&pfd, 1, 200);  // 200ms timeout

        if (ret > 0 && (pfd.revents & POLLIN)) {
            char *line;
            while ((line = lr_getline(&lr)) != NULL) {
                dispatch_message(line, sock);
            }
            if (pfd.revents & (POLLERR | POLLHUP)) {
                fprintf(stderr, "Pool connection lost\n");
                break;
            }
        }

        // Periodic status report
        struct timespec ts_now;
        clock_gettime(CLOCK_MONOTONIC, &ts_now);
        double mono_now = ts_now.tv_sec + ts_now.tv_nsec * 1e-9;
        if (mono_now - mono_last >= 10.0) {
            uint64_t count = hh_get_hash_count();
            uint32_t status = hh_read(HH_STATUS);
            // Use jobs_processed * estimated_rate since HW counter resets each job
            double rate_khs = 346.0;  // known from smoke test; TODO: measure
            double expected_hashes = (g_target.target[7] > 0)
                ? 4294967296.0 / (double)g_target.target[7] : 0;
            double time_to_find = (expected_hashes > 0 && rate_khs > 0)
                ? expected_hashes / (rate_khs * 1000.0) : 0;
            double our_fraction = (expected_hashes > 0)
                ? (rate_khs * 1000.0) / expected_hashes : 0;

            printf("[%.0fs] ~%.0f KH/s | shares: %d | "
                   "status=0x%x (busy=%d found=%d) | "
                   "~%.1fM hashes/block, ~%.0fs to find, "
                   "win: %.3f%% (1 in %.0f)\n",
                   mono_now - mono_start,
                   rate_khs, g_shares_submitted,
                   status, !!(status & HH_STATUS_BUSY),
                   !!(status & HH_STATUS_FOUND),
                   expected_hashes / 1e6, time_to_find,
                   our_fraction * 100.0,
                   our_fraction > 0 ? 1.0 / our_fraction : 0);
            fflush(stdout);

            mono_last = mono_now;
        }
    }

    // Shutdown
    hh_stop();
    printf("\nStopping miner. Total shares submitted: %d\n", g_shares_submitted);

    close(sock);
    hh_cleanup();
    return 0;
}
