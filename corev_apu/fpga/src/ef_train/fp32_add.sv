// fp32_add.sv — Single-precision floating-point adder
//
// Combinational FP32 addition used in adder trees and BN computations.

module fp32_add (
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] result
);

  // Field extraction
  wire        a_sign = a[31],       b_sign = b[31];
  wire [7:0]  a_exp  = a[30:23],    b_exp  = b[30:23];
  wire [22:0] a_man  = a[22:0],     b_man  = b[22:0];

  // Sort by magnitude (larger = op_a)
  wire swap = (b_exp > a_exp) || (b_exp == a_exp && b_man > a_man);

  wire [31:0] op_a = swap ? b : a;
  wire [31:0] op_b = swap ? a : b;

  wire        oa_sign = op_a[31];
  wire [7:0]  oa_exp  = op_a[30:23];
  wire [23:0] oa_full = (oa_exp != 0) ? {1'b1, op_a[22:0]} : 24'd0;

  wire        ob_sign = op_b[31];
  wire [7:0]  ob_exp  = op_b[30:23];
  wire [23:0] ob_full = (ob_exp != 0) ? {1'b1, op_b[22:0]} : 24'd0;

  wire [7:0]  exp_diff = oa_exp - ob_exp;
  wire [24:0] ob_shifted = (exp_diff < 25) ? {1'b0, ob_full} >> exp_diff : 25'd0;

  wire        effective_sub = oa_sign ^ ob_sign;
  wire [25:0] sum_raw = effective_sub ?
                         {2'b0, oa_full} - {1'b0, ob_shifted} :
                         {2'b0, oa_full} + {1'b0, ob_shifted};

  wire [25:0] sum_abs = sum_raw[25] ? ~sum_raw + 1 : sum_raw;
  wire        res_sign = sum_raw[25] ? ~oa_sign : oa_sign;

  logic [4:0] lzc;
  always_comb begin
    lzc = 5'd0;
    for (int i = 25; i >= 0; i--) begin
      if (sum_abs[i]) begin
        lzc = 5'd25 - 5'(i);
        break;
      end
    end
  end

  wire [25:0] sum_norm = sum_abs << lzc;
  wire [7:0]  res_exp  = (sum_abs == 0) ? 8'd0 : oa_exp + 8'd1 - {3'd0, lzc};
  wire [22:0] res_man  = sum_norm[24:2];

  wire a_zero = (a[30:0] == 0);
  wire b_zero = (b[30:0] == 0);

  assign result = a_zero ? b :
                  b_zero ? a :
                  (sum_abs == 0) ? 32'd0 :
                  {res_sign, res_exp, res_man};

endmodule
