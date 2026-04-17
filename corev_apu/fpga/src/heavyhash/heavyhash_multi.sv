// heavyhash_multi.sv — Multi-lane HeavyHash mining wrapper
//
// Instantiates NUM_LANES parallel heavyhash_pipeline instances.
// Each lane starts at nonce_start + lane_id, stepping by NUM_LANES.
// First lane to find a solution wins; it stays in P_FOUND until software stops.
//
// Matrix BRAM write is broadcast to all lanes.
// Hash count is the sum of all lane counts.

module heavyhash_multi
  import keccak_pkg::*,
         heavyhash_pkg::*;
#(
  parameter int unsigned NUM_LANES = 4
)
(
  input  logic          clk,
  input  logic          rst_n,

  // Control
  input  logic          start,
  input  logic          stop,
  output logic          busy,
  output logic          found,

  // Configuration
  input  logic [1599:0] mid_state_1,
  input  logic [1599:0] mid_state_2,
  input  logic [RATE-1:0] msg_block,
  input  logic [255:0]  target,
  input  logic [63:0]   nonce_start,

  // Results
  output logic [63:0]   nonce_found,
  output logic [63:0]   hash_count,

  // Matrix BRAM write port (broadcast to all lanes)
  input  logic          mat_wr_en,
  input  logic [5:0]    mat_wr_addr,
  input  logic [255:0]  mat_wr_data
);

  // Per-lane signals
  logic [NUM_LANES-1:0] lane_busy;
  logic [NUM_LANES-1:0] lane_found;
  logic [63:0]          lane_nonce  [NUM_LANES];
  logic [63:0]          lane_hcount [NUM_LANES];

  // Do NOT auto-stop lanes on found. The winning lane must stay in P_FOUND
  // so that found and nonce_found remain stable for the 50 MHz CDC to capture.
  // Other lanes continue mining harmlessly until software issues stop.
  logic any_found;
  assign any_found = |lane_found;

  // Busy if any lane is busy
  assign busy = |lane_busy;

  // Found if any lane found (level, stays high while winner is in P_FOUND)
  assign found = any_found;

  // Priority-encode winning lane (lowest index wins on tie)
  always_comb begin
    nonce_found = lane_nonce[0];
    for (int i = NUM_LANES-1; i >= 0; i--) begin
      if (lane_found[i])
        nonce_found = lane_nonce[i];
    end
  end

  // Sum hash counts from all lanes
  always_comb begin
    hash_count = '0;
    for (int i = 0; i < NUM_LANES; i++)
      hash_count = hash_count + lane_hcount[i];
  end

  // Instantiate lanes
  genvar g;
  generate
    for (g = 0; g < NUM_LANES; g++) begin : gen_lane
      heavyhash_pipeline #(
        .NONCE_STEP ( NUM_LANES )
      ) u_pipe (
        .clk         ( clk                            ),
        .rst_n       ( rst_n                          ),
        .start       ( start                          ),
        .stop        ( stop                            ),
        .busy        ( lane_busy[g]                   ),
        .found       ( lane_found[g]                  ),
        .mid_state_1 ( mid_state_1                    ),
        .mid_state_2 ( mid_state_2                    ),
        .msg_block   ( msg_block                      ),
        .target      ( target                         ),
        .nonce_start ( nonce_start + 64'(g)           ),
        .nonce_found ( lane_nonce[g]                  ),
        .hash_count  ( lane_hcount[g]                 ),
        .mat_wr_en   ( mat_wr_en                      ),
        .mat_wr_addr ( mat_wr_addr                    ),
        .mat_wr_data ( mat_wr_data                    )
      );
    end
  endgenerate

endmodule
