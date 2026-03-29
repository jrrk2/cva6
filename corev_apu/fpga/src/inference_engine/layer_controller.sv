// layer_controller.sv — FSM that orchestrates layer-by-layer inference
//
// For each layer, the controller:
//   1. Reads layer descriptor (input_dim, output_dim, activation, addresses)
//   2. Tiles the computation across ARRAY_ROWS x ARRAY_COLS
//   3. For each output tile:
//      a. Clears accumulators
//      b. Streams K/ARRAY_COLS weight+activation tiles through systolic array
//      c. Adds bias
//      d. Applies activation function
//      e. Writes result to output activation buffer
//   4. Swaps activation buffer banks and moves to next layer
//
// Tiling strategy:
//   Output dim M is tiled in chunks of ARRAY_COLS (16)
//   Input dim K is tiled in chunks of ARRAY_ROWS (16)
//   For each (m_tile, k_tile): stream ARRAY_ROWS cycles of data

module layer_controller
  import inference_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // Control interface
  input  logic        start,
  output logic [7:0]  done_count,
  output logic        busy,
  input  logic [4:0]  num_layers,

  // Layer descriptors (stored in register file, indexed by layer)
  input  logic [15:0] layer_input_dim  [MAX_LAYERS],
  input  logic [15:0] layer_output_dim [MAX_LAYERS],
  input  act_fn_e     layer_activation [MAX_LAYERS],
  input  logic [13:0] layer_weight_addr[MAX_LAYERS],
  input  logic [13:0] layer_bias_addr  [MAX_LAYERS],

  // Weight buffer interface
  output logic                             wbuf_rd_en,
  output logic                             wbuf_rd_bank,
  output logic [$clog2(4096)-1:0]          wbuf_rd_addr,
  input  logic [ARRAY_COLS*DATA_WIDTH-1:0] wbuf_rd_data,

  // Activation buffer interface
  output logic                              abuf_rd_en,
  output logic                              abuf_rd_bank,
  output logic [$clog2(1024)-1:0]           abuf_rd_addr,
  input  logic [ARRAY_ROWS*DATA_WIDTH-1:0]  abuf_rd_data,

  output logic                              abuf_wr_en,
  output logic                              abuf_wr_bank,
  output logic [$clog2(1024)-1:0]           abuf_wr_addr,
  output logic [ARRAY_ROWS*DATA_WIDTH-1:0]  abuf_wr_data,

  // Bias buffer interface
  output logic                              bbuf_rd_en,
  output logic [$clog2(256)-1:0]            bbuf_rd_addr,
  input  logic [ARRAY_COLS*BIAS_WIDTH-1:0]  bbuf_rd_data,

  // Systolic array interface
  output logic                              sa_enable,
  output logic                              sa_acc_clear,
  output logic signed [DATA_WIDTH-1:0]      sa_w_in  [ARRAY_ROWS],
  output logic signed [DATA_WIDTH-1:0]      sa_a_in  [ARRAY_COLS],
  output logic [$clog2(ARRAY_ROWS)-1:0]     sa_result_row_sel,
  input  logic signed [ACC_WIDTH-1:0]       sa_result_out [ARRAY_COLS],

  // Activation unit interface
  output logic                              act_valid_in,
  output act_fn_e                           act_fn_sel,
  output logic signed [ACC_WIDTH-1:0]       act_data_in  [ARRAY_COLS],
  input  logic        [DATA_WIDTH-1:0]      act_data_out [ARRAY_COLS],
  input  logic                              act_valid_out,

  // Status
  output logic [4:0]  current_layer
);

  // ---- FSM States ----
  typedef enum logic [3:0] {
    S_IDLE,
    S_LAYER_SETUP,
    S_CLEAR_ACC,
    S_STREAM,
    S_STREAM_DRAIN,
    S_BIAS_LOAD,
    S_BIAS_ADD,
    S_ACTIVATE,
    S_WRITE_RESULT,
    S_NEXT_M_TILE,
    S_NEXT_LAYER,
    S_DONE
  } state_e;

  state_e state_q, state_d;

  // ---- Counters & registers ----
  logic [4:0]  layer_idx;
  logic [15:0] cur_input_dim, cur_output_dim;
  act_fn_e     cur_activation;
  logic [13:0] cur_weight_base, cur_bias_base;

  // Tile counters
  logic [15:0] m_tile;      // current output tile (steps of ARRAY_COLS)
  logic [15:0] k_tile;      // current input tile (steps of ARRAY_ROWS)
  logic [15:0] stream_cnt;  // cycles within a tile
  logic [3:0]  drain_cnt;   // pipeline drain counter
  logic [3:0]  readout_row; // row readout counter

  // Activation bank select (ping-pong)
  logic act_bank;  // 0: read from bank0/write to bank1, 1: vice versa

  // Bias register
  logic signed [BIAS_WIDTH-1:0] bias_reg [ARRAY_COLS];

  // Tile counts
  logic [15:0] m_tiles, k_tiles;

  // Ceiling division helper
  function automatic logic [15:0] ceil_div(logic [15:0] a, logic [15:0] b);
    return (a + b - 1) / b;
  endfunction

  // ---- FSM ----
  always_ff @(posedge clk) begin
    if (!rst_n)
      state_q <= S_IDLE;
    else
      state_q <= state_d;
  end

  always_comb begin
    state_d = state_q;

    case (state_q)
      S_IDLE:
        if (start)
          state_d = S_LAYER_SETUP;

      S_LAYER_SETUP:
        state_d = S_CLEAR_ACC;

      S_CLEAR_ACC:
        state_d = S_STREAM;

      S_STREAM:
        if (stream_cnt == ARRAY_ROWS - 1)
          state_d = S_STREAM_DRAIN;

      S_STREAM_DRAIN:
        if (drain_cnt == 3)  // 2 extra cycles for pipeline + BRAM latency
          state_d = (k_tile + ARRAY_ROWS < cur_input_dim) ? S_CLEAR_ACC : S_BIAS_LOAD;

      S_BIAS_LOAD:
        state_d = S_BIAS_ADD;  // 1 cycle for BRAM read latency

      S_BIAS_ADD:
        state_d = S_ACTIVATE;

      S_ACTIVATE:
        if (act_valid_out)
          state_d = S_WRITE_RESULT;

      S_WRITE_RESULT:
        if (readout_row == ARRAY_ROWS - 1)
          state_d = S_NEXT_M_TILE;
        else
          state_d = S_WRITE_RESULT;  // scatter all 16 columns without re-activating

      S_NEXT_M_TILE:
        if (m_tile + ARRAY_COLS >= cur_output_dim)
          state_d = S_NEXT_LAYER;
        else
          state_d = S_CLEAR_ACC;

      S_NEXT_LAYER:
        if (layer_idx + 1 >= num_layers)
          state_d = S_DONE;
        else
          state_d = S_LAYER_SETUP;

      S_DONE:
        state_d = S_IDLE;

      default:
        state_d = S_IDLE;
    endcase
  end

  // ---- Datapath ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      layer_idx       <= '0;
      m_tile          <= '0;
      k_tile          <= '0;
      stream_cnt      <= '0;
      drain_cnt       <= '0;
      readout_row     <= '0;
      act_bank        <= 1'b0;
      cur_input_dim   <= '0;
      cur_output_dim  <= '0;
      cur_activation  <= ACT_NONE;
      cur_weight_base <= '0;
      cur_bias_base   <= '0;
      for (int i = 0; i < ARRAY_COLS; i++)
        bias_reg[i] <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (start) begin
            layer_idx <= '0;
            act_bank  <= 1'b0;
          end
        end

        S_LAYER_SETUP: begin
          cur_input_dim   <= layer_input_dim[layer_idx];
          cur_output_dim  <= layer_output_dim[layer_idx];
          cur_activation  <= layer_activation[layer_idx];
          cur_weight_base <= layer_weight_addr[layer_idx];
          cur_bias_base   <= layer_bias_addr[layer_idx];
          m_tile          <= '0;
          k_tile          <= '0;
        end

        S_CLEAR_ACC: begin
          stream_cnt <= '0;
        end

        S_STREAM: begin
          stream_cnt <= stream_cnt + 1;
          if (stream_cnt == ARRAY_ROWS - 1)
            drain_cnt <= '0;
        end

        S_STREAM_DRAIN: begin
          drain_cnt <= drain_cnt + 1;
          if (drain_cnt == 3) begin
            if (k_tile + ARRAY_ROWS < cur_input_dim) begin
              k_tile     <= k_tile + ARRAY_ROWS;
              stream_cnt <= '0;
            end
          end
        end

        S_BIAS_LOAD: begin
          // nothing — wait for BRAM read
        end

        S_BIAS_ADD: begin
          // Latch bias values from buffer
          for (int i = 0; i < ARRAY_COLS; i++)
            bias_reg[i] <= signed'(bbuf_rd_data[i*BIAS_WIDTH +: BIAS_WIDTH]);
          readout_row <= '0;
        end

        S_ACTIVATE: begin
          // Wait for activation unit
        end

        S_WRITE_RESULT: begin
          readout_row <= readout_row + 1;
        end

        S_NEXT_M_TILE: begin
          m_tile <= m_tile + ARRAY_COLS;
          k_tile <= '0;
        end

        S_NEXT_LAYER: begin
          layer_idx <= layer_idx + 1;
          act_bank  <= ~act_bank;  // swap ping-pong
        end

        default: ;
      endcase
    end
  end

  // ---- Output assignments ----

  // Weight buffer: read during STREAM phase (with 1-cycle prefetch)
  // BRAM has 1-cycle read latency, so we issue the address 1 cycle early:
  //   S_CLEAR_ACC: prefetch row 0 of tile
  //   S_STREAM:    fetch row stream_cnt+1 (data for stream_cnt arrives this cycle)
  always_comb begin
    wbuf_rd_en   = (state_q == S_STREAM) || (state_q == S_CLEAR_ACC);
    wbuf_rd_bank = 1'b0;  // single bank for now
    wbuf_rd_addr = cur_weight_base +
                   (m_tile >> $clog2(ARRAY_COLS)) * (ceil_div(cur_input_dim, ARRAY_ROWS[15:0]) << $clog2(ARRAY_ROWS)) +
                   (k_tile >> $clog2(ARRAY_ROWS)) * ARRAY_ROWS +
                   ((state_q == S_CLEAR_ACC) ? {$clog2(4096){1'b0}} :
                    stream_cnt[$clog2(4096)-1:0] + 1);
  end

  // Activation buffer: read during STREAM phase (with 1-cycle prefetch)
  // Same pipeline compensation as weight buffer
  always_comb begin
    abuf_rd_en   = (state_q == S_STREAM) || (state_q == S_CLEAR_ACC);
    abuf_rd_bank = act_bank;
    abuf_rd_addr = (state_q == S_CLEAR_ACC) ? k_tile[$clog2(1024)-1:0] :
                   ($clog2(1024))'(k_tile + stream_cnt + 1);
  end

  // Unpack weight and activation vectors for systolic array
  always_comb begin
    for (int i = 0; i < ARRAY_ROWS; i++)
      sa_w_in[i] = (state_q == S_STREAM) ?
        signed'(wbuf_rd_data[i*DATA_WIDTH +: DATA_WIDTH]) : '0;

    for (int i = 0; i < ARRAY_COLS; i++)
      sa_a_in[i] = (state_q == S_STREAM) ?
        signed'(abuf_rd_data[i*DATA_WIDTH +: DATA_WIDTH]) : '0;
  end

  assign sa_enable    = (state_q == S_STREAM) || (state_q == S_STREAM_DRAIN);
  assign sa_acc_clear = (state_q == S_CLEAR_ACC) && (k_tile == '0);

  // Bias buffer read
  always_comb begin
    bbuf_rd_en   = (state_q == S_BIAS_LOAD);
    bbuf_rd_addr = cur_bias_base + (m_tile >> $clog2(ARRAY_COLS));
  end

  // Activation unit: feed accumulator + bias
  // Always read row 0: with the broadcast array, acc[0][c] holds the correct
  // single-image dot product for output neuron m*16+c.
  assign sa_result_row_sel = '0;

  always_comb begin
    act_valid_in = (state_q == S_ACTIVATE);
    act_fn_sel   = cur_activation;
    for (int i = 0; i < ARRAY_COLS; i++)
      act_data_in[i] = sa_result_out[i] + bias_reg[i];
  end

  // Scatter write: all 16 columns' results are computed in one S_ACTIVATE
  // then written one per cycle during S_WRITE_RESULT.
  // Column readout_row → byte 0 of address m_tile+readout_row.
  // The activation unit output registers hold stable after S_ACTIVATE completes.
  always_comb begin
    abuf_wr_en   = (state_q == S_WRITE_RESULT);
    abuf_wr_bank = ~act_bank;
    abuf_wr_addr = m_tile + readout_row;
    for (int i = 0; i < ARRAY_ROWS; i++) begin
      if (i == 0)
        abuf_wr_data[0 +: DATA_WIDTH] = act_data_out[readout_row];
      else
        abuf_wr_data[i*DATA_WIDTH +: DATA_WIDTH] = '0;
    end
  end

  // Completion counter — increments each time inference finishes
  logic [7:0] done_cnt_q;
  always_ff @(posedge clk) begin
    if (!rst_n)
      done_cnt_q <= 8'd0;
    else if (state_q == S_DONE)
      done_cnt_q <= done_cnt_q + 8'd1;
  end

  // Status outputs
  assign done_count    = done_cnt_q;
  assign busy          = (state_q != S_IDLE);
  assign current_layer = layer_idx;

endmodule
