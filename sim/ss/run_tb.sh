#!/usr/bin/env bash
# Pause and savestate unit benches: Icarus Verilog, GHDL and Verilator.
#
#   sim/ss/run_tb.sh            all benches
#   sim/ss/run_tb.sh ssui       only the ones whose name contains "ssui"
#
# Work files in sim/build/ss. tb_savestates also dumps its first slot and
# checks it with sim/scripts/ss_slot.py (CRC recomputed with zlib).
set -euo pipefail

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$SIM/.." && pwd)"
RTL="$ROOT/rtl/savestate"
OUT="$SIM/build/ss"
mkdir -p "$OUT"
cd "$OUT"

filter="${1:-}"
fail=0
run() { # name files...
	local name=$1; shift
	case "$name" in *"$filter"*) ;; *) return 0 ;; esac
	echo "[$name]"
	iverilog -g2012 -I "$RTL" -o "$OUT/$name" "$@"
	if vvp -n "$OUT/$name" | tee "$OUT/$name.log" | grep -q ": PASS"; then :; else fail=1; fi
	grep -E "FAIL|PASS" "$OUT/$name.log" || true
}

run tb_savestates "$SIM/ss/tb_chain_defs.vh" "$SIM/ss/tb_savestates.sv" \
	"$RTL/savestates.sv" "$RTL/ss_freeze.sv" "$RTL/ss_ddram_arb.sv" "$RTL/ss_chain.sv"
case "tb_savestates" in *"$filter"*)
	python3 "$SIM/scripts/ss_slot.py" --chain-bits 75 "$OUT/tb_slot.bin" || fail=1 ;;
esac
# same with segment C not instrumented (not live): its word is 0, A alone is the chain
run tb_savestates_dead -Ptb_savestates.LIVE_T=1 "$SIM/ss/tb_chain_defs.vh" "$SIM/ss/tb_savestates.sv" \
	"$RTL/savestates.sv" "$RTL/ss_freeze.sv" "$RTL/ss_ddram_arb.sv" "$RTL/ss_chain.sv"
run tb_statemanager "$SIM/ss/tb_statemanager.sv" "$RTL/statemanager.sv"
run tb_ssui "$SIM/ss/tb_ssui.sv" "$RTL/savestate_ui.sv"

# savestate SDRAM transport on rtl/sdram.v and the checked chip model
# (Verilator: Icarus takes neither the chip model nor sdram.v's inout reg)
case "tb_ss_transport" in *"$filter"*)
	echo "[tb_ss_transport]"
	python3 "$SIM/scripts/sdram_dq.py" "$ROOT/rtl/sdram.v" "$OUT/sdram_dq.v"
	if verilator --binary --timing --top-module tb_ss_transport --Mdir "$OUT/transport" -j "${JOBS:-4}" \
		-Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD "$SIM/rtl/sim_mt48lc16m16.sv" "$SIM/rtl/sim_altddio_out.sv" \
		"$OUT/sdram_dq.v" "$RTL/ss_sdram_port.sv" "$SIM/ss/tb_ss_transport.sv" > "$OUT/tb_ss_transport.build.log" 2>&1; then
		"$OUT/transport/Vtb_ss_transport" > "$OUT/tb_ss_transport.log" 2>&1 || true
		grep -q ": PASS" "$OUT/tb_ss_transport.log" || fail=1
		grep -E "FAIL|PASS|transfers|refresh gap|^SDRAM" "$OUT/tb_ss_transport.log" || true
	else
		tail -n 30 "$OUT/tb_ss_transport.build.log"
		fail=1
	fi ;;
esac

# the VHDL chain helper must analyse (GHDL, VHDL-93 and -08)
case "ss_chain_pkg" in *"$filter"*)
	echo "[ss_chain_pkg]"
	ghdl -a --std=93c --workdir="$OUT" "$RTL/ss_chain_pkg.vhd" && echo "ss_chain_pkg: VHDL-93 OK" || fail=1
	mkdir -p "$OUT/w08"
	ghdl -a --std=08 --workdir="$OUT/w08" "$RTL/ss_chain_pkg.vhd" && echo "ss_chain_pkg: VHDL-08 OK" || fail=1 ;;
esac

case "tb_video_sync" in *"$filter"*)
	echo "[tb_video_sync]"
	mkdir -p "$OUT/w08"
	ghdl -a --std=08 -fsynopsys --workdir="$OUT/w08" "$ROOT/rtl/video_sync.vhd" "$SIM/ss/tb_video_sync.vhd" &&
		ghdl -e --std=08 -fsynopsys --workdir="$OUT/w08" tb_video_sync &&
		ghdl -r --std=08 -fsynopsys --workdir="$OUT/w08" tb_video_sync --assert-level=error > "$OUT/tb_video_sync.log" 2>&1 || fail=1
	grep -E "FAIL|PASS" "$OUT/tb_video_sync.log" || true ;;
esac

# local change of sys/ascal.vhd: the registered end-of-frame compare
case "tb_ascal_vcpt" in *"$filter"*)
	echo "[tb_ascal_vcpt]"
	mkdir -p "$OUT/w08"
	ghdl -a --std=08 --workdir="$OUT/w08" "$SIM/ss/tb_ascal_vcpt.vhd" &&
		ghdl -e --std=08 --workdir="$OUT/w08" tb_ascal_vcpt &&
		ghdl -r --std=08 --workdir="$OUT/w08" tb_ascal_vcpt --assert-level=error > "$OUT/tb_ascal_vcpt.log" 2>&1 || fail=1
	grep -E "PASS|failure|tb_ascal_vcpt:" "$OUT/tb_ascal_vcpt.log" || true ;;
esac

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
