// ie_dram_reader.sv — DMA read controller for weight/activation loading
//
// Transfers data from DRAM to inference engine BRAM buffers via AXI4
// read bursts.  Each BRAM word (ARRAY_COLS×DATA_WIDTH bits) is assembled
// from BEATS_PW consecutive 64-bit AXI beats (low beat first).
// INT16: BEATS_PW=4 (256-bit words).  INT8: BEATS_PW=2 (128-bit words).
//
// CSR map (active at wrapper offset 0x800):
//   0x00: DMA_CTRL      [0] start (W1S), [1] busy (RO), [2] done (RO/W1C)
//   0x04: DMA_SRC_LO    DRAM source address [31:0]
//   0x08: DMA_SRC_HI    DRAM source address [63:32]
//   0x0C: DMA_DST_ADDR  BRAM destination start address [11:0]
//   0x10: DMA_LEN       Number of 256-bit BRAM words to transfer [15:0]
//   0x14: DMA_TARGET    [0] 0=weight_buf, 1=activation_buf

module ie_dram_reader #(
  parameter int unsigned WBUF_DEPTH   = 16384,
  parameter int unsigned ABUF_DEPTH   = 1024,
  parameter int unsigned ARRAY_ROWS   = 16,
  parameter int unsigned ARRAY_COLS   = 16,
  parameter int unsigned DATA_WIDTH   = 16
) (
  input  logic clk,
  input  logic rst_n,

  // ---- 32-bit AXI-Lite slave (CSR) ----
  input  logic [11:0]  s_axi_awaddr,
  input  logic         s_axi_awvalid,
  output logic         s_axi_awready,
  input  logic [31:0]  s_axi_wdata,
  input  logic [3:0]   s_axi_wstrb,
  input  logic         s_axi_wvalid,
  output logic         s_axi_wready,
  output logic [1:0]   s_axi_bresp,
  output logic         s_axi_bvalid,
  input  logic         s_axi_bready,
  input  logic [11:0]  s_axi_araddr,
  input  logic         s_axi_arvalid,
  output logic         s_axi_arready,
  output logic [31:0]  s_axi_rdata,
  output logic [1:0]   s_axi_rresp,
  output logic         s_axi_rvalid,
  input  logic         s_axi_rready,

  // ---- AXI4 read-only master (64-bit data) ----
  output logic [63:0]  m_axi_araddr,
  output logic [7:0]   m_axi_arlen,
  output logic [2:0]   m_axi_arsize,
  output logic [1:0]   m_axi_arburst,
  output logic         m_axi_arvalid,
  input  logic         m_axi_arready,
  input  logic [63:0]  m_axi_rdata,
  input  logic [1:0]   m_axi_rresp,
  input  logic         m_axi_rlast,
  input  logic         m_axi_rvalid,
  output logic         m_axi_rready,

  // ---- Weight buffer write port ----
  output logic                              ext_wbuf_wr_en,
  output logic [$clog2(WBUF_DEPTH)-1:0]    ext_wbuf_wr_addr,
  output logic [ARRAY_COLS*DATA_WIDTH-1:0]  ext_wbuf_wr_data,

  // ---- Activation buffer write port ----
  output logic                              ext_abuf_wr_en,
  output logic [$clog2(ABUF_DEPTH)-1:0]    ext_abuf_wr_addr,
  output logic [ARRAY_ROWS*DATA_WIDTH-1:0]  ext_abuf_wr_data
);

  // ================================================================
  //  AXI-Lite CSR slave
  // ================================================================
  logic aw_pending, w_pending;
  logic [11:0] aw_addr_q;
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
    if (!rst_n) w_pending <= 1'b0;
    else if (w_fire)    w_pending <= 1'b1;
    else if (do_write)  w_pending <= 1'b0;
  end

  assign s_axi_awready = !aw_pending;
  assign s_axi_wready  = !w_pending;
  assign do_write       = aw_pending & w_pending;

  always_ff @(posedge clk) begin
    if (!rst_n)
      s_axi_bvalid <= 1'b0;
    else if (do_write)
      s_axi_bvalid <= 1'b1;
    else if (s_axi_bvalid && s_axi_bready)
      s_axi_bvalid <= 1'b0;
  end
  assign s_axi_bresp = 2'b00;

  // ================================================================
  //  CSR registers
  // ================================================================
  logic [63:0] src_addr_q;
  logic [$clog2(WBUF_DEPTH)-1:0] dst_addr_q;
  logic [15:0] length_q;
  logic        target_q;   // 0 = weight buffer, 1 = activation buffer
  logic        start_pulse;
  logic        done_clear;  // W1C pulse from CSR write
  logic        busy;
  logic        done;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      src_addr_q  <= '0;
      dst_addr_q  <= '0;
      length_q    <= '0;
      target_q    <= 1'b0;
      start_pulse <= 1'b0;
      done_clear  <= 1'b0;
    end else begin
      start_pulse <= 1'b0;
      done_clear  <= 1'b0;
      if (do_write) begin
        case (aw_addr_q[7:0])
          8'h00: begin
            if (s_axi_wdata[0]) start_pulse <= 1'b1;
            if (s_axi_wdata[2]) done_clear  <= 1'b1; // W1C done (pulse)
          end
          8'h04: src_addr_q[31:0]  <= s_axi_wdata;
          8'h08: src_addr_q[63:32] <= s_axi_wdata;
          8'h0C: dst_addr_q        <= s_axi_wdata[$clog2(WBUF_DEPTH)-1:0];
          8'h10: length_q          <= s_axi_wdata[15:0];
          8'h14: target_q          <= s_axi_wdata[0];
          default: ;
        endcase
      end
    end
  end

  // ---- Read path ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
    end else if (ar_fire) begin
      s_axi_rvalid <= 1'b1;
      case (s_axi_araddr[7:0])
        8'h00: s_axi_rdata <= {29'b0, done, busy, 1'b0};
        8'h04: s_axi_rdata <= src_addr_q[31:0];
        8'h08: s_axi_rdata <= src_addr_q[63:32];
        8'h0C: s_axi_rdata <= {{(32-$clog2(WBUF_DEPTH)){1'b0}}, dst_addr_q};
        8'h10: s_axi_rdata <= {16'b0, length_q};
        8'h14: s_axi_rdata <= {31'b0, target_q};
        default: s_axi_rdata <= 32'hDEAD_D1A0;
      endcase
    end else if (s_axi_rvalid && s_axi_rready)
      s_axi_rvalid <= 1'b0;
  end

  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp   = 2'b00;

  // ================================================================
  //  DMA state machine
  // ================================================================
  typedef enum logic [1:0] {
    DMA_IDLE,
    DMA_AR,
    DMA_RCOLLECT
  } dma_state_e;

  // BRAM word geometry derived from data width
  localparam int unsigned WORD_BITS  = ARRAY_COLS * DATA_WIDTH; // 256 for INT16
  localparam int unsigned BEATS_PW   = WORD_BITS / 64;          // 4 for INT16
  localparam int unsigned ADDR_SHIFT = $clog2(WORD_BITS / 8);   // 5 for INT16

  dma_state_e state;
  logic [15:0] words_done;         // BRAM words transferred so far
  logic [1:0]  beat_phase;         // current beat within a BRAM word (0..BEATS_PW-1)
  logic [WORD_BITS-1:0] accum_q;   // shift register assembling the current BRAM word

  // Burst geometry (combinational, derived from current state)
  wire [15:0] remaining   = length_q - words_done;
  wire [15:0] burst_words = (remaining >= 16'd8) ? 16'd8 : remaining;
  wire [63:0] burst_addr  = src_addr_q + ({48'b0, words_done} << ADDR_SHIFT);
  wire [$clog2(WBUF_DEPTH)-1:0] bram_addr = dst_addr_q + words_done[$clog2(WBUF_DEPTH)-1:0];

  assign m_axi_araddr  = burst_addr;
  assign m_axi_arlen   = 8'(burst_words * BEATS_PW) - 8'd1; // beats per burst, minus 1
  assign m_axi_arsize  = 3'b011;  // 8 bytes per beat
  assign m_axi_arburst = 2'b01;   // INCR

  wire r_beat  = m_axi_rvalid & m_axi_rready;
  wire bram_wr = r_beat & (beat_phase == 2'(BEATS_PW - 1));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= DMA_IDLE;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;
      busy          <= 1'b0;
      done          <= 1'b0;
      words_done    <= '0;
      beat_phase    <= 2'd0;
      accum_q       <= '0;
    end else begin
      case (state)
        // --------------------------------------------------------
        DMA_IDLE: begin
          if (done_clear) done <= 1'b0;
          if (start_pulse && !busy && length_q != '0) begin
            busy          <= 1'b1;
            done          <= 1'b0;
            words_done    <= '0;
            beat_phase    <= 2'd0;
            accum_q       <= '0;
            m_axi_arvalid <= 1'b1;   // issue first AR immediately
            state         <= DMA_AR;
          end
        end

        // --------------------------------------------------------
        DMA_AR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            state         <= DMA_RCOLLECT;
          end
        end

        // --------------------------------------------------------
        DMA_RCOLLECT: begin
          if (r_beat) begin
            // Shift accumulator: new beat enters at top, previous beats shift down
            accum_q    <= {m_axi_rdata, accum_q[WORD_BITS-1:64]};
            beat_phase <= beat_phase + 2'd1;
            if (beat_phase == 2'(BEATS_PW - 1)) begin
              beat_phase <= 2'd0;
              words_done <= words_done + 16'd1;
            end
          end

          // End of burst — rlast always aligns with beat_phase == BEATS_PW-1
          if (r_beat && m_axi_rlast) begin
            m_axi_rready <= 1'b0;
            // words_done + 1 accounts for the current (just-completing) word
            if (words_done + 16'd1 >= length_q) begin
              busy  <= 1'b0;
              done  <= 1'b1;
              state <= DMA_IDLE;
            end else begin
              m_axi_arvalid <= 1'b1;  // next burst
              state         <= DMA_AR;
            end
          end
        end

        default: state <= DMA_IDLE;
      endcase
    end
  end

  // ================================================================
  //  BRAM write outputs
  // ================================================================
  // On the last beat of a word, accum_q holds beats [BEATS_PW-2:0] shifted down,
  // and m_axi_rdata is beat BEATS_PW-1.  Full word: {last_beat, accum_q[WORD_BITS-1:64]}.
  wire [WORD_BITS-1:0] bram_wr_data = {m_axi_rdata, accum_q[WORD_BITS-1:64]};

  always_comb begin
    ext_wbuf_wr_en   = 1'b0;
    ext_wbuf_wr_addr = '0;
    ext_wbuf_wr_data = '0;
    ext_abuf_wr_en   = 1'b0;
    ext_abuf_wr_addr = '0;
    ext_abuf_wr_data = '0;

    if (bram_wr) begin
      if (!target_q) begin
        ext_wbuf_wr_en   = 1'b1;
        ext_wbuf_wr_addr = bram_addr[$clog2(WBUF_DEPTH)-1:0];
        ext_wbuf_wr_data = bram_wr_data;
      end else begin
        ext_abuf_wr_en   = 1'b1;
        ext_abuf_wr_addr = bram_addr[$clog2(ABUF_DEPTH)-1:0];
        ext_abuf_wr_data = bram_wr_data;
      end
    end
  end

endmodule
