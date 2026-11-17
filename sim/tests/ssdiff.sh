#!/usr/bin/env bash
# WP A3-A6 acceptance (B3 differential of the live chain segments: CPU, VIC,
# CIA1, CIA2, SID1, SID2, SYS):
#
#   sim/tests/ssdiff.sh                      DRIVES=0 model
#   LORENZ=dir sim/tests/ssdiff.sh           also inside Lorenz 2.15 tests; dir holds
#                                            Disk1.d64..Disk3.d64 of VICE testprogs
#                                            general/Lorenz-2.15 (not in the repo)
#   VICII=dir sim/tests/ssdiff.sh            also inside the PRGs in dir (VICE
#                                            testprogs VICII/*, BASIC start)
#   DRIVE=1 sim/tests/ssdiff.sh              also the 1541 (A8) and 1581 (A10)
#                                            disk LOADs (full model, hours)
#
# 1. Field layout: regs.prg sets A/X/Y and loops at $0814; the slot saved
#    there must decode (ss_slot.py --fields) to PC $0814, A $11, X $22, Y $33,
#    the KERNAL CPU port ($2F/$37), the KERNAL's CIA1 setup (timer A latch
#    $4025, IRQ mask) and VIC setup (colours, screen at $0400, $D011 $1B):
#    map.yaml offsets, bit order and length of the live chain.
# 2. ssdiff (sim/tb/c64_tb.cpp): B saves slot 2, runs on, saves slot 1,
#    loads slot 2, loads slot 1 and resumes; every running sample must equal
#    the uninterrupted instance A. At the READY prompt (KERNAL IRQ loop),
#    then inside Lorenz tests: decimal ADC/SBC, CPU port and banking, BRK/RTI,
#    IRQ and NMI timing, illegal opcodes (A3); CIA timers A/B in every count
#    mode, one-shot, force load, ICR/IMR, PB6/PB7 toggle, CNT, both CIAs (A4);
#    VIC-II raster splits, FLD, borders, sprite DMA/split/move (A5); sid.prg:
#    noise/pulse/triangle voices, gate toggled every 256 loops (ADSR attack
#    and release), filter cutoff sweep, OSC3/ENV3 read back (A6); opl.prg
#    (A9, --opl): Sound Expander timers polled by the CPU, music written
#    across the save points. The OPL plays from the replay after a load, so
#    the audio bits are compared up to the first load; after the resume the
#    register files the FM firmware took in A and B must be equal and the OPL
#    output must be back within one frame; oplrewind does the same with
#    --rewind, where the FM part holds the registers of C1 when C0 is loaded.
#    ef.crt (A11): EasyFlash flash erased and programmed in a loop from RAM,
#    both save points inside a sector erase (its write-back in progress), the
#    flash and the EasyFlash RAM in the slot; geo.prg: GeoRAM 4 MiB written
#    and read back page by page across the save points, GeoRAM in the slot.
#    slotphase re-pauses after loading another VIC phase; the full drive
#    suite repeats it during a 1581 LOAD. Real opposite-standard slot images
#    must be refused without changing the live machine.
# Verification hardening: NTSC 6567R8 (SID, decimal CPU loop), C128
# and Smart turbo, refused loads (REU both ways, CRC, format, chain length),
# compatible build hashes, moving 1351 input, and delayed OPL FIFO crossings.
# Output sync (every scenario, A and B): hsync/vsync periods of the core and
# of the freezer output (what the scaler and video_calc see) constant across
# every save, load and pause, video_calc's resolution unchanged, the
# resume at most a frame after the release, a stop back on its VIC position
# whole frames. rewindrun/rewindpause/ntscrewind/efrun/reurewind/vic856x/
# vicearly load another VIC position while B runs (rewindpause: user pause
# right after the load); poweron loads right after a cold start.
set -euo pipefail

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${SS_OUT:-$SIM/build/run}"
mkdir -p "$OUT"
fail=0

