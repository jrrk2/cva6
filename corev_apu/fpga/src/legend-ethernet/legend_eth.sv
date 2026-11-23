// SPDX-License-Identifier: Apache-2.0
// legend_eth: descriptor-ring Ethernet MAC front end that moves packets by DMA through a
// memory port that is coherent with the CPU's cache. The byte-stream MAC, PCS and PHY below it
// (legend_eth_mac_1g and LiteEth's SGMII PHY, in legend_sgmii) have AXI-stream interfaces on the PCS's
// receive and transmit clocks; this module sits between those and memory on the system clock.
//
// From the legend64 project. Changed here in one place, the memory port's arbitration at the
// end of the file: a request stays on the port until it is granted. In this SoC the port is
// the device port of CVA6's data cache (DevicePortEn in cva6.sv), which grants a write when the
// cache has answered it.
//
// Software interface (32-bit registers):
//   0x00 CTRL        bit0 receive enable, bit1 transmit enable, bit2 promiscuous,
//                    bit8 (write 1) reset both ring positions to 0
//   0x04 STATUS      bit0 link up; bits 31:16 PCS status
//   0x08 IRQ_STATUS  bit0 frame received, bit1 frame sent, bit2 frame dropped (no descriptor or
//                    FIFO full). Write 1 to clear.
//   0x0c IRQ_ENABLE
//   0x10 MAC_LO      address bytes 0..3 (byte 0 in bits 7:0)      0x14 MAC_HI  bytes 4..5
//   0x20 RX_BASE_LO  0x24 RX_BASE_HI   physical address of the receive descriptor array
//   0x28 RX_SIZE     number of descriptors (a power of two)
//   0x2c RX_HEAD     (read) next descriptor the hardware will fill
//   0x30 RX_TAIL     (write) hardware may fill descriptors up to, not including, this one
//   0x40 TX_BASE_LO  0x44 TX_BASE_HI   0x48 TX_SIZE
//   0x4c TX_HEAD     (read) next descriptor the hardware will send
//   0x50 TX_TAIL     (write) one past the last descriptor ready to send
//   0x60 RX_DROPPED  frames dropped, wraps
//   0x64 FEATURES    (read) bit0 receive checksum, bit1 transmit frames of several descriptors,
//                    bit2 transmit checksum insertion, bit3 the three receive counters below,
//                    bit4 the four transmit counters
//   0x68 RX_FIFO     frames lost because the receive FIFO was full          (16 bits, wrap)
//   0x6c RX_BAD      frames the MAC marked bad (FCS error, bad symbol)       (16 bits, wrap)
//   0x70 RX_LONG     frames over 1518 bytes, discarded                       (16 bits, wrap)
//   Transmit frames counted at four points on their way out (FEATURES bit4; 16 bits, wrap):
//   0x74 TX_QUEUED   frames put whole into the transmit FIFO
//   0x78 TX_DISCARD  frames given up (too long, empty, or transmission switched off part way)
//   0x7c TX_MAC      frames handed to the MAC, last byte accepted
//   0x80 TX_PCS      frames the MAC started on its GMII output (counted by the PHY wrapper)
//
// Descriptor, 16 bytes:  +0  u64 buffer physical address
//                        +8  u32 length, +12 u32 flags (bit0 DONE, written by the hardware)
// Receive: the buffer address must be 8-byte aligned and the buffer at least 1536 bytes. The
//   frame (without FCS) is stored starting at address + 2, so the IP header lands on a 4-byte
//   boundary; the hardware then writes the length and the flags and advances RX_HEAD.
//   Flags: bit0 DONE, bit1 checksum present, bits 31:16 the ones' complement sum of the frame
//   from byte 14 to its end, as 16-bit little-endian words, folded (what Linux calls
//   CHECKSUM_COMPLETE on a little-endian machine).
// Transmit: any byte address; a frame is the bytes of one or more descriptors (the MAC pads
//   short frames and appends the FCS); the hardware writes DONE to each and advances TX_HEAD.
//   Flags from software: bit1 MORE (the frame continues in the next descriptor); and in a
//   frame's first descriptor bit2 CSUM, bits 23:16 START, bits 31:24 OFFSET: the ones'
//   complement sum of the frame from byte START (even) to its end is folded, inverted and
//   stored at byte START + OFFSET (even), which until then holds the pseudo-header sum.
//   TX_TAIL must not expose part of a frame. Frames over 1518 bytes are discarded.
// Buffers and rings live in main memory; no bounce buffers or cache maintenance are needed.

