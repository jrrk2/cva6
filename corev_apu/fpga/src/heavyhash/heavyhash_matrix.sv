// heavyhash_matrix.sv — 64x64 matrix-vector multiply for HeavyHash
//
// Dual-port BRAM: reads 2 rows/cycle (even on port A, odd on port B).
// DSP48-packed multiplies: 2 products per DSP using nibble packing.
//   Pack: A = {nib1, 6'b0, nib0}, B = {vec1, 6'b0, vec0}
//   Product[7:0] = nib0*vec0, Product[27:20] = nib1*vec1
//   Guard bands prevent cross-term contamination (max product=225 < 256).
//
// 4-stage dot-product pipeline per port:
//   Stage 1 (registered): 32 DSP multiplies → 64 products
//   Stage 2 (comb + reg): 8 sub-partial sums of 8 products each
//   Stage 3 (comb + reg): 4 partial sums (pairs)
//   Stage 4 (comb):       final 14-bit dot product
//
// Total: 32 row-pairs + 4 pipeline fill = 36 cycles.
// Resources per lane: 64 DSP48E1 (32 per port), ~500 LUTs (adder trees).

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
  //  Matrix BRAM: 64 entries x 256 bits, true dual-port read
  // ----------------------------------------------------------------
  logic [255:0] matrix_mem [0:63];
  logic [255:0] mat_row_a;   // even row data
  logic [255:0] mat_row_b;   // odd row data

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

  // ================================================================
  //  DSP-packed dot product — Port A (even rows)
  //
  //  32 DSPs, each computing 2 products via nibble packing.
  //  DSP d handles matrix nibbles [2d] and [2d+1] × vec[2d] and [2d+1].
  //  Sub-partial sum k uses DSPs [4k..4k+3] (8 products).
  // ================================================================

  // Stage 1: DSP multiplies (registered — maps to DSP48E1 MREG)
  (* use_dsp = "yes" *)
  logic [27:0] dsp_a [0:31];

  always_ff @(posedge clk) begin
    for (int d = 0; d < 32; d++)
      dsp_a[d] <= {14'b0, mat_row_a[(2*d+1)*4+3 -: 4], 6'b0, mat_row_a[(2*d)*4+3 -: 4]}
                * {14'b0, vec[2*d+1], 6'b0, vec[2*d]};
  end

  // Stage 2: sub-partial sums — 8 groups of 4 DSPs (combinational)
  logic [10:0] a_spsum [0:7];

  always_comb begin
    for (int k = 0; k < 8; k++) begin
      a_spsum[k] = '0;
      for (int i = 0; i < 4; i++)
        a_spsum[k] = a_spsum[k] + {3'b0, dsp_a[4*k+i][7:0]}
                                 + {3'b0, dsp_a[4*k+i][27:20]};
    end
  end

  // Register stage 2
  logic [10:0] a_spsum_r [0:7];
  always_ff @(posedge clk)
    for (int k = 0; k < 8; k++)
      a_spsum_r[k] <= a_spsum[k];

  // Stage 3: partial sums — combine pairs (combinational)
  logic [11:0] a_psum [0:3];
  always_comb
    for (int k = 0; k < 4; k++)
      a_psum[k] = {1'b0, a_spsum_r[2*k]} + {1'b0, a_spsum_r[2*k+1]};

  // Register stage 3
  logic [11:0] a_psum_r [0:3];
  always_ff @(posedge clk)
    for (int k = 0; k < 4; k++)
      a_psum_r[k] <= a_psum[k];

  // Stage 4: final sum (combinational)
  logic [ACCUM_W-1:0] dot_a;
  assign dot_a = {2'b0, a_psum_r[0]} + {2'b0, a_psum_r[1]}
               + {2'b0, a_psum_r[2]} + {2'b0, a_psum_r[3]};
  wire [3:0] dot_nibble_a = dot_a[13:10];

  // ================================================================
  //  DSP-packed dot product — Port B (odd rows)
  // ================================================================

  (* use_dsp = "yes" *)
  logic [27:0] dsp_b [0:31];

  always_ff @(posedge clk) begin
    for (int d = 0; d < 32; d++)
      dsp_b[d] <= {14'b0, mat_row_b[(2*d+1)*4+3 -: 4], 6'b0, mat_row_b[(2*d)*4+3 -: 4]}
                * {14'b0, vec[2*d+1], 6'b0, vec[2*d]};
  end

  logic [10:0] b_spsum [0:7];
  always_comb begin
    for (int k = 0; k < 8; k++) begin
      b_spsum[k] = '0;
      for (int i = 0; i < 4; i++)
        b_spsum[k] = b_spsum[k] + {3'b0, dsp_b[4*k+i][7:0]}
                                 + {3'b0, dsp_b[4*k+i][27:20]};
    end
  end

  logic [10:0] b_spsum_r [0:7];
  always_ff @(posedge clk)
    for (int k = 0; k < 8; k++)
      b_spsum_r[k] <= b_spsum[k];

  logic [11:0] b_psum [0:3];
  always_comb
    for (int k = 0; k < 4; k++)
      b_psum[k] = {1'b0, b_spsum_r[2*k]} + {1'b0, b_spsum_r[2*k+1]};

  logic [11:0] b_psum_r [0:3];
  always_ff @(posedge clk)
    for (int k = 0; k < 4; k++)
      b_psum_r[k] <= b_psum[k];

  logic [ACCUM_W-1:0] dot_b;
  assign dot_b = {2'b0, b_psum_r[0]} + {2'b0, b_psum_r[1]}
               + {2'b0, b_psum_r[2]} + {2'b0, b_psum_r[3]};
  wire [3:0] dot_nibble_b = dot_b[13:10];

  // ================================================================
  //  Row-serial multiply FSM (2 rows per cycle, 4-stage pipeline)
  //
  //  pipe_cnt 0:     read rows 0,1
  //  pipe_cnt 1:     BRAM data available, DSP inputs packed
  //  pipe_cnt 2:     DSP products registered, sub-partial sums (comb)
  //  pipe_cnt 3:     sub-psums registered, partial sums (comb)
  //  pipe_cnt 4:     partial sums registered, dot valid rows 0,1 → store
  //  pipe_cnt N+4:   dot valid rows 2N, 2N+1 → store
  //  pipe_cnt 35:    dot valid rows 62,63 → store, done
  // ================================================================
  logic [5:0]   pipe_cnt;
  logic         running;
  logic [3:0]   result_nibbles [0:63];

  assign busy = running;

  // Dual-port BRAM read: port A = even row, port B = odd row
  always_ff @(posedge clk) begin
    if (pipe_cnt < 6'd32) begin
      mat_row_a <= matrix_mem[{pipe_cnt[4:0], 1'b0}];   // row 2N
      mat_row_b <= matrix_mem[{pipe_cnt[4:0], 1'b1}];   // row 2N+1
    end
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
        pipe_cnt <= 6'd0;
      end else if (running) begin
        // Store result nibbles when dots are valid (pipe_cnt >= 4)
        if (pipe_cnt >= 6'd4) begin
          result_nibbles[{(pipe_cnt[4:0] - 5'd4), 1'b0}] <= dot_nibble_a;  // even row
          result_nibbles[{(pipe_cnt[4:0] - 5'd4), 1'b1}] <= dot_nibble_b;  // odd row
        end

        if (pipe_cnt == 6'd35) begin
          // All 64 results stored (row pairs 0..31 at pipe_cnt 4..35)
          running <= 1'b0;
          done    <= 1'b1;
          pipe_cnt <= '0;
        end else begin
          pipe_cnt <= pipe_cnt + 6'd1;
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
