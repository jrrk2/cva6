// inference_engine_top.sv — Top-level parallel AI inference engine for VC707
//
// Target: Xilinx VC707 (xc7vx485tffg1761-2, Virtex-7)
//
// Architecture:
//   ┌─────────────────────────────────────────────────────────┐
//   │  AXI4-Lite Slave (control regs + readback)              │
//   └────────────┬──────────────┬──────────────┬─────────────┘
//                │              │              │
//   ┌────────────▼──┐  ┌───────▼───────┐  ┌──▼──────────┐
//   │ Weight Buffer  │  │  Bias Buffer  │  │  Activation  │
//   │ (4K×128b)     │  │  (256×512b)   │  │  Buffer     │
//   │ Port A: bridge │  │               │  │  (2x1K×128b)│
//   │ Port B: ctrl   │  │               │  │  Dual-port  │
//   └────────┬───────┘  └───────┬───────┘  └──┬──────────┘
//            │                  │              │
//   ┌────────▼──────────────────▼──────────────▼─────────────┐
//   │                  Layer Controller                       │
//   └────────┬──────────────────────────────┬─────────────────┘
//            │                              │
//   ┌────────▼──────────┐       ┌───────────▼────────────┐
//   │  16×16 Systolic   │       │  Activation Unit       │
//   │  Array (256 PEs)  │       │  (ReLU/Sigmoid/ReLU6)  │
//   └───────────────────┘       └────────────────────────┘

