// keccak_pkg.sv — Constants and helpers for Keccak-f[1600]
//
// Keccak-256 (legacy, as used by Kaspa HeavyHash):
//   Rate r = 1088, Capacity c = 512, Output = 256 bits
//   Padding: pad10*1 (0x01 ... 0x80), NOT SHA-3's 0x06

package keccak_pkg;

  // State is 5 x 5 x 64 = 1600 bits
  localparam int unsigned LANE_W   = 64;
  localparam int unsigned STATE_W  = 1600;
  localparam int unsigned RATE     = 1088;  // bits
  localparam int unsigned CAPACITY = 512;
  localparam int unsigned OUTPUT_W = 256;
  localparam int unsigned ROUNDS   = 24;

  // Round constants (iota step) — as function for simulator compatibility
  function automatic logic [63:0] get_rc(input logic [4:0] rnd);
    case (rnd)
       0: return 64'h0000000000000001;
       1: return 64'h0000000000008082;
       2: return 64'h800000000000808A;
       3: return 64'h8000000080008000;
       4: return 64'h000000000000808B;
       5: return 64'h0000000080000001;
       6: return 64'h8000000080008081;
       7: return 64'h8000000000008009;
       8: return 64'h000000000000008A;
       9: return 64'h0000000000000088;
      10: return 64'h0000000080008009;
      11: return 64'h000000008000000A;
      12: return 64'h000000008000808B;
      13: return 64'h800000000000008B;
      14: return 64'h8000000000008089;
      15: return 64'h8000000000008003;
      16: return 64'h8000000000008002;
      17: return 64'h8000000000000080;
      18: return 64'h000000000000800A;
      19: return 64'h800000008000000A;
      20: return 64'h8000000080008081;
      21: return 64'h8000000000008080;
      22: return 64'h0000000080000001;
      23: return 64'h8000000080008008;
      default: return 64'h0;
    endcase
  endfunction

  // Rotation offsets for rho step — as function for compatibility
  // Indexed as get_rot(x,y)
  function automatic int unsigned get_rot(
    input int unsigned x,
    input int unsigned y
  );
    case ({x[2:0], y[2:0]})
      // x=0
      {3'd0, 3'd0}: return  0;
      {3'd0, 3'd1}: return 36;
      {3'd0, 3'd2}: return  3;
      {3'd0, 3'd3}: return 41;
      {3'd0, 3'd4}: return 18;
      // x=1
      {3'd1, 3'd0}: return  1;
      {3'd1, 3'd1}: return 44;
      {3'd1, 3'd2}: return 10;
      {3'd1, 3'd3}: return 45;
      {3'd1, 3'd4}: return  2;
      // x=2
      {3'd2, 3'd0}: return 62;
      {3'd2, 3'd1}: return  6;
      {3'd2, 3'd2}: return 43;
      {3'd2, 3'd3}: return 15;
      {3'd2, 3'd4}: return 61;
      // x=3
      {3'd3, 3'd0}: return 28;
      {3'd3, 3'd1}: return 55;
      {3'd3, 3'd2}: return 25;
      {3'd3, 3'd3}: return 21;
      {3'd3, 3'd4}: return 56;
      // x=4
      {3'd4, 3'd0}: return 27;
      {3'd4, 3'd1}: return 20;
      {3'd4, 3'd2}: return 39;
      {3'd4, 3'd3}: return  8;
      {3'd4, 3'd4}: return 14;
      default:       return  0;
    endcase
  endfunction

  // Helper: index into flat 1600-bit state -> lane[x][y]
  // Convention: lane(x,y) occupies bits [(x*5+y)*64 +: 64]
  function automatic logic [63:0] get_lane(
    input logic [STATE_W-1:0] state,
    input int unsigned x,
    input int unsigned y
  );
    return state[(x*5+y)*LANE_W +: LANE_W];
  endfunction

  function automatic logic [STATE_W-1:0] set_lane(
    input logic [STATE_W-1:0] state,
    input int unsigned x,
    input int unsigned y,
    input logic [63:0] val
  );
    logic [STATE_W-1:0] s;
    s = state;
    s[(x*5+y)*LANE_W +: LANE_W] = val;
    return s;
  endfunction

  // Rotate left a 64-bit lane
  function automatic logic [63:0] rotl64(
    input logic [63:0] val,
    input int unsigned n
  );
    if (n == 0) return val;
    else        return (val << n) | (val >> (64 - n));
  endfunction

endpackage
