// dma_channel.sv — Single DMA channel with AXI4 read/write master
//
// EF-Train uses 4 independent DMA channels (Section III.C):
//   IFM DMA  — read input feature maps from DRAM → IFM buffer
//   OFM DMA  — read output feature maps from DRAM → OFM buffer (for BP/WU)
//   WEI DMA  — read weights from DRAM → Weight buffer
//   OUT DMA  — write results from buffer → DRAM
//
// Each channel supports both read and write directions.
// Data reshaping (intra-tile continuous allocation) means DMA issues
// sequential burst transfers — no gather/scatter needed.

module dma_channel
  import ef_train_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // ---- Control interface ----
  input  logic        start,
  input  logic        direction,    // 0 = DRAM→buffer (read), 1 = buffer→DRAM (write)
  input  logic [63:0] dram_addr,    // DRAM base address
  input  logic [15:0] buf_addr,     // buffer start address
  input  logic [15:0] xfer_len,     // number of FP32 words to transfer
  output logic        busy,
  output logic        done,

  // ---- AXI4 Read Master ----
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,
  input  logic [AXI_DATA_W-1:0] m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready,

  // ---- AXI4 Write Master ----
  output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,
  output logic [AXI_DATA_W-1:0] m_axi_wdata,
  output logic [7:0]            m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready,

  // ---- Buffer write port (for DRAM→buffer reads) ----
  output logic                  buf_wr_en,
  output logic [15:0]           buf_wr_addr,
  output logic [DATA_WIDTH-1:0] buf_wr_data,

  // ---- Buffer read port (for buffer→DRAM writes) ----
  output logic [15:0]           buf_rd_addr,
  output logic                  buf_rd_en,
  input  logic [DATA_WIDTH-1:0] buf_rd_data
);

  // FP32 words per AXI beat (64-bit bus, 32-bit data = 2 words per beat)
  localparam int unsigned WORDS_PER_BEAT = AXI_DATA_W / DATA_WIDTH;

  typedef enum logic [2:0] {
    DMA_IDLE,
    DMA_RD_AR,        // issue AXI read address
    DMA_RD_DATA,      // receive AXI read data
    DMA_WR_AW,        // issue AXI write address
    DMA_WR_DATA,      // send AXI write data
    DMA_WR_RESP,      // wait for write response
    DMA_DONE
  } dma_state_e;

  dma_state_e state;
  logic [15:0] words_done;
  logic [15:0] burst_words;
  logic [7:0]  beat_cnt;
  logic        word_phase;   // 0=low 32 bits, 1=high 32 bits of 64-bit beat

  wire [15:0] remaining = xfer_len - words_done;
  // Max burst: 256 beats × 2 words/beat = 512 words, but limit to 256 words
  wire [15:0] burst_w   = (remaining > 256) ? 16'd256 : remaining;
  wire [7:0]  burst_len = 8'((burst_w + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT) - 8'd1;

  assign m_axi_arsize  = 3'b011;  // 8 bytes
  assign m_axi_arburst = 2'b01;   // INCR
  assign m_axi_awsize  = 3'b011;
  assign m_axi_awburst = 2'b01;
  assign m_axi_wstrb   = 8'hFF;
  assign m_axi_bready  = 1'b1;

  assign busy = (state != DMA_IDLE && state != DMA_DONE);
  assign done = (state == DMA_DONE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state          <= DMA_IDLE;
      m_axi_arvalid  <= 1'b0;
      m_axi_rready   <= 1'b0;
      m_axi_awvalid  <= 1'b0;
      m_axi_wvalid   <= 1'b0;
      m_axi_wlast    <= 1'b0;
      buf_wr_en      <= 1'b0;
      buf_rd_en      <= 1'b0;
      words_done     <= '0;
      beat_cnt       <= '0;
      word_phase     <= 1'b0;
    end else begin
      buf_wr_en <= 1'b0;
      buf_rd_en <= 1'b0;

      case (state)
        DMA_IDLE: begin
          if (start && xfer_len != 0) begin
            words_done  <= '0;
            word_phase  <= 1'b0;
            burst_words <= burst_w;
            if (!direction) begin
              // Read: DRAM → buffer
              m_axi_araddr  <= dram_addr;
              m_axi_arlen   <= burst_len;
              m_axi_arvalid <= 1'b1;
              state         <= DMA_RD_AR;
            end else begin
              // Write: buffer → DRAM
              m_axi_awaddr  <= dram_addr;
              m_axi_awlen   <= burst_len;
              m_axi_awvalid <= 1'b1;
              state         <= DMA_WR_AW;
            end
          end
        end

        // ---- Read path ----
        DMA_RD_AR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            beat_cnt      <= '0;
            word_phase    <= 1'b0;
            state         <= DMA_RD_DATA;
          end
        end

        DMA_RD_DATA: begin
          if (m_axi_rvalid && m_axi_rready) begin
            // Extract 32-bit words from 64-bit beat
            if (!word_phase) begin
              buf_wr_data <= m_axi_rdata[31:0];
              buf_wr_addr <= buf_addr + words_done;
              buf_wr_en   <= 1'b1;
              words_done  <= words_done + 1;
              word_phase  <= 1'b1;
            end else begin
              buf_wr_data <= m_axi_rdata[63:32];
              buf_wr_addr <= buf_addr + words_done;
              buf_wr_en   <= 1'b1;
              words_done  <= words_done + 1;
              word_phase  <= 1'b0;
            end

            if (m_axi_rlast) begin
              m_axi_rready <= 1'b0;
              if (words_done + 1 >= xfer_len) begin
                state <= DMA_DONE;
              end else begin
                // Next burst
                m_axi_araddr  <= dram_addr + {48'd0, words_done + 16'd1} * 4;
                m_axi_arlen   <= burst_len;
                m_axi_arvalid <= 1'b1;
                state         <= DMA_RD_AR;
              end
            end
          end
        end

        // ---- Write path ----
        DMA_WR_AW: begin
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            beat_cnt      <= '0;
            word_phase    <= 1'b0;
            // Pre-fetch first word from buffer
            buf_rd_addr   <= buf_addr + words_done;
            buf_rd_en     <= 1'b1;
            state         <= DMA_WR_DATA;
          end
        end

        DMA_WR_DATA: begin
          if (!m_axi_wvalid || m_axi_wready) begin
            if (!word_phase) begin
              // Low 32 bits
              m_axi_wdata[31:0] <= buf_rd_data;
              word_phase <= 1'b1;
              buf_rd_addr <= buf_addr + words_done + 1;
              buf_rd_en   <= 1'b1;
            end else begin
              // High 32 bits — send beat
              m_axi_wdata[63:32] <= buf_rd_data;
              m_axi_wvalid <= 1'b1;
              m_axi_wlast  <= (beat_cnt == m_axi_awlen);
              words_done   <= words_done + 2;
              beat_cnt     <= beat_cnt + 1;
              word_phase   <= 1'b0;

              if (beat_cnt == m_axi_awlen) begin
                m_axi_wvalid <= 1'b1;
                state        <= DMA_WR_RESP;
              end else begin
                buf_rd_addr <= buf_addr + words_done + 2;
                buf_rd_en   <= 1'b1;
              end
            end
          end
        end

        DMA_WR_RESP: begin
          m_axi_wvalid <= 1'b0;
          m_axi_wlast  <= 1'b0;
          if (m_axi_bvalid) begin
            if (words_done >= xfer_len) begin
              state <= DMA_DONE;
            end else begin
              // Next burst
              m_axi_awaddr  <= dram_addr + {48'd0, words_done} * 4;
              m_axi_awlen   <= burst_len;
              m_axi_awvalid <= 1'b1;
              state         <= DMA_WR_AW;
            end
          end
        end

        DMA_DONE: begin
          state <= DMA_IDLE;
        end

        default: state <= DMA_IDLE;
      endcase
    end
  end

endmodule
