// SPDX-License-Identifier: Apache-2.0
// legend_sgmii: the SGMII PHY/PCS (LiteEth's, from synthgui's vc707_ethmin project) and the
// byte-stream MAC (eth_mac_1g), with the MAC's two halves running directly on the PCS's own
// receive and transmit clocks.
//
// vc707_ethmin's wrapper (sgmii_soc) puts a one-frame store-and-forward buffer between the PCS
// and the MAC in each direction so that its MAC can run on a slower clock. That suits a design
// that handles one frame at a time; under load it loses every frame that arrives while the
// previous one is still being replayed, and a short frame sent right behind a long one. Here
// nothing sits between PCS and MAC: frames can follow each other at the minimum gap in both
// directions, and the clock crossing is done by legend_eth's FIFOs.
`default_nettype none
module legend_sgmii #(
    parameter [7:0] TX_IFG = 8'd12       // idle bytes the MAC leaves between frames (12 is the standard's minimum)
) (
    input  wire        clk_int,          // free-running clock for the PHY's reset sequencing
    input  wire        rst_int,

    input  wire        sgmii_rxp,
    input  wire        sgmii_rxn,
    output wire        sgmii_txp,
    output wire        sgmii_txn,
    input  wire        sgmii_refclk_p,
    input  wire        sgmii_refclk_n,
    output wire        phy_reset_n,

    // transmit stream, on tx_clk
    output wire        tx_clk,
    output wire        tx_rst,
    input  wire [7:0]  tx_axis_tdata,
    input  wire        tx_axis_tvalid,
    input  wire        tx_axis_tlast,
    output wire        tx_axis_tready,
    output wire [15:0] tx_frames_out,    // frames started on the GMII output, wraps

    // receive stream, on rx_clk; tuser with tlast marks a bad frame
    output wire        rx_clk,
    output wire        rx_rst,
    output wire [7:0]  rx_axis_tdata,
    output wire        rx_axis_tvalid,
    output wire        rx_axis_tlast,
    output wire        rx_axis_tuser,

    output wire [15:0] pcspma_status
);
  wire [7:0] gmii_rxd, gmii_txd;
  wire       gmii_rx_dv, gmii_rx_er, gmii_tx_en;
  wire       link_up, phy_ready;

  liteeth_sgmii_phy i_phy (
      .clk_int(clk_int), .rst_int(rst_int),
      .sgmii_refclk_p(sgmii_refclk_p), .sgmii_refclk_n(sgmii_refclk_n),
      .sgmii_txp(sgmii_txp), .sgmii_txn(sgmii_txn), .sgmii_rxp(sgmii_rxp), .sgmii_rxn(sgmii_rxn),
      .gmii_tx_clk(tx_clk), .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en),
      .gmii_rx_clk(rx_clk), .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
      .link_up(link_up), .phy_ready(phy_ready)
  );

  // resets released on each clock once the PHY's clocks are stable
  (* ASYNC_REG = "TRUE" *) reg [3:0] txrst_sync = 4'hf, rxrst_sync = 4'hf;
  always @(posedge tx_clk or negedge phy_ready)
    if (!phy_ready) txrst_sync <= 4'hf;
    else            txrst_sync <= {txrst_sync[2:0], 1'b0};
  always @(posedge rx_clk or negedge phy_ready)
    if (!phy_ready) rxrst_sync <= 4'hf;
    else            rxrst_sync <= {rxrst_sync[2:0], 1'b0};
  assign tx_rst = txrst_sync[3];
  assign rx_rst = rxrst_sync[3];

  legend_eth_mac_1g #(.ENABLE_PADDING(1), .MIN_FRAME_LENGTH(64)) i_mac (
      .rx_clk(rx_clk), .rx_rst(rx_rst), .tx_clk(tx_clk), .tx_rst(tx_rst),
      .tx_axis_tdata(tx_axis_tdata), .tx_axis_tvalid(tx_axis_tvalid), .tx_axis_tready(tx_axis_tready),
      .tx_axis_tlast(tx_axis_tlast), .tx_axis_tuser(1'b0),
      .rx_axis_tdata(rx_axis_tdata), .rx_axis_tvalid(rx_axis_tvalid), .rx_axis_tlast(rx_axis_tlast),
      .rx_axis_tuser(rx_axis_tuser),
      .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
      .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
      .rx_clk_enable(1'b1), .tx_clk_enable(1'b1), .rx_mii_select(1'b0), .tx_mii_select(1'b0),
      .rx_error_bad_frame(), .rx_error_bad_fcs(), .rx_fcs_reg(), .tx_fcs_reg(),
      .ifg_delay(TX_IFG)
  );

  assign phy_reset_n = ~rst_int;

  // status, laid out as vc707_ethmin's wrapper does: the boot monitor prints it
  reg [25:0] hb_tx, hb_rx;
  reg        txen_seen, rxdv_seen, txen_q;
  reg [3:0]  tx_frames;
  reg [15:0] tx_frames16;
  assign tx_frames_out = tx_frames16;
  always @(posedge tx_clk) begin
    if (tx_rst) begin
      hb_tx <= 26'd0; txen_q <= 1'b0; txen_seen <= 1'b0; tx_frames <= 4'd0; tx_frames16 <= 16'd0;
    end else begin
      hb_tx  <= hb_tx + 1'b1;
      txen_q <= gmii_tx_en;
      if (gmii_tx_en) txen_seen <= 1'b1;
      if (gmii_tx_en && !txen_q) begin tx_frames <= tx_frames + 1'b1; tx_frames16 <= tx_frames16 + 1'b1; end
    end
  end
  always @(posedge rx_clk) begin
    if (rx_rst) begin
      hb_rx <= 26'd0; rxdv_seen <= 1'b0;
    end else begin
      hb_rx <= hb_rx + 1'b1;
      if (gmii_rx_dv) rxdv_seen <= 1'b1;
    end
  end
  assign pcspma_status = {tx_frames, 2'b10, hb_tx[25], hb_rx[25], txen_seen, rxdv_seen, 4'b0, phy_ready, link_up};
endmodule
`default_nettype wire
