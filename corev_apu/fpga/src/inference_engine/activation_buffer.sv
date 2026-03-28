// activation_buffer.sv — True dual-port ping-pong activation buffer
//
// Word width: ARRAY_ROWS * DATA_WIDTH = 16 * 8 = 128 bits
// Depth: 1024 words per bank, 2048 total (bank select is addr MSB)
//
// Port A: bridge init writes + AXI readback (active when engine idle)
//         Input signals are registered before reaching the BRAM.
// Port B: layer controller reads + writes (active during inference)
//
// Both banks share a single BRAM array (2048 × 128 bits) with the bank
// select bit concatenated into the address. This guarantees that port B
// writes are visible on port A reads — no risk of Vivado splitting the
// memory into separate port A / port B copies.

module activation_buffer
  import inference_pkg::*;
#(
  parameter int unsigned DEPTH = 1024
) (
  input  logic clk,

  // Port A (bridge / AXI readback) — active when engine idle
  input  logic                                     a_wr_en,
  input  logic                                     a_bank,
  input  logic [$clog2(DEPTH)-1:0]                 a_addr,
  input  logic [ARRAY_ROWS*DATA_WIDTH-1:0]         a_wr_data,
  output logic [ARRAY_ROWS*DATA_WIDTH-1:0]         a_rd_data,

  // Port B (layer controller) — active during inference
  input  logic                                     b_wr_en,
  input  logic                                     b_wr_bank,
  input  logic [$clog2(DEPTH)-1:0]                 b_wr_addr,
  input  logic [ARRAY_ROWS*DATA_WIDTH-1:0]         b_wr_data,
  input  logic                                     b_rd_en,
  input  logic                                     b_rd_bank,
  input  logic [$clog2(DEPTH)-1:0]                 b_rd_addr,
  output logic [ARRAY_ROWS*DATA_WIDTH-1:0]         b_rd_data
);

  localparam int unsigned WORD_WIDTH = ARRAY_ROWS * DATA_WIDTH;  // 128 bits
  localparam int unsigned TOTAL_DEPTH = DEPTH * 2;               // 2048

  // Single unified memory: bank select is address MSB
  (* ram_style = "block" *)
  logic [WORD_WIDTH-1:0] mem [TOTAL_DEPTH];

  // ---- Port A input pipeline register ----
  logic                                a_wr_en_r;
  logic [$clog2(TOTAL_DEPTH)-1:0]     a_full_addr_r;
  logic [WORD_WIDTH-1:0]              a_wr_data_r;

  always_ff @(posedge clk) begin
    a_wr_en_r     <= a_wr_en;
    a_full_addr_r <= {a_bank, a_addr};
    a_wr_data_r   <= a_wr_data;
  end

  // ---- Port B address ----
  // Port B uses write address when writing, read address otherwise.
  // Bank select: write bank for writes, read bank for reads.
  logic [$clog2(TOTAL_DEPTH)-1:0] b_full_addr;

  always_comb begin
    if (b_wr_en)
      b_full_addr = {b_wr_bank, b_wr_addr};
    else
      b_full_addr = {b_rd_bank, b_rd_addr};
  end

  // ---- True dual-port BRAM ----
  // Port A
  logic [WORD_WIDTH-1:0] a_rd_q;
  always_ff @(posedge clk) begin
    if (a_wr_en_r)
      mem[a_full_addr_r] <= a_wr_data_r;
    a_rd_q <= mem[a_full_addr_r];
  end

  // Port B
  logic [WORD_WIDTH-1:0] b_rd_q;
  always_ff @(posedge clk) begin
    if (b_wr_en)
      mem[b_full_addr] <= b_wr_data;
    b_rd_q <= mem[b_full_addr];
  end

  assign a_rd_data = a_rd_q;
  assign b_rd_data = b_rd_q;

endmodule