// Passes a multi-bit value to another clock domain: the value is held steady while a toggle
// goes round a request/acknowledge loop.
module legend_sync_val #(
    parameter int W = 12
) (
    input  logic         src_clk,
    input  logic         src_rst,      // each side has the reset of its own clock; if only one
    input  logic [W-1:0] src_val,      // is reset the loop settles again by itself
    input  logic         dst_clk,
    input  logic         dst_rst,
    output logic [W-1:0] dst_val
);
  logic [W-1:0] hold, dst_q;
  logic         req, ack;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_s, req_s;
  assign dst_val = dst_q;
  always_ff @(posedge src_clk) begin
    if (src_rst) begin
      ack_s <= '0; hold <= '0; req <= 1'b0;
    end else begin
      ack_s <= {ack_s[0], ack};
      if (ack_s[1] == req && src_val != hold) begin hold <= src_val; req <= !req; end
    end
  end
  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      req_s <= '0; dst_q <= '0; ack <= 1'b0;
    end else begin
      req_s <= {req_s[0], req};
      if (req_s[1] != ack) begin dst_q <= hold; ack <= req_s[1]; end
    end
  end
endmodule

// Dual-clock FIFO of 72-bit words in block RAM. Written words become visible to the reader
// only when committed, and can be discarded instead: whole packets or nothing.
module legend_pkt_fifo #(
    parameter int AW = 10
) (
    input  logic        wclk,
    input  logic        wrst,
    input  logic        w_valid,
    input  logic [71:0] w_data,
    input  logic        w_commit,    // with or after the last word
    input  logic        w_abort,
    input  logic        w_patch,     // rewrite an uncommitted word (not together with w_valid)
    input  logic [AW-1:0] w_patch_idx, // which: counted from the first uncommitted word
    output logic        w_full,      // no room for this word
    output logic [AW:0] w_free,      // words free (conservative)
    input  logic        rclk,
    input  logic        rrst,
    output logic        r_valid,
    output logic [71:0] r_data,
    input  logic        r_ready
);
  (* ram_style = "block" *) logic [71:0] mem[1 << AW];
  logic [AW:0] wr_ptr, wr_commit, rd_ptr, rd_ptr_w, commit_r, rd_next;

  // one write port, or the memory is not a block RAM
  logic [AW-1:0] w_addr;
  assign w_addr = w_patch ? wr_commit[AW-1:0] + w_patch_idx : wr_ptr[AW-1:0];
  assign w_free = (AW+1)'(1 << AW) - (wr_ptr - rd_ptr_w);
  assign w_full = w_free == '0;
  always_ff @(posedge wclk) begin
    if (w_patch || (w_valid && !w_full)) mem[w_addr] <= w_data;
    if (wrst) begin
      wr_ptr <= '0; wr_commit <= '0;
    end else begin
      if (w_abort) wr_ptr <= wr_commit;
      else begin
        if (w_valid && !w_full) wr_ptr <= wr_ptr + 1'b1;
        if (w_commit) wr_commit <= wr_ptr + (AW+1)'(w_valid && !w_full);
      end
    end
  end

  legend_sync_val #(.W(AW + 1)) u_c2r (.src_clk(wclk), .src_rst(wrst), .src_val(wr_commit), .dst_clk(rclk), .dst_rst(rrst), .dst_val(commit_r));
  legend_sync_val #(.W(AW + 1)) u_r2w (.src_clk(rclk), .src_rst(rrst), .src_val(rd_ptr), .dst_clk(wclk), .dst_rst(wrst), .dst_val(rd_ptr_w));

  assign r_valid = rd_ptr != commit_r;
  assign rd_next = rd_ptr + (AW+1)'(r_valid && r_ready);
  always_ff @(posedge rclk) begin
    r_data <= mem[rd_next[AW-1:0]];
    if (rrst) rd_ptr <= '0;
    else      rd_ptr <= rd_next;
  end
endmodule

