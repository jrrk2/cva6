// axi_read_arbiter.sv — 2:1 AXI read channel arbiter
//
// Merges two AXI read ports (AR/R only) into one downstream port.
// Port 0 (CPU) has priority.  At most one outstanding read to downstream.
// Write channels (AW/W/B) are handled externally — not touched here.

module axi_read_arbiter #(
  parameter int unsigned ADDR_WIDTH = 64,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned ID_WIDTH   = 5
) (
  input  logic clk,
  input  logic rst_n,

  // ---- Port 0 (CPU, priority) — AR/R only ----
  input  logic [ID_WIDTH-1:0]   p0_arid,
  input  logic [ADDR_WIDTH-1:0] p0_araddr,
  input  logic [7:0]            p0_arlen,
  input  logic [2:0]            p0_arsize,
  input  logic [1:0]            p0_arburst,
  input  logic [0:0]            p0_arlock,
  input  logic [3:0]            p0_arcache,
  input  logic [2:0]            p0_arprot,
  input  logic [3:0]            p0_arqos,
  input  logic                  p0_arvalid,
  output logic                  p0_arready,
  output logic [ID_WIDTH-1:0]   p0_rid,
  output logic [DATA_WIDTH-1:0] p0_rdata,
  output logic [1:0]            p0_rresp,
  output logic                  p0_rlast,
  output logic                  p0_rvalid,
  input  logic                  p0_rready,

  // ---- Port 1 (IE DMA) — AR/R only ----
  input  logic [ID_WIDTH-1:0]   p1_arid,
  input  logic [ADDR_WIDTH-1:0] p1_araddr,
  input  logic [7:0]            p1_arlen,
  input  logic [2:0]            p1_arsize,
  input  logic [1:0]            p1_arburst,
  input  logic [0:0]            p1_arlock,
  input  logic [3:0]            p1_arcache,
  input  logic [2:0]            p1_arprot,
  input  logic [3:0]            p1_arqos,
  input  logic                  p1_arvalid,
  output logic                  p1_arready,
  output logic [ID_WIDTH-1:0]   p1_rid,
  output logic [DATA_WIDTH-1:0] p1_rdata,
  output logic [1:0]            p1_rresp,
  output logic                  p1_rlast,
  output logic                  p1_rvalid,
  input  logic                  p1_rready,

  // ---- Merged downstream — AR/R only ----
  output logic [ID_WIDTH-1:0]   m_arid,
  output logic [ADDR_WIDTH-1:0] m_araddr,
  output logic [7:0]            m_arlen,
  output logic [2:0]            m_arsize,
  output logic [1:0]            m_arburst,
  output logic [0:0]            m_arlock,
  output logic [3:0]            m_arcache,
  output logic [2:0]            m_arprot,
  output logic [3:0]            m_arqos,
  output logic                  m_arvalid,
  input  logic                  m_arready,
  input  logic [ID_WIDTH-1:0]   m_rid,
  input  logic [DATA_WIDTH-1:0] m_rdata,
  input  logic [1:0]            m_rresp,
  input  logic                  m_rlast,
  input  logic                  m_rvalid,
  output logic                  m_rready
);

  typedef enum logic [1:0] {
    ARB_IDLE,
    ARB_P0_ACTIVE,
    ARB_P1_ACTIVE
  } arb_state_e;

  arb_state_e state;

  wire ar_fire = m_arvalid & m_arready;
  wire r_last  = m_rvalid  & m_rready & m_rlast;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= ARB_IDLE;
    end else begin
      case (state)
        ARB_IDLE: begin
          if (ar_fire) begin
            // We granted AR this cycle; which port won?
            state <= p0_arvalid ? ARB_P0_ACTIVE : ARB_P1_ACTIVE;
          end
        end
        ARB_P0_ACTIVE: if (r_last) state <= ARB_IDLE;
        ARB_P1_ACTIVE: if (r_last) state <= ARB_IDLE;
        default: state <= ARB_IDLE;
      endcase
    end
  end

  // ---- AR mux (only in IDLE, p0 has priority) ----
  always_comb begin
    // Defaults: block both ports
    m_arvalid  = 1'b0;
    m_arid     = '0;
    m_araddr   = '0;
    m_arlen    = '0;
    m_arsize   = '0;
    m_arburst  = '0;
    m_arlock   = '0;
    m_arcache  = '0;
    m_arprot   = '0;
    m_arqos    = '0;
    p0_arready = 1'b0;
    p1_arready = 1'b0;

    if (state == ARB_IDLE) begin
      if (p0_arvalid) begin
        // Forward p0
        m_arid     = p0_arid;
        m_araddr   = p0_araddr;
        m_arlen    = p0_arlen;
        m_arsize   = p0_arsize;
        m_arburst  = p0_arburst;
        m_arlock   = p0_arlock;
        m_arcache  = p0_arcache;
        m_arprot   = p0_arprot;
        m_arqos    = p0_arqos;
        m_arvalid  = 1'b1;
        p0_arready = m_arready;
      end else if (p1_arvalid) begin
        // Forward p1
        m_arid     = p1_arid;
        m_araddr   = p1_araddr;
        m_arlen    = p1_arlen;
        m_arsize   = p1_arsize;
        m_arburst  = p1_arburst;
        m_arlock   = p1_arlock;
        m_arcache  = p1_arcache;
        m_arprot   = p1_arprot;
        m_arqos    = p1_arqos;
        m_arvalid  = 1'b1;
        p1_arready = m_arready;
      end
    end
  end

  // ---- R demux (route to active port) ----
  always_comb begin
    // Defaults
    p0_rid    = m_rid;
    p0_rdata  = m_rdata;
    p0_rresp  = m_rresp;
    p0_rlast  = m_rlast;
    p0_rvalid = 1'b0;

    p1_rid    = m_rid;
    p1_rdata  = m_rdata;
    p1_rresp  = m_rresp;
    p1_rlast  = m_rlast;
    p1_rvalid = 1'b0;

    m_rready  = 1'b0;

    case (state)
      ARB_P0_ACTIVE: begin
        p0_rvalid = m_rvalid;
        m_rready  = p0_rready;
      end
      ARB_P1_ACTIVE: begin
        p1_rvalid = m_rvalid;
        m_rready  = p1_rready;
      end
      default: ;
    endcase
  end

endmodule
