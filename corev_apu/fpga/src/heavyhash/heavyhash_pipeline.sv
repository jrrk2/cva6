// heavyhash_pipeline.sv — Full HeavyHash mining pipeline
//
// Orchestrates: nonce patch -> 1st Keccak -> matrix multiply -> 2nd Keccak -> compare
// Auto-increments nonce on each hash, stops when target met or halted.
//
// Timing per hash (single Keccak core, reused, 100 MHz mining clock):
//   1st hash: 27 cycles (1 pipeline + absorb + 24 rounds + squeeze)
//   Matrix:   67 cycles (64 rows + 3-stage pipeline)
//   2nd hash: 27 cycles
//   Compare:   2 cycles (1 wait + 1 registered check)
//   Total:   ~124 cycles per nonce
//   With 16 lanes at 125 MHz: ~16.1 MH/s theoretical

module heavyhash_pipeline
  import keccak_pkg::*,
         heavyhash_pkg::*;
#(
  parameter int unsigned NONCE_STEP = 1
)
(
  input  logic          clk,
  input  logic          rst_n,

  // Control
  input  logic          start,       // begin mining
  input  logic          stop,        // halt mining
  output logic          busy,
  output logic          found,       // target met

  // Configuration (active during mining)
  input  logic [1599:0] mid_state_1, // cSHAKE prefix state for 1st hash
  input  logic [1599:0] mid_state_2, // cSHAKE prefix state for 2nd hash
  input  logic [RATE-1:0] msg_block, // pre-padded message template
  input  logic [255:0]  target,      // difficulty target (LE)
  input  logic [63:0]   nonce_start,

  // Results
  output logic [63:0]   nonce_found, // winning nonce
  output logic [63:0]   hash_count,  // total hashes computed

  // Matrix BRAM write port (directly exposed)
  input  logic          mat_wr_en,
  input  logic [5:0]    mat_wr_addr,
  input  logic [255:0]  mat_wr_data
);

  // ================================================================
  //  Internal state — one-hot FSM
  //
  //  One-hot encoding ensures `found` is a single FF output with
  //  no combinational decode.  This eliminates glitches that could
  //  be captured by the CDC synchronizer in heavyhash_top.
  // ================================================================
  localparam int PS_IDLE    = 0;
  localparam int PS_HASH1   = 1;
  localparam int PS_MATRIX  = 2;
  localparam int PS_HASH2   = 3;
  localparam int PS_COMPARE = 4;
  localparam int PS_FOUND   = 5;
  localparam int PS_COUNT   = 6;

  logic [PS_COUNT-1:0] ps;

  logic [63:0] nonce_reg;
  logic [63:0] hash_cnt;
  logic [255:0] first_hash;    // result of 1st Keccak
  logic [255:0] matrix_result; // after matrix XOR
  logic running;

  assign busy       = running;
  assign found      = ps[PS_FOUND];   // single FF, glitch-free
  assign nonce_found= nonce_reg;
  assign hash_count = hash_cnt;

  // ================================================================
  //  Keccak core (shared between 1st and 2nd hash)
  // ================================================================
  logic [1599:0]  keccak_mid;
  logic [RATE-1:0] keccak_block;
  logic           keccak_valid;
  logic           keccak_ready;
  logic [255:0]   keccak_hash;
  logic           keccak_done;

  // Pipeline registers to break high-fanout FSM→Keccak routing.
  // ps[PS_HASHx] fans out to 1600+1088 bit muxes; registering the
  // mux outputs lets the router place them near the Keccak, cutting
  // the critical 10 ns cross-die route in half.
  logic [1599:0]   keccak_mid_r;
  logic [RATE-1:0] keccak_block_r;
  logic            keccak_valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      keccak_mid_r   <= '0;
      keccak_block_r <= '0;
      keccak_valid_r <= 1'b0;
    end else begin
      keccak_mid_r   <= keccak_mid;
      keccak_block_r <= keccak_block;
      keccak_valid_r <= keccak_valid;
    end
  end

  keccak256 u_keccak (
    .clk       ( clk            ),
    .rst_n     ( rst_n          ),
    .mid_state ( keccak_mid_r   ),
    .in_block  ( keccak_block_r ),
    .in_valid  ( keccak_valid_r ),
    .in_ready  ( keccak_ready   ),
    .out_hash  ( keccak_hash    ),
    .out_valid ( keccak_done    )
  );

  // ================================================================
  //  Matrix multiply
  // ================================================================
  logic         mat_start;
  logic         mat_busy;
  logic         mat_done;
  logic [255:0] mat_hash_out;

  heavyhash_matrix u_matrix (
    .clk        ( clk          ),
    .rst_n      ( rst_n        ),
    .mat_wr_en  ( mat_wr_en   ),
    .mat_wr_addr( mat_wr_addr ),
    .mat_wr_data( mat_wr_data ),
    .hash_in    ( first_hash   ),
    .start      ( mat_start    ),
    .busy       ( mat_busy     ),
    .done       ( mat_done     ),
    .hash_out   ( mat_hash_out )
  );

  // ================================================================
  //  Build message block with current nonce patched in
  // ================================================================
  logic [RATE-1:0] msg_with_nonce;

  always_comb begin
    msg_with_nonce = msg_block;
    // Patch nonce at bytes 72-79 (bits 576-639)
    msg_with_nonce[NONCE_BIT_OFS +: 64] = nonce_reg;
  end

  // ================================================================
  //  Build rate block for 2nd hash
  //  Input to 2nd cSHAKE256: the 32-byte matrix result
  //  Padded with cSHAKE256 padding: byte[32] |= 0x04, byte[135] |= 0x80
  // ================================================================
  logic [RATE-1:0] hash2_block;

  always_comb begin
    hash2_block = '0;
    hash2_block[255:0] = matrix_result;
    // cSHAKE padding: 0x04 at byte[32], 0x80 at byte[135]
    hash2_block[32*8 +: 8] = 8'h04;
    hash2_block[135*8 +: 8] = 8'h80;
  end

  // ================================================================
  //  Keccak mux — select mid-state and input block based on pipeline stage
  // ================================================================
  always_comb begin
    keccak_mid   = '0;
    keccak_block = '0;
    keccak_valid = 1'b0;

    if (ps[PS_HASH1]) begin
      keccak_mid   = mid_state_1;
      keccak_block = msg_with_nonce;
      keccak_valid = keccak_ready;  // fire immediately when ready
    end else if (ps[PS_HASH2]) begin
      keccak_mid   = mid_state_2;
      keccak_block = hash2_block;
      keccak_valid = keccak_ready;
    end
  end

  // ================================================================
  //  Explicit word-by-word target comparison (MSB-first)
  //
  //  Replaces monolithic `keccak_hash <= target` which Vivado
  //  mis-synthesizes for 256-bit operands at 125 MHz (carry chain
  //  too deep for the clock period, producing silent wrong results).
  // ================================================================
  logic [7:0] cmp_lt;  // word[i]: hash < target
  logic [7:0] cmp_eq;  // word[i]: hash == target

  genvar cw;
  generate
    for (cw = 0; cw < 8; cw++) begin : gen_cmp
      assign cmp_lt[cw] = (keccak_hash[cw*32 +: 32] < target[cw*32 +: 32]);
      assign cmp_eq[cw] = (keccak_hash[cw*32 +: 32] == target[cw*32 +: 32]);
    end
  endgenerate

  // hash <= target  ≡  hash < target  OR  hash == target
  // MSB word is [7], LSB word is [0].
  //
  // Registered to give carry chains a full cycle to settle before
  // the FSM samples the result.  The FSM uses hash_le_target
  // (valid one cycle after P_HASH2→P_COMPARE transition).
  logic hash_le_target_comb;
  assign hash_le_target_comb =
      cmp_lt[7]
    | (cmp_eq[7] & cmp_lt[6])
    | (cmp_eq[7] & cmp_eq[6] & cmp_lt[5])
    | (cmp_eq[7] & cmp_eq[6] & cmp_eq[5] & cmp_lt[4])
    | (cmp_eq[7] & cmp_eq[6] & cmp_eq[5] & cmp_eq[4] & cmp_lt[3])
    | (cmp_eq[7] & cmp_eq[6] & cmp_eq[5] & cmp_eq[4] & cmp_eq[3] & cmp_lt[2])
    | (cmp_eq[7] & cmp_eq[6] & cmp_eq[5] & cmp_eq[4] & cmp_eq[3] & cmp_eq[2] & cmp_lt[1])
    | (cmp_eq[7] & cmp_eq[6] & cmp_eq[5] & cmp_eq[4] & cmp_eq[3] & cmp_eq[2] & cmp_eq[1] & (cmp_lt[0] | cmp_eq[0]));

  logic hash_le_target;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      hash_le_target <= 1'b0;
    else
      hash_le_target <= hash_le_target_comb;
  end

  // ================================================================
  //  Pipeline FSM (one-hot)
  // ================================================================
  logic hash1_started, hash2_started, cmp_wait;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps           <= '0;
      ps[PS_IDLE]  <= 1'b1;
      running      <= 1'b0;
      nonce_reg    <= '0;
      hash_cnt     <= '0;
      first_hash   <= '0;
      matrix_result<= '0;
      mat_start    <= 1'b0;
      hash1_started<= 1'b0;
      hash2_started<= 1'b0;
      cmp_wait     <= 1'b0;
    end else begin
      mat_start <= 1'b0;

      // ---- IDLE ----
      if (ps[PS_IDLE]) begin
        if (start) begin
          running      <= 1'b1;
          nonce_reg    <= nonce_start;
          hash_cnt     <= '0;
          ps           <= '0;
          ps[PS_HASH1] <= 1'b1;
          hash1_started<= 1'b0;
        end
      end

      // ---- HASH1 ----
      if (ps[PS_HASH1]) begin
        if (stop) begin
          ps          <= '0;
          ps[PS_IDLE] <= 1'b1;
          running     <= 1'b0;
        end else begin
          if (keccak_valid_r && keccak_ready)
            hash1_started <= 1'b1;
          if (keccak_done && hash1_started) begin
            first_hash    <= keccak_hash;
            mat_start     <= 1'b1;
            ps            <= '0;
            ps[PS_MATRIX] <= 1'b1;
            hash1_started <= 1'b0;
          end
        end
      end

      // ---- MATRIX ----
      if (ps[PS_MATRIX]) begin
        if (stop) begin
          ps          <= '0;
          ps[PS_IDLE] <= 1'b1;
          running     <= 1'b0;
        end else if (mat_done) begin
          matrix_result <= mat_hash_out;
          ps            <= '0;
          ps[PS_HASH2]  <= 1'b1;
          hash2_started <= 1'b0;
        end
      end

      // ---- HASH2 ----
      if (ps[PS_HASH2]) begin
        if (stop) begin
          ps          <= '0;
          ps[PS_IDLE] <= 1'b1;
          running     <= 1'b0;
        end else begin
          if (keccak_valid_r && keccak_ready)
            hash2_started <= 1'b1;
          if (keccak_done && hash2_started) begin
            hash_cnt      <= hash_cnt + 64'd1;
            hash2_started <= 1'b0;
            ps            <= '0;
            ps[PS_COMPARE]<= 1'b1;
          end
        end
      end

      // ---- COMPARE ----
      if (ps[PS_COMPARE]) begin
        // Wait one cycle for registered comparison to capture the
        // new keccak_hash result (hash_le_target lags by one cycle).
        if (!cmp_wait) begin
          cmp_wait <= 1'b1;
        end else begin
          cmp_wait <= 1'b0;
          if (hash_le_target) begin
            ps           <= '0;
            ps[PS_FOUND] <= 1'b1;
          end else if (stop) begin
            ps          <= '0;
            ps[PS_IDLE] <= 1'b1;
            running     <= 1'b0;
          end else begin
            // Increment nonce and continue
            nonce_reg    <= nonce_reg + 64'(NONCE_STEP);
            ps           <= '0;
            ps[PS_HASH1] <= 1'b1;
          end
        end
      end

      // ---- FOUND ----
      if (ps[PS_FOUND]) begin
        // Stay here until software reads the result and stops
        running <= 1'b0;
        if (stop) begin
          ps          <= '0;
          ps[PS_IDLE] <= 1'b1;
        end
      end
    end
  end

endmodule
