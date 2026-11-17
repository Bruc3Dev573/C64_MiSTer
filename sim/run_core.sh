#!/usr/bin/env bash
# Build (if needed) and run the whole-core simulation.
#
#   sim/run_core.sh [--nodrives] [--rebuild] boot      [harness options]
#   sim/run_core.sh [--nodrives] [--rebuild] pausetest [harness options]
#   sim/run_core.sh [--nodrives] [--rebuild] sstest    [harness options]
#   sim/run_core.sh boot --prg game.prg --freeze-at <cycles|$ADDR> --slot out.ss
#
#   --nodrives  use the DRIVES=0 model (no 1541/1581, ~2x faster)
#   --rebuild   force sim/build.sh even if the model exists
#
# Harness options are passed to sim/build/obj*/Vemu (see sim/tb/c64_tb.cpp
# and sim/README.md). Relative file arguments (--prg, --tap, --shot) are
# resolved against the directory the script is called from; the run
# directory is sim/build/run (ROM images live there).
set -euo pipefail

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBJ="$SIM/build/obj"
DRV=1
REBUILD=0
while [ $# -gt 0 ]; do
	case "$1" in
		--nodrives) DRV=0; OBJ="$SIM/build/obj-nodrv"; shift ;;
		--rebuild)  REBUILD=1; shift ;;
		*) break ;;
	esac
done

case "${SDRAM:-fast}" in
	fast) ;;
	real) OBJ="$OBJ-sdram-real" ;;
	*) echo "SDRAM must be fast or real" >&2; exit 2 ;;
esac

if [ "$REBUILD" = 1 ] || [ ! -x "$OBJ/Vemu" ]; then
	DRIVES=$DRV "$SIM/build.sh"
fi

args=()
prev=""
for a in "$@"; do
	case "$prev" in
		--prg|--ram-prg|--tap|--shot|--slot|--load-slot) case "$a" in /*) ;; *) a="$PWD/$a" ;; esac ;;
	esac
	args+=("$a")
	prev="$a"
done

cd "$SIM/build/run"
exec "$OBJ/Vemu" "${args[@]}"
