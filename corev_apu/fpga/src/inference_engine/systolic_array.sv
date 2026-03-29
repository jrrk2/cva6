// systolic_array.sv — 16x16 weight-stationary systolic array
//
// Architecture:
//   - Weights are pre-loaded into PE accumulators row by row
//   - Activations stream left-to-right with skewed injection
//   - After K cycles (input dimension), accumulators hold the dot products
//   - Results are read out column by column
//
// Resource estimate (16x16):
//   - 256 DSP48E1 (9.1% of 2,800 on xc7vx485t)
//   - ~4K FFs for pipeline registers

module systolic_array
  import inference_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // Control
  input  logic                          enable,
  input  logic                          acc_clear,

  // Weight loading: one column of weights per cycle, row-broadcast
  input  logic signed [DATA_WIDTH-1:0]  w_in  [ARRAY_ROWS],

  // Activation input: one row of activations per cycle, column-broadcast
  input  logic signed [DATA_WIDTH-1:0]  a_in  [ARRAY_COLS],

  // Result readout: full row of accumulators
  input  logic [$clog2(ARRAY_ROWS)-1:0] result_row_sel,
  output logic signed [ACC_WIDTH-1:0]   result_out [ARRAY_COLS]
);

  // Accumulator array
  logic signed [ACC_WIDTH-1:0] acc [ARRAY_ROWS][ARRAY_COLS];

  // Broadcast PE grid — each PE receives w_in[col] and a_in[row] directly.
  // This avoids the systolic propagation delay that would misalign weight and
  // activation indices for any PE not on the top/left edge.
  genvar gr, gc;
  generate
    for (gr = 0; gr < ARRAY_ROWS; gr++) begin : gen_row
      for (gc = 0; gc < ARRAY_COLS; gc++) begin : gen_col
        pe_cell u_pe (
          .clk       (clk),
          .rst_n     (rst_n),
          .enable    (enable),
          .acc_clear (acc_clear),
          .w_in      (w_in[gc]),
          .w_out     (),
          .a_in      (a_in[gr]),
          .a_out     (),
          .acc_out   (acc[gr][gc])
        );
      end
    end
  endgenerate

  // Output mux: select one row of results at a time
  always_comb begin
    for (int c = 0; c < ARRAY_COLS; c++) begin
      result_out[c] = acc[result_row_sel][c];
    end
  end

endmodule
