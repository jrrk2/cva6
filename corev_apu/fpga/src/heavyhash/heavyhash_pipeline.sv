// heavyhash_pipeline.sv — Pipelined HeavyHash mining pipeline
//
// Three-stage pipeline with valid/ready handshake between stages:
//   Stage 1: First Keccak hash (dedicated keccak256 instance)
//   Stage 2: Matrix multiply (64x64 4-bit matrix-vector, dual-port 2 rows/cyc)
//   Stage 3: Second Keccak hash + target comparison (dedicated keccak256)
//
// Each stage has a 1-deep output holding register.  Throughput is
// limited by the slowest stage (matrix at ~35 cycles with dual-port
// BRAM), giving ~3.57 MH/s per lane at 125 MHz.
//
// Resource cost vs non-pipelined: one additional keccak256 instance
// per lane (the keccak core is no longer shared between hash passes).

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

  // Configuration (stable during mining)
  input  logic [1599:0] mid_state_1, // cSHAKE prefix state for 1st hash
  input  logic [1599:0] mid_state_2, // cSHAKE prefix state for 2nd hash
  input  logic [RATE-1:0] msg_block, // pre-padded message template
  input  logic [255:0]  target,      // difficulty target (LE)
  input  logic [63:0]   nonce_start,

  // Results
  output logic [63:0]   nonce_found, // winning nonce
  output logic [63:0]   hash_count,  // total hashes computed

  // Matrix BRAM write port
  input  logic          mat_wr_en,
  input  logic [5:0]    mat_wr_addr,
  input  logic [255:0]  mat_wr_data
);

  // ================================================================
  //  Top-level state
  // ================================================================
  logic        running;
  logic        found_reg;      // single FF, glitch-free for CDC
  logic [63:0] nonce_found_reg;
  logic [63:0] hash_cnt;

  assign busy       = running;
  assign found      = found_reg;
  assign nonce_found = nonce_found_reg;
  assign hash_count = hash_cnt;

  // ================================================================
  //  Stage 1: First Keccak hash
  // ================================================================

  // Nonce management
  logic [63:0] s1_next_nonce;   // next nonce to issue to keccak1
  logic [63:0] s1_nonce;        // nonce currently in keccak1
  logic        s1_started;      // keccak1 is running for this nonce

  // Output holding register (1-deep FIFO to stage 2)
  logic         s1_valid;
  logic [63:0]  s1_nonce_out;
  logic [255:0] s1_hash_out;
  logic         s1_ready;       // set by stage 2

  // Keccak1 instance
  logic         k1_ready;
  logic [255:0] k1_hash;
  logic         k1_done;

  // Build message block with current nonce patched in
  logic [RATE-1:0] msg_with_nonce;
  always_comb begin
    msg_with_nonce = msg_block;
    msg_with_nonce[NONCE_BIT_OFS +: 64] = s1_next_nonce;
  end

  // Fire keccak1 when: running, not found, core idle, output slot available
  logic k1_fire;
  assign k1_fire = running && !found_reg && !s1_started
                 && (!s1_valid || s1_ready) && k1_ready;

  // Note: for synthesis, pipeline registers on mid_state_1 and
  // msg_with_nonce may be needed to break high-fanout routing.
  // Omitted here for simulation clarity.
  keccak256 u_keccak1 (
    .clk       ( clk            ),
    .rst_n     ( rst_n          ),
    .mid_state ( mid_state_1    ),
    .in_block  ( msg_with_nonce ),
    .in_valid  ( k1_fire        ),
    .in_ready  ( k1_ready       ),
    .out_hash  ( k1_hash        ),
    .out_valid ( k1_done        )
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_started    <= 1'b0;
      s1_valid      <= 1'b0;
      s1_nonce      <= '0;
      s1_nonce_out  <= '0;
      s1_hash_out   <= '0;
      s1_next_nonce <= '0;
    end else begin
      // Consume: stage 2 takes our output
      if (s1_valid && s1_ready)
        s1_valid <= 1'b0;

      // Fire: start keccak1 for next nonce
      if (k1_fire) begin
        s1_started    <= 1'b1;
        s1_nonce      <= s1_next_nonce;
        s1_next_nonce <= s1_next_nonce + 64'(NONCE_STEP);
      end

      // Done: keccak1 finished, latch result into output register
      if (k1_done && s1_started) begin
        s1_started   <= 1'b0;
        s1_valid     <= 1'b1;
        s1_nonce_out <= s1_nonce;
        s1_hash_out  <= k1_hash;
      end

      // Start: reset stage for new mining session
      if (start) begin
        s1_next_nonce <= nonce_start;
        s1_started    <= 1'b0;
        s1_valid      <= 1'b0;
      end
    end
  end

  // ================================================================
  //  Stage 2: Matrix multiply
  // ================================================================

  logic         mat_start_r;
  logic         mat_busy_i;
  logic         mat_done;
  logic [255:0] mat_hash_out;
  logic [255:0] mat_hash_in;    // registered input, stable during operation

  // Output holding register (1-deep FIFO to stage 3)
  logic         s2_valid;
  logic [63:0]  s2_nonce_out;
  logic [255:0] s2_result_out;
  logic         s2_ready;       // set by stage 3

  logic [63:0]  s2_nonce;       // nonce being processed by matrix

  // Accept from stage 1 when: matrix idle AND output slot available
  assign s1_ready = !mat_busy_i && (!s2_valid || s2_ready);

  heavyhash_matrix u_matrix (
    .clk        ( clk          ),
    .rst_n      ( rst_n        ),
    .mat_wr_en  ( mat_wr_en    ),
    .mat_wr_addr( mat_wr_addr  ),
    .mat_wr_data( mat_wr_data  ),
    .hash_in    ( mat_hash_in  ),
    .start      ( mat_start_r  ),
    .busy       ( mat_busy_i   ),
    .done       ( mat_done     ),
    .hash_out   ( mat_hash_out )
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mat_start_r   <= 1'b0;
      s2_valid      <= 1'b0;
      s2_nonce      <= '0;
      s2_nonce_out  <= '0;
      s2_result_out <= '0;
      mat_hash_in   <= '0;
    end else begin
      mat_start_r <= 1'b0;   // default: single-cycle pulse

      // Consume: stage 3 takes our output
      if (s2_valid && s2_ready)
        s2_valid <= 1'b0;

      // Accept from stage 1: latch hash and start matrix
      if (s1_valid && s1_ready) begin
        mat_hash_in <= s1_hash_out;
        mat_start_r <= 1'b1;
        s2_nonce    <= s1_nonce_out;
      end

      // Matrix done: latch result into output register
      if (mat_done) begin
        s2_valid      <= 1'b1;
        s2_nonce_out  <= s2_nonce;
        s2_result_out <= mat_hash_out;
      end

      // Start: reset stage
      if (start) begin
        s2_valid    <= 1'b0;
        mat_start_r <= 1'b0;
      end
    end
  end

  // ================================================================
  //  Stage 3: Second Keccak hash + target comparison
  // ================================================================

  logic         k2_ready;
  logic [255:0] k2_hash;
  logic         k2_done;

  logic         s3_started;     // keccak2 is running
  logic [63:0]  s3_nonce;       // nonce being hashed by keccak2

  // Build rate block for 2nd hash from stage 2 output
  logic [RATE-1:0] hash2_block;
  always_comb begin
    hash2_block = '0;
    hash2_block[255:0] = s2_result_out;
    // cSHAKE padding: 0x04 at byte[32], 0x80 at byte[135]
    hash2_block[32*8 +: 8] = 8'h04;
    hash2_block[135*8 +: 8] = 8'h80;
  end

  // Accept from stage 2 when: running, not found, keccak2 idle
  assign s2_ready = running && !found_reg && !s3_started && k2_ready;

  logic k2_fire;
  assign k2_fire = s2_valid && s2_ready;

  keccak256 u_keccak2 (
    .clk       ( clk         ),
    .rst_n     ( rst_n       ),
    .mid_state ( mid_state_2 ),
    .in_block  ( hash2_block ),
    .in_valid  ( k2_fire     ),
    .in_ready  ( k2_ready    ),
    .out_hash  ( k2_hash     ),
    .out_valid ( k2_done     )
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_started <= 1'b0;
      s3_nonce   <= '0;
    end else begin
      if (k2_fire) begin
        s3_started <= 1'b1;
        s3_nonce   <= s2_nonce_out;
      end

      if (k2_done && s3_started)
        s3_started <= 1'b0;

      if (start)
        s3_started <= 1'b0;
    end
  end

  // ================================================================
  //  Target comparison (word-by-word, MSB-first, registered)
  // ================================================================
  logic [7:0] cmp_lt;
  logic [7:0] cmp_eq;

  genvar cw;
  generate
    for (cw = 0; cw < 8; cw++) begin : gen_cmp
      assign cmp_lt[cw] = (k2_hash[cw*32 +: 32] < target[cw*32 +: 32]);
      assign cmp_eq[cw] = (k2_hash[cw*32 +: 32] == target[cw*32 +: 32]);
    end
  endgenerate

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

  // Comparison result valid one cycle after k2_done (registered compare)
  logic        cmp_valid;
  logic [63:0] cmp_nonce;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmp_valid <= 1'b0;
      cmp_nonce <= '0;
    end else begin
      cmp_valid <= k2_done && s3_started;
      if (k2_done && s3_started)
        cmp_nonce <= s3_nonce;
      if (start)
        cmp_valid <= 1'b0;
    end
  end

  // ================================================================
  //  Top-level control
  // ================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      running         <= 1'b0;
      found_reg       <= 1'b0;
      nonce_found_reg <= '0;
      hash_cnt        <= '0;
    end else begin
      if (start) begin
        running         <= 1'b1;
        found_reg       <= 1'b0;
        hash_cnt        <= '0;
        nonce_found_reg <= '0;
      end

      if (stop) begin
        running   <= 1'b0;
        found_reg <= 1'b0;
      end

      // Comparison done: count hash and check target
      if (cmp_valid) begin
        hash_cnt <= hash_cnt + 64'd1;
        if (hash_le_target && !found_reg) begin
          found_reg       <= 1'b1;
          nonce_found_reg <= cmp_nonce;
          running         <= 1'b0;
        end
      end
    end
  end

  // ================================================================
  //  Observability aliases (testbench / ILA)
  // ================================================================
  logic [255:0] first_hash;
  logic [255:0] matrix_result;
  logic [255:0] keccak_hash;
  assign first_hash    = s1_hash_out;
  assign matrix_result = s2_result_out;
  assign keccak_hash   = k2_hash;

endmodule
