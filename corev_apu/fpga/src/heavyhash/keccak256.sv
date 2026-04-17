// keccak256.sv — Iterative Keccak-f[1600] with mid-state support
//
// For cSHAKE256 mining: software pre-computes the state after absorbing
// the fixed cSHAKE bytepad prefix. Hardware loads this mid-state, XORs
// in the message block, and runs 24 rounds.
//
// Latency: 26 cycles (1 absorb + 24 permute + 1 squeeze)

module keccak256
  import keccak_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,

  // Pre-computed mid-state (1600 bits, from cSHAKE prefix absorption)
  input  logic [1599:0]    mid_state,

  // Input: pre-padded 1088-bit rate block (LSB-first)
  input  logic [RATE-1:0]  in_block,
  input  logic             in_valid,
  output logic             in_ready,

  // Output: 256-bit hash (first 4 lanes)
  output logic [255:0]     out_hash,
  output logic             out_valid
);

  logic [1599:0] state_reg;
  logic [1599:0] round_out;
  logic [4:0]    round_cnt;

  keccak_round u_round (
    .state_in  ( state_reg ),
    .round_idx ( round_cnt ),
    .state_out ( round_out )
  );

  typedef enum logic [1:0] {
    S_IDLE    = 2'b00,
    S_PERMUTE = 2'b01,
    S_DONE    = 2'b10
  } state_e;

  state_e fsm;

  assign in_ready = (fsm == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fsm       <= S_IDLE;
      round_cnt <= '0;
      out_valid <= 1'b0;
      out_hash  <= '0;
      state_reg <= '0;
    end else begin
      out_valid <= 1'b0;

      case (fsm)
        S_IDLE: begin
          if (in_valid) begin
            // Absorb: XOR rate block into mid-state
            state_reg[RATE-1:0]  <= mid_state[RATE-1:0] ^ in_block;
            state_reg[1599:RATE] <= mid_state[1599:RATE];
            round_cnt            <= 5'd0;
            fsm                  <= S_PERMUTE;
          end
        end

        S_PERMUTE: begin
          state_reg <= round_out;
          if (round_cnt == 5'd23)
            fsm <= S_DONE;
          else
            round_cnt <= round_cnt + 5'd1;
        end

        S_DONE: begin
          out_hash  <= state_reg[255:0];
          out_valid <= 1'b1;
          fsm       <= S_IDLE;
        end

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
