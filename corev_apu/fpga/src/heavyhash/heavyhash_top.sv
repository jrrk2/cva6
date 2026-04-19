// heavyhash_top.sv — AXI-Lite register file + HeavyHash pipeline
//
// The register file operates on the SoC clock (clk, 50 MHz).
// The mining pipeline operates on a fast clock (hh_clk, 125 MHz).
// CDC synchronizers bridge the two domains.
//
// CDC strategy:
//   - Config registers (mid-states, msg_block, target, nonce): quasi-static,
//     written before start and stable during mining. Direct connection is safe.
//   - Control pulses (start, stop, mat_wr): toggle-based pulse synchronizers.
//   - Status levels (busy, found): 2FF synchronizers.
//   - Result data (nonce_found, hash_count): quasi-static when read,
//     latched on found edge in 50 MHz domain.

module heavyhash_top
  import keccak_pkg::*,
         heavyhash_pkg::*;
(
  input  logic        clk,       // 50 MHz SoC clock
  input  logic        hh_clk,    // 100 MHz mining clock
  input  logic        rst_n,

  // 32-bit AXI-Lite slave (50 MHz domain)
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // Matrix write port (from DMA, active when DMA present)
  input  logic        ext_mat_wr_en,
  input  logic [5:0]  ext_mat_wr_addr,
  input  logic [255:0] ext_mat_wr_data,

  // Interrupt
  output logic        irq_done,
  output logic        busy
);

  // ================================================================
  //  Register storage (50 MHz domain)
  // ================================================================
  // Control
  logic        ctrl_start, ctrl_stop;
  logic [63:0] nonce_start;
  logic [255:0] target;

  // Message block template (1088 bits)
  logic [RATE-1:0] msg_block;

  // Mid-states (1600 bits each)
  logic [1599:0] mid_state_1;
  logic [1599:0] mid_state_2;

  // Matrix staging registers
  logic [5:0]   mat_stage_addr;
  logic [255:0] mat_stage_data;
  logic         mat_stage_wr;

  // Matrix write mux: staging register or external DMA
  logic         mat_wr_en;
  logic [5:0]   mat_wr_addr;
  logic [255:0] mat_wr_data;

  always_comb begin
    if (ext_mat_wr_en) begin
      mat_wr_en   = 1'b1;
      mat_wr_addr = ext_mat_wr_addr;
      mat_wr_data = ext_mat_wr_data;
    end else begin
      mat_wr_en   = mat_stage_wr;
      mat_wr_addr = mat_stage_addr;
      mat_wr_data = mat_stage_data;
    end
  end

  // ================================================================
  //  100 MHz reset synchronizer (async assert, sync deassert)
  // ================================================================
  logic rst_100_s1, rst_100_n;

  always_ff @(posedge hh_clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_100_s1 <= 1'b0;
      rst_100_n  <= 1'b0;
    end else begin
      rst_100_s1 <= 1'b1;
      rst_100_n  <= rst_100_s1;
    end
  end

  // ================================================================
  //  CDC: Pulse synchronizers (50 MHz → 100 MHz)
  //  Toggle in source domain, 2FF sync + edge-detect in destination.
  // ================================================================

  // --- Start pulse ---
  logic start_toggle_50;
  logic start_sync1, start_sync2, start_sync3;
  logic start_100;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      start_toggle_50 <= 1'b0;
    else if (ctrl_start)
      start_toggle_50 <= ~start_toggle_50;
  end

  always_ff @(posedge hh_clk or negedge rst_100_n) begin
    if (!rst_100_n) begin
      start_sync1 <= 1'b0;
      start_sync2 <= 1'b0;
      start_sync3 <= 1'b0;
    end else begin
      start_sync1 <= start_toggle_50;
      start_sync2 <= start_sync1;
      start_sync3 <= start_sync2;
    end
  end

  assign start_100 = start_sync2 ^ start_sync3;

  // --- Stop pulse ---
  logic stop_toggle_50;
  logic stop_sync1, stop_sync2, stop_sync3;
  logic stop_100;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      stop_toggle_50 <= 1'b0;
    else if (ctrl_stop)
      stop_toggle_50 <= ~stop_toggle_50;
  end

  always_ff @(posedge hh_clk or negedge rst_100_n) begin
    if (!rst_100_n) begin
      stop_sync1 <= 1'b0;
      stop_sync2 <= 1'b0;
      stop_sync3 <= 1'b0;
    end else begin
      stop_sync1 <= stop_toggle_50;
      stop_sync2 <= stop_sync1;
      stop_sync3 <= stop_sync2;
    end
  end

  assign stop_100 = stop_sync2 ^ stop_sync3;

  // --- Matrix write pulse ---
  logic matwr_toggle_50;
  logic matwr_sync1, matwr_sync2, matwr_sync3;
  logic mat_wr_en_100;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      matwr_toggle_50 <= 1'b0;
    else if (mat_wr_en)
      matwr_toggle_50 <= ~matwr_toggle_50;
  end

  always_ff @(posedge hh_clk or negedge rst_100_n) begin
    if (!rst_100_n) begin
      matwr_sync1 <= 1'b0;
      matwr_sync2 <= 1'b0;
      matwr_sync3 <= 1'b0;
    end else begin
      matwr_sync1 <= matwr_toggle_50;
      matwr_sync2 <= matwr_sync1;
      matwr_sync3 <= matwr_sync2;
    end
  end

  assign mat_wr_en_100 = matwr_sync2 ^ matwr_sync3;

  // Latch matrix write addr/data in 100 MHz domain
  // (stable for many cycles around the write pulse)
  logic [5:0]   mat_wr_addr_100;
  logic [255:0] mat_wr_data_100;

  always_ff @(posedge hh_clk) begin
    mat_wr_addr_100 <= mat_wr_addr;
    mat_wr_data_100 <= mat_wr_data;
  end

  // ================================================================
  //  CDC: Level synchronizers (100 MHz → 50 MHz)
  // ================================================================

  // Pipeline outputs (100 MHz domain)
  logic         pipe_busy, pipe_found;
  logic [63:0]  pipe_nonce_found;
  logic [63:0]  pipe_hash_count;

  // --- Busy level ---
  logic busy_sync1, busy_sync2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_sync1 <= 1'b0;
      busy_sync2 <= 1'b0;
    end else begin
      busy_sync1 <= pipe_busy;
      busy_sync2 <= busy_sync1;
    end
  end

  // --- Found level ---
  logic found_sync1, found_sync2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      found_sync1 <= 1'b0;
      found_sync2 <= 1'b0;
    end else begin
      found_sync1 <= pipe_found;
      found_sync2 <= found_sync1;
    end
  end

  // IRQ & status
  logic found_latched;
  assign irq_done = found_latched;
  assign busy     = busy_sync2;

  // Capture result data on rising edge of found_sync2
  logic found_prev;
  logic [63:0] nonce_found_latched;
  logic [63:0] hash_count_latched;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      found_prev         <= 1'b0;
      nonce_found_latched<= '0;
      hash_count_latched <= '0;
    end else begin
      found_prev <= found_sync2;

      // Latch nonce on rising edge of found
      if (found_sync2 && !found_prev)
        nonce_found_latched <= pipe_nonce_found;

      // Continuously sample hash_count when busy (for status display)
      // Cosmetic glitches on multi-bit CDC are acceptable here
      if (busy_sync2)
        hash_count_latched <= pipe_hash_count;
    end
  end

  // ================================================================
  //  Multi-lane pipeline instantiation (125 MHz domain, 8 lanes)
  // ================================================================
  heavyhash_multi #(
    .NUM_LANES ( 8 )
  ) u_multi (
    .clk         ( hh_clk            ),
    .rst_n       ( rst_100_n         ),
    .start       ( start_100         ),
    .stop        ( stop_100          ),
    .busy        ( pipe_busy         ),
    .found       ( pipe_found        ),
    .mid_state_1 ( mid_state_1       ),  // quasi-static, stable during mining
    .mid_state_2 ( mid_state_2       ),
    .msg_block   ( msg_block         ),
    .target      ( target            ),
    .nonce_start ( nonce_start       ),
    .nonce_found ( pipe_nonce_found  ),
    .hash_count  ( pipe_hash_count   ),
    .mat_wr_en   ( mat_wr_en_100     ),
    .mat_wr_addr ( mat_wr_addr_100   ),
    .mat_wr_data ( mat_wr_data_100   )
  );

  // ================================================================
  //  AXI-Lite write channel (50 MHz domain)
  // ================================================================
  logic        aw_fire, w_fire;
  logic [11:0] wr_addr;
  logic        wr_addr_valid;

  // AW channel
  assign s_axi_awready = !wr_addr_valid || (w_fire);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_addr       <= '0;
      wr_addr_valid <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        wr_addr       <= s_axi_awaddr;
        wr_addr_valid <= 1'b1;
      end else if (w_fire) begin
        wr_addr_valid <= 1'b0;
      end
    end
  end

  // W channel
  assign s_axi_wready = wr_addr_valid;
  assign w_fire       = s_axi_wvalid && s_axi_wready;

  // B channel
  logic b_pending;
  assign s_axi_bresp = 2'b00;
  assign s_axi_bvalid = b_pending;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      b_pending <= 1'b0;
    else if (w_fire)
      b_pending <= 1'b1;
    else if (s_axi_bready && b_pending)
      b_pending <= 1'b0;
  end

  // Word index within a register region (address bits [7:2])
  wire [5:0] wr_word_idx = wr_addr[7:2];

  // Relative word indices for regions not aligned to 0xN00
  wire [5:0] msg_word_rel = wr_addr[7:2] - REG_MSG_BASE[7:2];    // 0x040 base
  wire [2:0] mat_word_rel = wr_addr[4:2] - REG_MAT_DATA0[4:2];   // 0x304 base

  // ---- Write decoder ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_start    <= 1'b0;
      ctrl_stop     <= 1'b0;
      nonce_start   <= '0;
      target        <= '0;
      msg_block     <= '0;
      mid_state_1   <= '0;
      mid_state_2   <= '0;
      mat_stage_addr<= '0;
      mat_stage_data<= '0;
      mat_stage_wr  <= 1'b0;
      found_latched <= 1'b0;
    end else begin
      // Pulse controls
      ctrl_start   <= 1'b0;
      ctrl_stop    <= 1'b0;
      mat_stage_wr <= 1'b0;

      // Latch found from pipeline (via synchronized signal)
      if (found_sync2 && !found_prev)
        found_latched <= 1'b1;

      if (w_fire) begin
        case (wr_addr)
          REG_CTRL: begin
            if (s_axi_wdata[0]) ctrl_start <= 1'b1;
            if (s_axi_wdata[1]) ctrl_stop  <= 1'b1;
            if (s_axi_wdata[2]) found_latched <= 1'b0;  // clear found
          end
          REG_NONCE_LO: nonce_start[31:0]  <= s_axi_wdata;
          REG_NONCE_HI: nonce_start[63:32] <= s_axi_wdata;
          REG_MAT_ADDR: mat_stage_addr     <= s_axi_wdata[5:0];
          REG_MAT_WR:   mat_stage_wr       <= s_axi_wdata[0];
          default: ;
        endcase

        // Target registers (0x020-0x03C, 8 words)
        if (wr_addr >= REG_TARGET_BASE && wr_addr < REG_TARGET_BASE + 12'h020)
          target[wr_word_idx[2:0]*32 +: 32] <= s_axi_wdata;

        // Message block (0x040-0x0C4, 34 words)
        if (wr_addr >= REG_MSG_BASE && wr_addr < REG_MSG_BASE + 12'h088)
          msg_block[msg_word_rel*32 +: 32] <= s_axi_wdata;

        // Mid-state 1 (0x100-0x1C4, 50 words)
        if (wr_addr >= REG_MSTATE1_BASE && wr_addr < REG_MSTATE1_BASE + 12'h0C8)
          mid_state_1[wr_word_idx[5:0]*32 +: 32] <= s_axi_wdata;

        // Mid-state 2 (0x200-0x2C4, 50 words)
        if (wr_addr >= REG_MSTATE2_BASE && wr_addr < REG_MSTATE2_BASE + 12'h0C8)
          mid_state_2[wr_word_idx[5:0]*32 +: 32] <= s_axi_wdata;

        // Matrix data staging (0x304-0x320, 8 words)
        if (wr_addr >= REG_MAT_DATA0 && wr_addr < REG_MAT_WR)
          mat_stage_data[mat_word_rel*32 +: 32] <= s_axi_wdata;
      end
    end
  end

  // ================================================================
  //  AXI-Lite read channel (50 MHz domain)
  // ================================================================
  logic rd_pending;
  logic [31:0] rd_data;

  assign s_axi_arready = !rd_pending;
  assign s_axi_rdata   = rd_data;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rvalid  = rd_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_pending <= 1'b0;
      rd_data    <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        rd_pending <= 1'b1;
        case (s_axi_araddr)
          REG_CTRL:           rd_data <= '0;
          REG_STATUS:         rd_data <= {30'd0, found_latched, busy_sync2};
          REG_HASH_CNT_LO:   rd_data <= hash_count_latched[31:0];
          REG_HASH_CNT_HI:   rd_data <= hash_count_latched[63:32];
          REG_NONCE_LO:       rd_data <= nonce_start[31:0];
          REG_NONCE_HI:       rd_data <= nonce_start[63:32];
          REG_FOUND_NONCE_LO: rd_data <= nonce_found_latched[31:0];
          REG_FOUND_NONCE_HI: rd_data <= nonce_found_latched[63:32];
          default:             rd_data <= 32'hDEAD_BEEF;
        endcase
      end else if (s_axi_rready && rd_pending) begin
        rd_pending <= 1'b0;
      end
    end
  end

endmodule
