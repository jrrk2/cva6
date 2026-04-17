// heavyhash_matrix.sv — 64x64 matrix-vector multiply for HeavyHash
//
// Stores the mining matrix in a 64-entry BRAM (256 bits per row).
// Performs row-serial multiply: one row per cycle, 64 cycles total.
//
// Algorithm per output element:
//   acc = sum_{j=0}^{63} matrix[i][j] * vec[j]   (4-bit x 4-bit, 14-bit accum)
//   result_nibble[i] = (acc >> 10) & 0xF
//
// Final output: XOR result nibbles with input hash
//
// PIPELINING (3-stage, for 100 MHz / 10 ns timing):
//   Stage 1: 8 sub-partial sums of 8 products each (combinational, ~6-7 ns)
//   Stage 2: Combine pairs into 4 partial sums (registered + combinational, ~3 ns)
//   Stage 3: Final sum of 4 partial sums (registered + combinational, ~4 ns)
// Throughput: 1 row/cycle after 2-cycle pipeline fill.

module heavyhash_matrix
  import keccak_pkg::*,
         heavyhash_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,

  // Matrix BRAM write port (for loading matrix)
  input  logic         mat_wr_en,
  input  logic [5:0]   mat_wr_addr,
  input  logic [255:0] mat_wr_data,

  // Multiply interface
  input  logic [255:0] hash_in,       // 256-bit hash from first Keccak
  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [255:0] hash_out       // XOR'd result
);

  // ----------------------------------------------------------------
  //  Matrix BRAM: 64 entries x 256 bits
  // ----------------------------------------------------------------
  logic [255:0] matrix_mem [0:63];
  logic [255:0] mat_row;

  // Write port
  always_ff @(posedge clk) begin
    if (mat_wr_en)
      matrix_mem[mat_wr_addr] <= mat_wr_data;
  end

  // ----------------------------------------------------------------
  //  Extract 64 nibbles from hash (high-nibble-first per byte)
  // ----------------------------------------------------------------
  logic [3:0] vec [0:63];

  always_comb begin
    for (int b = 0; b < 32; b++) begin
      vec[2*b]   = hash_in[b*8+7 -: 4];  // high nibble
      vec[2*b+1] = hash_in[b*8+3 -: 4];  // low nibble
    end
  end

  // ----------------------------------------------------------------
  //  3-stage pipelined dot product
  //
  //  Stage 1 (combinational): 8 sub-partial sums of 8 products each.
  //    Each sub-sum: max = 8 * 15 * 15 = 1800, fits in 11 bits.
  //
  //  Stage 2 (registered + combinational): Combine pairs → 4 partial sums.
  //    Each partial sum: max = 3600, fits in 12 bits.
  //
  //  Stage 3 (registered + combinational): Final sum of 4 partial sums.
  //    Final sum: max = 64 * 225 = 14400, fits in ACCUM_W = 14 bits.
  // ----------------------------------------------------------------

  // Stage 1: 8 sub-partial sums of 8 products each (combinational)
  logic [10:0] spsum0, spsum1, spsum2, spsum3;
  logic [10:0] spsum4, spsum5, spsum6, spsum7;

  always_comb begin
    spsum0 = '0;
    for (int j = 0; j < 8; j++)
      spsum0 = spsum0 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum1 = '0;
    for (int j = 8; j < 16; j++)
      spsum1 = spsum1 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum2 = '0;
    for (int j = 16; j < 24; j++)
      spsum2 = spsum2 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum3 = '0;
    for (int j = 24; j < 32; j++)
      spsum3 = spsum3 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum4 = '0;
    for (int j = 32; j < 40; j++)
      spsum4 = spsum4 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum5 = '0;
    for (int j = 40; j < 48; j++)
      spsum5 = spsum5 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum6 = '0;
    for (int j = 48; j < 56; j++)
      spsum6 = spsum6 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  always_comb begin
    spsum7 = '0;
    for (int j = 56; j < 64; j++)
      spsum7 = spsum7 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
  end

  // Register stage 1 outputs
  logic [10:0] spsum0_r, spsum1_r, spsum2_r, spsum3_r;
  logic [10:0] spsum4_r, spsum5_r, spsum6_r, spsum7_r;

  always_ff @(posedge clk) begin
    spsum0_r <= spsum0;
    spsum1_r <= spsum1;
    spsum2_r <= spsum2;
    spsum3_r <= spsum3;
    spsum4_r <= spsum4;
    spsum5_r <= spsum5;
    spsum6_r <= spsum6;
    spsum7_r <= spsum7;
  end

  // Stage 2: combine pairs into 4 partial sums (combinational)
  logic [11:0] psum0, psum1, psum2, psum3;
  assign psum0 = {1'b0, spsum0_r} + {1'b0, spsum1_r};
  assign psum1 = {1'b0, spsum2_r} + {1'b0, spsum3_r};
  assign psum2 = {1'b0, spsum4_r} + {1'b0, spsum5_r};
  assign psum3 = {1'b0, spsum6_r} + {1'b0, spsum7_r};

  // Register stage 2 outputs
  logic [11:0] psum0_r, psum1_r, psum2_r, psum3_r;

  always_ff @(posedge clk) begin
    psum0_r <= psum0;
    psum1_r <= psum1;
    psum2_r <= psum2;
    psum3_r <= psum3;
  end

  // Stage 3: final sum (combinational, just 3 additions — very fast)
  logic [ACCUM_W-1:0] dot;
  assign dot = {2'b0, psum0_r} + {2'b0, psum1_r}
             + {2'b0, psum2_r} + {2'b0, psum3_r};

  // Shifted and truncated result nibble
  wire [3:0] dot_nibble = dot[13:10];

  // ----------------------------------------------------------------
  //  Row-serial multiply FSM
  //
  //  Pipeline timing (after start):
  //    Cycle 0: row_cnt=0 → BRAM read initiated
  //    Cycle 1: mat_row = row 0 data → sub-partial sums computed (comb)
  //    Cycle 2: sub-psums registered → partial sums computed (comb)
  //    Cycle 3: partial sums registered → dot valid for row 0
  //    Cycle N+3: dot valid for row N → store
  //    Cycle 66: store result_nibbles[63], done
  //
  //  We use a 'pipe_cnt' that counts from 0 to 66:
  //    pipe_cnt 0:     start → read row 0
  //    pipe_cnt 1:     read row 1, sub-psums for row 0
  //    pipe_cnt 2:     read row 2, psums for row 0, sub-psums for row 1
  //    pipe_cnt 3:     dot valid for row 0 → store
  //    pipe_cnt N+3:   dot valid for row N → store
  //    pipe_cnt 66:    dot valid for row 63 → store, signal done
  // ----------------------------------------------------------------
  logic [6:0]   pipe_cnt;
  logic         running;
  logic [3:0]   result_nibbles [0:63];

  assign busy = running;

  // BRAM read: address is pipe_cnt for the first 64 cycles
  always_ff @(posedge clk) begin
    if (pipe_cnt < 7'd64)
      mat_row <= matrix_mem[pipe_cnt[5:0]];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      running   <= 1'b0;
      done      <= 1'b0;
      pipe_cnt  <= '0;
    end else begin
      done <= 1'b0;

      if (start && !running) begin
        running  <= 1'b1;
        pipe_cnt <= 7'd0;
      end else if (running) begin
        // Store result nibble when dot is valid (pipe_cnt >= 3)
        if (pipe_cnt >= 7'd3)
          result_nibbles[pipe_cnt - 7'd3] <= dot_nibble;

        if (pipe_cnt == 7'd66) begin
          // All 64 results stored (rows 0-63 at pipe_cnt 3-66)
          running <= 1'b0;
          done    <= 1'b1;
          pipe_cnt <= '0;
        end else begin
          pipe_cnt <= pipe_cnt + 7'd1;
        end
      end
    end
  end

  // ----------------------------------------------------------------
  //  Pack result nibbles and XOR with input hash
  // ----------------------------------------------------------------
  logic [255:0] result_packed;

  always_comb begin
    result_packed = '0;
    for (int b = 0; b < 32; b++) begin
      result_packed[b*8+7 -: 4] = result_nibbles[2*b];
      result_packed[b*8+3 -: 4] = result_nibbles[2*b+1];
    end
  end

  assign hash_out = hash_in ^ result_packed;

endmodule
