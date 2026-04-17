// pool_kernel.sv — Pooling Kernel (Section III.B of EF-Train paper)
//
// FP mode:
//   Max pooling:  Y[r,c] = max(X[pool_window])  — stores index for BP
//   Avg pooling:  Y[r,c] = mean(X[pool_window])
//
// BP mode (Eq. 5):
//   Max pooling:  dX[i] = dY[j] if i was the argmax, else 0
//   Avg pooling:  dX[i] = dY[j] / (pool_h × pool_w)
//
// Processes one output element at a time, reading pool_h × pool_w inputs.

module pool_kernel
  import ef_train_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Control
  input  op_mode_e    mode,        // FP or BP
  input  pool_type_e  pool_type,   // MAX or AVG
  input  logic        start,
  input  logic [3:0]  pool_h,      // pooling window height
  input  logic [3:0]  pool_w,      // pooling window width
  output logic        busy,
  output logic        done,

  // Streaming input
  input  logic [DATA_WIDTH-1:0] x_in,
  input  logic                  x_valid,
  output logic                  x_ready,

  // Streaming gradient input (BP mode)
  input  logic [DATA_WIDTH-1:0] dy_in,
  input  logic                  dy_valid,

  // Pool index memory interface (for max pooling BP)
  output logic [15:0]           pool_idx_wr_addr,
  output logic [7:0]            pool_idx_wr_data,  // index within window
  output logic                  pool_idx_wr_en,
  input  logic [7:0]            pool_idx_rd_data,
  output logic [15:0]           pool_idx_rd_addr,
  output logic                  pool_idx_rd_en,

  // Output
  output logic [DATA_WIDTH-1:0] y_out,
  output logic                  y_valid,

  // Gradient output (BP mode)
  output logic [DATA_WIDTH-1:0] dx_out,
  output logic                  dx_valid
);

  typedef enum logic [2:0] {
    POOL_IDLE,
    POOL_FP_COLLECT,
    POOL_FP_OUTPUT,
    POOL_BP_SCATTER,
    POOL_DONE
  } pool_state_e;

  pool_state_e state;
  logic [7:0]  win_cnt;      // position within pooling window
  logic [7:0]  win_size;     // pool_h × pool_w
  logic [15:0] out_cnt;      // output element counter

  // Max tracking
  logic [DATA_WIDTH-1:0] max_val;
  logic [7:0]            max_idx;

  // Average accumulator
  logic [DATA_WIDTH-1:0] sum_acc;

  // FP32 helpers
  localparam logic [31:0] FP32_NEG_INF = 32'hFF80_0000;
  localparam logic [31:0] FP32_ZERO    = 32'h0000_0000;

  assign win_size = {4'd0, pool_h} * {4'd0, pool_w};
  assign busy     = (state != POOL_IDLE && state != POOL_DONE);
  assign done     = (state == POOL_DONE);
  assign x_ready  = (state == POOL_FP_COLLECT);

  // FP32 compare for max pooling (a > b if a is more positive)
  // Simplified: treat as sign-magnitude comparison
  wire x_gt_max = (!x_in[31] && max_val[31]) ||
                  (x_in[31] == max_val[31] && !x_in[31] && x_in[30:0] > max_val[30:0]) ||
                  (x_in[31] == max_val[31] &&  x_in[31] && x_in[30:0] < max_val[30:0]);

  // FP32 adder for average
  wire [DATA_WIDTH-1:0] sum_plus_x;
  fp32_add u_sum (
    .a      (sum_acc),
    .b      (x_in),
    .result (sum_plus_x)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= POOL_IDLE;
      win_cnt         <= '0;
      out_cnt         <= '0;
      max_val         <= FP32_NEG_INF;
      max_idx         <= '0;
      sum_acc         <= FP32_ZERO;
      y_valid         <= 1'b0;
      dx_valid        <= 1'b0;
      pool_idx_wr_en  <= 1'b0;
      pool_idx_rd_en  <= 1'b0;
    end else begin
      y_valid        <= 1'b0;
      dx_valid       <= 1'b0;
      pool_idx_wr_en <= 1'b0;
      pool_idx_rd_en <= 1'b0;

      case (state)
        POOL_IDLE: begin
          if (start) begin
            win_cnt <= '0;
            out_cnt <= '0;
            max_val <= FP32_NEG_INF;
            sum_acc <= FP32_ZERO;
            if (mode == MODE_FP)
              state <= POOL_FP_COLLECT;
            else
              state <= POOL_BP_SCATTER;
          end
        end

        // ---- FP: collect pool_h×pool_w elements ----
        POOL_FP_COLLECT: begin
          if (x_valid) begin
            win_cnt <= win_cnt + 1;

            if (pool_type == POOL_MAX) begin
              if (x_gt_max) begin
                max_val <= x_in;
                max_idx <= win_cnt;
              end
            end else begin
              sum_acc <= sum_plus_x;
            end

            if (win_cnt + 1 == win_size) begin
              state <= POOL_FP_OUTPUT;
            end
          end
        end

        POOL_FP_OUTPUT: begin
          if (pool_type == POOL_MAX) begin
            y_out   <= max_val;
            y_valid <= 1'b1;
            // Store argmax index for backprop
            pool_idx_wr_addr <= out_cnt;
            pool_idx_wr_data <= max_idx;
            pool_idx_wr_en   <= 1'b1;
          end else begin
            // Average: sum / window_size (division approximated)
            y_out   <= sum_acc;  // TODO: divide by win_size
            y_valid <= 1'b1;
          end

          out_cnt <= out_cnt + 1;
          win_cnt <= '0;
          max_val <= FP32_NEG_INF;
          sum_acc <= FP32_ZERO;
          state   <= POOL_FP_COLLECT;  // next window
          // Done condition checked externally
        end

        // ---- BP: scatter gradients ----
        POOL_BP_SCATTER: begin
          if (dy_valid) begin
            if (pool_type == POOL_MAX) begin
              // Read stored index, output dY at that position, 0 elsewhere
              pool_idx_rd_addr <= out_cnt;
              pool_idx_rd_en   <= 1'b1;
              // On next cycle, scatter
              for (int i = 0; i < 1; i++) begin
                dx_out  <= (win_cnt == pool_idx_rd_data) ? dy_in : FP32_ZERO;
                dx_valid <= 1'b1;
              end
            end else begin
              // Average: each input gets dY / window_size
              dx_out   <= dy_in;  // TODO: divide by win_size
              dx_valid <= 1'b1;
            end

            win_cnt <= win_cnt + 1;
            if (win_cnt + 1 == win_size) begin
              win_cnt <= '0;
              out_cnt <= out_cnt + 1;
            end
          end
        end

        POOL_DONE: begin
          state <= POOL_IDLE;
        end

        default: state <= POOL_IDLE;
      endcase
    end
  end

endmodule
