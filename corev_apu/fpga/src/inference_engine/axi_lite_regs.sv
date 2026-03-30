// axi_lite_regs.sv — AXI4-Lite register interface for inference engine control
//
// Register map (32-bit words):
//   0x000: CTRL        — [0] start (W1S), [1] busy (RO), [15:8] done_count (RO)
//   0x004: STATUS      — [4:0] current_layer, [12:8] num_layers
//   0x008: NUM_LAYERS  — [4:0] number of layers (RW)
//   0x00C: VERSION     — build version (RO), increment on each RTL change
//   0x018: ABUF_RD_ADDR — activation buffer readback address (RW)
//   0x01C: ABUF_RD_BANK — activation buffer readback bank select (RW)
//   0x020: ABUF_RD_DATA_0 — readback data [31:0]   (RO)
//   0x024: ABUF_RD_DATA_1 — readback data [63:32]  (RO)
//   0x028: ABUF_RD_DATA_2 — readback data [95:64]  (RO)
//   0x02C: ABUF_RD_DATA_3 — readback data [127:96] (RO)
//   0x030: ABUF_RD_DATA_4 — readback data [159:128](RO)  INT16 extension
//   0x034: ABUF_RD_DATA_5 — readback data [191:160](RO)
//   0x038: ABUF_RD_DATA_6 — readback data [223:192](RO)
//   0x03C: ABUF_RD_DATA_7 — readback data [255:224](RO)
//
//   0x040–0x04C: Debug registers (moved from 0x030 to make room for ABUF_RD_DATA_4..7)
//     0x040: DBG_WR_COUNT
//     0x044: DBG_WR_DATA0
//     0x048: DBG_WR_DATA1
//     0x04C: DBG_WR_INFO
//
//   0x200–0x2FF: Bias buffer write port
//     0x200: BBUF_ADDR   — write address
//     0x204: BBUF_DATA   — bias data [31:0], triggers write, replicated to all lanes
//
//   0x400–0x7FF: Layer descriptor table (8 words per layer, 32 layers max)
//     +0x00: input_dim
//     +0x04: output_dim
//     +0x08: activation
//     +0x0C: weight_addr
//     +0x10: bias_addr
//
//   0x100–0x124: BRAM staging write port (for CPU-driven weight/activation loading)
//     0x100: MEM_TARGET  — [0] 0=weight_buf, 1=activation_buf
//     0x104: MEM_ADDR    — BRAM write address
//     0x108: MEM_DATA_0  — staging word [31:0]
//     0x10C: MEM_DATA_1  — staging word [63:32]
//     0x110: MEM_DATA_2  — staging word [95:64]
//     0x114: MEM_DATA_3  — staging word [127:96]
//     0x118: MEM_DATA_4  — staging word [159:128]
//     0x11C: MEM_DATA_5  — staging word [191:160]
//     0x120: MEM_DATA_6  — staging word [223:192]
//     0x124: MEM_DATA_7  — staging word [255:224], write triggers 256-bit commit
//
// Weight and activation buffer writes can also come from the UDP bridge
// (CMD_MEM_WRITE = 0x04) bypassing AXI-Lite for reliable wide-word BRAM writes.

module axi_lite_regs
  import inference_pkg::*;
