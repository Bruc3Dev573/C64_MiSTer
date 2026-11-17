#!/usr/bin/env bash
# Build the whole C64 core (emu in c64.sv) as a Verilator model.
#
#   sim/build.sh            -> sim/build/obj/Vemu   (run directory: sim/build/run)
#
# Steps (all on copies under sim/build, rtl/ is never modified):
#   1. VHDL -> Verilog with ghdl-yosys-plugin (fixups in scripts/vhdl_fixups.py,
#      dprom black-boxed and replaced by sim/rtl/sim_dprom.v);
#   2. Verilog/SV copies patched by scripts/verilog_fixups.py;
#   3. .mif ROM images converted to <path>.hex in the run directory;
#   4. sim/build/filelist.f written (reused by other flows, e.g. B7 lint);
#   5. verilator --build.
#
# Environment: JOBS (default nproc), VERILATOR_THREADS (default 1),
#              PROFILE=1 (gprof build in sim/build/obj-prof),
#              DRIVES=0 (no 1541/1581, stub iec_drive, sim/build/obj-nodrv),
#              SDRAM=real (real controller + checked MT48LC16M16, obj*-sdram-real),
#              OPT (C++ optimization of the model, default -O3), SKIP_VHDL=1 to reuse step 1,
#              BUILD_DIR (default sim/build),
#              RTL_OVERLAY=dir: files in dir replace the sources of the same
#              name before the fixups (A/B experiments, negative controls).
set -euo pipefail

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SIM/.." && pwd)"
B="$(mkdir -p "${BUILD_DIR:-$SIM/build}" && cd "${BUILD_DIR:-$SIM/build}" && pwd)"
JOBS="${JOBS:-$(nproc)}"
OPT="${OPT:--O3}"
THREADS="${VERILATOR_THREADS:-1}"
SDRAM="${SDRAM:-fast}"
case "$SDRAM" in fast|real) ;; *) echo "SDRAM must be fast or real" >&2; exit 2 ;; esac

mkdir -p "$B/vhdl" "$B/v" "$B/gen" "$B/run" "$B/obj"