# ---------------------------------------------------------------- 1. fields
# 10 SYS2061 / SEI / LDA #$11 / LDX #$22 / LDY #$33 / $0814: JMP $0814
printf '\001\010\013\010\012\000\236\062\060\066\061\000\000\000\170\251\021\242\042\240\063\114\024\010' > "$OUT/regs.prg"
"$SIM/run_core.sh" --nodrives boot --status 14 --ram-prg "$OUT/regs.prg" --kbuf 'RUN\r' --freeze-at '$0814' --slot "$OUT/regs.ss" > "$OUT/regs.log"
# live chain bits: the SS_<SEG>_BITS of the segments named in LIVE (c64.sv)
BITS=$(python3 -c "
import re, sys
sys.path.insert(0, '$SIM/../tools/ss'); from ss_map import MAP
live = set(re.findall(r'<< \`SS_SEG_(\w+)\)', open('$SIM/../c64.sv').read()))
print(sum(s['chain_bits'] for s in MAP['segments'] if s['name'] in live))")
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields CPU --fields CIA1 --fields VIC "$OUT/regs.ss" | tee "$OUT/regs.fields" || fail=1
# CIA1 after the KERNAL init: IRQ timer A latch $4025 (PAL), running, IRQ on TA, keyboard port;
# VIC: border 14, background 6, $D011 $1B (DEN, RSEL, YSCROLL 3), $D016 CSEL, $D018 $14
for f in CPU.t65_pc=0x814 CPU.t65_debug_a=0x11 CPU.t65_debug_x=0x22 CPU.t65_debug_y=0x33 CPU.t65_mcycle=0x0 \
		CPU.iodir=0x2f CPU.iodata=0x37 CPU.currentio=0x37 CIA1.ta_lo=0x25 CIA1.ta_hi=0x40 CIA1.cra=0x1 \
		CIA1.imr=0x1 CIA1.ddra=0xff CIA1.pra=0x7f VIC.ec=0xe VIC.b0c=0x6 VIC.den=0x1 VIC.rsel=0x1 \
		VIC.yscroll=0x3 VIC.csel=0x1 VIC.vm=0x1 VIC.cb=0x2; do
	grep -qx "${f%%=*} = ${f#*=}" "$OUT/regs.fields" || { echo "FAIL: ${f%%=*} is not ${f#*=}"; fail=1; }
done

# test programs (sim/scripts/testprgs.sh): sid.prg, reu.prg, ocean.crt, rtc.prg, opl.prg, ef.crt, geo.prg;
# pilot.tap: 5000 pulses of pilot tone for a KERNAL LOAD; vartap.tap: pulses
# of varied length (a byte skipped, repeated or lost in the tape path changes
# the cassette line, which a pilot tone hides)
bash "$SIM/scripts/testprgs.sh" "$OUT"
# Small Lorenz-style decimal ADC/SBC + flags loop; also enables $D030 for C128
# turbo. The shared pot loop reads both SID pot registers through the CPU.
python3 - "$OUT" <<'EOF'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
stub = bytes.fromhex("01080b080a009e32303631000000")
def program(name, init, loop):
    start = 0x080D + len(init)
    body = init + loop + bytes([0x4C, start & 255, start >> 8])
    assert len(stub) == 14 and start < 0x1000
    (d / name).write_bytes(stub + body)
program("cpu.prg", bytes.fromhex("78a9018d30d0a200"),
        bytes.fromhex("8af818693708d89d0004689d00058af838e91908d89d0006689d0007e8"))
program("mouse.prg", bytes.fromhex("78a9ff8d02dca9408d00dc"),
        bytes.fromhex("ad19d48d0004ad1ad48d0104ee0204"))
EOF
# Pointer visibility must change only after the selected destination clocks.
iverilog -g2012 -s dcfifo_tb -o "$OUT/dcfifo_tb" "$SIM/rtl/sim_altera.sv" "$SIM/tb/dcfifo_tb.sv"
vvp -n "$OUT/dcfifo_tb" | tee "$OUT/dcfifo_tb.log"
grep -q '^dcfifo: PASS' "$OUT/dcfifo_tb.log" || fail=1
python3 "$SIM/scripts/mktap.py" "$OUT/pilot.tap" 5000
python3 "$SIM/scripts/mktap.py" "$OUT/vartap.tap" 20000 rand
"$SIM/run_core.sh" --nodrives boot --status 14 --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --freeze-at '$0855' --slot "$OUT/sid.ss" > "$OUT/sid.log"
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields SID1 --fields SID2 "$OUT/sid.ss" > "$OUT/sid.fields" || fail=1
for s in SID1 SID2; do
	for f in top_filter_mode_vol=0x1f top_filter_res_filt=0xf1 top_voice_1_att_dec=0x9 top_voice_1_sus_rel=0xa8 \
			top_voice_1_control=0x81 top_voice_2_pw=0x800 top_voice_2_freq=0x1000 top_voice_2_control=0x41 \
			top_voice_3_freq=0x300 top_voice_3_att_dec=0x22 top_voice_3_control=0x11; do
		grep -qx "$s.${f%%=*} = ${f#*=}" "$OUT/sid.fields" || { echo "FAIL: $s.${f%%=*} is not ${f#*=}"; fail=1; }
	done
done

# reu.prg (REU 512 KiB, --status 14,53)
"$SIM/run_core.sh" --nodrives boot --status 14,53 --ram-prg "$OUT/reu.prg" --kbuf 'RUN\r' --freeze-at '$083E' --slot "$OUT/reu.ss" > "$OUT/reu.log"
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields REU "$OUT/reu.ss" > "$OUT/reu.fields" || fail=1
# after the first swap (cmd $92 done: execute cleared, FF00 bit set), REU bank 1
for f in REU.cmd=0x12 REU.length_r=0x3e8 REU.addr_c64_r=0x400 REU.addr_ram_r=0x11000 REU.state=0x0 REU.dma_req=0x0; do
	grep -qx "${f%%=*} = ${f#*=}" "$OUT/reu.fields" || { echo "FAIL: ${f%%=*} is not ${f#*=}"; fail=1; }
done

# ocean.crt (Ocean type 1): reaching $8019 after the bank 1 write, the freeze
# lands ~33 cycles later at the next idle boundary, in the next loop before
# its bank write ($8016): bank 1, 16K mode
"$SIM/run_core.sh" --nodrives boot --status 14 --prg "$OUT/ocean.crt" --freeze-at '$8019' --slot "$OUT/ocean.ss" > "$OUT/ocean.log"
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields CART "$OUT/ocean.ss" > "$OUT/ocean.fields" || fail=1
for f in CART.bank_lo=0x1 CART.bank_hi=0x1 CART.exrom_overide=0x0 CART.game_overide=0x0 CART.ezrom_en=0x0; do
	grep -qx "${f%%=*} = ${f#*=}" "$OUT/ocean.fields" || { echo "FAIL: ${f%%=*} is not ${f#*=}"; fail=1; }
done

# rtc.prg: after the seconds byte is read ($0826) the PCF8583 points at
# word 3 and use_rtc is on (SCL toggled within the last 65 ms)
"$SIM/run_core.sh" --nodrives boot --status 14 --ram-prg "$OUT/rtc.prg" --kbuf 'RUN\r' --freeze-at '$0826' --slot "$OUT/rtc.ss" > "$OUT/rtc.log"
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields RTC "$OUT/rtc.ss" > "$OUT/rtc.fields" || fail=1
for f in RTC.ptr=0x3 RTC.ss_use_rtc=0x1; do
	grep -qx "${f%%=*} = ${f#*=}" "$OUT/rtc.fields" || { echo "FAIL: ${f%%=*} is not ${f#*=}"; fail=1; }
done

# opl.prg (Sound Expander, --opl runs clk48, status 12, DolphinDOS): at the first wait
# ($082B) the index holds $A0, the first music register, whose value is not
# written yet; timer 1 preset $E7, both timers running and unmasked; the
# register shadow (region OPL3_REGS) holds the init table, not $A0
"$SIM/run_core.sh" --nodrives boot --opl --status 12 --ram-prg "$OUT/opl.prg" --kbuf 'RUN\r' --freeze-at '$082B' --slot "$OUT/opl.ss" > "$OUT/opl.log"
python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields OPL3 --region 0x12 "$OUT/opl_regs.bin" "$OUT/opl.ss" > "$OUT/opl.fields" || fail=1
for f in OPL3.index=0xa0 OPL3.timer1_preset=0xe7 OPL3.timer1_active=0x1 OPL3.timer2_active=0x1 OPL3.timer1_mask=0x0 OPL3.irq_n=0x1; do
	grep -qx "${f%%=*} = ${f#*=}" "$OUT/opl.fields" || { echo "FAIL: ${f%%=*} is not ${f#*=}"; fail=1; }
done
python3 -c "import sys; r = open(sys.argv[1], 'rb').read(); sys.exit(not (len(r) == 256 and (r[0xB1], r[0x02], r[0x04], r[0xC0], r[0xA0]) == (0x32, 0xE7, 0x03, 0x06, 0)))" \
	"$OUT/opl_regs.bin" || { echo "FAIL: OPL3_REGS region"; fail=1; }

# ---------------------------------------------------------------- 2. ssdiff
run() {   # name, harness options; STATUS: status bits at power on (default 14)
	local n="$1"; shift
	"$SIM/run_core.sh" --nodrives ssdiff --status "${STATUS:-14}" "$@" > "$OUT/ssdiff_$n.log" 2>&1 || true
}
report() {
	local n="$1"
	if grep -q '^PASS' "$OUT/ssdiff_$n.log" && ! grep -q '^FAIL' "$OUT/ssdiff_$n.log"; then
		echo "ssdiff $n: $(grep -m1 '^PASS' "$OUT/ssdiff_$n.log")"
	else
		echo "ssdiff $n: FAIL"; grep -E 'FAIL|differ' "$OUT/ssdiff_$n.log" || tail -3 "$OUT/ssdiff_$n.log"; fail=1
	fi
}
# first alone: it (re)writes the READY snapshot the others start from
run ready --slot "$OUT/ssdiff_ready_"
report ready
TESTS="$OUT/sid.prg $OUT/reu.prg $OUT/ocean.crt $OUT/ef.crt $OUT/geo.prg $OUT/rtc.prg $OUT/opl.prg $OUT/pilot.tap $OUT/vartap.tap $OUT/rewind.rewind $OUT/oplrewind.rewind $OUT/efrewind.rewind"
TESTS="$TESTS $OUT/ntscsid.extra $OUT/ntsccpu.extra \
	$OUT/c1282x.extra $OUT/c1284x.extra $OUT/smart3x.extra $OUT/smart4x.extra \
	$OUT/reu-off.reject $OUT/reu-on.reject $OUT/crc.reject $OUT/version.reject $OUT/chain.reject \
	$OUT/buildhash.extra $OUT/mouse.extra $OUT/paddles.extra $OUT/mousefreeze.extra $OUT/opl2.extra $OUT/oplrewind2.extra"
TESTS="$TESTS $OUT/slotphase.extra"
TESTS="$TESTS $OUT/rewindrun.extra $OUT/rewindpause.extra $OUT/ntscrewind.extra $OUT/efrun.extra $OUT/reurewind.extra \
	$OUT/vic856x.extra $OUT/vicearly.extra $OUT/poweron.extra"
if [ -n "${LORENZ:-}" ]; then
	L="$OUT/lorenz"
	python3 "$SIM/scripts/d64_prg.py" "$LORENZ/Disk1.d64" "$L" adcb sbcb brkn rtin
	python3 "$SIM/scripts/d64_prg.py" "$LORENZ/Disk2.d64" "$L" sbcb-eb cpuport mmu trap1 shaay
	python3 "$SIM/scripts/d64_prg.py" "$LORENZ/Disk3.d64" "$L" irq nmi cia1tb123 cia2tb123 cia1pb6 cia1pb7 cia2pb6 cia2pb7 \
		cia1tab loadth cnto2 icr01 imr flipos oneshot cntdef cia1ta cia1tb cia2ta cia2tb
	TESTS="$TESTS $(ls "$L"/*.prg)"
fi
[ -n "${VICII:-}" ] && TESTS="$TESTS $(ls "$VICII"/*.prg)"
for p in $TESTS; do   # JOBS instances at a time (two models each)
	while [ "$(jobs -rp | wc -l)" -ge "${JOBS:-6}" ]; do wait -n || true; done
	n="$(basename "${p%.*}")"
	# with the REU the slot carries 512 KiB more (a save takes ~5.3M clk_sys); a
	# CRT load resets the machine and erases the RAM first (~7M clk_sys)
	if [ "$n" = reu ]; then st=14,53; t1=9000000; else st=14; t1=3000000; fi
	case "$p" in
		*/ntscsid.extra) STATUS=2,14 run "$n" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 --slot "$OUT/ssdiff_ntscsid_" & ;;
		*/ntsccpu.extra) STATUS=2,14 run "$n" --ram-prg "$OUT/cpu.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 & ;;
		*/c1282x.extra|*/c1284x.extra|*/smart3x.extra|*/smart4x.extra)
			case "$n" in c1282x) st=46 ;; c1284x) st=46,49 ;; smart3x) st=47,48 ;; smart4x) st=47,49 ;; esac
			run "$n" --status-ready "$st" --ram-prg "$OUT/cpu.prg" --kbuf 'RUN\r' --turbo-check --t0 300000 --t1 3000000 & ;;
		*.reject)
			[ "$n" = reu-off ] && st=14,53
			STATUS=$st run "$n" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --t0 300000 --reject "$n" & ;;
		*/buildhash.extra) run "$n" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 --build-hash & ;;
		*/mouse.extra) run "$n" --status-ready 26 --mouse --ram-prg "$OUT/mouse.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 & ;;
		*/paddles.extra) run "$n" --status-ready 27 --paddles --ram-prg "$OUT/mouse.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 & ;;
		*/mousefreeze.extra) run "$n" --status-ready 26 --mouse-freeze --ram-prg "$OUT/mouse.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 & ;;
		*/opl2.extra) STATUS=12 run "$n" --opl --fifo-sync 2 --ram-prg "$OUT/opl.prg" --kbuf 'RUN\r' --t0 1500000 --t1 3000000 --after 4000000 & ;;
		*/oplrewind2.extra) STATUS=12 run "$n" --opl --fifo-sync 2 --ram-prg "$OUT/opl.prg" --kbuf 'RUN\r' --t0 1500000 --t1 3000000 --after 5000000 --rewind & ;;
		# EasyFlash: a pass of ef.crt is 2.65M clk_sys, its sector erase busy from
		# 6.83M + k * 2.65M for 1M clk_sys (write-back 1.2M); a save carries the
		# 1 MiB flash (10.83M clk_sys). C0 (7.3M) falls in pass 0, C1 (26.1M, i.e.
		# 15.3M of running time) in pass 3: both with the busy counter running and
		# the write-back pending (checked in the slots below)
		*/ef.crt) STATUS=$st run "$n" --prg "$p" --t0 7300000 --t1 26100000 --slot "$OUT/ssdiff_ef_" & ;;
		# EasyFlash rewind: the state of C0 (inside the erase of pass 0) loaded in
		# the program phase of pass 1
		*/efrewind.rewind) STATUS=$st run "$n" --prg "$OUT/ef.crt" --t0 7300000 --t1 21000000 --after 3000000 --rewind & ;;
		*.crt) STATUS=$st run "$n" --prg "$p" --t0 8000000 --t1 12000000 & ;;
		# GeoRAM 4 MiB on at READY (status 52): ~300k clk_sys per pass of geo.prg,
		# a save takes 38.6M clk_sys; B runs 4.4M between the save points
		*/geo.prg) STATUS=$st run "$n" --status-ready 52 --ram-prg "$p" --kbuf 'RUN\r' --t0 2000000 --t1 45000000 --slot "$OUT/ssdiff_geo_" & ;;
		# Sound Expander: save and loads inside the music (timer ticks every 3 ms,
		# 48 steps), the audio compared up to the first load, then the replay checks
		*/opl.prg) STATUS=12 run "$n" --opl --ram-prg "$p" --kbuf 'RUN\r' --t0 1500000 --t1 3000000 --after 4000000 & ;;
		# Sound Expander rewind: the FM part holds the registers of C1 at the load
		# of C0, so the replay has to queue the ones that changed
		*/oplrewind.rewind) STATUS=12 run "$n" --opl --ram-prg "$OUT/opl.prg" --kbuf 'RUN\r' --t0 1500000 --t1 3000000 --after 5000000 --rewind & ;;
		# KERNAL LOAD reading the pilot tone: motor, player, FIFO, FLAG IRQs
		*.tap) STATUS=$st run "$n" --status-ready 96 --tap "$p" --kbuf 'LOAD\r' --t0 1500000 --t1 4000000 & ;;
		# rewind: load an older state (slot 2 saved at C0) and resume; B must replay A from C0
		*.rewind) STATUS=$st run "$n" --status-ready 96 --tap "$OUT/vartap.tap" --kbuf 'LOAD\r' --t0 1500000 --t1 4000000 --after 3000000 --rewind & ;;
		*/slotphase.extra) run "$n" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --slotphase --t0 1500000 --gap 1000000 --after 3000000 & ;;
		# loads to another VIC position (every scenario checks the output sync,
		# c64_tb.cpp sync_mon): while running (hotkey, or the OSD without Pause
		# When OSD is Open), with the user pause pressed right after the load,
		# NTSC, EasyFlash, REU, the 856x VIC variants, and a load right after
		# power on (no READY, the slot of the ready scenario)
		*/rewindrun.extra) STATUS=$st run "$n" --status-ready 96 --tap "$OUT/vartap.tap" --kbuf 'LOAD\r' --t0 1500000 --t1 4000000 --after 3000000 --rewind --running & ;;
		*/rewindpause.extra) STATUS=$st run "$n" --status-ready 96 --tap "$OUT/vartap.tap" --kbuf 'LOAD\r' --t0 1500000 --t1 4000000 --after 3000000 --rewind --repause & ;;
		*/ntscrewind.extra) STATUS=2,14 run "$n" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 --after 3000000 --rewind --running & ;;
		*/efrun.extra) STATUS=$st run "$n" --prg "$OUT/ef.crt" --t0 7300000 --t1 21000000 --after 3000000 --rewind --running & ;;
		*/reurewind.extra) STATUS=14,53 run "$n" --ram-prg "$OUT/reu.prg" --kbuf 'RUN\r' --t0 300000 --t1 9000000 --after 3000000 --rewind --running & ;;
		*/vic856x.extra|*/vicearly.extra)
			[ "$n" = vic856x ] && st=34 || st=35
			run "$n" --status-ready "$st" --ram-prg "$OUT/sid.prg" --kbuf 'RUN\r' --t0 300000 --t1 3000000 --after 3000000 --rewind --running & ;;
		*/poweron.extra) "$SIM/run_core.sh" --nodrives boot --status 14 --load-slot "$OUT/ssdiff_ready_1.ss" --load-at 1500000 \
			> "$OUT/ssdiff_poweron.log" 2>&1 & ;;
		*)     STATUS=$st run "$n" --ram-prg "$p" --kbuf 'RUN\r' --t0 300000 --t1 $t1 & ;;
	esac
