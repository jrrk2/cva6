// SPDX-License-Identifier: Apache-2.0
// CVA6 with a memory and a device that reads and writes that memory by itself, as a DMA
// Ethernet MAC does (corev_apu/fpga/src/legend-ethernet), through the device port of the data
// cache (DevicePortEn in cva6.sv):
//   A  the device writes words the cache holds and then reports that it is done; the program
//      must read the new values
//   B  the program stores to memory and then to a device register; when the device sees the
//      register written, it must read everything stored before
// The memory answers reads and write responses late and at random, so that refills are in
// flight and stores wait in the write buffer while this happens. See run.sh.
//   +behind    the device writes the memory directly, behind the cache: A must fail
//   +nostall   the memory answers at once
`include "axi/assign.svh"
`include "rvfi_types.svh"
`include "ypb_types.svh"
module tb_dcache_dev_port;
  import ariane_pkg::*;
  // the target's configuration, with everything below the memory a device (not idempotent)
  function automatic config_pkg::cva6_cfg_t build_tb_config(
      config_pkg::cva6_user_cfg_t CVA6UserCfg);
    config_pkg::cva6_user_cfg_t cfg = CVA6UserCfg;
    cfg.NrNonIdempotentRules = unsigned'(1);
    cfg.NonIdempotentAddrBase = 1024'({64'b0});
    cfg.NonIdempotentLength = 1024'({ariane_soc::DRAMBase});
    return build_config_pkg::build_config(cfg);
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_tb_config(cva6_config_pkg::cva6_cfg);
  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg);
  localparam type rvfi_probes_t = struct packed {
    logic csr;
    rvfi_probes_instr_t instr;
  };
  localparam type ypb_dev_req_t = `YPB_REQ_T(CVA6Cfg, CVA6Cfg.XLEN);
  localparam type ypb_dev_rsp_t = `YPB_RSP_T(CVA6Cfg, CVA6Cfg.XLEN);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  ariane_axi::req_t  axi_req;
  ariane_axi::resp_t axi_resp;
  ypb_dev_req_t      dev_req = '0;
  ypb_dev_rsp_t      dev_rsp;

  ariane #(
      .CVA6Cfg(CVA6Cfg),
      .rvfi_probes_instr_t(rvfi_probes_instr_t),
      .rvfi_probes_csr_t(rvfi_probes_csr_t),
      .rvfi_probes_t(rvfi_probes_t),
      .DevicePortEn(1'b1)
  ) i_ariane (
      .clk_i(clk),
      .rst_ni(rst_n),
      .boot_addr_i(64'h8000_0000),
      .hart_id_i('0),
      .irq_i('0),
      .ipi_i('0),
      .time_irq_i('0),
      .debug_req_i('0),
      .rvfi_probes_o(),
      .noc_req_o(axi_req),
      .noc_resp_i(axi_resp),
      .ypb_dev_req_i(dev_req),
      .ypb_dev_rsp_o(dev_rsp)
  );

  AXI_BUS #(
      .AXI_ADDR_WIDTH(64),
      .AXI_DATA_WIDTH(64),
      .AXI_ID_WIDTH  (ariane_axi::IdWidth),
      .AXI_USER_WIDTH(CVA6Cfg.AxiUserWidth)
  ) bus ();
  // the core's requests reach the memory late and at random, so that refills are in flight
  // for a while
  ariane_axi::req_t  mem_req;
  ariane_axi::resp_t mem_resp;
  logic stall_ar = 0, stall_r = 0, stall_b = 0;
  always @(posedge clk) begin
    stall_ar <= $urandom_range(0, 3) != 0 && !$test$plusargs("nostall");
    stall_r  <= $urandom_range(0, 3) != 0 && !$test$plusargs("nostall");
    stall_b  <= $urandom_range(0, 7) != 0 && !$test$plusargs("nostall");
  end
  always_comb begin
    mem_req           = axi_req;
    axi_resp          = mem_resp;
    mem_req.ar_valid  = axi_req.ar_valid && !stall_ar;
    axi_resp.ar_ready = mem_resp.ar_ready && !stall_ar;
    mem_req.r_ready   = axi_req.r_ready && !stall_r;
    axi_resp.r_valid  = mem_resp.r_valid && !stall_r;
    // write responses come back late as well, so stores stay in the write buffer for a while
    mem_req.b_ready   = axi_req.b_ready && !stall_b;
    axi_resp.b_valid  = mem_resp.b_valid && !stall_b;
  end
  `AXI_ASSIGN_FROM_REQ(bus, mem_req)
  `AXI_ASSIGN_TO_RESP(mem_resp, bus)

  logic req, we;
  logic [63:0] addr, wdata, rdata;
  logic [7:0] be;
  axi2mem #(
      .AXI_ID_WIDTH  (ariane_axi::IdWidth),
      .AXI_ADDR_WIDTH(64),
      .AXI_DATA_WIDTH(64),
      .AXI_USER_WIDTH(CVA6Cfg.AxiUserWidth)
  ) i_axi2mem (
      .clk_i (clk),
      .rst_ni(rst_n),
      .slave (bus),
      .req_o (req),
      .we_o  (we),
      .addr_o(addr),
      .be_o  (be),
      .user_o(),
      .data_o(wdata),
      .user_i('0),
      .data_i(rdata)
  );

  localparam int WORDS = 1 << 17;  // 1 MiB
  logic [63:0] mem[WORDS];
  logic [63:0] status = 0, xaddr = 0, kick = 0, check = 0, checked = 0;
  bit kicked = 0, check_req = 0;
  int errors = 0, n_a = 0, n_b = 0;
  wire is_ram = addr[31:28] == 4'h8;
  wire [16:0] widx = addr[19:3];

  always @(posedge clk) begin
    if (req && !we)
      rdata <= is_ram ? mem[widx] : (addr[7:0] == 8'h08 ? status : addr[7:0] == 8'h30 ? checked : 64'h0);
    if (req && we) begin
      if (is_ram) begin
        for (int i = 0; i < 8; i++) if (be[i]) mem[widx][8*i+:8] <= wdata[8*i+:8];
      end else begin
        case (addr[7:0])
          8'h00: begin
            kick   <= wdata;
            kicked <= 1;
          end
          8'h18: xaddr <= wdata;
          8'h10: begin
            check     <= wdata;
            check_req <= 1;
          end
          8'h20: begin
            $display("%s: %0d device writes, %0d ordering checks, %0d errors",
                     errors == 0 ? "PASS" : "FAIL", n_a, n_b, errors);
            $finish;
          end
          8'h28: begin
            $display("FAIL A: round %0d, the core read old data after the device was done", wdata);
            $finish;
          end
          default: ;
        endcase
      end
    end
  end

  // one access through the device port: the request until it is granted, then its response
  task automatic dev_access(input logic we_i, input logic [63:0] addr_i, input logic [63:0] data_i,
                            output logic [63:0] data_o);
    dev_req.preq <= 1'b1;
    dev_req.paddr <= addr_i[CVA6Cfg.PLEN-1:0];
    dev_req.we <= we_i;
    dev_req.be <= '1;
    dev_req.size <= 2'b11;
    dev_req.wdata <= data_i;
    dev_req.cacheable <= 1'b1;
    do @(posedge clk); while (!dev_rsp.pgnt);
    dev_req.preq <= 1'b0;
    do @(posedge clk); while (!dev_rsp.rvalid);
    data_o = dev_rsp.rdata;
    if (dev_rsp.err) begin
      $display("ERROR: the device port answered with an error at %h", addr_i);
      errors++;
    end
  endtask

  initial begin
    logic [63:0] q;
    forever begin
      @(posedge clk);
      // A: the device writes two words (they may be in one cache line or in two) and only
      // then reports that it is done
      if (kicked) begin
        kicked <= 0;
        repeat ($urandom_range(0, 60)) @(posedge clk);
        for (int w = 0; w < 2; w++) begin
          q = w == 0 ? kick ^ 64'h5a5a5a5a5a5a5a5a : ~(kick ^ 64'h5a5a5a5a5a5a5a5a);
          if ($test$plusargs("behind")) mem[xaddr[19:3]+17'(w)] <= q;
          else dev_access(1'b1, xaddr + 64'(8 * w), q, q);
          repeat ($urandom_range(0, 8)) @(posedge clk);
        end
        @(posedge clk);
        status <= kick;
        n_a++;
      end
      // B: everything the program stored before it wrote the register is what the device reads
      if (check_req) begin
        check_req <= 0;
        n_b++;
        for (int k = 0; k < 8; k++) begin
          dev_access(1'b0, 64'h8004_0000 + 64'(24 * k), '0, q);
          if (q !== 64'(16 * check + k)) begin
            if (errors < 10) $display("ERROR B: round %0d word %0d is %h", check, k, q);
            errors++;
          end
        end
        checked <= check;
      end
    end
  end

  initial begin
    $readmemh("prog.hex", mem);
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (40_000_000) @(posedge clk);
    $display("FAIL: timeout, %0d device writes, %0d ordering checks", n_a, n_b);
    $finish;
  end
endmodule
