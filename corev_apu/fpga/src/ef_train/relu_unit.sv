// relu_unit.sv — ReLU activation unit (Eq. 3 in EF-Train paper)
//
// FP mode:  Y = max(0, X)
// BP mode:  dX = dY if X > 0, else 0
//
// Combinational — inserted inline in the datapath.

module relu_unit
  import ef_train_pkg::*;
(
  input  op_mode_e              mode,
  input  logic [DATA_WIDTH-1:0] x_in,     // activation (FP) or original activation (BP)
  input  logic [DATA_WIDTH-1:0] dy_in,    // upstream gradient (BP mode only)
  output logic [DATA_WIDTH-1:0] y_out
);

  // FP32: positive if sign bit = 0 and not zero
  wire x_positive = !x_in[31] && (x_in[30:0] != 0);

  always_comb begin
    case (mode)
      MODE_FP: y_out = x_positive ? x_in : 32'd0;
      MODE_BP: y_out = x_positive ? dy_in : 32'd0;
      default: y_out = x_in;
    endcase
  end

endmodule
