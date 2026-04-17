// ef_train_pkg.sv — Global parameters and types for EF-Train CNN training accelerator
//
// Based on: "EF-Train: Enable Efficient On-device CNN Training on FPGA"
//           Tang et al., arXiv 2202.10935v1, Feb 2022
//
// Configurable channel-level parallelism (Tm × Tn) with FP32 datapath.

package ef_train_pkg;

  // ================================================================
  //  Parallelism parameters (Table I in paper)
  // ================================================================
  parameter int unsigned TM         = 8;   // output channel parallelism
  parameter int unsigned TN         = 8;   // input channel parallelism
  parameter int unsigned NUM_DSP    = TM * TN;  // total PE count

  // ================================================================
  //  Data widths — full precision (FP32) per paper Section IV
  // ================================================================
  parameter int unsigned DATA_WIDTH = 32;  // FP32 feature/weight width
  parameter int unsigned ACC_WIDTH  = 32;  // FP32 accumulator

  // ================================================================
  //  Convolution geometry limits
  // ================================================================
  parameter int unsigned MAX_KERNEL = 7;   // max kernel dimension (K×K)
  parameter int unsigned MAX_CH     = 512; // max channels
  parameter int unsigned MAX_DIM    = 224; // max spatial dimension (H or W)
  parameter int unsigned MAX_BATCH  = 32;  // max mini-batch size

  // ================================================================
  //  On-chip buffer depths (in words)
  //  Double-buffered: actual BRAM = 2× these depths
  // ================================================================
  parameter int unsigned IFM_BUF_DEPTH  = 4096;  // input feature map buffer
  parameter int unsigned OFM_BUF_DEPTH  = 4096;  // output feature map buffer
  parameter int unsigned WEI_BUF_DEPTH  = 4096;  // weight buffer
  parameter int unsigned POOL_BUF_DEPTH = 1024;  // pooling index buffer
  parameter int unsigned BN_BUF_DEPTH   = 512;   // BN parameter buffer (gamma, beta, mean, var)

  // ================================================================
  //  DMA / AXI parameters
  // ================================================================
  parameter int unsigned AXI_DATA_W   = 64;   // AXI data bus width
  parameter int unsigned AXI_ADDR_W   = 64;   // AXI address width
  parameter int unsigned AXI_ID_W     = 4;
  parameter int unsigned MAX_BURST    = 256;  // max AXI burst length

  // ================================================================
  //  Operation modes — the unified conv kernel supports three modes
  // ================================================================
  typedef enum logic [1:0] {
    MODE_FP  = 2'b00,  // Forward Propagation  (connection mode 1)
    MODE_BP  = 2'b01,  // Backward Propagation (connection mode 1, flipped weights)
    MODE_WU  = 2'b10   // Weight Update        (connection mode 2)
  } op_mode_e;

  // ================================================================
  //  Layer types
  // ================================================================
  typedef enum logic [2:0] {
    LAYER_CONV    = 3'b000,
    LAYER_FC      = 3'b001,  // implemented as 1×1 conv
    LAYER_BN      = 3'b010,  // batch normalization
    LAYER_RELU    = 3'b011,
    LAYER_POOL    = 3'b100
  } layer_type_e;

  // ================================================================
  //  Activation types
  // ================================================================
  typedef enum logic [1:0] {
    ACT_NONE = 2'b00,
    ACT_RELU = 2'b01
  } act_type_e;

  // ================================================================
  //  Pooling types
  // ================================================================
  typedef enum logic [0:0] {
    POOL_MAX = 1'b0,
    POOL_AVG = 1'b1
  } pool_type_e;

  // ================================================================
  //  Layer descriptor — programmed by host before each layer
  // ================================================================
  typedef struct packed {
    layer_type_e layer_type;
    op_mode_e    op_mode;       // FP, BP, or WU
    act_type_e   activation;    // fused activation (ReLU or none)
    pool_type_e  pool_type;

    logic [15:0] in_channels;   // C_in
    logic [15:0] out_channels;  // C_out
    logic [7:0]  in_h, in_w;   // input spatial dims
    logic [7:0]  out_h, out_w; // output spatial dims
    logic [3:0]  kern_h, kern_w; // kernel size
    logic [3:0]  stride;
    logic [3:0]  pad;
    logic [7:0]  batch_size;   // mini-batch B

    // Buffer base addresses
    logic [15:0] ifm_base;
    logic [15:0] ofm_base;
    logic [15:0] wei_base;
    logic [15:0] bn_base;
    logic [15:0] pool_idx_base;
  } layer_desc_t;

  // ================================================================
  //  Adder tree depth
  // ================================================================
  parameter int unsigned ADDER_TREE_DEPTH = $clog2(TN);

  // ================================================================
  //  Helper functions
  // ================================================================
  function automatic int unsigned min2(int unsigned a, int unsigned b);
    return (a < b) ? a : b;
  endfunction

  function automatic int unsigned ceildiv(int unsigned a, int unsigned b);
    return (a + b - 1) / b;
  endfunction

endpackage