module inference_engine_top
  import inference_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // AXI4-Lite Slave interface
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

  // Direct BRAM write from UDP bridge (port A of dual-port buffers)
  input  logic                             ext_wbuf_wr_en,
  input  logic [$clog2(4096)-1:0]         ext_wbuf_wr_addr,
  input  logic [ARRAY_COLS*DATA_WIDTH-1:0] ext_wbuf_wr_data,

  input  logic                             ext_abuf_wr_en,
  input  logic [$clog2(1024)-1:0]         ext_abuf_wr_addr,
  input  logic [ARRAY_ROWS*DATA_WIDTH-1:0] ext_abuf_wr_data,

  // Status / interrupt
  output logic         irq_done,
  output logic         busy
);

  // ---- Internal signals ----

  // Engine control
  logic        engine_start, engine_busy;
  logic [7:0]  engine_done_count;
  logic [4:0]  engine_num_layers, engine_current_layer;

  // Layer descriptors
  logic [15:0] layer_input_dim  [MAX_LAYERS];
  logic [15:0] layer_output_dim [MAX_LAYERS];
  act_fn_e     layer_activation [MAX_LAYERS];
  logic [13:0] layer_weight_addr[MAX_LAYERS];
  logic [13:0] layer_bias_addr  [MAX_LAYERS];

  // Weight buffer signals (port B — layer controller read)
  logic                             wbuf_rd_en;
  logic                             wbuf_rd_bank;
  logic [$clog2(4096)-1:0]         wbuf_rd_addr;
  logic [ARRAY_COLS*DATA_WIDTH-1:0] wbuf_rd_data;

  // Bias buffer signals
  logic                             bbuf_wr_en, bbuf_rd_en;
  logic [$clog2(256)-1:0]          bbuf_wr_addr, bbuf_rd_addr;
  logic [ARRAY_COLS*BIAS_WIDTH-1:0] bbuf_wr_data, bbuf_rd_data;

  // Activation buffer signals — port B (layer controller)
  logic                              abuf_wr_en, abuf_rd_en;
  logic                              abuf_wr_bank, abuf_rd_bank;
  logic [$clog2(1024)-1:0]          abuf_wr_addr, abuf_rd_addr;
  logic [ARRAY_ROWS*DATA_WIDTH-1:0] abuf_wr_data, abuf_rd_data;

  // BRAM staging write from AXI regs (CPU-driven loading)
  logic                              mem_wr_en;
  logic                              mem_wr_target;
  logic [$clog2(4096)-1:0]          mem_wr_addr;
  logic [ARRAY_COLS*DATA_WIDTH-1:0] mem_wr_data;

  // Combined BRAM write signals (external OR staging)
  logic                              wbuf_a_wr_en;
  logic [$clog2(4096)-1:0]          wbuf_a_wr_addr;
  logic [ARRAY_COLS*DATA_WIDTH-1:0] wbuf_a_wr_data;

  logic                              ext_or_stg_abuf_wr_en;
  logic [$clog2(1024)-1:0]          ext_or_stg_abuf_wr_addr;
  logic [ARRAY_ROWS*DATA_WIDTH-1:0] ext_or_stg_abuf_wr_data;

  // Mux: external ports have priority, then staging registers
  always_comb begin
    if (ext_wbuf_wr_en) begin
      wbuf_a_wr_en   = 1'b1;
      wbuf_a_wr_addr = ext_wbuf_wr_addr;
      wbuf_a_wr_data = ext_wbuf_wr_data;
    end else if (mem_wr_en && !mem_wr_target) begin
      wbuf_a_wr_en   = 1'b1;
      wbuf_a_wr_addr = mem_wr_addr;
      wbuf_a_wr_data = mem_wr_data;
    end else begin
      wbuf_a_wr_en   = 1'b0;
      wbuf_a_wr_addr = '0;
      wbuf_a_wr_data = '0;
    end

    if (ext_abuf_wr_en) begin
      ext_or_stg_abuf_wr_en   = 1'b1;
      ext_or_stg_abuf_wr_addr = ext_abuf_wr_addr;
      ext_or_stg_abuf_wr_data = ext_abuf_wr_data;
    end else if (mem_wr_en && mem_wr_target) begin
      ext_or_stg_abuf_wr_en   = 1'b1;
      ext_or_stg_abuf_wr_addr = mem_wr_addr[$clog2(1024)-1:0];
      ext_or_stg_abuf_wr_data = mem_wr_data;
    end else begin
      ext_or_stg_abuf_wr_en   = 1'b0;
      ext_or_stg_abuf_wr_addr = '0;
      ext_or_stg_abuf_wr_data = '0;
    end
  end

  // Activation buffer readback — port A read (from AXI regs, active when idle)
  logic                              axi_abuf_rd_en;
  logic [$clog2(1024)-1:0]          axi_abuf_rd_addr;
  logic                              axi_abuf_rd_bank;
  logic [ARRAY_ROWS*DATA_WIDTH-1:0] axi_abuf_rd_data;

  // Port A address/bank mux: bridge writes when active, AXI readback otherwise
  logic                              abuf_a_wr_en;
  logic                              abuf_a_bank;
  logic [$clog2(1024)-1:0]          abuf_a_addr;
  logic [ARRAY_ROWS*DATA_WIDTH-1:0] abuf_a_wr_data;

  always_comb begin
    if (ext_or_stg_abuf_wr_en) begin
      // External bridge or staging regs writing init data
      abuf_a_wr_en   = 1'b1;
      abuf_a_bank    = 1'b0;  // always bank 0 for init
      abuf_a_addr    = ext_or_stg_abuf_wr_addr;
      abuf_a_wr_data = ext_or_stg_abuf_wr_data;
    end else begin
      // AXI readback
      abuf_a_wr_en   = 1'b0;
      abuf_a_bank    = axi_abuf_rd_bank;
      abuf_a_addr    = axi_abuf_rd_addr;
      abuf_a_wr_data = '0;
    end
  end

  // Systolic array signals
  logic                          sa_enable, sa_acc_clear;
  logic signed [DATA_WIDTH-1:0]  sa_w_in   [ARRAY_ROWS];
  logic signed [DATA_WIDTH-1:0]  sa_a_in   [ARRAY_COLS];
  logic [$clog2(ARRAY_ROWS)-1:0] sa_result_row_sel;
  logic signed [ACC_WIDTH-1:0]   sa_result_out [ARRAY_COLS];

  // Activation unit signals
  logic                          act_valid_in, act_valid_out;
  act_fn_e                       act_fn_sel;
  logic signed [ACC_WIDTH-1:0]   act_data_in  [ARRAY_COLS];
  logic        [DATA_WIDTH-1:0]  act_data_out [ARRAY_COLS];

  // ---- Debug: snoop port B writes to activation buffer ----
  logic [31:0] dbg_wr_count;
  logic [31:0] dbg_wr_data0;   // first write data [31:0]
  logic [31:0] dbg_wr_data1;   // first write data [63:32]
  logic [31:0] dbg_wr_info;    // {bank, addr[9:0], sa_enable, act_valid_in/out, state}

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_wr_count <= '0;
      dbg_wr_data0 <= '0;
      dbg_wr_data1 <= '0;
      dbg_wr_info  <= '0;
    end else if (abuf_wr_en) begin
      dbg_wr_count <= dbg_wr_count + 1;
      if (dbg_wr_count == 0) begin
        // Capture first write
        dbg_wr_data0 <= abuf_wr_data[31:0];
        dbg_wr_data1 <= abuf_wr_data[63:32];
        dbg_wr_info  <= {abuf_wr_bank, 1'b0, abuf_wr_addr, 20'b0};
      end
    end
  end

  // ---- Module instantiations ----

  // AXI-Lite register file (control, bias writes, readback)
  axi_lite_regs u_axi_regs (
    .clk                 (clk),
    .rst_n               (rst_n),
    .s_axi_awaddr        (s_axi_awaddr),
    .s_axi_awvalid       (s_axi_awvalid),
    .s_axi_awready       (s_axi_awready),
    .s_axi_wdata         (s_axi_wdata),
    .s_axi_wstrb         (s_axi_wstrb),
    .s_axi_wvalid        (s_axi_wvalid),
    .s_axi_wready        (s_axi_wready),
    .s_axi_bresp         (s_axi_bresp),
    .s_axi_bvalid        (s_axi_bvalid),
    .s_axi_bready        (s_axi_bready),
    .s_axi_araddr        (s_axi_araddr),
    .s_axi_arvalid       (s_axi_arvalid),
    .s_axi_arready       (s_axi_arready),
    .s_axi_rdata         (s_axi_rdata),
    .s_axi_rresp         (s_axi_rresp),
    .s_axi_rvalid        (s_axi_rvalid),
    .s_axi_rready        (s_axi_rready),
    .engine_start        (engine_start),
    .engine_done_count   (engine_done_count),
    .engine_busy         (engine_busy),
    .engine_current_layer(engine_current_layer),
    .engine_num_layers   (engine_num_layers),
    .layer_input_dim     (layer_input_dim),
    .layer_output_dim    (layer_output_dim),
    .layer_activation    (layer_activation),
    .layer_weight_addr   (layer_weight_addr),
    .layer_bias_addr     (layer_bias_addr),
    .bbuf_wr_en          (bbuf_wr_en),
    .bbuf_wr_addr        (bbuf_wr_addr),
    .bbuf_wr_data        (bbuf_wr_data),
    .abuf_rd_en          (axi_abuf_rd_en),
    .abuf_rd_addr        (axi_abuf_rd_addr),
    .abuf_rd_bank        (axi_abuf_rd_bank),
    .abuf_rd_data        (axi_abuf_rd_data),
    .mem_wr_en           (mem_wr_en),
    .mem_wr_target       (mem_wr_target),
    .mem_wr_addr         (mem_wr_addr),
    .mem_wr_data         (mem_wr_data),
    .dbg_wr_count        (dbg_wr_count),
    .dbg_wr_data0        (dbg_wr_data0),
    .dbg_wr_data1        (dbg_wr_data1),
    .dbg_wr_info         (dbg_wr_info)
  );

  // Weight buffer — simple dual-port (port A: bridge/staging write, port B: controller read)
  weight_buffer u_weight_buf (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (wbuf_a_wr_en),
    .wr_bank (1'b0),
    .wr_addr (wbuf_a_wr_addr),
    .wr_data (wbuf_a_wr_data),
    .rd_en   (wbuf_rd_en),
    .rd_bank (wbuf_rd_bank),
    .rd_addr (wbuf_rd_addr),
    .rd_data (wbuf_rd_data)
  );

  // Bias buffer — simple dual-port (port A: AXI write, port B: controller read)
  bias_buffer u_bias_buf (
    .clk     (clk),
    .wr_en   (bbuf_wr_en),
    .wr_addr (bbuf_wr_addr),
    .wr_data (bbuf_wr_data),
    .rd_en   (bbuf_rd_en),
    .rd_addr (bbuf_rd_addr),
    .rd_data (bbuf_rd_data)
  );

  // Activation buffer — true dual-port (port A: bridge+AXI, port B: controller)
  activation_buffer u_act_buf (
    .clk        (clk),
    // Port A (bridge init write + AXI readback)
    .a_wr_en    (abuf_a_wr_en),
    .a_bank     (abuf_a_bank),
    .a_addr     (abuf_a_addr),
    .a_wr_data  (abuf_a_wr_data),
    .a_rd_data  (axi_abuf_rd_data),
    // Port B (layer controller)
    .b_wr_en    (abuf_wr_en),
    .b_wr_bank  (abuf_wr_bank),
    .b_wr_addr  (abuf_wr_addr),
    .b_wr_data  (abuf_wr_data),
    .b_rd_en    (abuf_rd_en),
    .b_rd_bank  (abuf_rd_bank),
    .b_rd_addr  (abuf_rd_addr),
    .b_rd_data  (abuf_rd_data)
  );

  // 16×16 Systolic array
  systolic_array u_systolic (
    .clk            (clk),
    .rst_n          (rst_n),
    .enable         (sa_enable),
    .acc_clear      (sa_acc_clear),
    .w_in           (sa_w_in),
    .a_in           (sa_a_in),
    .result_row_sel (sa_result_row_sel),
    .result_out     (sa_result_out)
  );

  // Activation function unit (16 parallel lanes)
  activation_unit u_act_fn (
    .clk       (clk),
    .rst_n     (rst_n),
    .valid_in  (act_valid_in),
    .fn_sel    (act_fn_sel),
    .data_in   (act_data_in),
    .data_out  (act_data_out),
    .valid_out (act_valid_out)
  );

  // Layer controller (FSM)
  layer_controller u_ctrl (
    .clk               (clk),
    .rst_n             (rst_n),
    .start             (engine_start),
    .done_count        (engine_done_count),
    .busy              (engine_busy),
    .num_layers        (engine_num_layers),
    .layer_input_dim   (layer_input_dim),
    .layer_output_dim  (layer_output_dim),
    .layer_activation  (layer_activation),
    .layer_weight_addr (layer_weight_addr),
    .layer_bias_addr   (layer_bias_addr),
    .wbuf_rd_en        (wbuf_rd_en),
    .wbuf_rd_bank      (wbuf_rd_bank),
    .wbuf_rd_addr      (wbuf_rd_addr),
    .wbuf_rd_data      (wbuf_rd_data),
    .abuf_rd_en        (abuf_rd_en),
    .abuf_rd_bank      (abuf_rd_bank),
    .abuf_rd_addr      (abuf_rd_addr),
    .abuf_rd_data      (abuf_rd_data),
    .abuf_wr_en        (abuf_wr_en),
    .abuf_wr_bank      (abuf_wr_bank),
    .abuf_wr_addr      (abuf_wr_addr),
    .abuf_wr_data      (abuf_wr_data),
    .bbuf_rd_en        (bbuf_rd_en),
    .bbuf_rd_addr      (bbuf_rd_addr),
    .bbuf_rd_data      (bbuf_rd_data),
    .sa_enable         (sa_enable),
    .sa_acc_clear      (sa_acc_clear),
    .sa_w_in           (sa_w_in),
    .sa_a_in           (sa_a_in),
    .sa_result_row_sel (sa_result_row_sel),
    .sa_result_out     (sa_result_out),
    .act_valid_in      (act_valid_in),
    .act_fn_sel        (act_fn_sel),
    .act_data_in       (act_data_in),
    .act_data_out      (act_data_out),
    .act_valid_out     (act_valid_out),
    .current_layer     (engine_current_layer)
  );

  // ---- Output assignments ----
  assign irq_done = (engine_done_count != 8'd0);
  assign busy     = engine_busy;

endmodule
