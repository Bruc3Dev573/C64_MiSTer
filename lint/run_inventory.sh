#!/usr/bin/env bash
# B7 on the whole design: reuse the sim flow's file list (VHDL converted by
# ghdl-yosys with signal names kept), dump it with Verilator and run the
# state inventory against savestate/state_classes.yaml.
#
#   lint/run_inventory.sh [--fail-unclassified]
#
# Outputs lint/build/inventory.md and lint/build/inventory.csv.
# Needs the sim flow tools (ghdl-gcc, yosys, yosys-plugin-ghdl, verilator).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/lint/build"
mkdir -p "$OUT"

# file list (and converted sources) from the sim flow; XML_ONLY skips the C++ build
[ -f "$ROOT/sim/build/filelist.f" ] || XML_ONLY=1 "$ROOT/sim/build.sh"

WARN=$(sed -n 's/^WARN="\(.*\)"$/\1/p' "$ROOT/sim/build.sh")
# The sim replaces some framework blocks (PLL, hps_io, video_mixer, SDRAM
# controller): state_classes.yaml marks them ignored with the reason.
verilator --xml-only --xml-output "$OUT/design.xml" $WARN --top-module emu -f "$ROOT/sim/build/filelist.f"

python3 "$ROOT/lint/state_inventory.py" "$OUT/design.xml" --top-alias emu \
	--classes "$ROOT/savestate/state_classes.yaml" --map "$ROOT/savestate/map.yaml" \
	--md "$OUT/inventory.md" --csv "$OUT/inventory.csv" --group-depth 2 "$@"
