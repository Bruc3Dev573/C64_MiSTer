#!/usr/bin/env bash
# WP A2 acceptance in the whole-core simulation (DDR3 modelled):
#
#   sim/tests/savestate.sh            DRIVES=0 model
#   sim/tests/savestate.sh --full     full model (drives and track cache arbiter)
#
# sstest: boot to READY (standard KERNAL, status 14; the PRG is put into RAM
# by the harness), save to slot 1, screenshot A; start fill.prg from the
# keyboard buffer (screen 'X', Color RAM red), screenshot B; load slot 1:
# RAM and Color RAM must equal their state at the save, screenshot C = A;
# OSD self-test. The slot image is then checked with ss_slot.py (zlib CRC)
# and its RAM region compared with the RAM dump of the harness.
set -euo pipefail

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL=--nodrives
[ "${1:-}" = "--full" ] && MODEL=
OUT="${SS_OUT:-$SIM/build/run}"   # SS_OUT: other directory for slot and log
# SS_STATUS: power-on status bits (default 14; 14,52 adds GeoRAM, 14,53 a 512 KiB REU)
mkdir -p "$OUT"
python3 "$SIM/scripts/mkfill.py" "$OUT/fill.prg"

"$SIM/run_core.sh" $MODEL sstest --status "${SS_STATUS:-14}" --prg "$OUT/fill.prg" --kbuf 'SYS2061\r' \
	--freeze-at 200000 --slot "$OUT/sstest_slot.ss" | tee "$OUT/sstest.log"

python3 "$SIM/scripts/ss_slot.py" "$OUT/sstest_slot.ss"
grep -q "^PASS: sstest" "$OUT/sstest.log"
echo "savestate.sh: PASS"