# ---------------------------------------------------------------- 1. VHDL
VHDL_SRC=(
	rtl/spram.vhd
	rtl/t65/T65_Pack.vhd rtl/t65/T65_ALU.vhd rtl/t65/T65_MCode.vhd rtl/t65/T65.vhd
	rtl/cpu_6510.vhd
	rtl/video_vicII_656x.vhd rtl/fpga64_rgbcolor.vhd rtl/fpga64_keyboard.vhd
	rtl/fpga64_buslogic.vhd rtl/fpga64_sid_iec.vhd
	rtl/video_sync.vhd
	rtl/iec_drive/iecdrv_via6522.vhd
)
if [ "${SKIP_VHDL:-0}" != 1 ] || [ ! -f "$B/gen/fpga64_sid_iec.v" ]; then
	rm -f "$B"/vhdl/*.vhd
	for f in "${VHDL_SRC[@]}"; do cp "$ROOT/$f" "$B/vhdl/"; done
	cp "$SIM/rtl/bb_dprom.vhd" "$B/vhdl/"
	if [ -n "${RTL_OVERLAY:-}" ]; then for f in "$RTL_OVERLAY"/*.vhd; do [ -f "$f" ] && cp "$f" "$B/vhdl/" && echo "[overlay] $f"; done; fi
	python3 "$SIM/scripts/vhdl_fixups.py" "$B"/vhdl/*.vhd
	V="$B/vhdl"
	CORE="$V/bb_dprom.vhd $V/spram.vhd $V/T65_Pack.vhd $V/T65_ALU.vhd $V/T65_MCode.vhd $V/T65.vhd $V/cpu_6510.vhd $V/video_vicII_656x.vhd $V/fpga64_rgbcolor.vhd $V/fpga64_keyboard.vhd $V/fpga64_buslogic.vhd $V/fpga64_sid_iec.vhd"
	# opt_clean keeps the VHDL signal names on the flip-flops (needed by B7)
	conv() { # top files... -> gen/top.v
		local top=$1; shift
		echo "[vhdl] $top"
		yosys -q -m ghdl -l "$B/gen/$top.log" -p "ghdl --std=08 -fsynopsys -frelaxed $* -e $top; opt_clean; write_verilog -noattr $B/gen/$top.v" >/dev/null
	}
	conv fpga64_sid_iec $CORE
	conv video_sync "$V/video_sync.vhd"
	conv iecdrv_via6522 "$V/iecdrv_via6522.vhd"
fi

# ---------------------------------------------------------------- 2. Verilog
V_SRC=(
	c64.sv
	rtl/mos6526.v rtl/rtcF83.sv rtl/cartridge.v rtl/reu.v rtl/am29f040.sv
	rtl/c1530.sv rtl/c1351.v rtl/drv_overlay.sv rtl/pause_fb.sv
	rtl/tap_scanner.sv rtl/tap_time_map.sv rtl/tape_counter.sv rtl/tape_subsystem.sv
	rtl/sid/sid_top.sv rtl/sid/sid_voice.sv rtl/sid/sid_tables.sv rtl/sid/sid_filter.sv
	rtl/sid/sid_envelope.sv rtl/sid/sid_dac.sv
	rtl/opl3/opl3.sv rtl/opl3/opl3fm.sv rtl/opl3/opl3seq.sv rtl/opl3/compressor.sv
	rtl/opl3/NextZ80Reg.v rtl/opl3/NextZ80CPU.v rtl/opl3/NextZ80ALU.v
	rtl/iec_drive/iec_drive.sv
	rtl/iec_drive/c1541_multi.sv rtl/iec_drive/c1541_drv.sv rtl/iec_drive/c1541_gcr.sv
	rtl/iec_drive/c1541_direct_gcr.sv rtl/iec_drive/c1541_track.sv rtl/iec_drive/c1541_logic.sv
	rtl/iec_drive/c1581_multi.sv rtl/iec_drive/c1581_drv.sv rtl/iec_drive/fdc1772.v rtl/iec_drive/floppy.v
	rtl/iec_drive/iecdrv_mos8520.v rtl/iec_drive/iecdrv_misc.sv rtl/iec_drive/lfsr.v
	rtl/savestate/savestates.sv rtl/savestate/statemanager.sv rtl/savestate/savestate_ui.sv
	rtl/savestate/ss_freeze.sv rtl/savestate/ss_sdram_port.sv rtl/savestate/ss_ddram_arb.sv
	rtl/savestate/ss_chain.sv
	sys/video_freezer.sv
)
[ "$SDRAM" != real ] || V_SRC+=(rtl/sdram.v)
rm -rf "$B/v"; mkdir -p "$B/v/sys"
for f in "${V_SRC[@]}"; do cp "$ROOT/$f" "$B/v/"; done
cp "$ROOT/sys/emu_ports.vh" "$B/v/sys/"
mkdir -p "$B/v/rtl/savestate"
cp "$ROOT/rtl/savestate/c64_savestates.vh" "$B/v/" && cp "$ROOT/rtl/savestate/c64_savestates.vh" "$B/v/rtl/savestate/"
if [ -n "${RTL_OVERLAY:-}" ]; then for f in "$RTL_OVERLAY"/*.v "$RTL_OVERLAY"/*.sv; do [ -f "$f" ] && cp "$f" "$B/v/" && echo "[overlay] $f"; done; fi
# BUILD_DATE=yymmdd: the slot header of a board build of that day (to load board slots)
echo "\`define BUILD_DATE \"${BUILD_DATE:-sim}\"" > "$B/v/build_id.v"
GEN_DIR="$B/gen" VHDL_DIR="$B/vhdl" python3 "$SIM/scripts/verilog_fixups.py" "$B"/v/*.v "$B"/v/*.sv
# iecdrv_mem: ram_init_file attribute -> $readmemh of the converted image
sed -i 's/(\* *ram_init_file *= *INITFILE *\*) *\(reg \[DATAWIDTH-1:0\] ram\[1<<ADDRWIDTH\];\)/\1 initial if (INITFILE != " ") $readmemh({INITFILE, ".hex"}, ram);/' "$B/v/iecdrv_misc.sv"
# cartridge.v: one blocking "bank_no = 0;" in a clocked block (EasyFlash init);
# same result as non-blocking there, Verilator rejects the mix (BLKANDNBLK)
sed -i 's/\bbank_no = 0;/bank_no <= 0;/' "$B/v/cartridge.v"
if [ "$SDRAM" = real ]; then
	python3 - "$B/v/c64.sv" "$B/v/sdram.v" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
assert s.count("sdram sdram") == 1, "SDRAM instance not found"
p.write_text(s.replace("sdram sdram", '`include "sim_sdram_chip.vh"\nsdram sdram'))
# Verilator 5.020 cannot lower a procedural assignment of Z. Separate its
# registered value/enable; the real controller's state machine stays intact.
p = pathlib.Path(sys.argv[2])
s = p.read_text()
s, n = re.subn(r'inout\s+reg(\s+\[15:0\]\s+sd_data)', r'inout wire\1', s)
assert n == 1, "SDRAM DQ declaration changed"
for old, new in (
    ("reg bt;", "reg [15:0] sim_dq_out;\nreg sim_dq_oe;\nassign sd_data = sim_dq_oe ? sim_dq_out : 16'bz;\nreg bt;"),
    ("sd_data <= 16'bZ;", "sim_dq_oe <= 0;"),
    ("if(wr) sd_data <= {wrdata, wrdata};", "if(wr) begin sim_dq_out <= {wrdata, wrdata}; sim_dq_oe <= 1; end"),
):
    assert s.count(old) == 1, "SDRAM DQ assignment changed: " + old
    s = s.replace(old, new)
p.write_text(s)
PY
fi

# ---------------------------------------------------------------- 3. ROMs
for m in $(cd "$ROOT" && ls rtl/roms/*.mif rtl/iec_drive/*.mif); do
	mkdir -p "$B/run/$(dirname "$m")"
	[ "$B/run/$m.hex" -nt "$ROOT/$m" ] || python3 "$SIM/scripts/mif2hex.py" "$ROOT/$m" "$B/run/$m.hex"
done
cp "$ROOT"/rtl/opl3/*.mem "$B/run/"

# ---------------------------------------------------------------- 4. file list
{
	echo "+incdir+$B/v"
	echo "+incdir+$SIM/rtl"
	ls "$SIM"/rtl/*.vlt
	ls "$B"/gen/*.v
	for f in "${V_SRC[@]}"; do echo "$B/v/$(basename "$f")"; done
	for f in "$SIM"/rtl/*.v "$SIM"/rtl/*.sv; do
		if [ "$SDRAM" = real ] && [ "$f" = "$SIM/rtl/sim_sdram.v" ]; then continue; fi
		echo "$f"
	done
} > "$B/filelist.f"

# ---------------------------------------------------------------- 5. verilator
if [ "${XML_ONLY:-0}" = 1 ]; then  # used by lint/run_inventory.sh: sources and file list only
	echo "file list ready: $B/filelist.f"
	exit 0
fi
WARN="-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-IMPLICIT -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-TIMESCALEMOD -Wno-MULTITOP -Wno-SYMRSVDWORD -Wno-COMBDLY -Wno-UNOPT -Wno-LATCH -Wno-ALWCOMBORDER -Wno-PROCASSWIRE"
EXTRA=()
[ "$THREADS" -gt 1 ] && EXTRA+=(--threads "$THREADS")
OBJ="$B/obj"
FILELIST="$B/filelist.f"
if [ "${DRIVES:-1}" = 0 ]; then  # no 1541/1581: ~1.7x faster, obj-nodrv
	OBJ="$B/obj-nodrv"
	FILELIST="$B/filelist-nodrv.f"
	grep -vE '/(iec_drive|c1541_[a-z_]+|c1581_[a-z_]+|fdc1772|floppy|iecdrv_[a-z0-9_]+|lfsr)\.(sv|v)$' "$B/filelist.f" > "$FILELIST"
	echo "$SIM/rtl/nodrives/iec_drive_stub.sv" >> "$FILELIST"
	OBJ="$OBJ${PROFILE:+-prof}"
fi
if [ "${PROFILE:-0}" = 1 ]; then  # gprof build in obj-prof
	[ "${DRIVES:-1}" = 0 ] || OBJ="$B/obj-prof"
	EXTRA+=(-CFLAGS -pg -LDFLAGS -pg)
fi
if [ "$SDRAM" = real ]; then
	OBJ="$OBJ-sdram-real"
	EXTRA+=(-CFLAGS -DSIM_SDRAM_REAL)
fi
echo "[verilator] building (jobs $JOBS, threads $THREADS)"
time verilator --cc --exe --build -j "$JOBS" $WARN "${EXTRA[@]}" \
	--top-module emu --x-assign 0 --x-initial 0 --savable \
	-MAKEFLAGS "OPT_FAST=$OPT OPT_SLOW=-O1 OPT_GLOBAL=-O2" -O3 \
	--Mdir "$OBJ" \
	-f "$FILELIST" "$SIM/tb/c64_tb.cpp" \
	-o Vemu
echo "built $OBJ/Vemu"
