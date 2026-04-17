// tb_pipeline.cpp — Verilator C++ testbench for heavyhash_pipeline
//
// Drives the pipeline with a known-good test vector from kaspad's pow_hashers.rs:
//   pre_pow_hash = [42]*32, timestamp = 5435345234, nonce = 432432432
//
// Expected results (kaspad convention):
//   pow_hash:    2fb72b63dd0dd0d82b00cd9f83d4eca0710b7eb8c05966888f39ebc578978abf
//   mat_product: 1c841850ee4e939c1833feacc7e7df9342383d8cf36a55bbcc0dd8814ba4c9fc
//   heavy_hash:  5a5bcd6e352eb8c87c80d0f0574a45a5fcc3d5755660ac120dc9893684c19be6

#include <cstdio>
#include <cstdint>
#include <cstring>
#include "Vheavyhash_pipeline.h"
#include "Vheavyhash_pipeline___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

// Wide signal helpers: Verilator stores >64-bit signals as uint32_t arrays
// Index 0 = bits [31:0], index 1 = bits [63:32], etc.

static void set_u64(uint32_t *dst, int lane, uint64_t val) {
    dst[lane*2]   = (uint32_t)(val & 0xFFFFFFFF);
    dst[lane*2+1] = (uint32_t)(val >> 32);
}

static uint64_t get_u64(const uint32_t *src, int lane) {
    return (uint64_t)src[lane*2] | ((uint64_t)src[lane*2+1] << 32);
}

static void print_hex(const char *label, const uint32_t *src, int bits) {
    int nbytes = bits / 8;
    printf("%s: ", label);
    for (int i = 0; i < nbytes; i++) {
        int word = i / 4;
        int byte_in_word = i % 4;
        uint8_t b = (src[word] >> (byte_in_word * 8)) & 0xFF;
        printf("%02x", b);
    }
    printf("\n");
}

static int compare_256(const char *label, const uint32_t *actual, const uint64_t expected[4]) {
    uint32_t exp32[8];
    for (int i = 0; i < 4; i++) {
        exp32[i*2]   = (uint32_t)(expected[i] & 0xFFFFFFFF);
        exp32[i*2+1] = (uint32_t)(expected[i] >> 32);
    }
    int match = (memcmp(actual, exp32, 32) == 0);
    if (match) {
        printf("[PASS] %s matches expected\n", label);
    } else {
        printf("[FAIL] %s MISMATCH!\n", label);
        print_hex("  actual  ", actual, 256);
        print_hex("  expected", exp32, 256);
        // Show word-by-word diff
        for (int i = 0; i < 8; i++) {
            if (actual[i] != exp32[i])
                printf("  word[%d]: got 0x%08x, exp 0x%08x\n", i, actual[i], exp32[i]);
        }
    }
    return match;
}

// ----------------------------------------------------------------
//  Test vector data
// ----------------------------------------------------------------

