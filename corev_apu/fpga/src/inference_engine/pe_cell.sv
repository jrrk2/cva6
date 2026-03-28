// pe_cell.sv — Single processing element for the systolic array
// Performs: acc += weight * activation (MAC)
// Maps to one DSP48E1 slice on Virtex-7
//
// Data flows:
//   - Weights flow downward  (w_in -> w_out, 1-cycle latency)
//   - Activations flow right (a_in -> a_out, 1-cycle latency)
//   - Accumulator is local, cleared by `acc_clear`
//
// Note: DSP48E1 only supports synchronous reset, so this module uses
// synchronous reset to ensure proper DSP inference.

module pe_cell
  import inference_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // Control
  input  logic                    enable,      // MAC enable
  input  logic                    acc_clear,   // clear accumulator

  // Weight input (flows down)
  input  logic signed [DATA_WIDTH-1:0] w_in,
  output logic signed [DATA_WIDTH-1:0] w_out,

  // Activation input (flows right)
  input  logic signed [DATA_WIDTH-1:0] a_in,
  output logic signed [DATA_WIDTH-1:0] a_out,

  // Accumulated result
  output logic signed [ACC_WIDTH-1:0]  acc_out
);

  // Pipeline registers for systolic data flow
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w_out <= '0;
      a_out <= '0;
    end else if (enable) begin
      w_out <= w_in;
      a_out <= a_in;
    end
  end

  // MAC accumulator — DSP48E1 inference requires synchronous reset
  // DSP48E1 primitive: 25x18 multiplier + 48-bit accumulator
  (* use_dsp = "yes" *)
  logic signed [ACC_WIDTH-1:0] acc_q;

  always_ff @(posedge clk) begin
    if (!rst_n || acc_clear) begin
      acc_q <= '0;
    end else if (enable) begin
      acc_q <= acc_q + (w_in * a_in);
    end
  end

  assign acc_out = acc_q;

endmodule
