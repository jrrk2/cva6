// conv_kernel.sv — Unified Convolution Kernel (Fig. 4 in EF-Train paper)
//
// Implements the PE array with Tm×Tn PEs and TM adder trees.
// Supports three modes via connection switching:
//
//   Mode 1 (FP/BP): PE[tm][tn] computes weight[tn] × ifm[tn,spatial]
//                    Adder tree reduces across Tn → ofm[tm]
//                    (Eq. 1 for FP, Eq. 2 for BP with flipped weights)
//
//   Mode 2 (WU):    PE[tm][tn] computes loss[tm] × activation[tn]
//                    Each PE accumulates dW[tm,tn] independently across spatial
//                    (Eq. 4: dW = Σ_spatial loss × activation)
//
// The layer controller iterates over channel tiles and spatial positions.

module conv_kernel
  import ef_train_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Control
  input  op_mode_e    mode,       // FP, BP, or WU
  input  logic        clear_acc,  // clear PE accumulators
  input  logic        compute_en, // enable MAC computation

  // Data inputs — Tn values broadcast along one axis, Tm along the other
  input  logic [DATA_WIDTH-1:0] a_bus [TN],  // FP/BP: weights; WU: activations
  input  logic [DATA_WIDTH-1:0] b_bus [TM],  // FP/BP: ifm;     WU: loss gradients

  // Outputs
  // FP/BP mode: TM reduced sums (one per output channel tile)
  output logic [DATA_WIDTH-1:0] ofm_out [TM],
  output logic                  ofm_valid,

  // WU mode: TM×TN weight gradients (read out after spatial accumulation)
  output logic [DATA_WIDTH-1:0] dw_out [TM][TN],
  output logic                  dw_valid
);

  // ================================================================
  //  PE array: TM rows × TN columns
  // ================================================================
  logic [ACC_WIDTH-1:0] pe_acc [TM][TN];

  genvar tm, tn;
  generate
    for (tm = 0; tm < TM; tm++) begin : gen_row
      for (tn = 0; tn < TN; tn++) begin : gen_col
        pe_cell u_pe (
          .clk     (clk),
          .rst_n   (rst_n),
          .clear   (clear_acc),
          .enable  (compute_en),
          .a_in    (a_bus[tn]),    // weight (FP/BP) or activation (WU)
          .b_in    (b_bus[tm]),    // ifm (FP/BP)    or loss (WU)
          .acc_out (pe_acc[tm][tn])
        );
      end
    end
  endgenerate

  // ================================================================
  //  Adder trees — one per output channel (Tm trees, each sums Tn inputs)
  //  Used in FP/BP mode to reduce partial products across input channels
  // ================================================================
  logic [DATA_WIDTH-1:0] tree_inputs [TM][TN];
  logic [DATA_WIDTH-1:0] tree_sums   [TM];
  logic                  tree_valid   [TM];

  generate
    for (tm = 0; tm < TM; tm++) begin : gen_tree

      // Feed PE accumulators into adder tree
      for (tn = 0; tn < TN; tn++) begin : gen_tree_in
        assign tree_inputs[tm][tn] = pe_acc[tm][tn];
      end

      adder_tree #(.NUM_INPUTS(TN)) u_tree (
        .clk       (clk),
        .rst_n     (rst_n),
        .enable    (compute_en && (mode == MODE_FP || mode == MODE_BP)),
        .data_in   (tree_inputs[tm]),
        .sum_out   (tree_sums[tm]),
        .valid_out (tree_valid[tm])
      );
    end
  endgenerate

  // ================================================================
  //  Output muxing
  // ================================================================
  // FP/BP: adder tree outputs
  always_comb begin
    for (int m = 0; m < TM; m++)
      ofm_out[m] = tree_sums[m];
  end
  assign ofm_valid = tree_valid[0];

  // WU: raw PE accumulators are the weight gradients
  always_comb begin
    for (int m = 0; m < TM; m++)
      for (int n = 0; n < TN; n++)
        dw_out[m][n] = pe_acc[m][n];
  end

  // dw_valid is asserted by the controller after all spatial positions are accumulated
  assign dw_valid = 1'b0;  // driven externally by layer controller

endmodule
