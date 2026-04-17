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
// PIPELINING: The dot product is split into 4 partial sums of 16 products
// each (combinational), registered, then combined in the following cycle.
// This breaks the critical path from ~42 ns to ~12 ns, fixing timing at 50 MHz.
// Throughput remains 1 row/cycle after a 1-cycle pipeline fill.

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
  //  Pipelined dot product
  //
  //  Stage 1 (combinational): Compute 4 partial sums of 16 products each.
  //  Stage 2 (registered):    Sum the 4 partial sums → final dot product.
  //
  //  Each partial sum: max = 16 * 15 * 15 = 3600, fits in 12 bits.
  //  Final sum: max = 64 * 225 = 14400, fits in ACCUM_W = 14 bits.
  // ----------------------------------------------------------------

  // Stage 1: four 16-element partial sums (combinational)
  logic [11:0] psum0, psum1, psum2, psum3;

  always_comb begin
    psum0 = '0;
    for (int j = 0; j < 16; j++) begin
      psum0 = psum0 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
    end
  end

  always_comb begin
    psum1 = '0;
    for (int j = 16; j < 32; j++) begin
      psum1 = psum1 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
    end
  end

  always_comb begin
    psum2 = '0;
    for (int j = 32; j < 48; j++) begin
      psum2 = psum2 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
    end
  end

  always_comb begin
    psum3 = '0;
    for (int j = 48; j < 64; j++) begin
      psum3 = psum3 + {4'b0, mat_row[j*4+3 -: 4]} * {4'b0, vec[j]};
    end
  end

  // Register the partial sums
  logic [11:0] psum0_r, psum1_r, psum2_r, psum3_r;

  always_ff @(posedge clk) begin
    psum0_r <= psum0;
    psum1_r <= psum1;
    psum2_r <= psum2;
    psum3_r <= psum3;
  end

  // Stage 2: final sum (combinational, just 3 additions — very fast)
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
  //    Cycle 1: mat_row = row 0 data → partial sums computed (comb)
  //    Cycle 2: psum*_r registered → dot valid for row 0
  //             Also: mat_row = row 1 data → partial sums for row 1
  //    Cycle 3: store result_nibbles[0], dot valid for row 1
  //    ...
  //    Cycle N+2: store result_nibbles[N], dot valid for row N+1
  //    Cycle 65: store result_nibbles[63], done
  //
  //  We use a 'pipe_cnt' that counts from 0 to 66:
  //    pipe_cnt 0:     start → read row 0
  //    pipe_cnt 1:     read row 1, partial sums for row 0
  //    pipe_cnt 2:     read row 2, partial sums for row 1, dot valid for row 0 → store
  //    pipe_cnt N+2:   dot valid for row N → store
  //    pipe_cnt 65:    dot valid for row 63 → store, signal done
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
        // Store result nibble when dot is valid (pipe_cnt >= 2)
        if (pipe_cnt >= 7'd2)
          result_nibbles[pipe_cnt - 7'd2] <= dot_nibble;

        if (pipe_cnt == 7'd65) begin
          // All 64 results stored (rows 0-63 at pipe_cnt 2-65)
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