// Mid-state 1 (ProofOfWorkHash) — 25 x u64 LE
static const uint64_t MS1[25] = {
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
static const uint64_t MS2[25] = {
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
static const uint64_t MSG_LANES[17] = {
    0x2a2a2a2a2a2a2a2aULL, 0x2a2a2a2a2a2a2a2aULL, 0x2a2a2a2a2a2a2a2aULL,
    0x2a2a2a2a2a2a2a2aULL, 0x0000000143f8c952ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x0000000000000000ULL, 0x0000000000000000ULL,
    0x0000000019c66530ULL, 0x0000000000000004ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x0000000000000000ULL, 0x0000000000000000ULL,
    0x0000000000000000ULL, 0x8000000000000000ULL,
};

// Matrix: 64 rows x 256 bits, each row stored as 4 x u64 (LE)
static const uint64_t MATRIX[64][4] = {
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

// Expected results
static const uint64_t EXPECTED_POW_HASH[4] = {
    0xd8d00ddd632bb72fULL, 0xa0ecd4839fcd002bULL,
    0x886659c0b87e0b71ULL, 0xbf8a9778c5eb398fULL,
};

static const uint64_t EXPECTED_MAT_PRODUCT[4] = {
    0x9c934eee5018841cULL, 0x93dfe7c7acfe3318ULL,
    0xbb556af38c3d3842ULL, 0xfcc9a44b81d80dccULL,
};

static const uint64_t EXPECTED_HEAVY_HASH[4] = {
    0xc8b82e356ecd5b5aULL, 0xa5454a57f0d0807cULL,
    0x12ac605675d5c3fcULL, 0xe69bc1843689c90dULL,
};

// ----------------------------------------------------------------
//  Simulation
// ----------------------------------------------------------------
static Vheavyhash_pipeline *dut;
static VerilatedVcdC *tfp;
static vluint64_t sim_time = 0;

static void tick() {
    dut->clk = 0;
    dut->eval();
    if (tfp) tfp->dump(sim_time++);
    dut->clk = 1;
    dut->eval();
    if (tfp) tfp->dump(sim_time++);
}

static void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 10; i++) tick();
    dut->rst_n = 1;
    for (int i = 0; i < 5; i++) tick();
}

static void write_matrix_row(int row, const uint64_t data[4]) {
    dut->mat_wr_addr = row;
    for (int i = 0; i < 4; i++) set_u64(dut->mat_wr_data, i, data[i]);
    dut->mat_wr_en = 1;
    tick();
    dut->mat_wr_en = 0;
}

// ----------------------------------------------------------------
//  Main
// ----------------------------------------------------------------
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    dut = new Vheavyhash_pipeline;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("tb_pipeline.vcd");

    printf("=== HeavyHash Pipeline Verilator Test ===\n");
    printf("Test vector: pre_pow=[42]*32, ts=5435345234, nonce=432432432\n\n");

    // Initialize
    dut->start = 0;
    dut->stop = 0;
    dut->mat_wr_en = 0;
    dut->mat_wr_addr = 0;
    memset(dut->mat_wr_data, 0, sizeof(dut->mat_wr_data));

    reset();

    // Load mid-states (1600 bits = 50 x u32)
    printf("Loading mid-states...\n");
    for (int i = 0; i < 25; i++) {
        set_u64(dut->mid_state_1, i, MS1[i]);
        set_u64(dut->mid_state_2, i, MS2[i]);
    }

    // Load message block (1088 bits = 34 x u32)
    printf("Loading message block...\n");
    for (int i = 0; i < 17; i++)
        set_u64(dut->msg_block, i, MSG_LANES[i]);

    // Load target (all FF = easy)
    printf("Loading target (all FF)...\n");
    for (int i = 0; i < 4; i++)
        set_u64(dut->target, i, 0xFFFFFFFFFFFFFFFFULL);

    // Load matrix
    printf("Loading matrix (64 rows)...\n");
    for (int r = 0; r < 64; r++)
        write_matrix_row(r, MATRIX[r]);

    // Verify matrix was loaded correctly
    printf("\nVerifying matrix BRAM contents...\n");
    {
        auto *rootp = dut->rootp;
        int mat_ok = 1;
        for (int r = 0; r < 64; r++) {
            auto &row = rootp->heavyhash_pipeline__DOT__u_matrix__DOT__matrix_mem[r];
            for (int w = 0; w < 4; w++) {
                uint64_t got = get_u64(row.data(), w);
                if (got != MATRIX[r][w]) {
                    printf("  BRAM mismatch row %d word %d: got 0x%016lx exp 0x%016lx\n",
                           r, w, got, MATRIX[r][w]);
                    mat_ok = 0;
                }
            }
        }
        printf("  Matrix BRAM: %s\n", mat_ok ? "OK (all 64 rows match)" : "MISMATCHES FOUND");
    }

    // Set nonce
    dut->nonce_start = 432432432ULL;
    tick();

    // Start pipeline
    printf("\nStarting pipeline...\n\n");
    dut->start = 1;
    tick();
    dut->start = 0;

    // Monitor pipeline state transitions and capture intermediate values
    int cycles = 0;
    const int MAX_CYCLES = 2000;
    int prev_pstate = -1;
    int first_hash_captured = 0;
    int matrix_result_captured = 0;
    int mat_debug_count = 0;

    while (cycles < MAX_CYCLES) {
        tick();
        cycles++;

        // Access internal pipeline state via rootp
        auto *rootp = dut->rootp;
        int pstate = rootp->heavyhash_pipeline__DOT__pstate;

        // Print state transitions
        if (pstate != prev_pstate) {
            const char *names[] = {"IDLE", "HASH1", "MATRIX", "HASH2", "COMPARE", "FOUND"};
            printf("cycle %4d: state -> %s (%d)\n", cycles,
                   (pstate >= 0 && pstate <= 5) ? names[pstate] : "???", pstate);

            // Capture first_hash when entering MATRIX state
            if (pstate == 2 && !first_hash_captured) {
                first_hash_captured = 1;
                printf("\n--- First Hash (PowHash) captured ---\n");
                print_hex("  first_hash", rootp->heavyhash_pipeline__DOT__first_hash, 256);
                compare_256("first_hash (PowHash)",
                           rootp->heavyhash_pipeline__DOT__first_hash,
                           EXPECTED_POW_HASH);

                // Print vec[] (input nibbles extracted from first_hash)
                printf("  Input nibbles (vec[0..15]): ");
                for (int j = 0; j < 16; j++)
                    printf("%x ", rootp->heavyhash_pipeline__DOT__u_matrix__DOT__vec[j]);
                printf("...\n");
                printf("\n");
            }

            // Capture matrix_result when entering HASH2 state
            if (pstate == 3 && !matrix_result_captured) {
                matrix_result_captured = 1;
                printf("\n--- Matrix Result captured ---\n");
                print_hex("  matrix_result", rootp->heavyhash_pipeline__DOT__matrix_result, 256);
                compare_256("matrix_result",
                           rootp->heavyhash_pipeline__DOT__matrix_result,
                           EXPECTED_MAT_PRODUCT);
                printf("\n");
            }

            // At COMPARE state, capture the final Keccak hash
            if (pstate == 4) {
                printf("\n--- Final Hash captured at COMPARE ---\n");
                // keccak_hash is the output of the shared keccak core
                print_hex("  keccak_hash", rootp->heavyhash_pipeline__DOT__keccak_hash, 256);
                compare_256("heavy_hash (final)",
                           rootp->heavyhash_pipeline__DOT__keccak_hash,
                           EXPECTED_HEAVY_HASH);
                printf("\n");
            }

            prev_pstate = pstate;
        }

        // During MATRIX state, print dot product for first few rows
        if (pstate == 2 && mat_debug_count < 10) {
            auto *rootp2 = dut->rootp;
            int pipe_cnt = rootp2->heavyhash_pipeline__DOT__u_matrix__DOT__pipe_cnt;
            int running_m = rootp2->heavyhash_pipeline__DOT__u_matrix__DOT__running;
            int dot_val = rootp2->heavyhash_pipeline__DOT__u_matrix__DOT__dot;
            int dot_nib = (dot_val >> 10) & 0xF;
            printf("  [mat cycle %d] pipe_cnt=%d running=%d dot=%d (0x%x) nibble=%x  mat_row[0..3]=",
                   mat_debug_count, pipe_cnt, running_m, dot_val, dot_val, dot_nib);
            print_hex("", rootp2->heavyhash_pipeline__DOT__u_matrix__DOT__mat_row, 256);
            mat_debug_count++;
        }

        // Check for FOUND
        if (dut->found) {
            printf("\nPipeline FOUND result after %d cycles\n", cycles);
            printf("  nonce_found: %lu (0x%016lx)\n",
                   (unsigned long)dut->nonce_found,
                   (unsigned long)dut->nonce_found);
            printf("  hash_count: %lu\n", (unsigned long)dut->hash_count);
            break;
        }
    }

    if (!dut->found) {
        printf("\n[FAIL] Pipeline did not find result in %d cycles!\n", MAX_CYCLES);
        printf("  busy=%d, hash_count=%lu\n",
               dut->busy, (unsigned long)dut->hash_count);
    }

    // Summary
    printf("\n=== Summary ===\n");
    printf("first_hash captured:    %s\n", first_hash_captured ? "YES" : "NO");
    printf("matrix_result captured: %s\n", matrix_result_captured ? "YES" : "NO");

    // Stop
    dut->stop = 1;
    tick();
    dut->stop = 0;
    tick();

    tfp->close();
    dut->final();
    delete tfp;
    delete dut;

    printf("\nVCD trace written to tb_pipeline.vcd\n");
    return 0;
}
