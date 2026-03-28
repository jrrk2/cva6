// inference_pkg.sv — Shared parameters and types for the inference engine
// Target: Xilinx VC707 (xc7vx485tffg1761-2)
//
// Resource budget (xc7vx485t):
//   - 2,800 DSP48E1 slices
//   - 2,060 BRAM36K (37,080 Kb)
//   - 303,600 LUTs
//
// Design point: 16x16 systolic array, INT8 data, INT32 accumulators
//   - DSP usage:  256 DSP48E1 (9.1% of 2,800)
//   - Leaves headroom for multi-array or larger networks

package inference_pkg;

  // ---- Systolic array dimensions ----
  localparam int unsigned ARRAY_ROWS = 16;  // output neurons computed in parallel
  localparam int unsigned ARRAY_COLS = 16;  // input features consumed in parallel

  // ---- Data widths ----
  localparam int unsigned DATA_WIDTH = 8;   // INT8 weights & activations
  localparam int unsigned ACC_WIDTH  = 32;  // accumulator width (avoids overflow)
  localparam int unsigned BIAS_WIDTH = 32;  // bias stored in full precision

  // ---- Network geometry limits ----
  localparam int unsigned MAX_INPUT_DIM   = 1024;  // max neurons in one layer
  localparam int unsigned MAX_OUTPUT_DIM  = 1024;
  localparam int unsigned MAX_LAYERS      = 32;

  // ---- Activation function select ----
  typedef enum logic [1:0] {
    ACT_NONE    = 2'b00,
    ACT_RELU    = 2'b01,
    ACT_SIGMOID = 2'b10,
    ACT_RELU6   = 2'b11
  } act_fn_e;

  // ---- Layer descriptor (loaded via AXI-Lite) ----
  typedef struct packed {
    logic [15:0] input_dim;     // # input features (K)
    logic [15:0] output_dim;    // # output neurons (M)
    act_fn_e     activation;    // activation function
    logic [13:0] weight_addr;   // start address in weight BRAM (word-aligned)
    logic [13:0] bias_addr;     // start address in bias BRAM
    logic [13:0] reserved;
  } layer_desc_t;

  // ---- AXI-Lite register map ----
  // 0x00: CTRL       [0] start, [1] done (RO), [2] busy (RO), [3] clear_irq
  // 0x04: STATUS     [7:0] current_layer, [15:8] total_layers
  // 0x08: NUM_LAYERS number of layers (1..MAX_LAYERS)
  // 0x0C: INPUT_ADDR start address of input activations in activation BRAM
  // 0x10: OUTPUT_ADDR start address of output activations in activation BRAM
  // 0x40-0xBF: LAYER_DESC[0..MAX_LAYERS-1] (packed layer_desc_t, 3 words each)

endpackage
