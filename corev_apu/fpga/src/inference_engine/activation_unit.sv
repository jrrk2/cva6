// activation_unit.sv — Configurable activation function unit
//
// Supports: None, ReLU, Sigmoid (piecewise-linear), ReLU6
// Operates on INT32 accumulator values, outputs INT8 with saturation
//
// Sigmoid approximation (5-segment piecewise linear):
//   x <= -5.0  -> 0
//   -5 < x < 0 -> linear interpolation
//   x == 0     -> 128 (0.5 in Q0.8)
//   0 < x < 5  -> linear interpolation
//   x >= 5.0   -> 255
//
// The accumulator value is treated as Q24.8 fixed point (8 fractional bits)

module activation_unit
  import inference_pkg::*;
#(
  parameter int unsigned NUM_UNITS = ARRAY_COLS  // parallel activation lanes
) (
  input  logic                           clk,
  input  logic                           rst_n,

  input  logic                           valid_in,
  input  act_fn_e                        fn_sel,

  // Accumulator inputs (after bias add)
  input  logic signed [ACC_WIDTH-1:0]    data_in  [NUM_UNITS],

  // Activated INT8 outputs
  output logic        [DATA_WIDTH-1:0]   data_out [NUM_UNITS],
  output logic                           valid_out
);

  // Pipeline: 1 cycle latency
  logic [DATA_WIDTH-1:0] result [NUM_UNITS];
  logic                  valid_q;

  // Intermediate signals for activation computation (hoisted from always_ff)
  logic signed [ACC_WIDTH-1:0] sigmoid_scaled [NUM_UNITS];
  logic signed [ACC_WIDTH-1:0] sigmoid_shifted [NUM_UNITS];
  logic        [ACC_WIDTH-1:0] relu6_scaled [NUM_UNITS];

  always_comb begin
    for (int i = 0; i < NUM_UNITS; i++) begin
      sigmoid_scaled[i]  = (data_in[i] * 25) >>> FRAC_BITS;
      sigmoid_shifted[i] = 128 + sigmoid_scaled[i];
      relu6_scaled[i]    = (data_in[i] * 43) >>> FRAC_BITS;
    end
  end

  // Fixed-point scaling: accumulator is in Q24.8
  // Output INT8 range: 0..255 (unsigned) or -128..127 (signed)
  // We use unsigned output for activation results

  localparam int FRAC_BITS = 8;  // fractional bits in accumulator
  // Sigmoid breakpoints in Q24.8 (x * 256)
  localparam int signed SIGMOID_MIN = -5 * (1 << FRAC_BITS);  // -1280
  localparam int signed SIGMOID_MAX =  5 * (1 << FRAC_BITS);  //  1280
  // ReLU6 max in Q24.8
  localparam int signed RELU6_MAX   =  6 * (1 << FRAC_BITS);  //  1536

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      for (int i = 0; i < NUM_UNITS; i++)
        result[i] <= '0;
    end else begin
      valid_q <= valid_in;
      for (int i = 0; i < NUM_UNITS; i++) begin
        case (fn_sel)
          ACT_NONE: begin
            // Saturate Q24.8 to unsigned 8-bit (shift right by FRAC_BITS)
            if (data_in[i] < 0)
              result[i] <= 8'd0;
            else if (data_in[i][ACC_WIDTH-1:FRAC_BITS] > 255)
              result[i] <= 8'd255;
            else
              result[i] <= data_in[i][FRAC_BITS +: DATA_WIDTH];
          end

          ACT_RELU: begin
            if (data_in[i] <= 0)
              result[i] <= 8'd0;
            else if (data_in[i][ACC_WIDTH-1:FRAC_BITS] > 255)
              result[i] <= 8'd255;
            else
              result[i] <= data_in[i][FRAC_BITS +: DATA_WIDTH];
          end

          ACT_SIGMOID: begin
            if (data_in[i] <= SIGMOID_MIN)
              result[i] <= 8'd0;
            else if (data_in[i] >= SIGMOID_MAX)
              result[i] <= 8'd255;
            else begin
              // Linear approximation: y = 128 + (x * 25) >> 8
              // Slope ~0.1 maps [-5,5] -> [0,255]
              if (sigmoid_shifted[i] < 0)
                result[i] <= 8'd0;
              else if (sigmoid_shifted[i] > 255)
                result[i] <= 8'd255;
              else
                result[i] <= sigmoid_shifted[i][7:0];
            end
          end

          ACT_RELU6: begin
            if (data_in[i] <= 0)
              result[i] <= 8'd0;
            else if (data_in[i] >= RELU6_MAX)
              // Scale 6.0 to 255 (6 * 256/6 ≈ 255)
              result[i] <= 8'd255;
            else begin
              // Scale [0, 6] to [0, 255]: y = x * 255 / 6 ≈ x * 43 >> 8
              if (relu6_scaled[i] > 255)
                result[i] <= 8'd255;
              else
                result[i] <= relu6_scaled[i][7:0];
            end
          end

          default:
            result[i] <= 8'd0;
        endcase
      end
    end
  end

  assign data_out  = result;
  assign valid_out = valid_q;

endmodule