#(
  parameter int unsigned ADDR_WIDTH = 12,
  parameter int unsigned DATA_WIDTH_AXI = 32,
  parameter int unsigned VERSION = 32'd13
) (
  input  logic clk,
  input  logic rst_n,

  // AXI4-Lite Slave interface
  input  logic [ADDR_WIDTH-1:0]      s_axi_awaddr,
  input  logic                       s_axi_awvalid,
  output logic                       s_axi_awready,

  input  logic [DATA_WIDTH_AXI-1:0]  s_axi_wdata,
  input  logic [3:0]                 s_axi_wstrb,
  input  logic                       s_axi_wvalid,
  output logic                       s_axi_wready,

  output logic [1:0]                 s_axi_bresp,
  output logic                       s_axi_bvalid,
  input  logic                       s_axi_bready,

  input  logic [ADDR_WIDTH-1:0]      s_axi_araddr,
  input  logic                       s_axi_arvalid,
  output logic                       s_axi_arready,

  output logic [DATA_WIDTH_AXI-1:0]  s_axi_rdata,
  output logic [1:0]                 s_axi_rresp,
  output logic                       s_axi_rvalid,
  input  logic                       s_axi_rready,

  // Engine control signals
  output logic                       engine_start,
  input  logic [7:0]                 engine_done_count,
  input  logic                       engine_busy,
  input  logic [4:0]                 engine_current_layer,
  output logic [4:0]                 engine_num_layers,

  // Layer descriptor outputs
  output logic [15:0]                layer_input_dim  [MAX_LAYERS],
  output logic [15:0]                layer_output_dim [MAX_LAYERS],
  output act_fn_e                    layer_activation [MAX_LAYERS],
  output logic [13:0]                layer_weight_addr[MAX_LAYERS],
  output logic [13:0]                layer_bias_addr  [MAX_LAYERS],

  // Bias buffer write (still via AXI — single 32-bit value replicated)
  output logic                               bbuf_wr_en,
  output logic [$clog2(256)-1:0]             bbuf_wr_addr,
  output logic [ARRAY_COLS*BIAS_WIDTH-1:0]   bbuf_wr_data,

  // Activation buffer readback (for reading inference results)
  output logic                               abuf_rd_en,
  output logic [$clog2(1024)-1:0]            abuf_rd_addr,
  output logic                               abuf_rd_bank,
  input  logic [ARRAY_ROWS*DATA_WIDTH-1:0]   abuf_rd_data,

  // BRAM staging write ports (for CPU-driven weight/activation loading)
  output logic                               mem_wr_en,
  output logic                               mem_wr_target,  // 0=weight, 1=activation
  output logic [$clog2(4096)-1:0]            mem_wr_addr,
  output logic [ARRAY_COLS*DATA_WIDTH-1:0]   mem_wr_data,

  // Debug: port B write snoop
  input  logic [31:0]                        dbg_wr_count,
  input  logic [31:0]                        dbg_wr_data0,
  input  logic [31:0]                        dbg_wr_data1,
  input  logic [31:0]                        dbg_wr_info
);

  // ---- AXI-Lite handshake ----
  logic aw_fire, w_fire, ar_fire;
  logic [ADDR_WIDTH-1:0] aw_addr_q, ar_addr_q;
  logic aw_pending, w_pending;

  assign aw_fire = s_axi_awvalid & s_axi_awready;
  assign w_fire  = s_axi_wvalid  & s_axi_wready;
  assign ar_fire = s_axi_arvalid & s_axi_arready;

  // Write address channel
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      aw_addr_q  <= '0;
    end else if (aw_fire) begin
      aw_pending <= 1'b1;
      aw_addr_q  <= s_axi_awaddr;
    end else if (do_write) begin
      aw_pending <= 1'b0;
    end
  end

  assign s_axi_awready = !aw_pending;

  // Write data channel
  always_ff @(posedge clk) begin
    if (!rst_n)
      w_pending <= 1'b0;
    else if (w_fire)
      w_pending <= 1'b1;
    else if (do_write)
      w_pending <= 1'b0;
  end

  assign s_axi_wready = !w_pending;

  // Write response — do_write is a single-cycle pulse (pending flags clear
  // immediately), so bvalid lifecycle is independent of pending flags.
  logic do_write;
  assign do_write = aw_pending & w_pending;

  always_ff @(posedge clk) begin
    if (!rst_n)
      s_axi_bvalid <= 1'b0;
    else if (do_write)
      s_axi_bvalid <= 1'b1;
    else if (s_axi_bvalid && s_axi_bready)
      s_axi_bvalid <= 1'b0;
  end

  assign s_axi_bresp = 2'b00;  // OKAY

  // ---- Write Data Registers ----
  // Layer index decoded from AXI write address (hoisted from always_ff)
  logic [4:0] wr_layer_idx;
  assign wr_layer_idx = aw_addr_q[9:5];

  logic [4:0]  num_layers_q;
  logic        start_pulse;
  logic [$clog2(1024)-1:0] abuf_rd_addr_reg;
  logic                    abuf_rd_bank_reg;
  logic [31:0] bbuf_staging;
  logic [11:0] bbuf_addr_reg;

  // BRAM staging registers (CPU-driven weight/activation loading)
  // 8 × 32-bit = 256-bit word (INT16: ARRAY_COLS × DATA_WIDTH = 16 × 16)
  logic        mem_target_reg;  // 0=weight, 1=activation
  logic [$clog2(4096)-1:0] mem_addr_reg;
  logic [31:0] mem_staging [8]; // 8 x 32-bit = 256-bit
  logic        mem_commit;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      num_layers_q     <= '0;
      start_pulse      <= 1'b0;
      abuf_rd_addr_reg <= '0;
      abuf_rd_bank_reg <= 1'b0;
      bbuf_addr_reg    <= '0;
      bbuf_wr_en       <= 1'b0;
      bbuf_staging     <= '0;
      mem_target_reg   <= 1'b0;
      mem_addr_reg     <= '0;
      mem_commit       <= 1'b0;
      for (int i = 0; i < 8; i++)
        mem_staging[i] <= '0;
      for (int i = 0; i < MAX_LAYERS; i++) begin
        layer_input_dim[i]   <= '0;
        layer_output_dim[i]  <= '0;
        layer_activation[i]  <= ACT_NONE;
        layer_weight_addr[i] <= '0;
        layer_bias_addr[i]   <= '0;
      end
    end else begin
      start_pulse <= 1'b0;
      bbuf_wr_en  <= 1'b0;
      mem_commit  <= 1'b0;

      if (do_write) begin
        case (aw_addr_q[11:8])
          4'h0: begin // Control registers
            case (aw_addr_q[7:0])
              8'h00: start_pulse       <= s_axi_wdata[0];
              8'h08: num_layers_q      <= s_axi_wdata[4:0];
              8'h18: abuf_rd_addr_reg  <= s_axi_wdata[$clog2(1024)-1:0];
              8'h1C: abuf_rd_bank_reg  <= s_axi_wdata[0];
              default: ;
            endcase
          end

          4'h1: begin // BRAM staging write port (256-bit, 8 x 32-bit words)
            case (aw_addr_q[5:0])
              6'h00: mem_target_reg <= s_axi_wdata[0];
              6'h04: mem_addr_reg   <= s_axi_wdata[$clog2(4096)-1:0];
              6'h08: mem_staging[0] <= s_axi_wdata;
              6'h0C: mem_staging[1] <= s_axi_wdata;
              6'h10: mem_staging[2] <= s_axi_wdata;
              6'h14: mem_staging[3] <= s_axi_wdata;
              6'h18: mem_staging[4] <= s_axi_wdata;
              6'h1C: mem_staging[5] <= s_axi_wdata;
              6'h20: mem_staging[6] <= s_axi_wdata;
              6'h24: begin
                mem_staging[7] <= s_axi_wdata;
                mem_commit     <= 1'b1;
              end
              default: ;
            endcase
          end

          4'h2: begin // Bias buffer write port
            case (aw_addr_q[3:0])
              4'h0: bbuf_addr_reg <= s_axi_wdata[11:0];
              4'h4: begin
                bbuf_staging <= s_axi_wdata;
                bbuf_wr_en   <= 1'b1;
              end
              default: ;
            endcase
          end

          4'h4, 4'h5, 4'h6, 4'h7: begin // Layer descriptors
            if (wr_layer_idx < MAX_LAYERS) begin
              case (aw_addr_q[4:0])
                5'h00: layer_input_dim[wr_layer_idx]   <= s_axi_wdata[15:0];
                5'h04: layer_output_dim[wr_layer_idx]   <= s_axi_wdata[15:0];
                5'h08: layer_activation[wr_layer_idx]   <= act_fn_e'(s_axi_wdata[1:0]);
                5'h0C: layer_weight_addr[wr_layer_idx]  <= s_axi_wdata[13:0];
                5'h10: layer_bias_addr[wr_layer_idx]    <= s_axi_wdata[13:0];
                default: ;
              endcase
            end
          end

          default: ;
        endcase
      end
    end
  end

  // Wire up outputs
  assign engine_start      = start_pulse;
  assign engine_num_layers = num_layers_q;

  assign bbuf_wr_addr = bbuf_addr_reg;
  // Replicate single staging word across all bias lanes
  always_comb begin
    for (int i = 0; i < ARRAY_COLS; i++)
      bbuf_wr_data[i*BIAS_WIDTH +: BIAS_WIDTH] = bbuf_staging;
  end

  // BRAM staging write outputs (256-bit, commit on DATA_7)
  assign mem_wr_en     = mem_commit;
  assign mem_wr_target = mem_target_reg;
  assign mem_wr_addr   = mem_addr_reg;
  assign mem_wr_data   = {mem_staging[7], mem_staging[6], mem_staging[5], mem_staging[4],
                          mem_staging[3], mem_staging[2], mem_staging[1], mem_staging[0]};

  // Activation buffer readback (active when engine is idle)
  assign abuf_rd_en   = 1'b1;  // always reading — BRAM can handle it
  assign abuf_rd_addr = abuf_rd_addr_reg;
  assign abuf_rd_bank = abuf_rd_bank_reg;

  // ---- Read path ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      ar_addr_q    <= '0;
    end else if (ar_fire) begin
      s_axi_rvalid <= 1'b1;
      ar_addr_q    <= s_axi_araddr;
      case (s_axi_araddr[11:0])
        12'h000: s_axi_rdata <= {16'b0, engine_done_count, 6'b0, engine_busy, 1'b0};
        12'h004: s_axi_rdata <= {19'b0, num_layers_q, 3'b0, engine_current_layer};
        12'h008: s_axi_rdata <= {27'b0, num_layers_q};
        12'h00C: s_axi_rdata <= VERSION;
        12'h018: s_axi_rdata <= {{(32-$clog2(1024)){1'b0}}, abuf_rd_addr_reg};
        12'h01C: s_axi_rdata <= {31'b0, abuf_rd_bank_reg};
        12'h020: s_axi_rdata <= abuf_rd_data[31:0];
        12'h024: s_axi_rdata <= abuf_rd_data[63:32];
        12'h028: s_axi_rdata <= abuf_rd_data[95:64];
        12'h02C: s_axi_rdata <= abuf_rd_data[127:96];
        12'h030: s_axi_rdata <= abuf_rd_data[159:128];
        12'h034: s_axi_rdata <= abuf_rd_data[191:160];
        12'h038: s_axi_rdata <= abuf_rd_data[223:192];
        12'h03C: s_axi_rdata <= abuf_rd_data[255:224];
        12'h040: s_axi_rdata <= dbg_wr_count;
        12'h044: s_axi_rdata <= dbg_wr_data0;
        12'h048: s_axi_rdata <= dbg_wr_data1;
        12'h04C: s_axi_rdata <= dbg_wr_info;
        12'h100: s_axi_rdata <= {31'b0, mem_target_reg};
        12'h104: s_axi_rdata <= {{(32-$clog2(4096)){1'b0}}, mem_addr_reg};
        12'h108: s_axi_rdata <= mem_staging[0];
        12'h10C: s_axi_rdata <= mem_staging[1];
        12'h110: s_axi_rdata <= mem_staging[2];
        12'h114: s_axi_rdata <= mem_staging[3];
        12'h118: s_axi_rdata <= mem_staging[4];
        12'h11C: s_axi_rdata <= mem_staging[5];
        12'h120: s_axi_rdata <= mem_staging[6];
        12'h124: s_axi_rdata <= mem_staging[7];
        default: s_axi_rdata <= 32'hDEAD_BEEF;
      endcase
    end else if (s_axi_rready) begin
      s_axi_rvalid <= 1'b0;
    end
  end

  assign s_axi_arready = !s_axi_rvalid;
  assign s_axi_rresp   = 2'b00;

endmodule
