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

# Decompiler
DECOMPILER_DIR = /home/jonathan/System-Verilog-decompiler
DECOMPILER    = $(DECOMPILER_DIR)/_build/default/sv_main_unified.exe
JSON_OUT      = $(OBJ_DIR)/V$(SV_TOP).tree.json
HARDCAML_OUT  = $(OBJ_DIR)/heavyhash_pipeline.ml

.PHONY: all clean run json-only hardcaml

all: $(OBJ_DIR)/V$(SV_TOP)

$(OBJ_DIR)/V$(SV_TOP): $(SV_PKG) $(SV_RTL) $(CPP_TB)
	$(VERILATOR) $(VFLAGS) --top-module $(SV_TOP) \
		$(SV_PKG) $(SV_RTL) $(CPP_TB)
	$(MAKE) -C $(OBJ_DIR) -f V$(SV_TOP).mk

run: $(OBJ_DIR)/V$(SV_TOP)
	./$(OBJ_DIR)/V$(SV_TOP)

json-only: $(JSON_OUT)

$(JSON_OUT): $(SV_PKG) $(SV_RTL)
	$(VERILATOR) -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
		-Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
		--json-only --dump-tree-json \
		--json-only-output $(JSON_OUT) \
		--top-module $(SV_TOP) $(SV_PKG) $(SV_RTL)

$(DECOMPILER):
	cd $(DECOMPILER_DIR) && eval $$(opam env --switch=5.3.0 --set-switch) && dune build sv_main_unified.exe

hardcaml: $(HARDCAML_OUT)

$(HARDCAML_OUT): $(JSON_OUT) $(DECOMPILER)
	$(DECOMPILER) file hardcaml $(JSON_OUT) $(HARDCAML_OUT)

clean:
	rm -rf $(OBJ_DIR) tb_pipeline.vcd
