// fp32_mac.sv — Single-precision floating-point multiply-accumulate
//
// Wraps a DSP-friendly FP32 multiply followed by FP32 add for accumulation.
// On Xilinx, synthesis infers DSP48E2 slices for the multiplier.
// This is a combinational module; pipelining is handled externally.

module fp32_mac (
  input  logic [31:0] a,       // multiplicand (feature or activation)
  input  logic [31:0] b,       // multiplier   (weight or loss)
  input  logic [31:0] acc_in,  // accumulator input
  output logic [31:0] result   // acc_in + a*b
);

  // ---- IEEE 754 field extraction ----
  wire        a_sign = a[31],       b_sign = b[31],       acc_sign = acc_in[31];
  wire [7:0]  a_exp  = a[30:23],    b_exp  = b[30:23],    acc_exp  = acc_in[30:23];
  wire [22:0] a_man  = a[22:0],     b_man  = b[22:0],     acc_man  = acc_in[22:0];

  // ---- Multiplication ----
  wire        prod_sign = a_sign ^ b_sign;
  wire [8:0]  prod_exp_raw = {1'b0, a_exp} + {1'b0, b_exp} - 9'd127;

  // Implicit leading 1 for normalized numbers
  wire [23:0] a_full = (a_exp != 0) ? {1'b1, a_man} : 24'd0;
  wire [23:0] b_full = (b_exp != 0) ? {1'b1, b_man} : 24'd0;

  wire [47:0] prod_man_full = a_full * b_full;  // 24×24 = 48-bit result

  // Normalize product mantissa
  wire        prod_man_msb = prod_man_full[47];
  wire [22:0] prod_man = prod_man_msb ? prod_man_full[46:24] : prod_man_full[45:23];
  wire [8:0]  prod_exp = (a_exp == 0 || b_exp == 0) ? 9'd0 :
                          prod_man_msb ? prod_exp_raw + 9'd1 : prod_exp_raw;

  wire [31:0] product = (a_exp == 0 || b_exp == 0) ? 32'd0 :
                         {prod_sign, prod_exp[7:0], prod_man};

  // ---- Addition (product + acc_in) ----
  // Simplified FP32 add — sufficient for training accuracy
  wire [31:0] op_a, op_b;
  wire        swap = (acc_exp > prod_exp[7:0]) ||
                     (acc_exp == prod_exp[7:0] && acc_man > prod_man);

  assign op_a = swap ? acc_in : product;  // larger magnitude
  assign op_b = swap ? product : acc_in;  // smaller magnitude

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
                         {1'b0, 1'b0, oa_full} - {1'b0, ob_shifted} :
                         {1'b0, 1'b0, oa_full} + {1'b0, ob_shifted};

  // Leading-zero count for normalization (simplified — check top bits)
  wire [25:0] sum_abs = sum_raw[25] ? ~sum_raw + 1 : sum_raw;  // handle negative
  wire        res_sign = sum_raw[25] ? ~oa_sign : oa_sign;

  // Find leading one position
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
  wire [7:0]  res_exp  = (sum_abs == 0) ? 8'd0 :
                          (sum_norm[25]) ? oa_exp + 8'd1 - lzc[7:0] :
                                           oa_exp - lzc[7:0];
  wire [22:0] res_man  = sum_norm[24:2];  // take top 23 bits after leading 1

  // Handle special cases
  wire a_zero   = (a[30:0] == 0);
  wire b_zero   = (b[30:0] == 0);
  wire acc_zero = (acc_in[30:0] == 0);

  assign result = (a_zero || b_zero) ? acc_in :
                  acc_zero            ? product :
                  (sum_abs == 0)      ? 32'd0 :
                  {res_sign, res_exp, res_man};

endmodule
