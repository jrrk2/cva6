// layer_controller.sv — Layer execution FSM for EF-Train
//
// Implements the tiled loop ordering from Fig. 15 of the EF-Train paper:
//
// FP/BP loop order:
//   for to = 0..C_out step TM:        // output channel tiles
//     for row = 0..out_H:              // output rows
//       for ti = 0..C_in step TN:      // input channel tiles
//         DMA: load IFM tile [ti..ti+TN-1]
//         DMA: load WEI tile [to..to+TM-1, ti..ti+TN-1]
//         Compute: MAC across kernel window
//       Store OFM tile [to..to+TM-1]
//
// WU loop order:
//   for to = 0..C_out step TM:
//     for ti = 0..C_in step TN:
//       for row = 0..out_H:
//         DMA: load IFM tile, OFM tile (loss gradients)
//         Compute: accumulate dW
//       DMA: store dW tile [to..to+TM-1, ti..ti+TN-1]
//
// Weight reuse: weights loaded once for first batch image's first row,
// reused across mini-batch (Section IV.B).

module layer_controller
  import ef_train_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // ---- Host interface ----
  input  layer_desc_t  layer_desc,
  input  logic         layer_start,
  output logic         layer_done,
  output logic         layer_busy,

  // ---- Conv kernel control ----
  output op_mode_e     conv_mode,
  output logic         conv_clear_acc,
  output logic         conv_compute_en,

  // ---- Conv kernel data buses ----
  output logic [DATA_WIDTH-1:0] conv_a_bus [TN],   // weights or activations
  output logic [DATA_WIDTH-1:0] conv_b_bus [TM],   // ifm or loss

  // ---- Buffer read interfaces ----
  // IFM buffer
  output logic [15:0]           ifm_rd_addr,
  output logic                  ifm_rd_en,
  input  logic [DATA_WIDTH-1:0] ifm_rd_data,

  // OFM buffer (for BP/WU: holds loss gradients)
  output logic [15:0]           ofm_rd_addr,
  output logic                  ofm_rd_en,
  input  logic [DATA_WIDTH-1:0] ofm_rd_data,

  // Weight buffer
  output logic [15:0]           wei_rd_addr,
  output logic                  wei_rd_en,
  input  logic [DATA_WIDTH-1:0] wei_rd_data,

  // ---- Buffer write interfaces ----
  output logic [15:0]           ofm_wr_addr,
  output logic [DATA_WIDTH-1:0] ofm_wr_data,
  output logic                  ofm_wr_en,

  output logic [15:0]           wei_wr_addr,
  output logic [DATA_WIDTH-1:0] wei_wr_data,
  output logic                  wei_wr_en,

  // ---- DMA kick signals ----
  output logic        dma_ifm_start,
  output logic [63:0] dma_ifm_addr,
  output logic [15:0] dma_ifm_len,
  input  logic        dma_ifm_done,

  output logic        dma_ofm_start,
  output logic [63:0] dma_ofm_addr,
  output logic [15:0] dma_ofm_len,
  input  logic        dma_ofm_done,

  output logic        dma_wei_start,
  output logic [63:0] dma_wei_addr,
  output logic [15:0] dma_wei_len,
  input  logic        dma_wei_done,

  output logic        dma_out_start,
  output logic        dma_out_dir,      // 0=read, 1=write
  output logic [63:0] dma_out_addr,
  output logic [15:0] dma_out_len,
  input  logic        dma_out_done,

  // ---- Buffer swap signals ----
  output logic        ifm_buf_swap,
  output logic        ofm_buf_swap,
  output logic        wei_buf_swap,

  // ---- Conv kernel results (from adder tree or PE array) ----
  input  logic [DATA_WIDTH-1:0] conv_ofm_out [TM],
  input  logic                  conv_ofm_valid,
  input  logic [DATA_WIDTH-1:0] conv_dw_out [TM][TN],

  // ---- ReLU ----
  output op_mode_e              relu_mode,
  output logic [DATA_WIDTH-1:0] relu_x_in,
  output logic [DATA_WIDTH-1:0] relu_dy_in,
  input  logic [DATA_WIDTH-1:0] relu_y_out
);

  // ================================================================
  //  Tile loop iterators
  // ================================================================
  logic [15:0] to_idx;     // output channel tile index
  logic [15:0] ti_idx;     // input channel tile index
  logic [7:0]  row_idx;    // output row
  logic [7:0]  col_idx;    // output column
  logic [3:0]  kr_idx;     // kernel row
  logic [3:0]  kc_idx;     // kernel column
  logic [7:0]  batch_idx;  // mini-batch index
  logic [3:0]  tm_idx;     // PE row within tile (0..TM-1)
  logic [3:0]  tn_idx;     // PE col within tile (0..TN-1)

  // Derived dimensions
  wire [15:0] out_ch_tiles = ceildiv(layer_desc.out_channels, TM[15:0]);
  wire [15:0] in_ch_tiles  = ceildiv(layer_desc.in_channels,  TN[15:0]);

  // OFM partial sum accumulator (TM accumulators, accumulated across Tn tiles)
  logic [DATA_WIDTH-1:0] psum [TM];

  // ================================================================
  //  Main FSM
  // ================================================================
  typedef enum logic [4:0] {
    S_IDLE,
    S_LAYER_SETUP,
    // -- DMA load phase --
    S_DMA_LOAD_WEI,
    S_DMA_LOAD_IFM,
    S_DMA_LOAD_OFM,       // BP/WU only
    S_DMA_WAIT,
    S_BUF_SWAP,
    // -- Compute phase --
    S_CLEAR_ACC,
    S_LOAD_OPERANDS,      // read from buffers into PE input buses
    S_COMPUTE,            // MAC operation
    S_ADVANCE_KERNEL,     // advance kr, kc
    S_ADVANCE_SPATIAL,    // advance col, row
    S_REDUCE,             // adder tree reduction (FP/BP)
    S_ACTIVATE,           // ReLU
    S_WRITE_OFM,          // write result to OFM buffer
    S_WRITE_DW,           // WU: write weight gradients
    // -- Tile advancement --
    S_NEXT_TI,
    S_NEXT_ROW,
    S_NEXT_TO,
    S_NEXT_BATCH,
    S_STORE_OUT,          // DMA store results to DRAM
    S_STORE_WAIT,
    S_DONE
  } ctrl_state_e;

  ctrl_state_e state;

  assign layer_busy = (state != S_IDLE && state != S_DONE);
  assign layer_done = (state == S_DONE);

  // ================================================================
  //  Address generation helpers
  // ================================================================
  // Weight address in buffer: for tile (to, ti), kernel position (kr, kc)
  // Layout: [to_tile][ti_tile][kr][kc] — continuous per paper's data reshaping
  function automatic logic [15:0] wei_addr(
    input logic [15:0] to, ti,
    input logic [3:0] kr, kc,
    input logic [3:0] tm, tn
  );
    // Flattened: ((to/TM * in_ch_tiles * K*K) + (ti/TN * K*K) + kr*K + kc) * TM*TN + tm*TN + tn
    return layer_desc.wei_base +
           (to[15:0] * {12'd0, layer_desc.kern_h} * {12'd0, layer_desc.kern_w} +
            {12'd0, kr} * {12'd0, layer_desc.kern_w} + {12'd0, kc}) *
           TN[15:0] + {12'd0, tn};
  endfunction

  // IFM address: for input channel tn at spatial position
  function automatic logic [15:0] ifm_addr(
    input logic [15:0] ti,
    input logic [3:0] tn,
    input logic [7:0] row, col
  );
    return layer_desc.ifm_base +
           {8'd0, row} * {8'd0, layer_desc.in_w} + {8'd0, col};
  endfunction

  // ================================================================
  //  State machine
  // ================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= S_IDLE;
      to_idx          <= '0;
      ti_idx          <= '0;
      row_idx         <= '0;
      col_idx         <= '0;
      kr_idx          <= '0;
      kc_idx          <= '0;
      batch_idx       <= '0;
      tm_idx          <= '0;
      tn_idx          <= '0;
      conv_clear_acc  <= 1'b0;
      conv_compute_en <= 1'b0;
      conv_mode       <= MODE_FP;
      ofm_wr_en       <= 1'b0;
      wei_wr_en       <= 1'b0;
      dma_ifm_start   <= 1'b0;
      dma_ofm_start   <= 1'b0;
      dma_wei_start   <= 1'b0;
      dma_out_start   <= 1'b0;
      ifm_buf_swap    <= 1'b0;
      ofm_buf_swap    <= 1'b0;
      wei_buf_swap    <= 1'b0;
      ifm_rd_en       <= 1'b0;
      ofm_rd_en       <= 1'b0;
      wei_rd_en       <= 1'b0;
    end else begin
      // Default: deassert pulses
      conv_clear_acc  <= 1'b0;
      conv_compute_en <= 1'b0;
      ofm_wr_en       <= 1'b0;
      wei_wr_en       <= 1'b0;
      dma_ifm_start   <= 1'b0;
      dma_ofm_start   <= 1'b0;
      dma_wei_start   <= 1'b0;
      dma_out_start   <= 1'b0;
      ifm_buf_swap    <= 1'b0;
      ofm_buf_swap    <= 1'b0;
      wei_buf_swap    <= 1'b0;
      ifm_rd_en       <= 1'b0;
      ofm_rd_en       <= 1'b0;
      wei_rd_en       <= 1'b0;

      case (state)
        // ============================================================
        S_IDLE: begin
          if (layer_start) begin
            to_idx    <= '0;
            ti_idx    <= '0;
            row_idx   <= '0;
            col_idx   <= '0;
            kr_idx    <= '0;
            kc_idx    <= '0;
            batch_idx <= '0;
            conv_mode <= layer_desc.op_mode;
            state     <= S_LAYER_SETUP;
          end
        end

        // ============================================================
        S_LAYER_SETUP: begin
          // Kick off first DMA loads
          state <= S_DMA_LOAD_WEI;
        end

        // ============================================================
        //  DMA Load Phase
        // ============================================================
        S_DMA_LOAD_WEI: begin
          if (layer_desc.op_mode != MODE_WU) begin
            // FP/BP: load weight tile [to..to+TM-1, ti..ti+TN-1]
            dma_wei_start <= 1'b1;
            dma_wei_len   <= TM[15:0] * TN[15:0] *
                             {12'd0, layer_desc.kern_h} * {12'd0, layer_desc.kern_w};
          end
          state <= S_DMA_LOAD_IFM;
        end

        S_DMA_LOAD_IFM: begin
          // Load IFM tile
          dma_ifm_start <= 1'b1;
          dma_ifm_len   <= TN[15:0] * {8'd0, layer_desc.in_h} * {8'd0, layer_desc.in_w};

          if (layer_desc.op_mode == MODE_BP || layer_desc.op_mode == MODE_WU)
            state <= S_DMA_LOAD_OFM;
          else
            state <= S_DMA_WAIT;
        end

        S_DMA_LOAD_OFM: begin
          // BP/WU: also load loss gradients into OFM buffer
          dma_ofm_start <= 1'b1;
          dma_ofm_len   <= TM[15:0] * {8'd0, layer_desc.out_h} * {8'd0, layer_desc.out_w};
          state <= S_DMA_WAIT;
        end

        S_DMA_WAIT: begin
          // Wait for all active DMAs to complete
          if (dma_ifm_done && dma_wei_done &&
              (layer_desc.op_mode == MODE_FP || dma_ofm_done)) begin
            state <= S_BUF_SWAP;
          end
        end

        S_BUF_SWAP: begin
          // Swap double buffers so compute uses freshly loaded data
          ifm_buf_swap <= 1'b1;
          wei_buf_swap <= 1'b1;
          if (layer_desc.op_mode != MODE_FP)
            ofm_buf_swap <= 1'b1;
          state <= S_CLEAR_ACC;
        end

        // ============================================================
        //  Compute Phase
        // ============================================================
        S_CLEAR_ACC: begin
          conv_clear_acc <= 1'b1;
          state          <= S_LOAD_OPERANDS;
        end

        S_LOAD_OPERANDS: begin
          // Read weight and IFM/OFM data from buffers
          // Address depends on current tile position and kernel indices
          if (layer_desc.op_mode == MODE_FP || layer_desc.op_mode == MODE_BP) begin
            // FP/BP mode 1: a_bus = weights, b_bus = IFM
            for (int n = 0; n < TN; n++) begin
              wei_rd_addr <= wei_addr(to_idx, ti_idx, kr_idx, kc_idx, 4'd0, 4'(n));
              wei_rd_en   <= 1'b1;
            end
            for (int m = 0; m < TM; m++) begin
              ifm_rd_addr <= ifm_addr(ti_idx, 4'd0,
                                      row_idx * layer_desc.stride[3:0] + kr_idx,
                                      col_idx * layer_desc.stride[3:0] + kc_idx);
              ifm_rd_en   <= 1'b1;
            end
          end else begin
            // WU mode 2: a_bus = activations (IFM), b_bus = loss (OFM)
            for (int n = 0; n < TN; n++) begin
              ifm_rd_addr <= ifm_addr(ti_idx, 4'(n),
                                      row_idx * layer_desc.stride[3:0] + kr_idx,
                                      col_idx * layer_desc.stride[3:0] + kc_idx);
              ifm_rd_en   <= 1'b1;
            end
            ofm_rd_addr <= {8'd0, row_idx} * {8'd0, layer_desc.out_w} + {8'd0, col_idx};
            ofm_rd_en   <= 1'b1;
          end
          state <= S_COMPUTE;
        end

        S_COMPUTE: begin
          conv_compute_en <= 1'b1;
          // Route buffer data to PE array
          // (In practice, buffer outputs are registered and routed combinationally)
          if (layer_desc.op_mode == MODE_FP || layer_desc.op_mode == MODE_BP) begin
            conv_a_bus[0] <= wei_rd_data;  // simplified: should be per-TN
            conv_b_bus[0] <= ifm_rd_data;  // simplified: should be per-TM
          end else begin
            conv_a_bus[0] <= ifm_rd_data;
            conv_b_bus[0] <= ofm_rd_data;
          end
          state <= S_ADVANCE_KERNEL;
        end

        // ============================================================
        //  Loop advancement
        // ============================================================
        S_ADVANCE_KERNEL: begin
          if (kc_idx + 1 < {4'd0, layer_desc.kern_w}) begin
            kc_idx <= kc_idx + 1;
            state  <= S_LOAD_OPERANDS;
          end else begin
            kc_idx <= '0;
            if (kr_idx + 1 < {4'd0, layer_desc.kern_h}) begin
              kr_idx <= kr_idx + 1;
              state  <= S_LOAD_OPERANDS;
            end else begin
              kr_idx <= '0;
              state  <= S_ADVANCE_SPATIAL;
            end
          end
        end

        S_ADVANCE_SPATIAL: begin
          if (layer_desc.op_mode == MODE_WU) begin
            // WU: spatial is inner loop — advance col, row
            if (col_idx + 1 < layer_desc.out_w) begin
              col_idx <= col_idx + 1;
              state   <= S_LOAD_OPERANDS;
            end else begin
              col_idx <= '0;
              if (row_idx + 1 < layer_desc.out_h) begin
                row_idx <= row_idx + 1;
                state   <= S_LOAD_OPERANDS;
              end else begin
                row_idx <= '0;
                // All spatial done for this (to, ti) tile → write dW
                state <= S_WRITE_DW;
              end
            end
          end else begin
            // FP/BP: spatial is middle loop — after kernel, check ti
            state <= S_NEXT_TI;
          end
        end

        S_NEXT_TI: begin
          if (ti_idx + TN[15:0] < layer_desc.in_channels) begin
            ti_idx <= ti_idx + TN[15:0];
            // Need to load next weight and IFM tiles
            state  <= S_DMA_LOAD_WEI;
          end else begin
            ti_idx <= '0;
            // All input channels accumulated → activate and write
            state  <= S_REDUCE;
          end
        end

        // ============================================================
        //  Result processing
        // ============================================================
        S_REDUCE: begin
          // Adder tree results available in conv_ofm_out after pipeline flush
          if (conv_ofm_valid) begin
            for (int m = 0; m < TM; m++)
              psum[m] <= conv_ofm_out[m];
            if (layer_desc.activation == ACT_RELU)
              state <= S_ACTIVATE;
            else
              state <= S_WRITE_OFM;
          end
        end

        S_ACTIVATE: begin
          // Apply ReLU to each of TM outputs
          relu_mode <= layer_desc.op_mode;
          // Process sequentially (could be parallelized with TM ReLU units)
          relu_x_in  <= psum[tm_idx];
          relu_dy_in <= '0;
          psum[tm_idx] <= relu_y_out;
          if (tm_idx + 1 == TM[3:0]) begin
            tm_idx <= '0;
            state  <= S_WRITE_OFM;
          end else begin
            tm_idx <= tm_idx + 1;
          end
        end

        S_WRITE_OFM: begin
          // Write TM output values to OFM buffer
          ofm_wr_addr <= layer_desc.ofm_base +
                         ({8'd0, row_idx} * {8'd0, layer_desc.out_w} + {8'd0, col_idx}) *
                         TM[15:0] + {12'd0, tm_idx};
          ofm_wr_data <= psum[tm_idx];
          ofm_wr_en   <= 1'b1;

          if (tm_idx + 1 == TM[3:0]) begin
            tm_idx <= '0;
            // Advance spatial position
            if (col_idx + 1 < layer_desc.out_w) begin
              col_idx <= col_idx + 1;
              state   <= S_CLEAR_ACC;
            end else begin
              col_idx <= '0;
              if (row_idx + 1 < layer_desc.out_h) begin
                row_idx <= row_idx + 1;
                state   <= S_CLEAR_ACC;
              end else begin
                row_idx <= '0;
                state   <= S_NEXT_TO;
              end
            end
          end else begin
            tm_idx <= tm_idx + 1;
          end
        end

        S_WRITE_DW: begin
          // WU: write TM×TN weight gradient values
          wei_wr_addr <= wei_addr(to_idx, ti_idx, kr_idx, kc_idx, tm_idx, tn_idx);
          wei_wr_data <= conv_dw_out[tm_idx][tn_idx];
          wei_wr_en   <= 1'b1;

          if (tn_idx + 1 == TN[3:0]) begin
            tn_idx <= '0;
            if (tm_idx + 1 == TM[3:0]) begin
              tm_idx <= '0;
              state  <= S_NEXT_TI;  // advance to next channel tile
            end else begin
              tm_idx <= tm_idx + 1;
            end
          end else begin
            tn_idx <= tn_idx + 1;
          end
        end

        S_NEXT_TO: begin
          // Store completed output tile to DRAM
          dma_out_start <= 1'b1;
          dma_out_dir   <= 1'b1;  // write
          dma_out_len   <= TM[15:0] * {8'd0, layer_desc.out_h} * {8'd0, layer_desc.out_w};
          state         <= S_STORE_WAIT;
        end

        S_STORE_WAIT: begin
          if (dma_out_done) begin
            if (to_idx + TM[15:0] < layer_desc.out_channels) begin
              to_idx <= to_idx + TM[15:0];
              state  <= S_LAYER_SETUP;
            end else begin
              to_idx <= '0;
              state  <= S_NEXT_BATCH;
            end
          end
        end

        S_NEXT_BATCH: begin
          if (batch_idx + 1 < layer_desc.batch_size) begin
            batch_idx <= batch_idx + 1;
            state     <= S_LAYER_SETUP;
          end else begin
            batch_idx <= '0;
            state     <= S_DONE;
          end
        end

        S_DONE: begin
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