done
wait
for p in $TESTS; do n="$(basename "$p")"; report "${n%.*}"; done
# Use real opposite-standard slots, not a patched configuration header.
STATUS=2,14 run ntsc-from-pal --reject video-standard --load-slot "$OUT/ssdiff_ready_1.ss" &
run pal-from-ntsc --reject video-standard --load-slot "$OUT/ssdiff_ntscsid_1.ss" &
wait
report ntsc-from-pal
report pal-from-ntsc
# ef: both slots inside a sector erase of ROML bank 0 (chip 0 busy and its
# counter running, the write-back to the SDRAM pending); geo: GeoRAM in the
# slot, data window on
for s in 1 2; do
	python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields CART "$OUT/ssdiff_ef_$s.ss" > "$OUT/ef_$s.fields" || fail=1
	for f in CART.ezrom_en=0x1 CART.bank_no=0x0 CART.ez_rom_rom0_state=0x4 CART.ez_rom_rom0_mem_req=0x1; do
		grep -qx "${f%%=*} = ${f#*=}" "$OUT/ef_$s.fields" || { echo "FAIL: ef slot $s ${f%%=*} is not ${f#*=}"; fail=1; }
	done
	! grep -qx "CART.ez_rom_rom0_busy_cnt = 0x0" "$OUT/ef_$s.fields" || { echo "FAIL: ef slot $s: erase counter not running"; fail=1; }
	python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields CART --region 0x08 "$OUT/geo_$s.bin" "$OUT/ssdiff_geo_$s.ss" > "$OUT/geo_$s.fields" || fail=1
