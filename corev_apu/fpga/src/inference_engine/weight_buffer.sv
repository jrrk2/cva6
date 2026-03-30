// weight_buffer.sv — BRAM for weight storage
//
// Each word is ARRAY_COLS * DATA_WIDTH = 16 * 8 = 128 bits wide
// Default depth: 16384 words -> 256 KB
//
// Simple dual-port: one write port, one read port.

module weight_buffer
  import inference_pkg::*;
#(
  parameter int unsigned DEPTH = 16384
) (
  input  logic clk,
  input  logic rst_n,

  // Write port
  input  logic                                     wr_en,
  input  logic                                     wr_bank,   // kept for port compat, ignored
  input  logic [$clog2(DEPTH)-1:0]                 wr_addr,
  input  logic [ARRAY_COLS*DATA_WIDTH-1:0]         wr_data,

  // Read port
  input  logic                                     rd_en,
  input  logic                                     rd_bank,   // kept for port compat, ignored
  input  logic [$clog2(DEPTH)-1:0]                 rd_addr,
  output logic [ARRAY_COLS*DATA_WIDTH-1:0]         rd_data
);

  localparam int unsigned WORD_WIDTH = ARRAY_COLS * DATA_WIDTH;  // 128 bits

  (* ram_style = "block" *)
  logic [WORD_WIDTH-1:0] mem [DEPTH];

  // Write
  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data;
  end

  // Read
  always_ff @(posedge clk) begin
    if (rd_en)
      rd_data <= mem[rd_addr];
  end

endmodule
