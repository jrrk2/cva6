// double_buffer.sv — Generic double-buffered BRAM with ping-pong control
//
// Two banks of DEPTH × WIDTH BRAM. DMA fills one bank while compute
// reads the other. A swap signal toggles which bank is active for
// compute vs fill.  This enables overlapping data transfer with
// computation (Section III.C of EF-Train paper).

module double_buffer #(
  parameter int unsigned DEPTH     = 4096,
  parameter int unsigned WIDTH     = 32,
  parameter int unsigned ADDR_BITS = $clog2(DEPTH)
) (
  input  logic clk,
  input  logic rst_n,

  // Bank control
  input  logic swap,  // toggle active bank (pulse)

  // Write port (DMA fill side)
  input  logic                  wr_en,
  input  logic [ADDR_BITS-1:0]  wr_addr,
  input  logic [WIDTH-1:0]      wr_data,

  // Read port (compute side)
  input  logic                  rd_en,
  input  logic [ADDR_BITS-1:0]  rd_addr,
  output logic [WIDTH-1:0]      rd_data
);

  logic bank_sel;  // 0: compute reads bank0, DMA writes bank1
                   // 1: compute reads bank1, DMA writes bank0

  always_ff @(posedge clk) begin
    if (!rst_n)
      bank_sel <= 1'b0;
    else if (swap)
      bank_sel <= ~bank_sel;
  end

  // Bank 0
  logic [WIDTH-1:0] mem0 [DEPTH];
  logic [WIDTH-1:0] rd0_q;

  always_ff @(posedge clk) begin
    if (wr_en && bank_sel)  // DMA writes to bank0 when bank_sel=1
      mem0[wr_addr] <= wr_data;
    if (rd_en && !bank_sel) // compute reads bank0 when bank_sel=0
      rd0_q <= mem0[rd_addr];
  end

  // Bank 1
  logic [WIDTH-1:0] mem1 [DEPTH];
  logic [WIDTH-1:0] rd1_q;

  always_ff @(posedge clk) begin
    if (wr_en && !bank_sel) // DMA writes to bank1 when bank_sel=0
      mem1[wr_addr] <= wr_data;
    if (rd_en && bank_sel)  // compute reads bank1 when bank_sel=1
      rd1_q <= mem1[rd_addr];
  end

  assign rd_data = bank_sel ? rd1_q : rd0_q;

endmodule
