// tb_heavyhash.sv — Full HeavyHash pipeline testbench
//
// Tests the complete pipeline: Keccak -> matrix multiply -> Keccak -> compare
// Uses a known test case with identity-like matrix and easy target.

`timescale 1ns / 1ps

module tb_heavyhash;

  import keccak_pkg::*;
  import heavyhash_pkg::*;

  logic          clk, rst_n;
  logic          start, stop;
  logic          busy, found;
  logic [1599:0] mid_state_1, mid_state_2;
  logic [RATE-1:0] msg_block;
  logic [255:0]  target;
  logic [63:0]   nonce_start;
  logic [63:0]   nonce_found;
  logic [63:0]   hash_count;

  // Matrix write port
  logic          mat_wr_en;
  logic [5:0]    mat_wr_addr;
  logic [255:0]  mat_wr_data;

  heavyhash_pipeline u_dut (
    .clk         ( clk         ),
    .rst_n       ( rst_n       ),
    .start       ( start       ),
    .stop        ( stop        ),
    .busy        ( busy        ),
    .found       ( found       ),
    .mid_state_1 ( mid_state_1 ),
    .mid_state_2 ( mid_state_2 ),
    .msg_block   ( msg_block   ),
    .target      ( target      ),
    .nonce_start ( nonce_start ),
    .nonce_found ( nonce_found ),
    .hash_count  ( hash_count  ),
    .mat_wr_en   ( mat_wr_en   ),
    .mat_wr_addr ( mat_wr_addr ),
    .mat_wr_data ( mat_wr_data )
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // ----------------------------------------------------------------
  //  Apply cSHAKE-style padding to a message block
  //  For testing, we use plain Keccak padding (0x01...0x80)
  //  with zero mid-states (equivalent to standard Keccak-256)
  // ----------------------------------------------------------------
  function automatic logic [RATE-1:0] pad_msg(
    input logic [639:0] header,  // 80 bytes
    input int           len
  );
    logic [RATE-1:0] block;
    block = '0;
    block[639:0] = header;
    // Keccak pad10*1: byte[len] |= 0x01, byte[135] |= 0x80
    block[len*8 +: 8]   = block[len*8 +: 8] | 8'h01;
    block[135*8 +: 8]   = block[135*8 +: 8] | 8'h80;
    return block;
  endfunction

  // ----------------------------------------------------------------
  //  Load identity-like matrix: matrix[i][j] = (i==j) ? 1 : 0
  //  This makes the matrix multiply output = input nibbles >> 10
  //  which are all zero for small inputs (no shift overflow).
  //  Result = XOR of hash with zero = hash (no-op matrix)
  // ----------------------------------------------------------------
  task automatic load_identity_matrix();
    for (int i = 0; i < 64; i++) begin
      mat_wr_data = '0;
      mat_wr_data[i*4 +: 4] = 4'd1;  // diagonal = 1
      mat_wr_addr = i[5:0];
      mat_wr_en   = 1'b1;
      @(posedge clk);
    end
    mat_wr_en = 1'b0;
    @(posedge clk);
  endtask

  // ----------------------------------------------------------------
  //  Load a simple non-trivial matrix for testing
  //  matrix[i][j] = ((i + j) % 16)  — gives known products
  // ----------------------------------------------------------------
  task automatic load_test_matrix();
    for (int i = 0; i < 64; i++) begin
      mat_wr_data = '0;
      for (int j = 0; j < 64; j++) begin
        mat_wr_data[j*4 +: 4] = ((i + j) % 16);
      end
      mat_wr_addr = i[5:0];
      mat_wr_en   = 1'b1;
      @(posedge clk);
    end
    mat_wr_en = 1'b0;
    @(posedge clk);
  endtask

  // ----------------------------------------------------------------
  //  Test
  // ----------------------------------------------------------------
  initial begin
    $dumpfile("tb_heavyhash.vcd");
    $dumpvars(0, tb_heavyhash);

    rst_n       = 0;
    start       = 0;
    stop        = 0;
    mid_state_1 = '0;  // zero mid-state = standard Keccak-256
    mid_state_2 = '0;
    msg_block   = '0;
    target      = '0;
    nonce_start = '0;
    mat_wr_en   = 0;
    mat_wr_addr = '0;
    mat_wr_data = '0;

    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // Load test matrix
    $display("Loading test matrix...");
    load_test_matrix();
    $display("Matrix loaded.");

    // ---- Test 1: Run one hash with very easy target (all F's) ----
    $display("\n=== Test 1: Single hash with easy target ===");

    // Build a simple 80-byte header (all zeros, nonce will be patched)
    msg_block   = pad_msg(640'h0, 80);
    target      = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    nonce_start = 64'd0;

    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Wait for found or timeout
    fork
      begin
        wait (found);
        $display("[PASS] Found nonce: %0d after %0d hashes", nonce_found, hash_count);
      end
      begin
        repeat (500) @(posedge clk);
        $display("[TIMEOUT] Pipeline did not find result in 500 cycles");
      end
    join_any
    disable fork;

    // Stop the pipeline
    @(posedge clk);
    stop = 1'b1;
    @(posedge clk);
    stop = 1'b0;
    repeat (5) @(posedge clk);

    // ---- Test 2: Run several nonces with impossible target ----
    $display("\n=== Test 2: Multiple hashes with impossible target ===");

    target      = 256'h0;  // impossible: hash must be exactly zero
    nonce_start = 64'd100;

    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Let it run for a while
    repeat (1000) @(posedge clk);

    $display("Hashes completed: %0d (should be > 0)", hash_count);
    if (hash_count > 0 && !found)
      $display("[PASS] Pipeline running, no false positive");
    else if (found)
      $display("[FAIL] False positive with impossible target");
    else
      $display("[FAIL] No hashes computed");

    stop = 1'b1;
    @(posedge clk);
    stop = 1'b0;
    repeat (5) @(posedge clk);

    // ---- Test 3: Run and check hash count increments ----
    $display("\n=== Test 3: Hash rate check ===");

    target      = 256'h0;
    nonce_start = 64'd0;

    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    repeat (2000) @(posedge clk);

    $display("Hashes in 2000 cycles: %0d", hash_count);
    $display("Cycles per hash: ~%0d", hash_count > 0 ? 2000 / hash_count : 0);

    stop = 1'b1;
    @(posedge clk);
    stop = 1'b0;

    repeat (10) @(posedge clk);
    $display("\nAll tests complete.");
    $finish;
  end

  // Watchdog
  initial begin
    #100000;
    $display("[WATCHDOG] Simulation timeout");
    $finish;
  end

endmodule
