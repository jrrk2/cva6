// bias_buffer.sv — BRAM storage for bias vectors
//
// One bias value (32-bit) per output neuron, read in groups of ARRAY_COLS.
//
// Memory organization:
//   - Word width: ARRAY_COLS * BIAS_WIDTH = 16 * 32 = 512 bits
//   - Depth: 256 → supports up to 256 * 16 = 4096 output neurons
//   - Size: 256 * 512b = 16 KB → ~4 BRAM36K

module bias_buffer
  import inference_pkg::*;
#(
  parameter int unsigned DEPTH = 256
) (
  input  logic clk,

  // Write port
  input  logic                                     wr_en,
  input  logic [$clog2(DEPTH)-1:0]                 wr_addr,
  input  logic [ARRAY_COLS*BIAS_WIDTH-1:0]         wr_data,

  // Read port
  input  logic                                     rd_en,
  input  logic [$clog2(DEPTH)-1:0]                 rd_addr,
  output logic [ARRAY_COLS*BIAS_WIDTH-1:0]         rd_data
);

  localparam int unsigned WORD_WIDTH = ARRAY_COLS * BIAS_WIDTH;

  (* ram_style = "block" *)
  logic [WORD_WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data;
  end

  logic [WORD_WIDTH-1:0] rd_data_q;

  always_ff @(posedge clk) begin
    if (rd_en)
      rd_data_q <= mem[rd_addr];
  end

  assign rd_data = rd_data_q;

endmodule
