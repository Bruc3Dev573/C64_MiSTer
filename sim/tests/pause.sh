#!/usr/bin/env bash
# A0 acceptance in simulation: user pause of N cycles + resume must be
# identical to the uninterrupted run shifted by N (see sim/README.md).
#
#   sim/tests/pause.sh            # DRIVES=0 model, PAL and NTSC scenarios
#   DRIVE=1 sim/tests/pause.sh    # also the 1541 and 1581 disk LOADs (full model)
#
# First run boots twice (DolphinDOS ~2 min, standard KERNAL with RAM test
# ~7.5 min); the READY snapshots are cached in sim/build/run afterwards.
set -euo pipefail
SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$SIM/run_core.sh --nodrives"
python3 "$SIM/scripts/mktap.py" "$SIM/build/run/pilot.tap" 5000 2>/dev/null || {
	DRIVES=0 "$SIM/build.sh"; python3 "$SIM/scripts/mktap.py" "$SIM/build/run/pilot.tap" 5000; }
python3 "$SIM/scripts/mktap.py" "$SIM/build/run/vartap.tap" 5000 rand

fail=0
run() {
	local name=$1; shift
	echo "== $name"
	if $RUN pausetest "$@" | tee "$SIM/build/run/pause_$name.log" | grep -E '^(PASS|FAIL|B paused|B resumed|while B|video|sync)'; then :; fi
	# machine samples, core video output (sync, replayed frame) and the output
	# sync monitor (core and freezer periods, video_calc size) must all pass
	grep -q '^PASS' "$SIM/build/run/pause_$name.log" || fail=1
	grep -q '^video: PASS' "$SIM/build/run/pause_$name.log" || fail=1
	grep -q '^sync b: PASS' "$SIM/build/run/pause_$name.log" || fail=1
	! grep -q 'FAIL' "$SIM/build/run/pause_$name.log" || fail=1
}

# idle READY loop, Pause/Break key
run key  --trigger key --t0 200000 --hold 3 --after 2000000
# idle READY loop, pad "Pause" button
run joy  --trigger joy --t0 300000 --hold 2 --after 2000000
# NTSC 6567R8: 65 C64 cycles/line, 263 lines; video must remain regular.
run ntsc --status 2 --trigger key --t0 300000 --hold 3 --after 2000000
# tape: KERNAL LOAD reading a pilot tone (motor on, FLAG IRQs, CIA timers)
run tape --status 14 --status-ready 96 --tap "$SIM/build/run/pilot.tap" --kbuf 'LOAD\r' \
         --trigger key --t0 1500000 --hold 2 --after 3000000
# tape with varied pulse lengths and a longer pause: a pilot tone cannot show
# a pulse skipped or repeated across the pause, this one can
run tapevar --status 14 --status-ready 96 --tap "$SIM/build/run/vartap.tap" --kbuf 'LOAD\r' \
         --trigger joy --t0 1500000 --hold 10 --after 3000000
# SID voices/filter and REU DMA (swap + $FF00 fetch) running across the pause
bash "$SIM/scripts/testprgs.sh" "$SIM/build/run"
run sid  --status 14 --ram-prg "$SIM/build/run/sid.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000
run reu  --status 14,53 --ram-prg "$SIM/build/run/reu.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000
# cartridge: Ocean bank switching from the cartridge ROM (the CRT load resets
# the machine and erases the RAM first, ~7M clk_sys)
run cart --status 14 --prg "$SIM/build/run/ocean.crt" --trigger key --t0 9000000 --hold 2 --after 2000000
# EasyFlash: sector erase and byte programs of the flash from RAM; the pause
# (requested at 7.0M, taken on the next frame) inside the erase of the first
# pass (busy 6.83M-7.83M, write-back to the SDRAM until 8.03M)
run ef   --status 14 --prg "$SIM/build/run/ef.crt" --trigger key --t0 7000000 --hold 2 --after 2000000
# GeoRAM 4 MiB: pages written and read back through $DE00
run geo  --status 14 --status-ready 52 --ram-prg "$SIM/build/run/geo.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000
# PCF8583 RTC read over I2C on the cassette port in a loop (SCL/SDA, sense)
run rtc  --status 14 --ram-prg "$SIM/build/run/rtc.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000
# Sound Expander (OPL, clk48): music written on its timer ticks, the CPU polls
# the status; the FM part holds with the machine, the mix takes its sample on
# the C64 cycle grid
run opl  --opl --status 12 --ram-prg "$SIM/build/run/opl.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000
run opl2 --opl --fifo-sync 2 --status 12 --ram-prg "$SIM/build/run/opl.prg" --kbuf 'RUN\r' --trigger key --t0 3000000 --hold 2 --after 2000000

# 1541 and 1581 (full model, DRIVE=1): user pause during a DolphinDOS LOAD
# from a tiny D64 while the head reads track 17, and from a tiny D81 while the
# WD1772 reads the directory track (ssdiff.sh); hours per run
if [ "${DRIVE:-0}" = 1 ]; then
	D="$SIM/build/run"
	python3 -c 'import sys; sys.stdout.buffer.write(bytes([1, 8]) + bytes(range(256)) * 6)' > "$D/a8.prg"
	python3 "$SIM/scripts/mkd64.py" "$D/a8.d64" TEST "$D/a8.prg" > /dev/null
	RUN="$SIM/run_core.sh" run drive --disk "$D/a8.d64" --kbuf 'LOAD"*",8\r' --trigger key --t0 22000000 --hold 2 --after 3000000
	python3 -c 'import sys; sys.stdout.buffer.write(bytes([1, 8]) + bytes(range(256)) * 2)' > "$D/a10.prg"
	python3 "$SIM/scripts/mkd81.py" "$D/a10.d81" TEST "$D/a10.prg" > /dev/null
	RUN="$SIM/run_core.sh" run drive1581 --disk "$D/a10.d81" --kbuf 'LOAD"*",8\r' --trigger key --t0 64000000 --hold 2 --after 3000000
fi

[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
