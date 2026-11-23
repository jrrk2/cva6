// SPDX-License-Identifier: Apache-2.0
// legend_eth_axi: the legend64 project's gigabit Ethernet for the VC707 as a peripheral of the
// CVA6 SoC: an AXI slave for the registers (32 bits wide, see legend_eth.sv), a memory port for
// the packet and descriptor DMA (to the device port of the core's data cache), an interrupt, and the SGMII pins of the
// board's Marvell PHY.
`default_nettype none
module legend_eth_axi #(
    parameter int unsigned AxiAddrWidth = 64,
    parameter int unsigned AxiDataWidth = 64,
    parameter int unsigned AxiIdWidth   = 5,
    parameter int unsigned AxiUserWidth = 1,
    parameter int          RxFifoAw     = 14,     // receive FIFO, 8-byte words: 14 is 128 KiB
    parameter logic [7:0]  TxIfg        = 8'd12   // transmit inter-frame gap, bytes
) (
    input  wire         clk_i,
    input  wire         rst_ni,
    AXI_BUS.Slave       axi,
    output wire         irq_o,

    output wire         e_req_o,
    output wire         e_we_o,
    output wire [29:0]  e_addr_o,
    output wire [63:0]  e_wdata_o,
    output wire [7:0]   e_be_o,
    input  wire         e_gnt_i,
    input  wire         e_rvalid_i,
    input  wire [63:0]  e_rdata_i,

    input  wire         sgmii_rxp,
    input  wire         sgmii_rxn,
    output wire         sgmii_txp,
    output wire         sgmii_txn,
    input  wire         sgmii_refclk_p,
    input  wire         sgmii_refclk_n,
    output wire         phy_reset_no,
    output wire         link_up_o
);
  // ------------------------------------------------------------------ registers
  // The bus is 64 bits wide and the registers 32: a register at an address that is 4 more than
  // a multiple of 8 travels in the upper half of the word.
  wire                      req, we;
  wire [AxiAddrWidth-1:0]   addr;
  wire [AxiDataWidth-1:0]   wdata;
  wire [AxiDataWidth/8-1:0] be;
  wire [31:0]               reg_rdata;
  wire                      wr_hi = ~|be[3:0];

  axi2mem #(
      .AXI_ID_WIDTH  (AxiIdWidth),
      .AXI_ADDR_WIDTH(AxiAddrWidth),
      .AXI_DATA_WIDTH(AxiDataWidth),
      .AXI_USER_WIDTH(AxiUserWidth)
  ) i_axi2reg (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .slave (axi),
      .req_o (req),
      .we_o  (we),
      .addr_o(addr),
      .be_o  (be),
      .user_o(),
      .data_o(wdata),
      .user_i('0),
      .data_i({reg_rdata, reg_rdata})
  );

  // ------------------------------------------------------------------ PHY and MAC
  wire [7:0]  rx_tdata, tx_tdata;
  wire        rx_tvalid, rx_tlast, rx_tuser, tx_tvalid, tx_tlast, tx_tready;
  wire        rx_clk, rx_rst, tx_clk, tx_rst;
  wire [15:0] tx_pcs_frames, pcs_status;

  legend_sgmii #(
      .TX_IFG(TxIfg)
  ) i_sgmii (
      .clk_int       (clk_i),
      .rst_int       (~rst_ni),
      .sgmii_rxp     (sgmii_rxp),
      .sgmii_rxn     (sgmii_rxn),
      .sgmii_txp     (sgmii_txp),
      .sgmii_txn     (sgmii_txn),
      .sgmii_refclk_p(sgmii_refclk_p),
      .sgmii_refclk_n(sgmii_refclk_n),
      .phy_reset_n   (phy_reset_no),
      .tx_clk        (tx_clk),
      .tx_rst        (tx_rst),
      .tx_axis_tdata (tx_tdata),
      .tx_axis_tvalid(tx_tvalid),
      .tx_axis_tlast (tx_tlast),
      .tx_axis_tready(tx_tready),
      .tx_frames_out (tx_pcs_frames),
      .rx_clk        (rx_clk),
      .rx_rst        (rx_rst),
      .rx_axis_tdata (rx_tdata),
      .rx_axis_tvalid(rx_tvalid),
      .rx_axis_tlast (rx_tlast),
      .rx_axis_tuser (rx_tuser),
      .pcspma_status (pcs_status)
  );
  assign link_up_o = pcs_status[0];

  // ------------------------------------------------------------------ descriptor rings and DMA
  legend_eth #(
      .RX_FIFO_AW(RxFifoAw)
  ) i_eth (
      .clk          (clk_i),
      .rst          (~rst_ni),
      .reg_sel      (req),
      .reg_we       (we),
      .reg_addr     (we ? {addr[7:3], wr_hi, 2'b00} : {addr[7:2], 2'b00}),
      .reg_wdata    (wr_hi ? wdata[63:32] : wdata[31:0]),
      .reg_rdata    (reg_rdata),
      .irq          (irq_o),
      .e_req        (e_req_o),
      .e_we         (e_we_o),
      .e_addr       (e_addr_o),
      .e_wdata      (e_wdata_o),
      .e_be         (e_be_o),
      .e_gnt        (e_gnt_i),
      .e_rvalid     (e_rvalid_i),
      .e_rdata      (e_rdata_i),
      .mac_clk      (rx_clk),
      .mac_rst      (rx_rst),
      .mac_tx_clk   (tx_clk),
      .mac_tx_rst   (tx_rst),
      .rx_tdata     (rx_tdata),
      .rx_tvalid    (rx_tvalid),
      .rx_tlast     (rx_tlast),
      .rx_tuser     (rx_tuser),
      .tx_tdata     (tx_tdata),
      .tx_tvalid    (tx_tvalid),
      .tx_tlast     (tx_tlast),
      .tx_tready    (tx_tready),
      .tx_pcs_frames(tx_pcs_frames),
      .pcs_status   (pcs_status)
  );
endmodule
`default_nettype wire
