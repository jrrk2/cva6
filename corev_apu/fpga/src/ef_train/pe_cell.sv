// pe_cell.sv — Processing Element for EF-Train Conv Kernel
//
// Each PE performs one FP32 MAC per cycle.
// Supports two connection modes (Fig. 4 in paper):
//   Mode 1 (FP/BP): weight[tn] × ifm[tm] → accumulate into ofm[tm]
//   Mode 2 (WU):    activation[tn] × loss[tm] → accumulate into dW[tm,tn]
//
// The PE itself is agnostic to the mode — it just multiplies a×b and accumulates.

module pe_cell
  import ef_train_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic        clear,     // clear accumulator
  input  logic        enable,    // compute enable

  input  logic [DATA_WIDTH-1:0] a_in,   // multiplicand (broadcast along row)
  input  logic [DATA_WIDTH-1:0] b_in,   // multiplier   (broadcast along column)

  output logic [ACC_WIDTH-1:0]  acc_out  // accumulated result
);

  logic [ACC_WIDTH-1:0] acc_q;

  wire [ACC_WIDTH-1:0] mac_result;

  fp32_mac u_mac (
    .a      (a_in),
    .b      (b_in),
    .acc_in (acc_q),
    .result (mac_result)
  );

  always_ff @(posedge clk) begin
    if (!rst_n || clear)
      acc_q <= '0;
    else if (enable)
      acc_q <= mac_result;
  end

  assign acc_out = acc_q;

endmodule
