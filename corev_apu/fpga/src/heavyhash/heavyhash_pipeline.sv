// heavyhash_pipeline.sv — Full HeavyHash mining pipeline
//
// Orchestrates: nonce patch -> 1st Keccak -> matrix multiply -> 2nd Keccak -> compare
// Auto-increments nonce on each hash, stops when target met or halted.
//
// Timing per hash (single Keccak core, reused, 100 MHz mining clock):
//   1st hash: 26 cycles (absorb + 24 rounds + squeeze)
//   Matrix:   67 cycles (64 rows + 3-stage pipeline)
//   2nd hash: 26 cycles
//   Compare:   1 cycle
//   Total:   ~121 cycles per nonce (~1210 ns at 100 MHz)

module heavyhash_pipeline
  import keccak_pkg::*,
         heavyhash_pkg::*;
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
  //  Internal state
  // ================================================================
  typedef enum logic [2:0] {
    P_IDLE      = 3'd0,
    P_HASH1     = 3'd1,  // first cSHAKE256
    P_MATRIX    = 3'd2,  // matrix multiply
    P_HASH2     = 3'd3,  // second cSHAKE256
    P_COMPARE   = 3'd4,
    P_FOUND     = 3'd5
  } pipe_state_e;

  pipe_state_e pstate;

  logic [63:0] nonce_reg;
  logic [63:0] hash_cnt;
  logic [255:0] first_hash;    // result of 1st Keccak
  logic [255:0] matrix_result; // after matrix XOR
  logic running;

  assign busy       = running;
  assign found      = (pstate == P_FOUND);
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

  keccak256 u_keccak (
    .clk       ( clk          ),
    .rst_n     ( rst_n        ),
    .mid_state ( keccak_mid   ),
    .in_block  ( keccak_block ),
    .in_valid  ( keccak_valid ),
    .in_ready  ( keccak_ready ),
    .out_hash  ( keccak_hash  ),
    .out_valid ( keccak_done  )
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

    case (pstate)
      P_HASH1: begin
        keccak_mid   = mid_state_1;
        keccak_block = msg_with_nonce;
        keccak_valid = keccak_ready;  // fire immediately when ready
      end
      P_HASH2: begin
        keccak_mid   = mid_state_2;
        keccak_block = hash2_block;
        keccak_valid = keccak_ready;
      end
      default: ;
    endcase
  end

  // ================================================================
  //  Pipeline FSM
  // ================================================================
  logic hash1_started, hash2_started;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pstate       <= P_IDLE;
      running      <= 1'b0;
      nonce_reg    <= '0;
      hash_cnt     <= '0;
      first_hash   <= '0;
      matrix_result<= '0;
      mat_start    <= 1'b0;
      hash1_started<= 1'b0;
      hash2_started<= 1'b0;
    end else begin
      mat_start <= 1'b0;

      case (pstate)
        P_IDLE: begin
          if (start) begin
            running      <= 1'b1;
            nonce_reg    <= nonce_start;
            hash_cnt     <= '0;
            pstate       <= P_HASH1;
            hash1_started<= 1'b0;
          end
        end

        P_HASH1: begin
          if (stop) begin
            pstate  <= P_IDLE;
            running <= 1'b0;
          end else begin
            // Wait for Keccak to accept input then wait for result
            if (keccak_valid && keccak_ready)
              hash1_started <= 1'b1;
            if (keccak_done && hash1_started) begin
              first_hash    <= keccak_hash;
              mat_start     <= 1'b1;
              pstate        <= P_MATRIX;
              hash1_started <= 1'b0;
            end
          end
        end

        P_MATRIX: begin
          if (stop) begin
            pstate  <= P_IDLE;
            running <= 1'b0;
          end else if (mat_done) begin
            matrix_result <= mat_hash_out;
            pstate        <= P_HASH2;
            hash2_started <= 1'b0;
          end
        end

        P_HASH2: begin
          if (stop) begin
            pstate  <= P_IDLE;
            running <= 1'b0;
          end else begin
            if (keccak_valid && keccak_ready)
              hash2_started <= 1'b1;
            if (keccak_done && hash2_started) begin
              hash_cnt      <= hash_cnt + 64'd1;
              hash2_started <= 1'b0;
              pstate        <= P_COMPARE;
            end
          end
        end

        P_COMPARE: begin
          // Compare final hash with target (unsigned LE comparison)
          // keccak_hash is still valid from last cycle
          if (keccak_hash <= target) begin
            pstate <= P_FOUND;
          end else if (stop) begin
            pstate  <= P_IDLE;
            running <= 1'b0;
          end else begin
            // Increment nonce and continue
            nonce_reg <= nonce_reg + 64'd1;
            pstate    <= P_HASH1;
          end
        end

        P_FOUND: begin
          // Stay here until software reads the result and stops
          running <= 1'b0;
          if (stop)
            pstate <= P_IDLE;
        end

        default: pstate <= P_IDLE;
      endcase
    end
  end

endmodule
