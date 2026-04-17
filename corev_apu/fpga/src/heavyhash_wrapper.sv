// heavyhash_wrapper.sv — CVA6 SoC integration wrapper for HeavyHash miner
//
// Drop-in replacement for inference_engine_wrapper.
// Same external port list: 64-bit AXI-Lite slave, DMA master, IRQ.
//
// Address space (4 KB):
//   0x000-0x7FF: HeavyHash registers (heavyhash_top)
//   0x800-0xFFF: DMA control registers (loads mining matrix from DRAM)

module heavyhash_wrapper #(
  parameter int unsigned AXI_ADDR_WIDTH = 12,
  parameter int unsigned AXI_DATA_WIDTH = 64,
  parameter bit          HAS_DMA        = 1'b0
) (
  input  logic clk,
  input  logic hh_clk,   // 100 MHz mining clock
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

  // DMA AXI4 read-only master (active when HAS_DMA)
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
  //  64-bit to 32-bit AXI-Lite adaptation (same as inference wrapper)
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
  //  Intermediate signals to heavyhash_top (core_*)
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

  // External matrix write port (from DMA)
  logic         ext_mat_wr_en;
  logic [5:0]   ext_mat_wr_addr;
  logic [255:0] ext_mat_wr_data;

  logic hh_busy;

  // ================================================================
  //  HeavyHash Core
  // ================================================================
  heavyhash_top u_hh (
    .clk              (clk),
    .hh_clk           (hh_clk),
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
    .ext_mat_wr_en    (ext_mat_wr_en),
    .ext_mat_wr_addr  (ext_mat_wr_addr),
    .ext_mat_wr_data  (ext_mat_wr_data),
    .irq_done         (irq_done),
    .busy             (hh_busy)
  );

  // ================================================================
  //  Phase 1: No DMA — straight pass-through
  // ================================================================
  generate
    if (!HAS_DMA) begin : gen_no_dma

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

      assign ext_mat_wr_en   = 1'b0;
      assign ext_mat_wr_addr = '0;
      assign ext_mat_wr_data = '0;

      assign m_axi_araddr  = '0;
      assign m_axi_arlen   = '0;
      assign m_axi_arsize  = '0;
      assign m_axi_arburst = '0;
      assign m_axi_arvalid = 1'b0;
      assign m_axi_rready  = 1'b0;

    end else begin : gen_dma

      // ============================================================
      //  DMA: AXI-Lite address demux + DMA engine
      //  Reuses ie_dram_reader to load matrix BRAM from DRAM
      // ============================================================

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

      // Write address demux on bit[11]
      logic wr_sel_q;
      always_ff @(posedge clk) begin
        if (!rst_n) wr_sel_q <= 1'b0;
        else if (ie_awvalid && ie_awready) wr_sel_q <= ie_awaddr[11];
      end

      wire wr_to_dma = ie_awaddr[11];
      wire wr_sel    = ie_awvalid ? wr_to_dma : wr_sel_q;

      assign core_awaddr  = ie_awaddr;
      assign core_awvalid = ie_awvalid & ~wr_to_dma;
      assign dma_awaddr   = ie_awaddr;
      assign dma_awvalid  = ie_awvalid & wr_to_dma;
      assign ie_awready   = wr_to_dma ? dma_awready : core_awready;

      assign core_wdata   = ie_wdata;
      assign core_wstrb   = ie_wstrb;
      assign core_wvalid  = ie_wvalid & ~wr_sel;
      assign dma_wdata    = ie_wdata;
      assign dma_wstrb    = ie_wstrb;
      assign dma_wvalid   = ie_wvalid & wr_sel;
      assign ie_wready    = wr_sel ? dma_wready : core_wready;

      assign ie_bresp     = wr_sel_q ? dma_bresp  : core_bresp;
      assign ie_bvalid    = wr_sel_q ? dma_bvalid : core_bvalid;
      assign core_bready  = ~wr_sel_q & ie_bready;
      assign dma_bready   = wr_sel_q  & ie_bready;

      // Read address demux
      logic rd_sel_q;
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

      // DMA engine — repurposed for matrix loading
      // wbuf port → matrix BRAM (256-bit writes)
      // abuf port → tied off (not used for mining)
      logic                  dma_wbuf_wr_en;
      logic [9:0]            dma_wbuf_wr_addr;
      logic [255:0]          dma_wbuf_wr_data;
      logic                  dma_abuf_wr_en;
      logic [9:0]            dma_abuf_wr_addr;
      logic [255:0]          dma_abuf_wr_data;

      // Map DMA wbuf port to matrix write port
      assign ext_mat_wr_en   = dma_wbuf_wr_en;
      assign ext_mat_wr_addr = dma_wbuf_wr_addr[5:0];
      assign ext_mat_wr_data = dma_wbuf_wr_data;

      ie_dram_reader #(
        .WBUF_DEPTH  ( 1024      ),  // >= ABUF_DEPTH to avoid part-select range error
        .ABUF_DEPTH  ( 1024      ),
        .ARRAY_ROWS  ( 16        ),
        .ARRAY_COLS  ( 16        ),
        .DATA_WIDTH  ( 16        )
      ) u_dma (
        .clk   ( clk   ),
        .rst_n ( rst_n ),
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
        .ext_wbuf_wr_en   ( dma_wbuf_wr_en   ),
        .ext_wbuf_wr_addr ( dma_wbuf_wr_addr  ),
        .ext_wbuf_wr_data ( dma_wbuf_wr_data  ),
        .ext_abuf_wr_en   ( dma_abuf_wr_en    ),
        .ext_abuf_wr_addr ( dma_abuf_wr_addr  ),
        .ext_abuf_wr_data ( dma_abuf_wr_data  )
      );

    end
  endgenerate

endmodule
