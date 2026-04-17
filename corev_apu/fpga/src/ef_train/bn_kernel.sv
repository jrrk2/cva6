// bn_kernel.sv — Batch Normalization Kernel (Section III.B of EF-Train paper)
//
// FP mode (Eqs. 6–11):
//   1. Compute channel mean:    E(X) = (1/N) Σ X_i
//   2. Compute channel variance: V(X) = (1/N) Σ (X_i - E(X))^2
//   3. Normalize:                Â = (X - E(X)) / sqrt(V(X) + ε)
//   4. Scale and shift:          Y = γ × Â + β
//
// BP mode (Eqs. 12–14):
//   1. Compute dγ = Σ (dY × Â)
//   2. Compute dβ = Σ dY
//   3. Propagate: dX = (1/N)(γ / sqrt(V+ε))(N×dY - dβ - Â×dγ)
//
// Processes one channel at a time, streaming spatial elements.

module bn_kernel
  import ef_train_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Control
  input  op_mode_e    mode,
  input  logic        start,
  input  logic [15:0] num_elements,  // N = H × W × B (spatial × batch)
  output logic        busy,
  output logic        done,

  // BN parameters (loaded from BN buffer)
  input  logic [DATA_WIDTH-1:0] gamma,
  input  logic [DATA_WIDTH-1:0] beta,
  input  logic [DATA_WIDTH-1:0] running_mean,   // for inference (not training)
  input  logic [DATA_WIDTH-1:0] running_var,

  // Streaming input
  input  logic [DATA_WIDTH-1:0] x_in,
  input  logic                  x_valid,
  output logic                  x_ready,

  // Streaming gradient input (BP mode)
  input  logic [DATA_WIDTH-1:0] dy_in,
  input  logic                  dy_valid,

  // Streaming output
  output logic [DATA_WIDTH-1:0] y_out,
  output logic                  y_valid,

  // Gradient outputs (BP mode)
  output logic [DATA_WIDTH-1:0] dx_out,
  output logic                  dx_valid,
  output logic [DATA_WIDTH-1:0] dgamma_out,
  output logic [DATA_WIDTH-1:0] dbeta_out,
  output logic                  dparams_valid
);

  // ================================================================
  //  State machine
  // ================================================================
  typedef enum logic [3:0] {
    BN_IDLE,
    BN_FP_MEAN,        // accumulate sum for mean
    BN_FP_VAR,         // accumulate sum for variance (2nd pass)
    BN_FP_NORM,        // normalize, scale, shift (3rd pass)
    BN_BP_DPARAMS,     // accumulate dγ, dβ (1st pass)
    BN_BP_DX,          // compute dX (2nd pass)
    BN_DONE
  } bn_state_e;

  bn_state_e state;
  logic [15:0] elem_cnt;

  // Accumulators
  logic [DATA_WIDTH-1:0] sum_acc;       // for mean
  logic [DATA_WIDTH-1:0] var_acc;       // for variance
  logic [DATA_WIDTH-1:0] dgamma_acc;    // dγ accumulator
  logic [DATA_WIDTH-1:0] dbeta_acc;     // dβ accumulator

  // Computed statistics
  logic [DATA_WIDTH-1:0] mean_q;
  logic [DATA_WIDTH-1:0] inv_std_q;     // 1 / sqrt(var + ε)
  logic [DATA_WIDTH-1:0] inv_n;         // 1/N precomputed

  // FP32 constants
  localparam logic [31:0] FP32_EPSILON = 32'h3727_C5AC;  // ~1e-5
  localparam logic [31:0] FP32_ZERO    = 32'h0000_0000;

  // Intermediate computation wires
  logic [DATA_WIDTH-1:0] add_a, add_b, add_result;
  logic [DATA_WIDTH-1:0] mul_a, mul_b, mul_result;

  // Simple FP32 multiply (reuse MAC with zero accumulator)
  fp32_mac u_mul (
    .a      (mul_a),
    .b      (mul_b),
    .acc_in (FP32_ZERO),
    .result (mul_result)
  );

  fp32_add u_add (
    .a      (add_a),
    .b      (add_b),
    .result (add_result)
  );

  assign busy    = (state != BN_IDLE && state != BN_DONE);
  assign done    = (state == BN_DONE);
  assign x_ready = (state == BN_FP_MEAN || state == BN_FP_VAR || state == BN_FP_NORM);

  // ================================================================
  //  State machine transitions
  // ================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= BN_IDLE;
      elem_cnt     <= '0;
      sum_acc      <= '0;
      var_acc      <= '0;
      dgamma_acc   <= '0;
      dbeta_acc    <= '0;
      mean_q       <= '0;
      inv_std_q    <= '0;
      inv_n        <= '0;
      y_valid      <= 1'b0;
      dx_valid     <= 1'b0;
      dparams_valid <= 1'b0;
    end else begin
      y_valid       <= 1'b0;
      dx_valid      <= 1'b0;
      dparams_valid <= 1'b0;

      case (state)
        BN_IDLE: begin
          if (start) begin
            sum_acc    <= '0;
            var_acc    <= '0;
            dgamma_acc <= '0;
            dbeta_acc  <= '0;
            elem_cnt   <= '0;
            if (mode == MODE_FP)
              state <= BN_FP_MEAN;
            else
              state <= BN_BP_DPARAMS;
          end
        end

        // ---- FP: Pass 1 — accumulate sum ----
        BN_FP_MEAN: begin
          if (x_valid) begin
            sum_acc  <= add_result;  // sum_acc + x_in
            elem_cnt <= elem_cnt + 1;
            if (elem_cnt + 1 == num_elements) begin
              // mean = sum / N — store for next pass
              // (inv_n and mean computed externally or in transition)
              mean_q   <= add_result;  // placeholder: needs division
              elem_cnt <= '0;
              state    <= BN_FP_VAR;
            end
          end
        end

        // ---- FP: Pass 2 — accumulate variance ----
        BN_FP_VAR: begin
          if (x_valid) begin
            // var_acc += (x - mean)^2
            var_acc  <= add_result;
            elem_cnt <= elem_cnt + 1;
            if (elem_cnt + 1 == num_elements) begin
              elem_cnt <= '0;
              state    <= BN_FP_NORM;
            end
          end
        end

        // ---- FP: Pass 3 — normalize and output ----
        BN_FP_NORM: begin
          if (x_valid) begin
            // y = gamma * ((x - mean) * inv_std) + beta
            y_out   <= add_result;  // final result
            y_valid <= 1'b1;
            elem_cnt <= elem_cnt + 1;
            if (elem_cnt + 1 == num_elements)
              state <= BN_DONE;
          end
        end

        // ---- BP: Pass 1 — accumulate dγ, dβ ----
        BN_BP_DPARAMS: begin
          if (dy_valid && x_valid) begin
            dbeta_acc  <= add_result;  // dβ += dY
            // dgamma += dY * x_hat (requires x_hat computation)
            elem_cnt <= elem_cnt + 1;
            if (elem_cnt + 1 == num_elements) begin
              dgamma_out    <= dgamma_acc;
              dbeta_out     <= dbeta_acc;
              dparams_valid <= 1'b1;
              elem_cnt      <= '0;
              state         <= BN_BP_DX;
            end
          end
        end

        // ---- BP: Pass 2 — compute dX ----
        BN_BP_DX: begin
          if (dy_valid) begin
            // dX = (gamma / (N * std)) * (N*dY - dβ - x_hat*dγ)
            dx_out   <= mul_result;
            dx_valid <= 1'b1;
            elem_cnt <= elem_cnt + 1;
            if (elem_cnt + 1 == num_elements)
              state <= BN_DONE;
          end
        end

        BN_DONE: begin
          state <= BN_IDLE;
        end

        default: state <= BN_IDLE;
      endcase
    end
  end

  // ================================================================
  //  Datapath muxing (simplified — real impl needs more pipeline stages)
  // ================================================================
  always_comb begin
    add_a = FP32_ZERO;
    add_b = FP32_ZERO;
    mul_a = FP32_ZERO;
    mul_b = FP32_ZERO;

    case (state)
      BN_FP_MEAN: begin
        add_a = sum_acc;
        add_b = x_in;
      end
      BN_FP_VAR: begin
        // (x - mean)^2 accumulated — simplified
        add_a = var_acc;
        add_b = mul_result;
        mul_a = x_in;  // should be (x - mean)
        mul_b = x_in;  // should be (x - mean)
      end
      BN_FP_NORM: begin
        // y = gamma * x_hat + beta
        mul_a = gamma;
        mul_b = x_in;  // should be x_hat = (x-mean)*inv_std
        add_a = mul_result;
        add_b = beta;
      end
      BN_BP_DPARAMS: begin
        add_a = dbeta_acc;
        add_b = dy_in;
      end
      BN_BP_DX: begin
        mul_a = gamma;
        mul_b = dy_in;  // simplified
      end
      default: ;
    endcase
  end

endmodule
