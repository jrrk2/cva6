// axi_lite_timeout.sv — AXI-Lite timeout wrapper for fault isolation
//
// Wraps an AXI-Lite slave port.  If any handshake stalls for longer than
// TIMEOUT_CYCLES, the wrapper forces completion and returns SLVERR (2'b10).
// This prevents a malfunctioning slave from deadlocking the upstream
// crossbar / interconnect.
//
// The module is fully transparent when the slave responds normally.

module axi_lite_timeout #(
  parameter int unsigned ADDR_WIDTH     = 12,
  parameter int unsigned DATA_WIDTH     = 64,
  parameter int unsigned TIMEOUT_CYCLES = 4096  // ~80 us at 50 MHz
) (
  input  logic clk,
  input  logic rst_n,

  // --- Upstream (from crossbar / AXI-to-AXI-Lite bridge) ---
  input  logic [ADDR_WIDTH-1:0] s_awaddr,
  input  logic                  s_awvalid,
  output logic                  s_awready,
  input  logic [DATA_WIDTH-1:0] s_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_wstrb,
  input  logic                  s_wvalid,
  output logic                  s_wready,
  output logic [1:0]            s_bresp,
  output logic                  s_bvalid,
  input  logic                  s_bready,
  input  logic [ADDR_WIDTH-1:0] s_araddr,
  input  logic                  s_arvalid,
  output logic                  s_arready,
  output logic [DATA_WIDTH-1:0] s_rdata,
  output logic [1:0]            s_rresp,
  output logic                  s_rvalid,
  input  logic                  s_rready,

  // --- Downstream (to inference engine slave) ---
  output logic [ADDR_WIDTH-1:0] m_awaddr,
  output logic                  m_awvalid,
  input  logic                  m_awready,
  output logic [DATA_WIDTH-1:0] m_wdata,
  output logic [DATA_WIDTH/8-1:0] m_wstrb,
  output logic                  m_wvalid,
  input  logic                  m_wready,
  input  logic [1:0]            m_bresp,
  input  logic                  m_bvalid,
  output logic                  m_bready,
  output logic [ADDR_WIDTH-1:0] m_araddr,
  output logic                  m_arvalid,
  input  logic                  m_arready,
  input  logic [DATA_WIDTH-1:0] m_rdata,
  input  logic [1:0]            m_rresp,
  input  logic                  m_rvalid,
  output logic                  m_rready
);

  localparam int unsigned CTR_W = $clog2(TIMEOUT_CYCLES + 1);

  // ---- Write path state ----
  logic wr_timeout;
  logic [CTR_W-1:0] aw_ctr, w_ctr, b_ctr;

  // AW timeout counter
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)         aw_ctr <= '0;
    else if (!s_awvalid || s_awready) aw_ctr <= '0;
    else if (aw_ctr != TIMEOUT_CYCLES[CTR_W-1:0]) aw_ctr <= aw_ctr + 1;

  // W timeout counter
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)         w_ctr <= '0;
    else if (!s_wvalid || s_wready) w_ctr <= '0;
    else if (w_ctr != TIMEOUT_CYCLES[CTR_W-1:0]) w_ctr <= w_ctr + 1;

  wire aw_expired = (aw_ctr == TIMEOUT_CYCLES[CTR_W-1:0]);
  wire w_expired  = (w_ctr  == TIMEOUT_CYCLES[CTR_W-1:0]);

  // Write timeout: either AW or W channel stalled
  assign wr_timeout = aw_expired | w_expired;

  // When timed out, absorb the write and inject a SLVERR B response
  // Normal path: forward to downstream slave
  assign m_awaddr  = s_awaddr;
  assign m_awvalid = s_awvalid & ~wr_timeout;
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wvalid  = s_wvalid  & ~wr_timeout;

  // B channel: inject SLVERR on timeout, otherwise forward from slave
  logic b_inject_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)
      b_inject_q <= 1'b0;
    else if (b_inject_q && s_bready)
      b_inject_q <= 1'b0;
    else if (wr_timeout && s_awvalid && s_wvalid && !b_inject_q)
      b_inject_q <= 1'b1;

  assign s_awready = wr_timeout ? (s_wvalid & !b_inject_q) : m_awready;
  assign s_wready  = wr_timeout ? (s_awvalid & !b_inject_q) : m_wready;
  assign s_bvalid  = b_inject_q ? 1'b1    : m_bvalid;
  assign s_bresp   = b_inject_q ? 2'b10   : m_bresp;   // SLVERR
  assign m_bready  = b_inject_q ? 1'b0    : s_bready;

  // ---- Read path state ----
  logic [CTR_W-1:0] ar_ctr;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)         ar_ctr <= '0;
    else if (!s_arvalid || s_arready) ar_ctr <= '0;
    else if (ar_ctr != TIMEOUT_CYCLES[CTR_W-1:0]) ar_ctr <= ar_ctr + 1;

  wire ar_expired = (ar_ctr == TIMEOUT_CYCLES[CTR_W-1:0]);

  // When timed out, absorb the read and inject a SLVERR R response
  logic r_inject_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)
      r_inject_q <= 1'b0;
    else if (r_inject_q && s_rready)
      r_inject_q <= 1'b0;
    else if (ar_expired && s_arvalid && !r_inject_q)
      r_inject_q <= 1'b1;

  assign m_araddr  = s_araddr;
  assign m_arvalid = s_arvalid & ~ar_expired;

  assign s_arready = ar_expired ? !r_inject_q : m_arready;
  assign s_rvalid  = r_inject_q ? 1'b1        : m_rvalid;
  assign s_rdata   = r_inject_q ? '0           : m_rdata;
  assign s_rresp   = r_inject_q ? 2'b10        : m_rresp;  // SLVERR
  assign m_rready  = r_inject_q ? 1'b0         : s_rready;

endmodule
