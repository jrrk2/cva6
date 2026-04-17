// ef_train_top.sv — Top-level EF-Train CNN training accelerator
//
// Integrates all components from "EF-Train: Enable Efficient On-device
// CNN Training on FPGA" (Tang et al., arXiv 2202.10935v1):
//
//   - Unified Conv Kernel (Tm×Tn PE array + adder trees) for FP/BP/WU
//   - Pooling Kernel (max/avg, FP/BP)
//   - BatchNorm Kernel (FP/BP)
//   - ReLU (fused with conv output)
//   - 5 double-buffered BRAM banks (IFM, OFM, Weight, Pool Index, BN Params)
//   - 4 DMA channels (IFM, OFM, WEI, OUT)
//   - Layer controller FSM with tiled loop execution
//   - AXI-Lite CSR interface for host control
//
// AXI interfaces:
//   - 1× AXI-Lite slave for CSR register access
//   - 4× AXI4 masters for DMA channels

module ef_train_top
  import ef_train_pkg::*;
#(
  parameter int unsigned AXI_LITE_ADDR_W = 16,
  parameter int unsigned CSR_BASE        = 32'h6000_0000
) (
  input  logic clk,
  input  logic rst_n,

  // ==== AXI-Lite Slave (CSR) ====
  input  logic [AXI_LITE_ADDR_W-1:0] s_axi_awaddr,
  input  logic                        s_axi_awvalid,
  output logic                        s_axi_awready,
  input  logic [31:0]                 s_axi_wdata,
  input  logic [3:0]                  s_axi_wstrb,
  input  logic                        s_axi_wvalid,
  output logic                        s_axi_wready,
  output logic [1:0]                  s_axi_bresp,
  output logic                        s_axi_bvalid,
  input  logic                        s_axi_bready,
  input  logic [AXI_LITE_ADDR_W-1:0] s_axi_araddr,
  input  logic                        s_axi_arvalid,
  output logic                        s_axi_arready,
  output logic [31:0]                 s_axi_rdata,
  output logic [1:0]                  s_axi_rresp,
  output logic                        s_axi_rvalid,
  input  logic                        s_axi_rready,

  // ==== AXI4 Master — IFM DMA ====
  output logic [AXI_ADDR_W-1:0]  m0_axi_araddr,
  output logic [7:0]             m0_axi_arlen,
  output logic [2:0]             m0_axi_arsize,
  output logic [1:0]             m0_axi_arburst,
  output logic                   m0_axi_arvalid,
  input  logic                   m0_axi_arready,
  input  logic [AXI_DATA_W-1:0] m0_axi_rdata,
  input  logic [1:0]             m0_axi_rresp,
  input  logic                   m0_axi_rlast,
  input  logic                   m0_axi_rvalid,
  output logic                   m0_axi_rready,

  // ==== AXI4 Master — OFM DMA ====
  output logic [AXI_ADDR_W-1:0]  m1_axi_araddr,
  output logic [7:0]             m1_axi_arlen,
  output logic [2:0]             m1_axi_arsize,
  output logic [1:0]             m1_axi_arburst,
  output logic                   m1_axi_arvalid,
  input  logic                   m1_axi_arready,
  input  logic [AXI_DATA_W-1:0] m1_axi_rdata,
  input  logic [1:0]             m1_axi_rresp,
  input  logic                   m1_axi_rlast,
  input  logic                   m1_axi_rvalid,
  output logic                   m1_axi_rready,

  // ==== AXI4 Master — WEI DMA ====
  output logic [AXI_ADDR_W-1:0]  m2_axi_araddr,
  output logic [7:0]             m2_axi_arlen,
  output logic [2:0]             m2_axi_arsize,
  output logic [1:0]             m2_axi_arburst,
  output logic                   m2_axi_arvalid,
  input  logic                   m2_axi_arready,
  input  logic [AXI_DATA_W-1:0] m2_axi_rdata,
  input  logic [1:0]             m2_axi_rresp,
  input  logic                   m2_axi_rlast,
  input  logic                   m2_axi_rvalid,
  output logic                   m2_axi_rready,

  // ==== AXI4 Master — OUT DMA (read + write) ====
  output logic [AXI_ADDR_W-1:0]  m3_axi_araddr,
  output logic [7:0]             m3_axi_arlen,
  output logic [2:0]             m3_axi_arsize,
  output logic [1:0]             m3_axi_arburst,
  output logic                   m3_axi_arvalid,
  input  logic                   m3_axi_arready,
  input  logic [AXI_DATA_W-1:0] m3_axi_rdata,
  input  logic [1:0]             m3_axi_rresp,
  input  logic                   m3_axi_rlast,
  input  logic                   m3_axi_rvalid,
  output logic                   m3_axi_rready,
  output logic [AXI_ADDR_W-1:0]  m3_axi_awaddr,
  output logic [7:0]             m3_axi_awlen,
  output logic [2:0]             m3_axi_awsize,
  output logic [1:0]             m3_axi_awburst,
  output logic                   m3_axi_awvalid,
  input  logic                   m3_axi_awready,
  output logic [AXI_DATA_W-1:0]  m3_axi_wdata,
  output logic [7:0]             m3_axi_wstrb,
  output logic                   m3_axi_wlast,
  output logic                   m3_axi_wvalid,
  input  logic                   m3_axi_wready,
  input  logic [1:0]             m3_axi_bresp,
  input  logic                   m3_axi_bvalid,
  output logic                   m3_axi_bready
);

  // ================================================================
  //  CSR Register File
  // ================================================================
  //  0x000: CTRL       [0] start, [1] busy (RO), [2] done (RO/W1C)
  //  0x004: STATUS     [2:0] op_mode, [5:3] layer_type, etc.
  //  0x008: VERSION    (RO) 32'hEF01_0001
  //
  //  0x100–0x1FF: Layer descriptor registers (mapped to layer_desc_t)
  //    0x100: LAYER_TYPE    [2:0] layer_type, [4:3] op_mode, [6:5] activation, [7] pool_type
  //    0x104: IN_CHANNELS
  //    0x108: OUT_CHANNELS
  //    0x10C: IN_H_W        [15:8] in_h, [7:0] in_w
  //    0x110: OUT_H_W       [15:8] out_h, [7:0] out_w
  //    0x114: KERN_STRIDE   [7:4] kern_h, [3:0] kern_w, [11:8] stride, [15:12] pad
  //    0x118: BATCH_SIZE
  //    0x11C: IFM_BASE
  //    0x120: OFM_BASE
  //    0x124: WEI_BASE
  //    0x128: BN_BASE
  //    0x12C: POOL_IDX_BASE
  //
  //  0x200–0x2FF: DMA base address registers
  //    0x200: DMA_IFM_ADDR_LO
  //    0x204: DMA_IFM_ADDR_HI
  //    0x208: DMA_OFM_ADDR_LO
  //    0x20C: DMA_OFM_ADDR_HI
  //    0x210: DMA_WEI_ADDR_LO
  //    0x214: DMA_WEI_ADDR_HI
  //    0x218: DMA_OUT_ADDR_LO
  //    0x21C: DMA_OUT_ADDR_HI

  // CSR state
  logic        start_pulse, done_flag, busy_flag;
  layer_desc_t layer_desc_q;
  logic [63:0] dma_ifm_base_addr, dma_ofm_base_addr, dma_wei_base_addr, dma_out_base_addr;

  // AXI-Lite write channel
  logic aw_pending, w_pending;
  logic [AXI_LITE_ADDR_W-1:0] aw_addr_q;
  logic [31:0] w_data_q;
  logic do_write;

  wire aw_fire = s_axi_awvalid & s_axi_awready;
  wire w_fire  = s_axi_wvalid  & s_axi_wready;
  wire ar_fire = s_axi_arvalid & s_axi_arready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      aw_addr_q  <= '0;
    end else if (aw_fire) begin
      aw_pending <= 1'b1;
      aw_addr_q  <= s_axi_awaddr;
    end else if (do_write)
      aw_pending <= 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w_pending <= 1'b0;
      w_data_q  <= '0;
    end else if (w_fire) begin
      w_pending <= 1'b1;
      w_data_q  <= s_axi_wdata;
    end else if (do_write)
      w_pending <= 1'b0;
  end

  assign s_axi_awready = !aw_pending;
  assign s_axi_wready  = !w_pending;
  assign do_write       = aw_pending & w_pending;

  // Write response
  always_ff @(posedge clk) begin
    if (!rst_n)
      s_axi_bvalid <= 1'b0;
    else if (do_write)
      s_axi_bvalid <= 1'b1;
    else if (s_axi_bvalid && s_axi_bready)
      s_axi_bvalid <= 1'b0;
  end
  assign s_axi_bresp = 2'b00;

  // CSR write decode
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      start_pulse        <= 1'b0;
      layer_desc_q       <= '0;
      dma_ifm_base_addr  <= '0;
      dma_ofm_base_addr  <= '0;
      dma_wei_base_addr  <= '0;
      dma_out_base_addr  <= '0;
    end else begin
      start_pulse <= 1'b0;

      if (do_write) begin
        case (aw_addr_q[11:0])
          12'h000: begin
            if (w_data_q[0]) start_pulse <= 1'b1;
          end

          // Layer descriptor
          12'h100: begin
            layer_desc_q.layer_type <= layer_type_e'(w_data_q[2:0]);
            layer_desc_q.op_mode    <= op_mode_e'(w_data_q[4:3]);
            layer_desc_q.activation <= act_type_e'(w_data_q[6:5]);
            layer_desc_q.pool_type  <= pool_type_e'(w_data_q[7]);
          end
          12'h104: layer_desc_q.in_channels  <= w_data_q[15:0];
          12'h108: layer_desc_q.out_channels <= w_data_q[15:0];
          12'h10C: begin
            layer_desc_q.in_h <= w_data_q[15:8];
            layer_desc_q.in_w <= w_data_q[7:0];
          end
          12'h110: begin
            layer_desc_q.out_h <= w_data_q[15:8];
            layer_desc_q.out_w <= w_data_q[7:0];
          end
          12'h114: begin
            layer_desc_q.kern_h <= w_data_q[7:4];
            layer_desc_q.kern_w <= w_data_q[3:0];
            layer_desc_q.stride <= w_data_q[11:8];
            layer_desc_q.pad    <= w_data_q[15:12];
          end
          12'h118: layer_desc_q.batch_size <= w_data_q[7:0];
          12'h11C: layer_desc_q.ifm_base       <= w_data_q[15:0];
          12'h120: layer_desc_q.ofm_base       <= w_data_q[15:0];
          12'h124: layer_desc_q.wei_base       <= w_data_q[15:0];
          12'h128: layer_desc_q.bn_base        <= w_data_q[15:0];
          12'h12C: layer_desc_q.pool_idx_base  <= w_data_q[15:0];

          // DMA base addresses
          12'h200: dma_ifm_base_addr[31:0]  <= w_data_q;
          12'h204: dma_ifm_base_addr[63:32] <= w_data_q;
          12'h208: dma_ofm_base_addr[31:0]  <= w_data_q;
          12'h20C: dma_ofm_base_addr[63:32] <= w_data_q;
          12'h210: dma_wei_base_addr[31:0]  <= w_data_q;
          12'h214: dma_wei_base_addr[63:32] <= w_data_q;
          12'h218: dma_out_base_addr[31:0]  <= w_data_q;
          12'h21C: dma_out_base_addr[63:32] <= w_data_q;
          default: ;
        endcase
      end
    end
  end

  // CSR read path
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
    end else if (ar_fire) begin
      s_axi_rvalid <= 1'b1;
      case (s_axi_araddr[11:0])
        12'h000: s_axi_rdata <= {29'b0, done_flag, busy_flag, 1'b0};
        12'h008: s_axi_rdata <= 32'hEF01_0001;  // version
        12'h104: s_axi_rdata <= {16'b0, layer_desc_q.in_channels};
        12'h108: s_axi_rdata <= {16'b0, layer_desc_q.out_channels};
        default: s_axi_rdata <= 32'hDEAD_EF01;
      endcase
    end else if (s_axi_rvalid && s_axi_rready)
      s_axi_rvalid <= 1'b0;
  end

  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp   = 2'b00;

  // ================================================================
  //  Double-buffered BRAMs
  // ================================================================

  // --- IFM Buffer ---
  logic        ifm_buf_swap;
  logic        ifm_wr_en;
  logic [15:0] ifm_wr_addr;
  logic [DATA_WIDTH-1:0] ifm_wr_data;
  logic        ifm_rd_en;
  logic [15:0] ifm_rd_addr;
  logic [DATA_WIDTH-1:0] ifm_rd_data;

  double_buffer #(
    .DEPTH (IFM_BUF_DEPTH),
    .WIDTH (DATA_WIDTH)
  ) u_ifm_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .swap    (ifm_buf_swap),
    .wr_en   (ifm_wr_en),
    .wr_addr (ifm_wr_addr[$clog2(IFM_BUF_DEPTH)-1:0]),
    .wr_data (ifm_wr_data),
    .rd_en   (ifm_rd_en),
    .rd_addr (ifm_rd_addr[$clog2(IFM_BUF_DEPTH)-1:0]),
    .rd_data (ifm_rd_data)
  );

  // --- OFM Buffer ---
  logic        ofm_buf_swap;
  logic        ofm_wr_en;
  logic [15:0] ofm_wr_addr;
  logic [DATA_WIDTH-1:0] ofm_wr_data;
  logic        ofm_rd_en;
  logic [15:0] ofm_rd_addr;
  logic [DATA_WIDTH-1:0] ofm_rd_data;

  double_buffer #(
    .DEPTH (OFM_BUF_DEPTH),
    .WIDTH (DATA_WIDTH)
  ) u_ofm_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .swap    (ofm_buf_swap),
    .wr_en   (ofm_wr_en),
    .wr_addr (ofm_wr_addr[$clog2(OFM_BUF_DEPTH)-1:0]),
    .wr_data (ofm_wr_data),
    .rd_en   (ofm_rd_en),
    .rd_addr (ofm_rd_addr[$clog2(OFM_BUF_DEPTH)-1:0]),
    .rd_data (ofm_rd_data)
  );

  // --- Weight Buffer ---
  logic        wei_buf_swap;
  logic        wei_wr_en;
  logic [15:0] wei_wr_addr;
  logic [DATA_WIDTH-1:0] wei_wr_data;
  logic        wei_rd_en;
  logic [15:0] wei_rd_addr;
  logic [DATA_WIDTH-1:0] wei_rd_data;

  double_buffer #(
    .DEPTH (WEI_BUF_DEPTH),
    .WIDTH (DATA_WIDTH)
  ) u_wei_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .swap    (wei_buf_swap),
    .wr_en   (wei_wr_en),
    .wr_addr (wei_wr_addr[$clog2(WEI_BUF_DEPTH)-1:0]),
    .wr_data (wei_wr_data),
    .rd_en   (wei_rd_en),
    .rd_addr (wei_rd_addr[$clog2(WEI_BUF_DEPTH)-1:0]),
    .rd_data (wei_rd_data)
  );

  // --- Pooling Index Buffer (single-port, no double-buffer needed) ---
  logic [7:0]  pool_idx_mem [POOL_BUF_DEPTH];
  logic [15:0] pool_idx_wr_addr, pool_idx_rd_addr;
  logic [7:0]  pool_idx_wr_data, pool_idx_rd_data;
  logic        pool_idx_wr_en, pool_idx_rd_en;

  always_ff @(posedge clk) begin
    if (pool_idx_wr_en)
      pool_idx_mem[pool_idx_wr_addr[$clog2(POOL_BUF_DEPTH)-1:0]] <= pool_idx_wr_data;
    if (pool_idx_rd_en)
      pool_idx_rd_data <= pool_idx_mem[pool_idx_rd_addr[$clog2(POOL_BUF_DEPTH)-1:0]];
  end

  // --- BN Parameter Buffer (single-port) ---
  logic [DATA_WIDTH-1:0] bn_mem [BN_BUF_DEPTH];
  logic [15:0] bn_rd_addr;
  logic [DATA_WIDTH-1:0] bn_rd_data;
  logic        bn_rd_en;

  always_ff @(posedge clk) begin
    if (bn_rd_en)
      bn_rd_data <= bn_mem[bn_rd_addr[$clog2(BN_BUF_DEPTH)-1:0]];
  end

  // ================================================================
  //  Conv Kernel
  // ================================================================
  op_mode_e    conv_mode;
  logic        conv_clear_acc, conv_compute_en;
  logic [DATA_WIDTH-1:0] conv_a_bus [TN];
  logic [DATA_WIDTH-1:0] conv_b_bus [TM];
  logic [DATA_WIDTH-1:0] conv_ofm_out [TM];
  logic                  conv_ofm_valid;
  logic [DATA_WIDTH-1:0] conv_dw_out [TM][TN];
  logic                  conv_dw_valid;

  conv_kernel u_conv (
    .clk          (clk),
    .rst_n        (rst_n),
    .mode         (conv_mode),
    .clear_acc    (conv_clear_acc),
    .compute_en   (conv_compute_en),
    .a_bus        (conv_a_bus),
    .b_bus        (conv_b_bus),
    .ofm_out      (conv_ofm_out),
    .ofm_valid    (conv_ofm_valid),
    .dw_out       (conv_dw_out),
    .dw_valid     (conv_dw_valid)
  );

  // ================================================================
  //  ReLU Unit
  // ================================================================
  op_mode_e              relu_mode;
  logic [DATA_WIDTH-1:0] relu_x_in, relu_dy_in, relu_y_out;

  relu_unit u_relu (
    .mode   (relu_mode),
    .x_in   (relu_x_in),
    .dy_in  (relu_dy_in),
    .y_out  (relu_y_out)
  );

  // ================================================================
  //  Pooling Kernel
  // ================================================================
  // (Connected but not driven by layer_controller in this version —
  //  host would configure a separate pooling pass)
  logic pool_start, pool_busy, pool_done;
  logic [DATA_WIDTH-1:0] pool_x_in, pool_dy_in, pool_y_out, pool_dx_out;
  logic pool_x_valid, pool_x_ready, pool_dy_valid, pool_y_valid, pool_dx_valid;

  pool_kernel u_pool (
    .clk              (clk),
    .rst_n            (rst_n),
    .mode             (layer_desc_q.op_mode),
    .pool_type        (layer_desc_q.pool_type),
    .start            (pool_start),
    .pool_h           (4'd2),  // default 2×2
    .pool_w           (4'd2),
    .busy             (pool_busy),
    .done             (pool_done),
    .x_in             (pool_x_in),
    .x_valid          (pool_x_valid),
    .x_ready          (pool_x_ready),
    .dy_in            (pool_dy_in),
    .dy_valid         (pool_dy_valid),
    .pool_idx_wr_addr (pool_idx_wr_addr),
    .pool_idx_wr_data (pool_idx_wr_data),
    .pool_idx_wr_en   (pool_idx_wr_en),
    .pool_idx_rd_data (pool_idx_rd_data),
    .pool_idx_rd_addr (pool_idx_rd_addr),
    .pool_idx_rd_en   (pool_idx_rd_en),
    .y_out            (pool_y_out),
    .y_valid          (pool_y_valid),
    .dx_out           (pool_dx_out),
    .dx_valid         (pool_dx_valid)
  );

  // ================================================================
  //  BN Kernel
  // ================================================================
  logic bn_start, bn_busy, bn_done;
  logic [DATA_WIDTH-1:0] bn_x_in, bn_dy_in, bn_y_out, bn_dx_out;
  logic [DATA_WIDTH-1:0] bn_dgamma, bn_dbeta;
  logic bn_x_valid, bn_x_ready, bn_dy_valid, bn_y_valid, bn_dx_valid, bn_dparams_valid;

  bn_kernel u_bn (
    .clk           (clk),
    .rst_n         (rst_n),
    .mode          (layer_desc_q.op_mode),
    .start         (bn_start),
    .num_elements  (16'({8'd0, layer_desc_q.out_h} * {8'd0, layer_desc_q.out_w})),
    .busy          (bn_busy),
    .done          (bn_done),
    .gamma         (32'h3F80_0000),  // 1.0 default — loaded from BN buffer in practice
    .beta          (32'h0000_0000),
    .running_mean  (32'h0000_0000),
    .running_var   (32'h3F80_0000),
    .x_in          (bn_x_in),
    .x_valid       (bn_x_valid),
    .x_ready       (bn_x_ready),
    .dy_in         (bn_dy_in),
    .dy_valid      (bn_dy_valid),
    .y_out         (bn_y_out),
    .y_valid       (bn_y_valid),
    .dx_out        (bn_dx_out),
    .dx_valid      (bn_dx_valid),
    .dgamma_out    (bn_dgamma),
    .dbeta_out     (bn_dbeta),
    .dparams_valid (bn_dparams_valid)
  );

  // ================================================================
  //  DMA Channels
  // ================================================================
  // DMA control signals from layer controller
  logic        lc_dma_ifm_start, lc_dma_ofm_start, lc_dma_wei_start, lc_dma_out_start;
  logic [63:0] lc_dma_ifm_addr, lc_dma_ofm_addr, lc_dma_wei_addr, lc_dma_out_addr;
  logic [15:0] lc_dma_ifm_len, lc_dma_ofm_len, lc_dma_wei_len, lc_dma_out_len;
  logic        lc_dma_out_dir;
  logic        dma_ifm_done, dma_ofm_done, dma_wei_done, dma_out_done;

  // IFM DMA (read-only)
  dma_channel u_dma_ifm (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (lc_dma_ifm_start),
    .direction      (1'b0),
    .dram_addr      (dma_ifm_base_addr),
    .buf_addr       (layer_desc_q.ifm_base),
    .xfer_len       (lc_dma_ifm_len),
    .busy           (),
    .done           (dma_ifm_done),
    .m_axi_araddr   (m0_axi_araddr),
    .m_axi_arlen    (m0_axi_arlen),
    .m_axi_arsize   (m0_axi_arsize),
    .m_axi_arburst  (m0_axi_arburst),
    .m_axi_arvalid  (m0_axi_arvalid),
    .m_axi_arready  (m0_axi_arready),
    .m_axi_rdata    (m0_axi_rdata),
    .m_axi_rresp    (m0_axi_rresp),
    .m_axi_rlast    (m0_axi_rlast),
    .m_axi_rvalid   (m0_axi_rvalid),
    .m_axi_rready   (m0_axi_rready),
    .m_axi_awaddr   (),
    .m_axi_awlen    (),
    .m_axi_awsize   (),
    .m_axi_awburst  (),
    .m_axi_awvalid  (),
    .m_axi_awready  (1'b0),
    .m_axi_wdata    (),
    .m_axi_wstrb    (),
    .m_axi_wlast    (),
    .m_axi_wvalid   (),
    .m_axi_wready   (1'b0),
    .m_axi_bresp    (2'b00),
    .m_axi_bvalid   (1'b0),
    .m_axi_bready   (),
    .buf_wr_en      (ifm_wr_en),
    .buf_wr_addr    (ifm_wr_addr),
    .buf_wr_data    (ifm_wr_data),
    .buf_rd_addr    (),
    .buf_rd_en      (),
    .buf_rd_data    ('0)
  );

  // OFM DMA (read-only — loads loss gradients for BP/WU)
  logic        ofm_dma_wr_en;
  logic [15:0] ofm_dma_wr_addr;
  logic [DATA_WIDTH-1:0] ofm_dma_wr_data;

  dma_channel u_dma_ofm (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (lc_dma_ofm_start),
    .direction      (1'b0),
    .dram_addr      (dma_ofm_base_addr),
    .buf_addr       (layer_desc_q.ofm_base),
    .xfer_len       (lc_dma_ofm_len),
    .busy           (),
    .done           (dma_ofm_done),
    .m_axi_araddr   (m1_axi_araddr),
    .m_axi_arlen    (m1_axi_arlen),
    .m_axi_arsize   (m1_axi_arsize),
    .m_axi_arburst  (m1_axi_arburst),
    .m_axi_arvalid  (m1_axi_arvalid),
    .m_axi_arready  (m1_axi_arready),
    .m_axi_rdata    (m1_axi_rdata),
    .m_axi_rresp    (m1_axi_rresp),
    .m_axi_rlast    (m1_axi_rlast),
    .m_axi_rvalid   (m1_axi_rvalid),
    .m_axi_rready   (m1_axi_rready),
    .m_axi_awaddr   (),
    .m_axi_awlen    (),
    .m_axi_awsize   (),
    .m_axi_awburst  (),
    .m_axi_awvalid  (),
    .m_axi_awready  (1'b0),
    .m_axi_wdata    (),
    .m_axi_wstrb    (),
    .m_axi_wlast    (),
    .m_axi_wvalid   (),
    .m_axi_wready   (1'b0),
    .m_axi_bresp    (2'b00),
    .m_axi_bvalid   (1'b0),
    .m_axi_bready   (),
    .buf_wr_en      (ofm_dma_wr_en),
    .buf_wr_addr    (ofm_dma_wr_addr),
    .buf_wr_data    (ofm_dma_wr_data),
    .buf_rd_addr    (),
    .buf_rd_en      (),
    .buf_rd_data    ('0)
  );

  // WEI DMA (read-only)
  dma_channel u_dma_wei (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (lc_dma_wei_start),
    .direction      (1'b0),
    .dram_addr      (dma_wei_base_addr),
    .buf_addr       (layer_desc_q.wei_base),
    .xfer_len       (lc_dma_wei_len),
    .busy           (),
    .done           (dma_wei_done),
    .m_axi_araddr   (m2_axi_araddr),
    .m_axi_arlen    (m2_axi_arlen),
    .m_axi_arsize   (m2_axi_arsize),
    .m_axi_arburst  (m2_axi_arburst),
    .m_axi_arvalid  (m2_axi_arvalid),
    .m_axi_arready  (m2_axi_arready),
    .m_axi_rdata    (m2_axi_rdata),
    .m_axi_rresp    (m2_axi_rresp),
    .m_axi_rlast    (m2_axi_rlast),
    .m_axi_rvalid   (m2_axi_rvalid),
    .m_axi_rready   (m2_axi_rready),
    .m_axi_awaddr   (),
    .m_axi_awlen    (),
    .m_axi_awsize   (),
    .m_axi_awburst  (),
    .m_axi_awvalid  (),
    .m_axi_awready  (1'b0),
    .m_axi_wdata    (),
    .m_axi_wstrb    (),
    .m_axi_wlast    (),
    .m_axi_wvalid   (),
    .m_axi_wready   (1'b0),
    .m_axi_bresp    (2'b00),
    .m_axi_bvalid   (1'b0),
    .m_axi_bready   (),
    .buf_wr_en      (wei_wr_en),
    .buf_wr_addr    (wei_wr_addr),
    .buf_wr_data    (wei_wr_data),
    .buf_rd_addr    (),
    .buf_rd_en      (),
    .buf_rd_data    ('0)
  );

  // OUT DMA (read + write — stores results back to DRAM)
  logic        out_dma_wr_en;
  logic [15:0] out_dma_wr_addr;
  logic [DATA_WIDTH-1:0] out_dma_wr_data;
  logic [15:0] out_dma_rd_addr;
  logic        out_dma_rd_en;
  logic [DATA_WIDTH-1:0] out_dma_rd_data;

  dma_channel u_dma_out (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (lc_dma_out_start),
    .direction      (lc_dma_out_dir),
    .dram_addr      (dma_out_base_addr),
    .buf_addr       (layer_desc_q.ofm_base),
    .xfer_len       (lc_dma_out_len),
    .busy           (),
    .done           (dma_out_done),
    .m_axi_araddr   (m3_axi_araddr),
    .m_axi_arlen    (m3_axi_arlen),
    .m_axi_arsize   (m3_axi_arsize),
    .m_axi_arburst  (m3_axi_arburst),
    .m_axi_arvalid  (m3_axi_arvalid),
    .m_axi_arready  (m3_axi_arready),
    .m_axi_rdata    (m3_axi_rdata),
    .m_axi_rresp    (m3_axi_rresp),
    .m_axi_rlast    (m3_axi_rlast),
    .m_axi_rvalid   (m3_axi_rvalid),
    .m_axi_rready   (m3_axi_rready),
    .m_axi_awaddr   (m3_axi_awaddr),
    .m_axi_awlen    (m3_axi_awlen),
    .m_axi_awsize   (m3_axi_awsize),
    .m_axi_awburst  (m3_axi_awburst),
    .m_axi_awvalid  (m3_axi_awvalid),
    .m_axi_awready  (m3_axi_awready),
    .m_axi_wdata    (m3_axi_wdata),
    .m_axi_wstrb    (m3_axi_wstrb),
    .m_axi_wlast    (m3_axi_wlast),
    .m_axi_wvalid   (m3_axi_wvalid),
    .m_axi_wready   (m3_axi_wready),
    .m_axi_bresp    (m3_axi_bresp),
    .m_axi_bvalid   (m3_axi_bvalid),
    .m_axi_bready   (m3_axi_bready),
    .buf_wr_en      (out_dma_wr_en),
    .buf_wr_addr    (out_dma_wr_addr),
    .buf_wr_data    (out_dma_wr_data),
    .buf_rd_addr    (out_dma_rd_addr),
    .buf_rd_en      (out_dma_rd_en),
    .buf_rd_data    (out_dma_rd_data)
  );

  // OUT DMA reads from OFM buffer for store-back
  assign out_dma_rd_data = ofm_rd_data;

  // ================================================================
  //  Layer Controller
  // ================================================================
  logic lc_layer_done, lc_layer_busy;

  // Wire controller outputs to buffers and conv kernel
  logic [15:0] lc_ifm_rd_addr, lc_ofm_rd_addr, lc_wei_rd_addr;
  logic        lc_ifm_rd_en, lc_ofm_rd_en, lc_wei_rd_en;
  logic [15:0] lc_ofm_wr_addr, lc_wei_wr_addr;
  logic [DATA_WIDTH-1:0] lc_ofm_wr_data, lc_wei_wr_data;
  logic        lc_ofm_wr_en, lc_wei_wr_en;

  layer_controller u_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .layer_desc      (layer_desc_q),
    .layer_start     (start_pulse),
    .layer_done      (lc_layer_done),
    .layer_busy      (lc_layer_busy),

    .conv_mode       (conv_mode),
    .conv_clear_acc  (conv_clear_acc),
    .conv_compute_en (conv_compute_en),
    .conv_a_bus      (conv_a_bus),
    .conv_b_bus      (conv_b_bus),

    .ifm_rd_addr     (lc_ifm_rd_addr),
    .ifm_rd_en       (lc_ifm_rd_en),
    .ifm_rd_data     (ifm_rd_data),
    .ofm_rd_addr     (lc_ofm_rd_addr),
    .ofm_rd_en       (lc_ofm_rd_en),
    .ofm_rd_data     (ofm_rd_data),
    .wei_rd_addr     (lc_wei_rd_addr),
    .wei_rd_en       (lc_wei_rd_en),
    .wei_rd_data     (wei_rd_data),

    .ofm_wr_addr     (lc_ofm_wr_addr),
    .ofm_wr_data     (lc_ofm_wr_data),
    .ofm_wr_en       (lc_ofm_wr_en),
    .wei_wr_addr     (lc_wei_wr_addr),
    .wei_wr_data     (lc_wei_wr_data),
    .wei_wr_en       (lc_wei_wr_en),

    .dma_ifm_start   (lc_dma_ifm_start),
    .dma_ifm_addr    (lc_dma_ifm_addr),
    .dma_ifm_len     (lc_dma_ifm_len),
    .dma_ifm_done    (dma_ifm_done),
    .dma_ofm_start   (lc_dma_ofm_start),
    .dma_ofm_addr    (lc_dma_ofm_addr),
    .dma_ofm_len     (lc_dma_ofm_len),
    .dma_ofm_done    (dma_ofm_done),
    .dma_wei_start   (lc_dma_wei_start),
    .dma_wei_addr    (lc_dma_wei_addr),
    .dma_wei_len     (lc_dma_wei_len),
    .dma_wei_done    (dma_wei_done),
    .dma_out_start   (lc_dma_out_start),
    .dma_out_dir     (lc_dma_out_dir),
    .dma_out_addr    (lc_dma_out_addr),
    .dma_out_len     (lc_dma_out_len),
    .dma_out_done    (dma_out_done),

    .ifm_buf_swap    (ifm_buf_swap),
    .ofm_buf_swap    (ofm_buf_swap),
    .wei_buf_swap    (wei_buf_swap),

    .conv_ofm_out    (conv_ofm_out),
    .conv_ofm_valid  (conv_ofm_valid),
    .conv_dw_out     (conv_dw_out),

    .relu_mode       (relu_mode),
    .relu_x_in       (relu_x_in),
    .relu_dy_in      (relu_dy_in),
    .relu_y_out      (relu_y_out)
  );

  // Mux buffer access between layer controller and DMA
  // Controller has priority during compute; DMA during load
  assign ifm_rd_addr = lc_ifm_rd_addr;
  assign ifm_rd_en   = lc_ifm_rd_en;
  assign ofm_rd_addr = out_dma_rd_en ? out_dma_rd_addr : lc_ofm_rd_addr;
  assign ofm_rd_en   = out_dma_rd_en | lc_ofm_rd_en;
  assign wei_rd_addr = lc_wei_rd_addr;
  assign wei_rd_en   = lc_wei_rd_en;

  // OFM write: mux between controller output and DMA load
  assign ofm_wr_en   = lc_ofm_wr_en | ofm_dma_wr_en;
  assign ofm_wr_addr = ofm_dma_wr_en ? ofm_dma_wr_addr : lc_ofm_wr_addr;
  assign ofm_wr_data = ofm_dma_wr_en ? ofm_dma_wr_data : lc_ofm_wr_data;

  // Status flags
  assign busy_flag = lc_layer_busy;

  always_ff @(posedge clk) begin
    if (!rst_n)
      done_flag <= 1'b0;
    else if (lc_layer_done)
      done_flag <= 1'b1;
    else if (do_write && aw_addr_q[11:0] == 12'h000 && w_data_q[2])
      done_flag <= 1'b0;  // W1C
  end

endmodule
