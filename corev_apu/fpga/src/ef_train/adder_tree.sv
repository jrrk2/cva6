// adder_tree.sv — Parameterized FP32 adder tree for partial-sum reduction
//
// Reduces TN partial products to a single sum for each output channel.
// Used in FP and BP modes where we sum across input channels (Tn dimension).
// log2(TN) pipeline stages.

module adder_tree
  import ef_train_pkg::*;
#(
  parameter int unsigned NUM_INPUTS = TN
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,

  input  logic [DATA_WIDTH-1:0] data_in [NUM_INPUTS],
  output logic [DATA_WIDTH-1:0] sum_out,
  output logic                  valid_out
);

  localparam int unsigned STAGES = $clog2(NUM_INPUTS);

  // Pipeline registers for each stage
  // Stage s has NUM_INPUTS / 2^(s+1) elements
  logic [DATA_WIDTH-1:0] stage_data [STAGES+1][NUM_INPUTS];
  logic [STAGES:0]       stage_valid;

  // Input stage
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stage_valid[0] <= 1'b0;
    end else begin
      stage_valid[0] <= enable;
      for (int i = 0; i < NUM_INPUTS; i++)
        stage_data[0][i] <= data_in[i];
    end
  end

  // Generate reduction stages
  genvar s, i;
  generate
    for (s = 0; s < STAGES; s++) begin : gen_stage
      localparam int unsigned PAIRS = NUM_INPUTS >> (s + 1);

      for (i = 0; i < PAIRS; i++) begin : gen_adder
        wire [DATA_WIDTH-1:0] add_result;

        fp32_add u_add (
          .a      (stage_data[s][2*i]),
          .b      (stage_data[s][2*i+1]),
          .result (add_result)
        );

        always_ff @(posedge clk) begin
          if (!rst_n)
            stage_data[s+1][i] <= '0;
          else if (stage_valid[s])
            stage_data[s+1][i] <= add_result;
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n)
          stage_valid[s+1] <= 1'b0;
        else
          stage_valid[s+1] <= stage_valid[s];
      end
    end
  endgenerate

  assign sum_out   = stage_data[STAGES][0];
  assign valid_out = stage_valid[STAGES];

endmodule
