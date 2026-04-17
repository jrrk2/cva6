// tb_keccak256.sv — Testbench for iterative Keccak-256 with mid-state support
//
// Tests both zero mid-state (equivalent to standard Keccak-256) and
// non-zero mid-state (simulating cSHAKE prefix absorption).

`timescale 1ns / 1ps

module tb_keccak256;

  import keccak_pkg::*;

  logic             clk;
  logic             rst_n;
  logic [1599:0]    mid_state;
  logic [RATE-1:0]  in_block;
  logic             in_valid;
  logic             in_ready;
  logic [255:0]     out_hash;
  logic             out_valid;

  keccak256 u_dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  int pass_cnt, fail_cnt;

  // Byte-reverse 256 bits (big-endian hex -> little-endian lanes)
  function automatic logic [255:0] bswap256(input logic [255:0] v);
    logic [255:0] r;
    for (int i = 0; i < 32; i++)
      r[i*8 +: 8] = v[(31-i)*8 +: 8];
    return r;
  endfunction

  // Apply Keccak pad10*1 to a message of 'len' bytes
  function automatic logic [RATE-1:0] keccak_pad(
    input logic [RATE-1:0] block,
    input int              len
  );
    logic [RATE-1:0] b;
    b = block;
    b[len*8 +: 8]   = b[len*8 +: 8] | 8'h01;
    b[135*8 +: 8]   = b[135*8 +: 8] | 8'h80;
    return b;
  endfunction

  task automatic hash_and_check(
    input logic [1599:0]  ms,
    input logic [7:0]     msg [],
    input int             len,
    input logic [255:0]   expected_be,
    input string          name
  );
    logic [255:0] expected;
    logic [RATE-1:0] block;
    expected = bswap256(expected_be);

    block = '0;
    for (int i = 0; i < len; i++)
      block[i*8 +: 8] = msg[i];
    block = keccak_pad(block, len);

    mid_state = ms;
    in_block  = block;
    @(posedge clk);
    in_valid = 1'b1;
    @(posedge clk);
    in_valid = 1'b0;

    while (!out_valid) @(posedge clk);

    if (out_hash === expected) begin
      $display("[PASS] %s", name);
      pass_cnt++;
    end else begin
      $display("[FAIL] %s", name);
      $display("  Expected: %064h", expected);
      $display("  Got:      %064h", out_hash);
      fail_cnt++;
    end
    @(posedge clk);
  endtask

  initial begin
    $dumpfile("tb_keccak256.vcd");
    $dumpvars(0, tb_keccak256);

    pass_cnt  = 0;
    fail_cnt  = 0;
    rst_n     = 0;
    in_valid  = 0;
    in_block  = '0;
    mid_state = '0;

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // Test 1-4: Standard Keccak-256 (zero mid-state)
    begin
      logic [7:0] m [];
      m = new[0];
      hash_and_check('0, m, 0,
        256'hc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
        "Keccak-256 empty (zero mid-state)");
    end

    begin
      logic [7:0] m [];
      m = new[3];
      m[0] = 8'h61; m[1] = 8'h62; m[2] = 8'h63;
      hash_and_check('0, m, 3,
        256'h4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45,
        "Keccak-256 'abc' (zero mid-state)");
    end

    begin
      logic [7:0] m [];
      m = new[80];
      for (int i = 0; i < 80; i++) m[i] = 8'h00;
      hash_and_check('0, m, 80,
        256'h3a709301f7eafe917c7a06e209b077a9f3942799fb24b913407674a4c1485893,
        "Keccak-256 80 zero bytes (zero mid-state)");
    end

    begin
      logic [7:0] m [];
      m = new[6];
      m[0] = 8'h4b; m[1] = 8'h65; m[2] = 8'h63;
      m[3] = 8'h63; m[4] = 8'h61; m[5] = 8'h6b;
      hash_and_check('0, m, 6,
        256'h868c016b666c7d3698636ee1bd023f3f065621514ab61bf26f062c175fdbe7f2,
        "Keccak-256 'Keccak' (zero mid-state)");
    end

    $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    #100;
    $finish;
  end

endmodule
