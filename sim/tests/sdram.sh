#!/usr/bin/env bash
# Chip data-path self-checks, then a real-controller RTL_OVERLAY negative control.
set -euo pipefail
SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$SIM/.." && pwd)"
B="$SIM/build/sdram-check"
mkdir -p "$B/chip" "$B/overlay"
verilator --binary --timing --top-module tb_sdram_chip --Mdir "$B/chip" -j "${JOBS:-6}" \
	-Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD \
	"$SIM/rtl/sim_mt48lc16m16.sv" "$SIM/ss/tb_sdram_chip.sv" > "$B/chip-build.log" 2>&1 || {
	cat "$B/chip-build.log"; exit 1;
}
"$B/chip/Vtb_sdram_chip" | tee "$B/chip.log"

# Never edit the synthesized source: the intentionally broken copy lives in build/.
python3 - "$ROOT/rtl/sdram.v" "$B/overlay/sdram.v" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
old = "RASCAS_DELAY   = 3'd2"
assert s.count(old) == 1, "RASCAS_DELAY declaration changed"
pathlib.Path(sys.argv[2]).write_text(s.replace(old, "RASCAS_DELAY   = 3'd1"))
PY
SDRAM=real DRIVES=0 RTL_OVERLAY="$B/overlay" BUILD_DIR="$B/negative" \
	"$SIM/build.sh" > "$B/negative-build.log" 2>&1 || {
	cat "$B/negative-build.log"; exit 1;
}
# A bounded cold boot is enough to exercise thousands of real controller accesses.
# Failure to reach READY is not the negative-control oracle: require a tRCD count.
set +e
(cd "$B/negative/run" && ../obj-nodrv-sdram-real/Vemu boot --no-cache --max-frames 1) > "$B/negative.log" 2>&1
rc=$?
set -e
grep -E '^SDRAM (violation|summary|count)|^FAIL: SDRAM' "$B/negative.log"
if [ "$rc" = 0 ] || ! grep -Eq '^SDRAM count .*kind=tRCD count=[1-9][0-9]*$' "$B/negative.log"; then
	echo 'FAIL: SDRAM RASCAS_DELAY=1 overlay did not produce a tRCD violation'
	exit 1
fi
echo 'PASS: SDRAM RASCAS_DELAY=1 RTL_OVERLAY rejected by tRCD checker'
