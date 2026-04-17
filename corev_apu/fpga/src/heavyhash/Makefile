# Makefile for Verilator-based HeavyHash pipeline testbench

VERILATOR = verilator
VFLAGS    = --cc --exe --trace --public-flat-rw \
            -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
            -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT

# Source files
SV_PKG  = keccak_pkg.sv heavyhash_pkg.sv
SV_RTL  = keccak_round.sv keccak256.sv heavyhash_matrix.sv heavyhash_pipeline.sv
SV_TOP  = heavyhash_pipeline
CPP_TB  = tb_pipeline.cpp

# Build directory
OBJ_DIR = obj_dir

.PHONY: all clean run

all: $(OBJ_DIR)/V$(SV_TOP)

$(OBJ_DIR)/V$(SV_TOP): $(SV_PKG) $(SV_RTL) $(CPP_TB)
	$(VERILATOR) $(VFLAGS) --top-module $(SV_TOP) \
		$(SV_PKG) $(SV_RTL) $(CPP_TB)
	$(MAKE) -C $(OBJ_DIR) -f V$(SV_TOP).mk

run: $(OBJ_DIR)/V$(SV_TOP)
	./$(OBJ_DIR)/V$(SV_TOP)

clean:
	rm -rf $(OBJ_DIR) tb_pipeline.vcd