done
# geo: the pages geo.prg wrote (block = pass, page = pass & 63) are in both
# slots, more of them at C1 (slot 1) than at C0 (slot 2)
grep -qx "CART.ioe_ena = 0x1" "$OUT/geo_1.fields" && python3 -c "
import sys
p = [sum(any(d[i:i + 256]) for i in range(0, len(d), 256)) for d in (open(f, 'rb').read() for f in sys.argv[1:])]
print('geo: GeoRAM pages written at C1 %d, at C0 %d' % tuple(p)); sys.exit(not p[0] > p[1] >= 3)" "$OUT/geo_1.bin" "$OUT/geo_2.bin" ||
	{ echo "FAIL: geo: GeoRAM pages missing in the slots"; fail=1; }

# 1541 (full model, DRIVE=1): DolphinDOS parallel-cable LOAD of a 7-block file
# from a tiny D64 (17/0, interleave 10). The LED lights ~18.7M clk_sys after
# READY and the head is on track 17 (half-track 0x20) from ~20.6M: both save
# points and the load fall while it reads the file there.
# 1581: DolphinDOS LOAD of a 3-block file (39/0) from a tiny D81. The WD1772
# spins up, steps from ~53.6M clk_sys after READY (one track per ~189k) to the
# directory track 40 (track register 0x27) by ~60.8M and reads its 10 sectors
# there from ~62.5M to ~68.6M (each read sector command: SD request, wait for
# the sector header, bytes to the CPU on DRQ): both save points fall in those
# commands. drive1581rw (--rewind) loads a state saved while the bytes of a
# sector go to the CPU (63.3M) and replays A from there; drive1541rw loads,
# while B runs, the state of C0 inside the 1541 file transfer. The runs share
# the READY snapshots, written first; hours per run
if [ "${DRIVE:-0}" = 1 ]; then
	python3 -c 'import sys; sys.stdout.buffer.write(bytes([1, 8]) + bytes(range(256)) * 6)' > "$OUT/a8.prg"
	python3 "$SIM/scripts/mkd64.py" "$OUT/a8.d64" TEST "$OUT/a8.prg" > /dev/null
	python3 -c 'import sys; sys.stdout.buffer.write(bytes([1, 8]) + bytes(range(256)) * 2)' > "$OUT/a10.prg"
	python3 "$SIM/scripts/mkd81.py" "$OUT/a10.d81" TEST "$OUT/a10.prg" > /dev/null
	"$SIM/run_core.sh" boot --disk "$OUT/a8.d64" > /dev/null &
	"$SIM/run_core.sh" boot --disk "$OUT/a10.d81" > /dev/null &
	wait
	"$SIM/run_core.sh" ssdiff --disk "$OUT/a8.d64" --kbuf 'LOAD"*",8\r' --t0 21500000 --t1 24500000 \
		--after 3000000 --slot "$OUT/ssdiff_drive_" > "$OUT/ssdiff_drive.log" 2>&1 &
	"$SIM/run_core.sh" ssdiff --disk "$OUT/a10.d81" --kbuf 'LOAD"*",8\r' --t0 62700000 --t1 65700000 \
		--after 3000000 --slot "$OUT/ssdiff_drive1581_" > "$OUT/ssdiff_drive1581.log" 2>&1 &
	"$SIM/run_core.sh" ssdiff --disk "$OUT/a10.d81" --kbuf 'LOAD"*",8\r' --t0 63300000 --t1 64300000 \
		--after 3000000 --rewind --slot "$OUT/ssdiff_drive1581rw_" > "$OUT/ssdiff_drive1581rw.log" 2>&1 &
	"$SIM/run_core.sh" ssdiff --disk "$OUT/a10.d81" --kbuf 'LOAD"*",8\r' --slotphase --t0 62700000 --gap 1000000 \
		--after 3000000 > "$OUT/ssdiff_slotdrive1581.log" 2>&1 &
	"$SIM/run_core.sh" ssdiff --disk "$OUT/a8.d64" --kbuf 'LOAD"*",8\r' --t0 21500000 --t1 24500000 \
		--after 3000000 --rewind --running > "$OUT/ssdiff_drive1541rw.log" 2>&1 &
	wait
	report drive
	for s in 1 2; do
		python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields DRV8_1541 "$OUT/ssdiff_drive_$s.ss" > "$OUT/drive_$s.fields" || fail=1
		for f in DRV8_1541.track=0x20 DRV8_1541.disk_present=0x1; do
			grep -qx "${f%%=*} = ${f#*=}" "$OUT/drive_$s.fields" || { echo "FAIL: slot $s ${f%%=*} is not ${f#*=}"; fail=1; }
		done
	done
	report drive1581
	for s in 1 2; do
		python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields DRV8_1581 "$OUT/ssdiff_drive1581_$s.ss" > "$OUT/drive1581_$s.fields" || fail=1
		for f in DRV8_1581.fdc_track=0x27 DRV8_1581.fdc_motor_on=0x1; do
			grep -qx "${f%%=*} = ${f#*=}" "$OUT/drive1581_$s.fields" || { echo "FAIL: slot $s ${f%%=*} is not ${f#*=}"; fail=1; }
		done
	done
	report drive1581rw
	python3 "$SIM/scripts/ss_slot.py" --chain-bits "$BITS" --fields DRV8_1581 "$OUT/ssdiff_drive1581rw_2.ss" > "$OUT/drive1581rw.fields" || fail=1
	grep -qx "DRV8_1581.fdc_data_transfer_state = 0x1" "$OUT/drive1581rw.fields" && ! grep -qx "DRV8_1581.fdc_data_transfer_cnt = 0x0" "$OUT/drive1581rw.fields" ||
		{ echo "FAIL: C0 of drive1581rw is not inside a sector transfer"; fail=1; }
	report slotdrive1581
	report drive1541rw
fi

[ "$fail" = 0 ] && echo "ssdiff.sh: PASS" || { echo "ssdiff.sh: FAIL"; exit 1; }
