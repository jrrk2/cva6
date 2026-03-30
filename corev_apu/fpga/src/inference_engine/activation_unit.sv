// activation_unit.sv — Configurable activation function unit
//
// Supports: None, ReLU, Sigmoid (piecewise-linear), ReLU6
// Operates on INT48 accumulator values, outputs INT16 with saturation
//
// Sigmoid approximation (5-segment piecewise linear):
//   x <= -5.0  -> 0
//   -5 < x < 0 -> linear interpolation
//   x == 0     -> DATA_MID (0.5 in Q0.DATA_WIDTH)
//   0 < x < 5  -> linear interpolation
//   x >= 5.0   -> DATA_MAX
//
// The accumulator value is treated as Q{ACC-FRAC}.FRAC fixed point

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

  // Activated INT16 outputs
  output logic        [DATA_WIDTH-1:0]   data_out [NUM_UNITS],
  output logic                           valid_out
);

  // Pipeline: 1 cycle latency
  logic [DATA_WIDTH-1:0] result [NUM_UNITS];
  logic                  valid_q;

  // Fixed-point shift: accumulator Q{ACC-FRAC}.FRAC → integer output
  localparam int FRAC_BITS  = 16;
  // Output saturation bounds
  localparam int DATA_MAX   = (1 << DATA_WIDTH) - 1;  // 65535
  localparam int DATA_MID   = 1 << (DATA_WIDTH - 1);  // 32768

  // Sigmoid breakpoints in Q{ACC-FRAC}.FRAC
  localparam int signed SIGMOID_MIN = -5 * (1 << FRAC_BITS);  // -327680
  localparam int signed SIGMOID_MAX =  5 * (1 << FRAC_BITS);  //  327680
  // ReLU6 max in Q{ACC-FRAC}.FRAC
  localparam int signed RELU6_MAX   =  6 * (1 << FRAC_BITS);  //  393216

  // Sigmoid slope: maps ±5 → ±DATA_MID (DATA_MID/5 = 6553 for INT16)
  localparam int SIGMOID_SLOPE = DATA_MID / 5;
  // ReLU6 slope: maps [0,6] → [0,DATA_MAX] (DATA_MAX/6 = 10922 for INT16)
  localparam int RELU6_SLOPE   = DATA_MAX / 6;

  // Intermediate signals for activation computation (hoisted from always_ff)
  logic signed [ACC_WIDTH-1:0] sigmoid_scaled [NUM_UNITS];
  logic signed [ACC_WIDTH-1:0] sigmoid_shifted [NUM_UNITS];
  logic        [ACC_WIDTH-1:0] relu6_scaled [NUM_UNITS];

  always_comb begin
    for (int i = 0; i < NUM_UNITS; i++) begin
      sigmoid_scaled[i]  = (data_in[i] * SIGMOID_SLOPE) >>> FRAC_BITS;
      sigmoid_shifted[i] = DATA_MID + sigmoid_scaled[i];
      relu6_scaled[i]    = (data_in[i] * RELU6_SLOPE) >>> FRAC_BITS;
    end
  end

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
            // Saturate Q{ACC-FRAC}.FRAC to unsigned DATA_WIDTH-bit (shift right by FRAC_BITS)
            if (data_in[i] < 0)
              result[i] <= '0;
            else if (data_in[i][ACC_WIDTH-1:FRAC_BITS] > DATA_MAX)
              result[i] <= DATA_WIDTH'(DATA_MAX);
            else
              result[i] <= data_in[i][FRAC_BITS +: DATA_WIDTH];
          end

          ACT_RELU: begin
            if (data_in[i] <= 0)
              result[i] <= '0;
            else if (data_in[i][ACC_WIDTH-1:FRAC_BITS] > DATA_MAX)
              result[i] <= DATA_WIDTH'(DATA_MAX);
            else
              result[i] <= data_in[i][FRAC_BITS +: DATA_WIDTH];
          end

          ACT_SIGMOID: begin
            if (data_in[i] <= SIGMOID_MIN)
              result[i] <= '0;
            else if (data_in[i] >= SIGMOID_MAX)
              result[i] <= DATA_WIDTH'(DATA_MAX);
            else begin
              // Linear approximation: y = DATA_MID + (x * SIGMOID_SLOPE) >> FRAC_BITS
              if (sigmoid_shifted[i] < 0)
                result[i] <= '0;
              else if (sigmoid_shifted[i] > DATA_MAX)
                result[i] <= DATA_WIDTH'(DATA_MAX);
              else
                result[i] <= sigmoid_shifted[i][DATA_WIDTH-1:0];
            end
          end

          ACT_RELU6: begin
            if (data_in[i] <= 0)
              result[i] <= '0;
            else if (data_in[i] >= RELU6_MAX)
              result[i] <= DATA_WIDTH'(DATA_MAX);
            else begin
              // Scale [0, 6] to [0, DATA_MAX]: y = x * RELU6_SLOPE >> FRAC_BITS
              if (relu6_scaled[i] > DATA_MAX)
                result[i] <= DATA_WIDTH'(DATA_MAX);
              else
                result[i] <= relu6_scaled[i][DATA_WIDTH-1:0];
            end
          end

          default:
            result[i] <= '0;
        endcase
      end
    end
  end

  assign data_out  = result;
  assign valid_out = valid_q;

endmodule
