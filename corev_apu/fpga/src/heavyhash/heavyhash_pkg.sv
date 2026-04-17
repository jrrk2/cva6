// heavyhash_pkg.sv — Parameters and register map for HeavyHash mining accelerator
//
// Kaspa kHeavyHash algorithm:
//   1. cSHAKE256(header, "ProofOfWorkHash") -> 256-bit hash
//   2. Extract 64 nibbles from hash, matrix-vector multiply (64x64 x 4-bit)
//   3. Shift >> 10, truncate to 4 bits, XOR with original hash
//   4. cSHAKE256(result, "HeavyHash") -> 256-bit final hash
//   5. Compare with target
//
// Mid-state optimization: software pre-computes the Keccak state after
// absorbing the cSHAKE bytepad prefix. Hardware only does one absorption
// per hash invocation.

package heavyhash_pkg;

  // Matrix dimensions
  localparam int unsigned MATRIX_DIM    = 64;    // 64x64 matrix
  localparam int unsigned NIBBLE_W      = 4;     // 4-bit elements
  localparam int unsigned MATRIX_ROW_W  = MATRIX_DIM * NIBBLE_W;  // 256 bits per row
  localparam int unsigned MATRIX_ROWS   = 64;
  localparam int unsigned ACCUM_W       = 14;    // max product: 15*15*64 = 14400

  // Nonce position within the 136-byte message block (bytes 72-79)
  localparam int unsigned NONCE_BYTE_OFS = 72;
  localparam int unsigned NONCE_BIT_OFS  = NONCE_BYTE_OFS * 8;  // 576

  // ---- AXI-Lite register map (active within 0x000-0x7FF) ----
  //
  // Control/Status:
  //   0x000: CTRL        [0] start (W1S), [1] stop (W1S)
  //   0x004: STATUS      [0] busy (RO), [1] found (RO)
  //   0x008: HASH_CNT_LO [31:0] (RO)
  //   0x00C: HASH_CNT_HI [31:0] (RO)
  //   0x010: NONCE_LO    [31:0] starting nonce
  //   0x014: NONCE_HI    [31:0]
  //   0x018: FOUND_NONCE_LO [31:0] (RO)
  //   0x01C: FOUND_NONCE_HI [31:0] (RO)
  //
  // Target (256 bits, little-endian):
  //   0x020: TARGET[0]  .. 0x03C: TARGET[7]
  //
  // Pre-padded message block (1088 bits = 136 bytes = 34 words):
  //   0x040: MSG[0]  .. 0x0C4: MSG[33]
  //   Nonce at MSG[18..19] = bytes 72-79
  //   cSHAKE256 padding (0x04...0x80) applied by software
  //
  // cSHAKE mid-state 1 (1600 bits = 200 bytes = 50 words):
  //   0x100: MSTATE1[0] .. 0x1C4: MSTATE1[49]
  //
  // cSHAKE mid-state 2 (1600 bits = 200 bytes = 50 words):
  //   0x200: MSTATE2[0] .. 0x2C4: MSTATE2[49]
  //
  // Matrix (loaded via write port, or via DMA):
  //   0x300: MAT_ADDR  [5:0] row address (0..63)
  //   0x304: MAT_DATA0 [31:0] row bits [31:0]
  //   0x308: MAT_DATA1 [31:0] row bits [63:32]
  //   0x30C: MAT_DATA2 [31:0] row bits [95:64]
  //   0x310: MAT_DATA3 [31:0] row bits [127:96]
  //   0x314: MAT_DATA4 [31:0] row bits [159:128]
  //   0x318: MAT_DATA5 [31:0] row bits [191:160]
  //   0x31C: MAT_DATA6 [31:0] row bits [223:192]
  //   0x320: MAT_DATA7 [31:0] row bits [255:224]
  //   0x324: MAT_WR    [0] write strobe (W1S, commits row to BRAM)

  // Register offsets
  localparam logic [11:0] REG_CTRL           = 12'h000;
  localparam logic [11:0] REG_STATUS         = 12'h004;
  localparam logic [11:0] REG_HASH_CNT_LO   = 12'h008;
  localparam logic [11:0] REG_HASH_CNT_HI   = 12'h00C;
  localparam logic [11:0] REG_NONCE_LO      = 12'h010;
  localparam logic [11:0] REG_NONCE_HI      = 12'h014;
  localparam logic [11:0] REG_FOUND_NONCE_LO= 12'h018;
  localparam logic [11:0] REG_FOUND_NONCE_HI= 12'h01C;
  localparam logic [11:0] REG_TARGET_BASE   = 12'h020;  // 8 words
  localparam logic [11:0] REG_MSG_BASE      = 12'h040;  // 34 words
  localparam logic [11:0] REG_MSTATE1_BASE  = 12'h100;  // 50 words
  localparam logic [11:0] REG_MSTATE2_BASE  = 12'h200;  // 50 words
  localparam logic [11:0] REG_MAT_ADDR      = 12'h300;
  localparam logic [11:0] REG_MAT_DATA0     = 12'h304;
  localparam logic [11:0] REG_MAT_WR        = 12'h324;

endpackage