module legend_eth #(
    parameter int RX_FIFO_AW = 14     // receive FIFO depth in 8-byte words: 14 is 128 KiB
) (
    input  logic        clk,          // system clock
    input  logic        rst,

    // register access: one-cycle strobe; read data is valid the following cycle
    input  logic        reg_sel,
    input  logic        reg_we,
    input  logic [7:0]  reg_addr,
    input  logic [31:0] reg_wdata,
    output logic [31:0] reg_rdata,
    output logic        irq,

    // coherent memory port; addresses are offsets into RAM. A write is complete, and visible
    // to the CPU, when it is granted; a read is granted and its data follows with e_rvalid.
    output logic        e_req,
    output logic        e_we,
    output logic [29:0] e_addr,
    output logic [63:0] e_wdata,
    output logic [7:0]  e_be,
    input  logic        e_gnt,
    input  logic        e_rvalid,
    input  logic [63:0] e_rdata,

    // byte streams of the MAC, each on its own clock
    input  logic        mac_clk,      // receive
    input  logic        mac_rst,
    input  logic        mac_tx_clk,
    input  logic        mac_tx_rst,
    input  logic [7:0]  rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    input  logic        rx_tuser,     // bad frame
    output logic [7:0]  tx_tdata,
    output logic        tx_tvalid,
    output logic        tx_tlast,
    input  logic        tx_tready,
    input  logic [15:0] tx_pcs_frames,   // on mac_tx_clk: frames started on the GMII output
    input  logic [15:0] pcs_status
);
  // ------------------------------------------------------------------ registers
  logic        rx_en, tx_en, promisc;
  logic [2:0]  irq_status, irq_enable;
  logic [47:0] mac_addr;
  logic [63:0] rx_base, tx_base;
  logic [15:0] rx_size, tx_size, rx_head, rx_tail, tx_head, tx_tail;
  logic [31:0] rx_dropped;
  logic [15:0] cnt_fifo, cnt_bad, cnt_long;    // from the MAC clock domain
  logic [15:0] cnt_txq, cnt_txdisc, cnt_txmac, cnt_txpcs;
  logic        ev_rx, ev_tx, ev_drop, rx_adv, tx_adv;
  (* ASYNC_REG = "TRUE" *) logic [1:0] link_s;

  assign irq = |(irq_status & irq_enable);

  always_ff @(posedge clk) begin
    link_s <= {link_s[0], pcs_status[0]};
    if (rst) begin
      rx_en <= 1'b0; tx_en <= 1'b0; promisc <= 1'b0; irq_status <= '0; irq_enable <= '0;
      mac_addr <= '0; rx_base <= '0; tx_base <= '0; rx_size <= 16'd1; tx_size <= 16'd1;
      rx_head <= '0; rx_tail <= '0; tx_head <= '0; tx_tail <= '0; rx_dropped <= '0;
      link_s <= '0; reg_rdata <= '0;
    end else begin
      if (ev_rx)   irq_status[0] <= 1'b1;
      if (ev_tx)   irq_status[1] <= 1'b1;
      if (ev_drop) begin irq_status[2] <= 1'b1; rx_dropped <= rx_dropped + 32'd1; end
      if (rx_adv) rx_head <= (rx_head + 16'd1) & (rx_size - 16'd1);
      if (tx_adv) tx_head <= (tx_head + 16'd1) & (tx_size - 16'd1);
      if (reg_sel && reg_we) begin
        unique case (reg_addr)
          8'h00: begin
            rx_en <= reg_wdata[0]; tx_en <= reg_wdata[1]; promisc <= reg_wdata[2];
            if (reg_wdata[8]) begin rx_head <= '0; rx_tail <= '0; tx_head <= '0; tx_tail <= '0; end
          end
          8'h08: irq_status <= (irq_status & ~reg_wdata[2:0]) | {ev_drop, ev_tx, ev_rx};
          8'h0c: irq_enable <= reg_wdata[2:0];
          8'h10: mac_addr[31:0]  <= reg_wdata;
          8'h14: mac_addr[47:32] <= reg_wdata[15:0];
          8'h20: rx_base[31:0]   <= reg_wdata;
          8'h24: rx_base[63:32]  <= reg_wdata;
          8'h28: rx_size <= reg_wdata[15:0];
          8'h30: rx_tail <= reg_wdata[15:0];
          8'h40: tx_base[31:0]   <= reg_wdata;
          8'h44: tx_base[63:32]  <= reg_wdata;
          8'h48: tx_size <= reg_wdata[15:0];
          8'h50: tx_tail <= reg_wdata[15:0];
          default: ;
        endcase
      end
      if (reg_sel && !reg_we) begin
        unique case (reg_addr)
          8'h00: reg_rdata <= {29'b0, promisc, tx_en, rx_en};
          8'h04: reg_rdata <= {pcs_status, 15'b0, link_s[1]};
          8'h08: reg_rdata <= {29'b0, irq_status};
          8'h0c: reg_rdata <= {29'b0, irq_enable};
          8'h10: reg_rdata <= mac_addr[31:0];
          8'h14: reg_rdata <= {16'b0, mac_addr[47:32]};
          8'h20: reg_rdata <= rx_base[31:0];
          8'h24: reg_rdata <= rx_base[63:32];
          8'h28: reg_rdata <= {16'b0, rx_size};
          8'h2c: reg_rdata <= {16'b0, rx_head};
          8'h30: reg_rdata <= {16'b0, rx_tail};
          8'h40: reg_rdata <= tx_base[31:0];
          8'h44: reg_rdata <= tx_base[63:32];
          8'h48: reg_rdata <= {16'b0, tx_size};
          8'h4c: reg_rdata <= {16'b0, tx_head};
          8'h50: reg_rdata <= {16'b0, tx_tail};
          8'h60: reg_rdata <= rx_dropped;
          8'h64: reg_rdata <= 32'h1f;
          8'h74: reg_rdata <= {16'b0, cnt_txq};
          8'h78: reg_rdata <= {16'b0, cnt_txdisc};
          8'h7c: reg_rdata <= {16'b0, cnt_txmac};
          8'h80: reg_rdata <= {16'b0, cnt_txpcs};
          8'h68: reg_rdata <= {16'b0, cnt_fifo};
          8'h6c: reg_rdata <= {16'b0, cnt_bad};
          8'h70: reg_rdata <= {16'b0, cnt_long};
          default: reg_rdata <= '0;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------ receive, MAC clock:
  // pack bytes into 64-bit words (two bytes of padding first), filter on the destination
  // address, and commit the frame to the FIFO only if it arrived whole and good
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_en_m, promisc_m;
  logic [63:0] rxp_word;
  logic [3:0]  rxp_cnt;          // bytes held in rxp_word
  logic        rxp_first, rxp_drop, rxf_wvalid, rxf_commit, rxf_abort, rxf_full;
  logic [71:0] rxf_wdata;
  logic [63:0] rxp_full;
  logic        rxp_last_now, rxp_word_now, addr_ok;
  logic [47:0] rxp_dst;
  logic [10:0] rxp_len;          // bytes of the frame so far, saturating
  logic        rxp_long, rxp_lost, rxp_too_long;
  logic [15:0] m_fifo, m_bad, m_long;

  assign rxp_full     = rxp_word | (64'(rx_tdata) << {rxp_cnt[2:0], 3'b000});
  assign rxp_last_now = rx_tvalid && rx_tlast;
  assign rxp_word_now = rx_tvalid && (rxp_cnt == 4'd7 || rx_tlast);
  assign rxp_dst      = rxp_full[63:16];
  // unicast to us, broadcast or any multicast (bit 0 of the first byte), or everything
  assign addr_ok      = promisc_m[1] || rxp_dst[0] || rxp_dst == mac_addr;

  assign rxf_wvalid = rxp_word_now && !rxp_drop && !(rxp_first && !addr_ok) && rx_en_m[1];
  assign rxf_wdata  = {rx_tlast, 3'b0, rxp_cnt + 4'd1, rxp_full};
  assign rxp_too_long = rxp_long || rxp_len == 11'd1518;      // this byte is one too many
  assign rxf_commit = rxp_last_now && !rx_tuser && !rxp_drop && !rxp_too_long && !rxf_full && !(rxp_first && !addr_ok) && rx_en_m[1];
  assign rxf_abort  = rxp_last_now && !rxf_commit;

  always_ff @(posedge mac_clk) begin
    rx_en_m   <= {rx_en_m[0], rx_en};
    promisc_m <= {promisc_m[0], promisc};
    if (mac_rst) begin
      rxp_word <= '0; rxp_cnt <= 4'd2; rxp_first <= 1'b1; rxp_drop <= 1'b0;
      rxp_len <= '0; rxp_long <= 1'b0; rxp_lost <= 1'b0; m_fifo <= '0; m_bad <= '0; m_long <= '0;
      rx_en_m <= '0; promisc_m <= '0;
    end else if (rx_tvalid) begin
      if (rxp_len != 11'd1518) rxp_len <= rxp_len + 11'd1;
      else begin rxp_long <= 1'b1; rxp_drop <= 1'b1; end
      if (rxp_word_now && rxf_full && !rxp_drop && !(rxp_first && !addr_ok) && rx_en_m[1]) rxp_lost <= 1'b1;
      if (rx_tlast) begin
        rxp_word <= '0; rxp_cnt <= 4'd2; rxp_first <= 1'b1; rxp_drop <= 1'b0;
        rxp_len <= '0; rxp_long <= 1'b0; rxp_lost <= 1'b0;
        // why a frame meant for us was not kept
        if (rx_tuser) m_bad <= m_bad + 16'd1;
        else if (rxp_too_long) m_long <= m_long + 16'd1;
        else if (rxp_lost || (rxf_full && !rxp_drop && !(rxp_first && !addr_ok) && rx_en_m[1])) m_fifo <= m_fifo + 16'd1;
      end else if (rxp_cnt == 4'd7) begin
        rxp_word <= '0; rxp_cnt <= 4'd0; rxp_first <= 1'b0;
        if (rxf_full || (rxp_first && !addr_ok) || !rx_en_m[1]) rxp_drop <= 1'b1;
      end else begin
        rxp_word <= rxp_full; rxp_cnt <= rxp_cnt + 4'd1;
      end
    end
  end

  logic        rxf_rvalid, rxf_rready;
  logic [71:0] rxf_rdata;
  legend_sync_val #(.W(16)) u_cf (.src_clk(mac_clk), .src_rst(mac_rst), .src_val(m_fifo), .dst_clk(clk), .dst_rst(rst), .dst_val(cnt_fifo));
  legend_sync_val #(.W(16)) u_cb (.src_clk(mac_clk), .src_rst(mac_rst), .src_val(m_bad), .dst_clk(clk), .dst_rst(rst), .dst_val(cnt_bad));
  legend_sync_val #(.W(16)) u_cl (.src_clk(mac_clk), .src_rst(mac_rst), .src_val(m_long), .dst_clk(clk), .dst_rst(rst), .dst_val(cnt_long));

  legend_pkt_fifo #(.AW(RX_FIFO_AW)) u_rxf (
      .wclk(mac_clk), .wrst(mac_rst), .w_valid(rxf_wvalid), .w_data(rxf_wdata), .w_commit(rxf_commit),
      .w_abort(rxf_abort), .w_patch(1'b0), .w_patch_idx('0), .w_full(rxf_full), .w_free(),
      .rclk(clk), .rrst(rst), .r_valid(rxf_rvalid), .r_data(rxf_rdata), .r_ready(rxf_rready)
  );

  // ------------------------------------------------------------------ receive, system clock
  typedef enum logic [2:0] {R_IDLE, R_DESC_RD, R_DESC_WAIT, R_COPY, R_FOLD, R_DESC_WR, R_DROP} rstate_e;
  rstate_e     r_state;
  logic [63:0] r_buf, r_desc;
  logic [27:0] r_csum;           // sum of the 16-bit words from byte 14 of the frame (word 2 here)
  logic [16:0] r_fold;
  logic [15:0] r_csum16;
  logic [8:0]  r_words;
  logic [10:0] r_len;
  logic        r_req, r_we, r_gnt, r_rvalid;
  logic [63:0] r_addr, r_wdata;
  logic [7:0]  r_be;

  assign r_desc   = rx_base + {44'b0, rx_head, 4'b0};
  assign r_csum16 = r_fold[15:0] + 16'(r_fold[16]);
  always_comb begin
    r_req = 1'b0; r_we = 1'b0; r_addr = r_desc; r_wdata = '0; r_be = 8'hff; rxf_rready = 1'b0;
    unique case (r_state)
      R_DESC_RD: r_req = 1'b1;
      R_COPY: begin
        r_req   = rxf_rvalid;
        r_we    = 1'b1;
        r_addr  = r_buf + {52'b0, r_words, 3'b0};
        r_wdata = rxf_rdata[63:0];
        r_be    = rxf_rdata[71] ? 8'((9'd1 << rxf_rdata[67:64]) - 9'd1) : 8'hff;
        rxf_rready = r_gnt && rxf_rvalid;
      end
      R_DESC_WR: begin
        r_req = 1'b1; r_we = 1'b1; r_addr = r_desc + 64'd8; r_wdata = {r_csum16, 14'b0, 2'b11, 21'b0, r_len};
      end
      R_DROP: rxf_rready = rxf_rvalid;
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    ev_rx <= 1'b0; ev_drop <= 1'b0; rx_adv <= 1'b0;
    if (rst) begin
      r_state <= R_IDLE;
      r_buf <= '0; r_words <= '0; r_len <= '0; r_csum <= '0; r_fold <= '0;
    end else begin
      unique case (r_state)
        R_IDLE: if (rxf_rvalid && !rx_adv) begin
          if (rx_en && rx_head != rx_tail) r_state <= R_DESC_RD;
          else begin r_state <= R_DROP; ev_drop <= 1'b1; end
        end
        R_DESC_RD:   if (r_gnt) r_state <= R_DESC_WAIT;
        R_DESC_WAIT: if (r_rvalid) begin r_buf <= e_rdata; r_words <= '0; r_csum <= '0; r_state <= R_COPY; end
        R_COPY: if (r_gnt && rxf_rvalid) begin
          r_words <= r_words + 9'd1;
          // bytes past the end of the frame are zero in the last word
          if (r_words >= 9'd2)
            r_csum <= r_csum + 28'(rxf_rdata[15:0]) + 28'(rxf_rdata[31:16]) + 28'(rxf_rdata[47:32]) + 28'(rxf_rdata[63:48]);
          if (rxf_rdata[71]) begin
            r_len   <= 11'({r_words, 3'b0}) + 11'(rxf_rdata[67:64]) - 11'd2;
            r_state <= R_FOLD;
          end
        end
        R_FOLD: begin r_fold <= 17'(r_csum[15:0]) + 17'(r_csum[27:16]); r_state <= R_DESC_WR; end
        R_DESC_WR: if (r_gnt) begin ev_rx <= 1'b1; rx_adv <= 1'b1; r_state <= R_IDLE; end
        R_DROP: if (rxf_rvalid && rxf_rdata[71]) r_state <= R_IDLE;
        default: r_state <= R_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------ transmit, system clock:
  // the bytes of a frame's descriptors, each at any alignment, are packed into 64-bit words
  // aligned to the frame; the checksum, if asked for, is summed as the words go into the FIFO
  // and put into the word that holds it before the frame is committed
  typedef enum logic [3:0] {T_IDLE, T_DESC0, T_DESC0_W, T_DESC1, T_DESC1_W, T_COPY, T_COPY_W, T_DESC_WR,
                            T_NEXT, T_FLUSH, T_FOLD, T_PATCH, T_END} tstate_e;
  tstate_e     t_state;
  logic [63:0] t_buf, t_desc;
  logic [10:0] t_len;
  logic [8:0]  t_word, t_nwords;
  logic [11:0] t_span;           // offset + length
  logic [11:0] t_total;          // frame length so far
  logic        t_first, t_more, t_bad, t_abort, t_len_bad;
  logic        t_csum_en;
  logic [7:0]  t_cs, t_co;
  logic        t_req, t_we, t_gnt, t_rvalid, txf_wvalid, txf_commit, txf_abort, txf_patch, txf_full;
  logic [10:0] txf_free;
  logic [63:0] t_addr, t_wdata;
  logic [71:0] txf_wdata;
  logic        t_last;

  assign t_desc    = tx_base + {44'b0, tx_head, 4'b0};
  assign t_span    = {9'b0, t_buf[2:0]} + {1'b0, t_len};
  assign t_nwords  = t_span[11:3] + 9'(|t_span[2:0]);
  assign t_last    = t_word + 9'd1 == t_nwords;
  assign t_len_bad = e_rdata[31:0] > 32'd1518 || 12'(e_rdata[10:0]) + t_total > 12'd1518;
  always_comb begin
    t_req = 1'b0; t_we = 1'b0; t_addr = t_desc; t_wdata = '0;
    unique case (t_state)
      T_DESC0: t_req = 1'b1;
      T_DESC1: begin t_req = 1'b1; t_addr = t_desc + 64'd8; end
      T_COPY:  begin t_req = 1'b1; t_addr = {t_buf[63:3], 3'b0} + {52'b0, t_word, 3'b0}; end
      T_DESC_WR: begin t_req = 1'b1; t_we = 1'b1; t_addr = t_desc + 64'd8; t_wdata = {32'd1, 21'b0, t_len}; end
      default: ;
    endcase
  end

  // a word from memory and which of its bytes belong to the frame
  logic        s1_v;
  logic [63:0] s1_data;
  logic [2:0]  s1_lo;
  logic [3:0]  s1_n;
  // packer: bytes not yet making a whole word, and the last whole word, held back so that the
  // frame's final word can be marked
  logic [63:0]  pk_acc, pk_pend, pk_in;
  logic [2:0]   pk_fill;
  logic         pk_pend_v;
  logic [127:0] pk_wide;
  logic [4:0]   pk_tot;
  assign pk_in   = (s1_data >> {s1_lo, 3'b0}) & ~(64'hffff_ffff_ffff_ffff << {s1_n, 3'b0});
  assign pk_wide = {64'b0, pk_acc} | ({64'b0, pk_in} << {pk_fill, 3'b0});
  assign pk_tot  = 5'(pk_fill) + 5'(s1_n);

  // what goes into the FIFO
  logic        tw_data, tw_last, tw_from_acc;
  logic [3:0]  tw_cnt;
  logic [63:0] tw_word;
  logic [7:0]  t_wi;             // words of this frame written so far
  always_comb begin
    tw_data = 1'b0; tw_last = 1'b0; tw_from_acc = 1'b0; tw_cnt = 4'd8;
    if (s1_v) tw_data = pk_tot >= 5'd8 && pk_pend_v;
    else if (t_state == T_FLUSH && !t_bad) begin
      if (pk_fill != 0 && pk_pend_v) tw_data = 1'b1;
      else if (pk_fill != 0) begin tw_data = 1'b1; tw_last = 1'b1; tw_from_acc = 1'b1; tw_cnt = {1'b0, pk_fill}; end
      else if (pk_pend_v)    begin tw_data = 1'b1; tw_last = 1'b1; end
    end
  end
  assign tw_word = tw_from_acc ? pk_acc : pk_pend;

  // checksum: the bytes from t_cs on, as 16-bit words
  logic [63:0] cs_masked;
  logic [27:0] cs_sum;
  logic [16:0] cs_fold;
  logic [15:0] cs_inv, cs_out;
  logic [8:0]  cs_field;         // byte offset of the checksum in the frame
  logic        fw_v;             // the word that holds it has been written and is kept here
  logic [63:0] fw_word, fw_patched;
  logic [7:0]  fw_meta;
  always_comb begin
    cs_masked = tw_word;
    if (t_wi < 8'(t_cs[7:3])) cs_masked = '0;
    else if (t_wi == 8'(t_cs[7:3])) cs_masked = tw_word & (64'hffff_ffff_ffff_ffff << {t_cs[2:0], 3'b0});
    fw_patched = fw_word;
    fw_patched[{cs_field[2:1], 4'b0}+:16] = cs_out;
  end
  assign cs_field = 9'(t_cs) + 9'(t_co);
  assign cs_inv   = ~(cs_fold[15:0] + 16'(cs_fold[16]));
  assign cs_out   = cs_inv == 16'h0 ? 16'hffff : cs_inv;

  assign txf_wvalid = tw_data;
  assign txf_wdata  = txf_patch ? {fw_meta, fw_patched} : {tw_last, 3'b0, tw_cnt, tw_word};
  assign txf_patch  = t_state == T_PATCH && fw_v;
  assign txf_commit = t_state == T_END && !t_abort;
  assign txf_abort  = t_state == T_END && t_abort;

  always_ff @(posedge clk) begin
    ev_tx <= 1'b0; tx_adv <= 1'b0; s1_v <= 1'b0;
    if (rst) begin
      t_state <= T_IDLE; pk_fill <= '0; pk_pend_v <= 1'b0; pk_acc <= '0;
      cnt_txq <= '0; cnt_txdisc <= '0;
      // the rest of the transmit path's registers: each is loaded before it is used
      t_buf <= '0; t_len <= '0; t_word <= '0; t_total <= '0; t_wi <= '0;
      t_first <= 1'b0; t_more <= 1'b0; t_bad <= 1'b0; t_abort <= 1'b0;
      t_csum_en <= 1'b0; t_cs <= '0; t_co <= '0; cs_sum <= '0; cs_fold <= '0;
      s1_data <= '0; s1_lo <= '0; s1_n <= '0; pk_pend <= '0;
      fw_v <= 1'b0; fw_word <= '0; fw_meta <= '0;
    end else begin
      if (s1_v) begin
        if (pk_tot >= 5'd8) begin
          pk_pend <= pk_wide[63:0]; pk_pend_v <= 1'b1; pk_acc <= pk_wide[127:64]; pk_fill <= 3'(pk_tot - 5'd8);
        end else begin
          pk_acc <= pk_wide[63:0]; pk_fill <= pk_tot[2:0];
        end
      end
      if (tw_data) begin
        t_wi   <= t_wi + 8'd1;
        cs_sum <= cs_sum + 28'(cs_masked[15:0]) + 28'(cs_masked[31:16]) + 28'(cs_masked[47:32]) + 28'(cs_masked[63:48]);
        // keep the word with the checksum field, unless the frame ends before the field does
        if (t_wi == 8'(cs_field[8:3]) && !(tw_last && tw_cnt < 4'({1'b0, cs_field[2:1], 1'b0}) + 4'd2)) begin
          fw_v <= 1'b1; fw_word <= tw_word; fw_meta <= {tw_last, 3'b0, tw_cnt};
        end
      end
      unique case (t_state)
        // start only with room for a whole maximum-size frame, so the copy never stalls half way
        T_IDLE: if (tx_en && tx_head != tx_tail && !tx_adv && txf_free > 11'd200) begin
          t_first <= 1'b1; t_total <= '0; t_bad <= 1'b0; t_abort <= 1'b0;
          pk_fill <= '0; pk_pend_v <= 1'b0; pk_acc <= '0; t_wi <= '0; cs_sum <= '0; fw_v <= 1'b0;
          t_state <= T_DESC0;
        end
        T_DESC0:   if (t_gnt) t_state <= T_DESC0_W;
        T_DESC0_W: if (t_rvalid) begin t_buf <= e_rdata; t_state <= T_DESC1; end
        T_DESC1:   if (t_gnt) t_state <= T_DESC1_W;
        T_DESC1_W: if (t_rvalid) begin
          t_len <= e_rdata[10:0]; t_word <= '0; t_more <= e_rdata[33];
          t_total <= t_total + 12'(e_rdata[10:0]);
          if (t_first) begin t_csum_en <= e_rdata[34]; t_cs <= e_rdata[55:48]; t_co <= e_rdata[63:56]; end
          if (t_len_bad) t_bad <= 1'b1;
          t_state <= (e_rdata[31:0] == 0 || t_len_bad || t_bad) ? T_DESC_WR : T_COPY;
        end
        T_COPY:    if (t_gnt) t_state <= T_COPY_W;
        T_COPY_W:  if (t_rvalid) begin
          s1_v    <= 1'b1; s1_data <= e_rdata;
          s1_lo   <= t_word == 0 ? t_buf[2:0] : 3'd0;
          s1_n    <= (t_last ? (t_span[2:0] == 3'd0 ? 4'd8 : {1'b0, t_span[2:0]}) : 4'd8) - (t_word == 0 ? {1'b0, t_buf[2:0]} : 4'd0);
          t_word  <= t_word + 9'd1;
          t_state <= t_last ? T_DESC_WR : T_COPY;
        end
        T_DESC_WR: if (t_gnt) begin tx_adv <= 1'b1; t_first <= 1'b0; t_state <= t_more ? T_NEXT : T_FLUSH; end
        // the rest of the frame must already be in the ring; if transmission is switched off
        // instead, give the frame up
        T_NEXT: if (!tx_en) begin t_bad <= 1'b1; t_state <= T_FLUSH; end
                else if (tx_head != tx_tail && !tx_adv) t_state <= T_DESC0;
        T_FLUSH: if (!s1_v) begin
          if (t_bad || (pk_fill == 0 && !pk_pend_v)) begin t_abort <= 1'b1; t_state <= T_END; end
          else if (pk_fill != 0 && pk_pend_v) pk_pend_v <= 1'b0;
          else t_state <= t_csum_en ? T_FOLD : T_END;
        end
        T_FOLD:  begin cs_fold <= 17'(cs_sum[15:0]) + 17'(cs_sum[27:16]); t_state <= T_PATCH; end
        T_PATCH: t_state <= T_END;
        T_END:   begin
          ev_tx <= 1'b1; t_state <= T_IDLE;
          if (t_abort) cnt_txdisc <= cnt_txdisc + 16'd1; else cnt_txq <= cnt_txq + 16'd1;
        end
        default: t_state <= T_IDLE;
      endcase
    end
  end

  logic        txf_rvalid, txf_rready;
  logic [71:0] txf_rdata;
  legend_pkt_fifo #(.AW(10)) u_txf (
      .wclk(clk), .wrst(rst), .w_valid(txf_wvalid), .w_data(txf_wdata), .w_commit(txf_commit),
      .w_abort(txf_abort), .w_patch(txf_patch), .w_patch_idx(10'(cs_field[8:3])), .w_full(txf_full), .w_free(txf_free),
      .rclk(mac_tx_clk), .rrst(mac_tx_rst), .r_valid(txf_rvalid), .r_data(txf_rdata), .r_ready(txf_rready)
  );

  // ------------------------------------------------------------------ transmit, MAC clock:
  // unpack words to bytes. A frame is started only once it is wholly in the FIFO, and each
  // word is taken from the FIFO as it starts, so the next one is ready when it ends: the MAC
  // is fed without gaps (it treats a gap inside a frame as an underrun).
  logic [71:0] txu_cur;
  logic [3:0]  txu_idx;
  logic        txu_run, txu_lastbyte;
  assign txu_lastbyte = txu_idx + 4'd1 == txu_cur[67:64];
  assign tx_tvalid    = txu_run;
  assign tx_tdata     = txu_cur[{txu_idx[2:0], 3'b000}+:8];
  assign tx_tlast     = txu_cur[71] && txu_lastbyte;
  assign txf_rready   = txf_rvalid && (!txu_run || (tx_tready && txu_lastbyte && !txu_cur[71]));
  logic [15:0] m_txmac;
  legend_sync_val #(.W(16)) u_ctm (.src_clk(mac_tx_clk), .src_rst(mac_tx_rst), .src_val(m_txmac), .dst_clk(clk), .dst_rst(rst), .dst_val(cnt_txmac));
  legend_sync_val #(.W(16)) u_ctp (.src_clk(mac_tx_clk), .src_rst(mac_tx_rst), .src_val(tx_pcs_frames), .dst_clk(clk), .dst_rst(rst), .dst_val(cnt_txpcs));
  always_ff @(posedge mac_tx_clk) begin
    if (mac_tx_rst) m_txmac <= '0;
    else if (tx_tvalid && tx_tready && tx_tlast) m_txmac <= m_txmac + 16'd1;
  end
  always_ff @(posedge mac_tx_clk) begin
    if (mac_tx_rst) begin
      txu_run <= 1'b0; txu_idx <= '0; txu_cur <= '0;
    end else if (!txu_run) begin
      if (txf_rvalid) begin txu_cur <= txf_rdata; txu_run <= 1'b1; txu_idx <= {1'b0, txf_rdata[70:68]}; end
    end else if (tx_tready) begin
      if (!txu_lastbyte) txu_idx <= txu_idx + 4'd1;
      else if (txu_cur[71]) txu_run <= 1'b0;
      else begin txu_cur <= txf_rdata; txu_idx <= '0; end
    end
  end

  // ------------------------------------------------------------------ memory port arbitration
  // Receive goes first, but a transmit request that has been put on the port stays there until
  // it is granted: the port may take several cycles to grant a write (not before the cache has
  // answered it), and what it is working on must not change under it.
  logic rd_owner_tx;
  logic sel_tx, tx_held;
  assign sel_tx   = tx_held || (!r_req && t_req);
  always_ff @(posedge clk) begin
    if (rst) tx_held <= 1'b0;
    else     tx_held <= sel_tx && !e_gnt;
  end
  assign e_req    = r_req || t_req;
  assign e_we     = sel_tx ? t_we : r_we;
  assign e_addr   = sel_tx ? t_addr[29:0] : r_addr[29:0];
  assign e_wdata  = sel_tx ? t_wdata : r_wdata;
  assign e_be     = sel_tx ? 8'hff : r_be;
  assign r_gnt    = e_gnt && r_req && !sel_tx;
  assign t_gnt    = e_gnt && sel_tx;
  assign r_rvalid = e_rvalid && !rd_owner_tx;
  assign t_rvalid = e_rvalid && rd_owner_tx;
  always_ff @(posedge clk) begin
    if (rst) rd_owner_tx <= 1'b0;
    else if (e_req && e_gnt && !e_we) rd_owner_tx <= sel_tx;
  end
endmodule
