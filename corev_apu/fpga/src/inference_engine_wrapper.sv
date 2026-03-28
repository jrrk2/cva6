// inference_engine_wrapper.sv — CVA6 SoC integration wrapper for inference engine
//
// Adapts the 64-bit AXI-Lite interface from the CVA6 crossbar to the
// 32-bit AXI-Lite interface expected by inference_engine_top.
//
// Address space (4 KB):
//   0x000–0x7FF: Inference engine registers (forwarded to axi_lite_regs)
//   0x800–0xFFF: DMA control registers (Phase 2, active only when HAS_DMA=1)
//
// The wrapper extracts the active 32-bit half of each 64-bit data word
// using wstrb / address bit [2].

module inference_engine_wrapper
  import inference_pkg::*;
#(
  parameter int unsigned AXI_ADDR_WIDTH = 12,
  parameter int unsigned AXI_DATA_WIDTH = 64,   // crossbar data width
  parameter bit          HAS_DMA        = 1'b0  // Phase 2: enable DMA registers
) (
  input  logic clk,
  input  logic rst_n,

  // AXI-Lite slave (64-bit data, from timeout wrapper)
  input  logic [AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  logic                         s_axi_awvalid,
  output logic                         s_axi_awready,
  input  logic [AXI_DATA_WIDTH-1:0]    s_axi_wdata,
  input  logic [AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
  input  logic                         s_axi_wvalid,
  output logic                         s_axi_wready,
  output logic [1:0]                   s_axi_bresp,
  output logic                         s_axi_bvalid,
  input  logic                         s_axi_bready,
  input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
  input  logic                         s_axi_arvalid,
  output logic                         s_axi_arready,
  output logic [AXI_DATA_WIDTH-1:0]    s_axi_rdata,
  output logic [1:0]                   s_axi_rresp,
  output logic                         s_axi_rvalid,
  input  logic                         s_axi_rready,

  // Phase 2: DMA AXI4 read-only master (directly exposed, active when HAS_DMA)
  output logic [63:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [63:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,

  // Interrupt
  output logic irq_done
);

  // ================================================================
  //  64-bit to 32-bit AXI-Lite adaptation
  // ================================================================
  logic [11:0] ie_awaddr;
  logic        ie_awvalid, ie_awready;
  logic [31:0] ie_wdata;
  logic [3:0]  ie_wstrb;
  logic        ie_wvalid, ie_wready;
  logic [1:0]  ie_bresp;
  logic        ie_bvalid, ie_bready;
  logic [11:0] ie_araddr;
  logic        ie_arvalid, ie_arready;
  logic [31:0] ie_rdata;
  logic [1:0]  ie_rresp;
  logic        ie_rvalid, ie_rready;

  // Write path: extract 32-bit half based on wstrb
  assign ie_awaddr  = s_axi_awaddr;
  assign ie_awvalid = s_axi_awvalid;
  assign s_axi_awready = ie_awready;

  wire wr_upper = |s_axi_wstrb[7:4] & ~|s_axi_wstrb[3:0];
  assign ie_wdata  = wr_upper ? s_axi_wdata[63:32] : s_axi_wdata[31:0];
  assign ie_wstrb  = wr_upper ? s_axi_wstrb[7:4]   : s_axi_wstrb[3:0];
  assign ie_wvalid = s_axi_wvalid;
  assign s_axi_wready = ie_wready;

  assign s_axi_bresp  = ie_bresp;
  assign s_axi_bvalid = ie_bvalid;
  assign ie_bready     = s_axi_bready;

  // Read path: replicate 32-bit read data to both halves
  assign ie_araddr  = s_axi_araddr;
  assign ie_arvalid = s_axi_arvalid;
  assign s_axi_arready = ie_arready;

  assign s_axi_rdata = {ie_rdata, ie_rdata};
  assign s_axi_rresp = ie_rresp;
  assign s_axi_rvalid = ie_rvalid;
  assign ie_rready    = s_axi_rready;

  // ================================================================
  //  Intermediate signals to inference_engine_top (core_*)
  // ================================================================
  logic [11:0] core_awaddr;
  logic        core_awvalid, core_awready;
  logic [31:0] core_wdata;
  logic [3:0]  core_wstrb;
  logic        core_wvalid, core_wready;
  logic [1:0]  core_bresp;
  logic        core_bvalid, core_bready;
  logic [11:0] core_araddr;
  logic        core_arvalid, core_arready;
  logic [31:0] core_rdata;
  logic [1:0]  core_rresp;
  logic        core_rvalid, core_rready;

  // External buffer write ports
  logic                             ext_wbuf_wr_en;
  logic [$clog2(4096)-1:0]         ext_wbuf_wr_addr;
  logic [ARRAY_COLS*DATA_WIDTH-1:0] ext_wbuf_wr_data;

  logic                             ext_abuf_wr_en;
  logic [$clog2(1024)-1:0]         ext_abuf_wr_addr;
  logic [ARRAY_ROWS*DATA_WIDTH-1:0] ext_abuf_wr_data;

  logic ie_busy;

  // ================================================================
  //  Inference Engine Core (always present)
  // ================================================================
  inference_engine_top u_ie (
    .clk              (clk),
    .rst_n            (rst_n),
    .s_axi_awaddr     (core_awaddr),
    .s_axi_awvalid    (core_awvalid),
    .s_axi_awready    (core_awready),
    .s_axi_wdata      (core_wdata),
    .s_axi_wstrb      (core_wstrb),
    .s_axi_wvalid     (core_wvalid),
    .s_axi_wready     (core_wready),
    .s_axi_bresp      (core_bresp),
    .s_axi_bvalid     (core_bvalid),
    .s_axi_bready     (core_bready),
    .s_axi_araddr     (core_araddr),
    .s_axi_arvalid    (core_arvalid),
    .s_axi_arready    (core_arready),
    .s_axi_rdata      (core_rdata),
    .s_axi_rresp      (core_rresp),
    .s_axi_rvalid     (core_rvalid),
    .s_axi_rready     (core_rready),
    .ext_wbuf_wr_en   (ext_wbuf_wr_en),
    .ext_wbuf_wr_addr (ext_wbuf_wr_addr),
    .ext_wbuf_wr_data (ext_wbuf_wr_data),
    .ext_abuf_wr_en   (ext_abuf_wr_en),
    .ext_abuf_wr_addr (ext_abuf_wr_addr),
    .ext_abuf_wr_data (ext_abuf_wr_data),
    .irq_done         (irq_done),
    .busy             (ie_busy)
  );

  // ================================================================
  //  Phase 1: No DMA — straight pass-through, tie off ext ports
  // ================================================================
  generate
    if (!HAS_DMA) begin : gen_no_dma

      // AXI-Lite pass-through: ie_* → core_*
      assign core_awaddr  = ie_awaddr;
      assign core_awvalid = ie_awvalid;
      assign ie_awready   = core_awready;
      assign core_wdata   = ie_wdata;
      assign core_wstrb   = ie_wstrb;
      assign core_wvalid  = ie_wvalid;
      assign ie_wready    = core_wready;
      assign ie_bresp     = core_bresp;
      assign ie_bvalid    = core_bvalid;
      assign core_bready  = ie_bready;
      assign core_araddr  = ie_araddr;
      assign core_arvalid = ie_arvalid;
      assign ie_arready   = core_arready;
      assign ie_rdata     = core_rdata;
      assign ie_rresp     = core_rresp;
      assign ie_rvalid    = core_rvalid;
      assign core_rready  = ie_rready;

      // Tie off external buffer ports
      assign ext_wbuf_wr_en   = 1'b0;
      assign ext_wbuf_wr_addr = '0;
      assign ext_wbuf_wr_data = '0;
      assign ext_abuf_wr_en   = 1'b0;
      assign ext_abuf_wr_addr = '0;
      assign ext_abuf_wr_data = '0;

      // Tie off DMA master port
      assign m_axi_araddr  = '0;
      assign m_axi_arlen   = '0;
      assign m_axi_arsize  = '0;
      assign m_axi_arburst = '0;
      assign m_axi_arvalid = 1'b0;
      assign m_axi_rready  = 1'b0;

    end else begin : gen_dma

      // ============================================================
      //  Phase 2: AXI-Lite address demux + DMA engine
      // ============================================================
      // Address bit [11]: 0 = IE core regs, 1 = DMA CSRs
      //
      // The upstream (axi_to_axi_lite with MAX_WRITE_TXNS=1 and
      // MAX_READ_TXNS=1) guarantees at most one outstanding write
      // and one outstanding read, so the simple selector is safe.

      // DMA AXI-Lite signals
      logic [11:0] dma_awaddr;
      logic        dma_awvalid, dma_awready;
      logic [31:0] dma_wdata;
      logic [3:0]  dma_wstrb;
      logic        dma_wvalid, dma_wready;
      logic [1:0]  dma_bresp;
      logic        dma_bvalid, dma_bready;
      logic [11:0] dma_araddr;
      logic        dma_arvalid, dma_arready;
      logic [31:0] dma_rdata;
      logic [1:0]  dma_rresp;
      logic        dma_rvalid, dma_rready;

      // ---- Write address demux ----
      // Latch target for W and B phases (AW fires before or with W)
      logic wr_sel_q;  // 0 = IE, 1 = DMA
      always_ff @(posedge clk) begin
        if (!rst_n) wr_sel_q <= 1'b0;
        else if (ie_awvalid && ie_awready) wr_sel_q <= ie_awaddr[11];
      end

      wire wr_to_dma = ie_awaddr[11];
      wire wr_sel    = ie_awvalid ? wr_to_dma : wr_sel_q;

      // AW steering
      assign core_awaddr  = ie_awaddr;
      assign core_awvalid = ie_awvalid & ~wr_to_dma;
      assign dma_awaddr   = ie_awaddr;
      assign dma_awvalid  = ie_awvalid & wr_to_dma;
      assign ie_awready   = wr_to_dma ? dma_awready : core_awready;

      // W steering (follows AW target)
      assign core_wdata   = ie_wdata;
      assign core_wstrb   = ie_wstrb;
      assign core_wvalid  = ie_wvalid & ~wr_sel;
      assign dma_wdata    = ie_wdata;
      assign dma_wstrb    = ie_wstrb;
      assign dma_wvalid   = ie_wvalid & wr_sel;
      assign ie_wready    = wr_sel ? dma_wready : core_wready;

      // B mux (from target that handled the write)
      assign ie_bresp     = wr_sel_q ? dma_bresp  : core_bresp;
      assign ie_bvalid    = wr_sel_q ? dma_bvalid : core_bvalid;
      assign core_bready  = ~wr_sel_q & ie_bready;
      assign dma_bready   = wr_sel_q  & ie_bready;

      // ---- Read address demux ----
      logic rd_sel_q;  // 0 = IE, 1 = DMA
      always_ff @(posedge clk) begin
        if (!rst_n) rd_sel_q <= 1'b0;
        else if (ie_arvalid && ie_arready) rd_sel_q <= ie_araddr[11];
      end

      wire rd_to_dma = ie_araddr[11];

      assign core_araddr  = ie_araddr;
      assign core_arvalid = ie_arvalid & ~rd_to_dma;
      assign dma_araddr   = ie_araddr;
      assign dma_arvalid  = ie_arvalid & rd_to_dma;
      assign ie_arready   = rd_to_dma ? dma_arready : core_arready;

      assign ie_rdata     = rd_sel_q ? dma_rdata  : core_rdata;
      assign ie_rresp     = rd_sel_q ? dma_rresp  : core_rresp;
      assign ie_rvalid    = rd_sel_q ? dma_rvalid : core_rvalid;
      assign core_rready  = ~rd_sel_q & ie_rready;
      assign dma_rready   = rd_sel_q  & ie_rready;

      // ---- DMA engine ----
      ie_dram_reader #(
        .WBUF_DEPTH ( 4096 ),
        .ABUF_DEPTH ( 1024 )
      ) u_dma (
        .clk   ( clk   ),
        .rst_n ( rst_n ),
        // CSR AXI-Lite
        .s_axi_awaddr  ( dma_awaddr  ),
        .s_axi_awvalid ( dma_awvalid ),
        .s_axi_awready ( dma_awready ),
        .s_axi_wdata   ( dma_wdata   ),
        .s_axi_wstrb   ( dma_wstrb   ),
        .s_axi_wvalid  ( dma_wvalid  ),
        .s_axi_wready  ( dma_wready  ),
        .s_axi_bresp   ( dma_bresp   ),
        .s_axi_bvalid  ( dma_bvalid  ),
        .s_axi_bready  ( dma_bready  ),
        .s_axi_araddr  ( dma_araddr  ),
        .s_axi_arvalid ( dma_arvalid ),
        .s_axi_arready ( dma_arready ),
        .s_axi_rdata   ( dma_rdata   ),
        .s_axi_rresp   ( dma_rresp   ),
        .s_axi_rvalid  ( dma_rvalid  ),
        .s_axi_rready  ( dma_rready  ),
        // AXI4 read master → exposed on wrapper ports
        .m_axi_araddr  ( m_axi_araddr  ),
        .m_axi_arlen   ( m_axi_arlen   ),
        .m_axi_arsize  ( m_axi_arsize  ),
        .m_axi_arburst ( m_axi_arburst ),
        .m_axi_arvalid ( m_axi_arvalid ),
        .m_axi_arready ( m_axi_arready ),
        .m_axi_rdata   ( m_axi_rdata   ),
        .m_axi_rresp   ( m_axi_rresp   ),
        .m_axi_rlast   ( m_axi_rlast   ),
        .m_axi_rvalid  ( m_axi_rvalid  ),
        .m_axi_rready  ( m_axi_rready  ),
        // BRAM write ports
        .ext_wbuf_wr_en   ( ext_wbuf_wr_en   ),
        .ext_wbuf_wr_addr ( ext_wbuf_wr_addr  ),
        .ext_wbuf_wr_data ( ext_wbuf_wr_data  ),
        .ext_abuf_wr_en   ( ext_abuf_wr_en    ),
        .ext_abuf_wr_addr ( ext_abuf_wr_addr  ),
        .ext_abuf_wr_data ( ext_abuf_wr_data  )
      );

    end
  endgenerate

endmodule
