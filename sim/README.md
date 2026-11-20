# Whole-core simulation (Track B1/B2)

Verilator model of the whole `emu` (c64.sv) with the real RTL of the C64,
VIC-II, CIAs, SID, cartridge/REU/EasyFlash, tape and (optionally) the drives.
Only the MiSTer framework around the core is replaced by simulation models.

## Tools

Ubuntu 24.04 packages:

```bash
sudo apt-get install -y ghdl-gcc yosys yosys-plugin-ghdl verilator python3
```

`ghdl-gcc` is required: `yosys-plugin-ghdl` looks for the GCC backend
libraries (`/usr/lib/ghdl/gcc`). Tested with GHDL 4.1.0, Yosys 0.33,
Verilator 5.020. Python 3 with Pillow is only needed to turn the PPM
screenshots into PNG.

## Usage

```bash
sim/build.sh                       # full model  -> sim/build/obj/Vemu
DRIVES=0 sim/build.sh              # no drives   -> sim/build/obj-nodrv/Vemu (~2x faster)
sim/run_core.sh boot --shot ready.ppm
sim/run_core.sh --nodrives pausetest
sim/run_core.sh --nodrives pausetest --hold 5
sim/run_core.sh --nodrives boot --prg game.prg --run-cycles 20000000 --shot game.ppm
sim/tests/pause.sh                 # A0 acceptance: idle, tape, chip and cartridge scenarios
```

`run_core.sh` builds the model if it is missing (`--rebuild` forces it) and
runs it in `sim/build/run`, where the ROM images live.

Harness modes (`sim/tb/c64_tb.cpp`):

| Mode | What it does |
| --- | --- |
| `boot` | Power on, run until `READY.` is in screen RAM, then optional `--prg`, `--tap`, `--type "LOAD\n"`, `--run-cycles N`; writes the last full frame (`--shot file.ppm`, default `screen.ppm`) and prints the text screen. |
| `pausetest` | A0 acceptance in simulation, see below. |

Other options: `--status 14,57` (status bits at power on; 14 selects the
standard KERNAL, the default DolphinDOS has no tape routines),
`--status-ready 96` (bits set once READY is reached; 96 = Tape Auto Unload
off), `--kbuf 'LOAD\r'` (text put straight into the KERNAL keyboard buffer),
`--opl`, `--clk50`, `--no-cache`.
NTSC at power on (`--status 2` or `2,14`) automatically enables CLK_50M:
the selection crosses that domain before reaching the VIC. READY checks the
latched mode, not just the requested status bit. Clock-enabled snapshots
have a `-clk50` suffix and cannot reuse a PAL-only snapshot.

The state at READY is saved once per model variant and power-on status
(`ready-obj.state`, `ready-obj-nodrv.state`, `ready-obj-nodrv-14.state` in
the run directory; the model is built with `--savable`) and restored on
later runs while it is newer than the verilated model; `--no-cache` forces
a real boot.

### Pause equivalence test

Two instances of the core in lockstep, B is an exact copy of A at READY.
B opens the OSD with "Pause When OSD is Open" on (status[42], `OSD_STATUS`
high) at `--t0` clk_sys cycles, keeps it open for `--hold` video frames (PAL
or NTSC 6567R8) after the machine stopped, then closes it. For every
clk_sys cycle in which the machine runs (`c64_pause == 0`) both instances
produce one sample of C64-visible state:

- CPU address, data out, `ram_we`, `ram_ce`
- VIC-II RGB output
- CIA TOD 50/60 Hz source (`fpga64.todclk`)
- cassette `read`, `motor`, `sense`
- audio mix (`alo`)

The two streams must be identical sample for sample: B is A shifted by the
paused time, which must be a whole number of C64 cycles (32 clk_sys). The
test fails on the first differing sample and prints both values.

`sim/tests/pause.sh` runs idle, tape, chip and cartridge scenarios on DRIVES=0,
including NTSC (`--status 2`) and OPL with two- and three-stage FIFO crossings.
Results of A0, with the user pause of branch `pause` as the trigger:

| Scenario | Trigger | Pause | Result |
| --- | --- | --- | --- |
| READY idle loop | Pause/Break key | 78,621 C64 cycles | PASS, 2.65M samples (also on the full model with drives, unmounted) |
| READY idle loop | pad "Pause" button | 58,965 C64 cycles | PASS, 2.65M samples |
| KERNAL `LOAD` on a pilot-tone TAP (`scripts/mktap.py`) | Pause/Break key | 58,965 C64 cycles | PASS, 4.8M samples; during the pause A saw 206 cassette read edges with the motor on |

Negative controls (the test must fail without the fixes), built with
`BUILD_DIR=sim/build-neg RTL_OVERLAY=<dir> DRIVES=0 sim/build.sh`, where the
overlay directory holds the upstream file:

| Overlay (upstream 88354ba) | Scenario | Result |
| --- | --- | --- |
| `fpga64_sid_iec.vhd` (TOD source not gated) | READY idle, key | FAIL at the first sample after resume, bit 26 (`todclk`) |
| `c1530.sv` (player ignores the pause) | tape | FAIL at the first sample after resume, bit 27 (`cass_read`) |

### Savestates (WP A2)

```bash
sim/ss/run_tb.sh                   # pause/engine benches (GHDL and Icarus)
sim/tests/savestate.sh [--full]    # whole-core acceptance (sstest mode)
sim/tests/ssdiff.sh                # A3: CPU fields + ssdiff (LORENZ=dir adds Lorenz tests, DRIVE=1 the 1541 and 1581 LOADs)
sim/run_core.sh --nodrives ssdiff --status 14 [--ram-prg f.prg --kbuf 'RUN\r'] [--t0 C] [--t1 C] [--after C]
sim/run_core.sh --nodrives ssdiff --status 14 --ram-prg sid.prg --kbuf 'RUN\r' --rewind --running        # load while B runs
sim/run_core.sh --nodrives boot --status 14 --load-slot ready.ss --load-at 1500000                        # load right after power on
python3 sim/scripts/d64_prg.py Disk1.d64 outdir adcb   # PRG files out of a .D64
python3 sim/scripts/mkd64.py test.d64 TEST file.prg    # tiny .D64 with one PRG (1541 tests)
python3 sim/scripts/mkd81.py test.d81 TEST file.prg    # tiny .D81 with one PRG on track 39 (1581 tests)
sim/run_core.sh --nodrives boot --status 14,50 --prg f.prg --kbuf 'SYS2061\r' \
    --freeze-at 300000 --slot out.ss      # or --freeze-at '$E5CD' (PC)
sim/run_core.sh --nodrives boot --status 14 --load-slot out.ss --shot after.ppm
sim/run_core.sh boot --disk $PWD/test.d64 --kbuf 'LOAD"*",8\r' --run-cycles 40000000 --trace-drive
sim/run_core.sh boot --disk $PWD/test.d81 --kbuf 'LOAD"$",8\r' --run-cycles 80000000 --trace-drive
python3 sim/scripts/ss_slot.py out.ss     # header, TLVs, CRC (zlib); --fields CPU decodes a segment
```

`--freeze-at` takes clk_sys cycles after READY/PRG or `$ADDR` (the CPU
fetches the opcode at ADDR); the save goes through the OSD "Save state"
option to slot 1, `--slot` writes the slot image read back from the DDRAM
model. `sstest` is described in `sim/tests/savestate.sh` and
`docs/SAVESTATES.md`. `ssdiff` (B3 differential): two instances in lockstep,
B saves slot 2 at `--t0`, takes the OSD pause at `--t1`, saves slot 1, loads
slot 2, loads slot 1, saves slot 3 (must equal slot 1 byte for byte) and
resumes; its running samples (the pausetest sample) must equal those of the
uninterrupted A, so every live chain bit came back and nothing off the chain
was disturbed by the saves and loads. While the engine owns B, the registers
left off the chain as 'rebuilt' are checked against their fixed values.
A depends only on its own clocks, so it runs at most 1M samples ahead of the
comparison: while the engine holds B (a save with GeoRAM takes 38.6M clk_sys)
A waits instead of queueing its samples. `--t1` counts B's clocks, frozen
ones included, so it must lie past `--t0` plus the save time. The test
programs (`scripts/testprgs.sh`) include an EasyFlash CRT that erases and
programs its flash in a loop (`ef.crt`, A11) and a GeoRAM page writer
(`geo.prg`, status 52); with `--opl` the harness also prints how far B's
sound after its first load is from A's (level per 10 ms window, energy of
the difference: the measurement behind decision D9). `--slotphase` saves
C0/C1/C2 in manual slots, loads C1 then C0, and re-pauses after each load,
with `--gap` running clocks between the points, excluding engine and
video-alignment stops. The pause-release timeout stays at 2M clocks,
below the hardware watchdog, so a watchdog-only release fails the regression.
`--rewind --running` loads slot 2 while B runs (hotkey, or the OSD without
Pause When OSD is Open) instead of inside the OSD pause; `--repause` also
opens the OSD as the load ends, before the video-aligned resume, keeps it
open two frames and closes it. `boot --load-slot f.ss --load-at C` powers on
without READY and loads the slot from clk_sys C on, retrying once a frame
while the engine refuses it (reset, RAM erase).

Output sync monitor (`sync_mon`/`stop_mon` in `c64_tb.cpp`), armed in every
`ssdiff` (A and B), `sstest`, `pausetest`, `boot --load-at` and `boot` with
`--load-slot` or `--freeze-at` (from READY/PRG on; the D13 format 1 slot
loads, field snapshots; exit 1 on FAIL): on clk64 it
follows the core's `hsync_out`/`vsync_out` and the freezer outputs of the
video mixer, i.e. what the scaler and `video_calc` of `sys/hps_io.sv` get
(the core's sync, or the one `video_freezer` regenerates while
`HDMI_FREEZE` is high). Every hsync and vsync period must be the selected
VIC line (504/520 dots) and frame; `video_calc` is modelled on the
`CE_PIXEL` samples and must keep one active size (a frame of another size
restarts its 15-frame timeout, at the end of which `vid_nres` counts and
Main shows the video info). It also checks the VIC raster offsets
`video_sync` takes its stop position from, while the machine runs: hsync_out
rises at VIC X 407 PAL / 413 NTSC, vsync_out on VIC line 296 PAL / 12 NTSC,
`vic_y` steps only at X 404 PAL / 420 NTSC, the machine stops at X = 8n+6.
Every resume comes at most one frame after the release (the last fall of
`freeze` or `ss_frz_ack`, or an engine request: a paused machine runs to
its savestate boundary only on the video position, `ss_freeze` `run_ok`), a
stop that resumes on the VIC position it stopped on (plain pause, save, a
load of the same state) lasts whole frames, and the pause release watchdog
never fires. Each stop is
logged (`stop:`) with its length, loads and VIC position at the stop and at
the resume; the verdict is the `sync a:`/`sync b:` line.

Verification-hardening scenarios in the quick suite:

| Scenario | Check |
| --- | --- |
| `ntscsid`, `ntsccpu` | NTSC selected at power on (status 2), SID and a local Lorenz-style decimal ADC/SBC/flags loop. VIC 6567R8 uses 65 cycles/line and 263 lines (`video_vicII_656x.vhd`); `pause.sh` also checks its output sync and frame replay. |
| `c1282x`, `c1284x`, `smart3x`, `smart4x` | Status[47:46] selects C128/Smart and [49:48] selects speed. The CPU loop writes `$D030=1` to enable C128 turbo. `--turbo-check` requires accelerated CPU cycles both before and after the loads. |
| `reu-off`, `reu-on`, `crc`, `version`, `chain` | `--reject`: real REU configuration changed in both directions, or a slot header's CRC/version/chain length damaged. Check result 5/6/4 and OSD info 18/19/17, byte-identical chain/memory before and after refusal, then exact running samples against uninterrupted A. |
| `ntsc-from-pal`, `pal-from-ntsc` | `--reject video-standard --load-slot`: real slots produced by the opposite-standard run. Require exactly the NTSC configuration bit to differ, result 5/info 18, unchanged frozen chain/RAM and exact running replay. |
| `slotphase` | Change VIC phase by manual slot loads, then take and release pause again. `DRIVE=1` adds `slotdrive1581` with the same sequence during a 1581 LOAD. |
| `buildhash` | Only the saved build hash changes; the load must be accepted and replay exactly. Build hash is metadata, not a compatibility gate. |
| `mouse` | `--mouse` supplies varying 1351 movement packets every 8192 running clocks, independently in A/B. A PRG reads SID POTX/POTY through the CPU; both coordinates and the pot-noise LFSR must survive save/load. Host time spent saving does not advance the input timeline. |
| `paddles` | `--paddles`, Pot 1/2 = Paddles (status[27:26] = 2): all four writable host paddle lines vary every 8192 running clocks, independently in A/B. The same CPU POTX/POTY loop must write changing values to screen RAM before and after load; every running sample and the restored slot must match. |
| `mousefreeze` | `--mouse-freeze`: one nonzero 1351 packet arrives 128 hold clocks into B's first save, another 128 hold clocks into its final load. A receives each at the same running-clock timestamp. Requires exact running samples, changing CPU POTX/POTY reads before/after resume, completed operations and both packets delivered. |
| `opl`, `oplrewind`, `opl2`, `oplrewind2` | OPL replay with three- and two-stage FIFO pointer crossings. `--fifo-sync 0` selects the previous instantaneous model for diagnosis; READY caches are separate for each latency. |
| `rewindrun`, `rewindpause`, `ntscrewind`, `efrun`, `reurewind`, `vic856x`, `vicearly`, `poweron` | Output sync across a load to another VIC position: `--rewind --running` on the tape LOAD, NTSC sid.prg, ef.crt, reu.prg (REU 512 KiB) and sid.prg with VIC-II 856x / Early 856x (status 34/35 at READY); `rewindpause` opens the OSD pause right after the load; `poweron` loads the slot of the `ready` scenario right after a cold start. `DRIVE=1` adds `drive1541rw` (load while running, inside the 1541 file transfer). |

`ssdiff.sh` also runs `tb/dcfifo_tb.sv`: flag/count visibility in both clock
domains, showahead data, full/overflow, pointer wrap and asynchronous clear
at zero, two and three stages.

`ss/run_tb.sh` also runs the production `video_sync` in GHDL against a model
of the core's VIC raster timing (X steps on the clocks into C64-cycle
positions 0, 4, ..., 28, the raster line at X 404/420, the last line one
cycle later, hsync X 397-496, vsync on line 300/12, stop and resume on the
pause sample, X = 8n+6, the c64.sv release path). Output hsync/vsync
periods must stay one line and one frame across plain pauses (whole
frames) and loads to the middle of the frame, both sides of the VIC and the
counter frame wraps, X 398 (and 406/414/422 NTSC) where the dot counter and
the raster line step apart, the delayed last line, the last stop of the
frame, the same position and a load followed by a pause, with the
resume at most a frame after the release; after running PAL/NTSC switches
that leave the VIC outside the new frame a pause still resumes within a
frame.

The video-sync fix passed on the `savestates` base `147df01` (patch relative
to `4218dcb`) with `SDRAM=fast`: all unit benches, `savestate.sh`, 13/13
sample and video pause checks, quick `ssdiff.sh` 37/37, and `DRIVE=1`
`ssdiff.sh` 42/42 plus 15/15 sample and video pause checks. These include
the 1581 ring/manual phase reproductions and both real cross-standard slot
refusals. Quartus and board validation of this fix are separate from these
simulation results.

The DRIVES=0 suite before the phase/standard-load additions passed on
2026-11-07, together with the
complete `pause.sh`, `savestate.sh`, `ss/run_tb.sh` and quick `ssdiff.sh`.
NTSC video measured 520 dots/line and 136760 dots/frame (263 lines);
`ntscsid`/`ntsccpu` compared 4363978/4364106 running samples, and
`ntscrwback` replayed 2000000 samples after its last rewind. Both FIFO
latencies drained OPL replay in 21234 clocks (`opl`) / 12666 (`oplrewind`),
with zero register differences; worst 10 ms level errors were +0.1/-0.7 dB.

Mouse packets are live host input, not a replay queue (D3). In `c1351`,
the packet-toggle detector holds with `ss_hold`; a single packet received
during an engine freeze is applied once when ownership is released, to
the restored coordinates on a load. It need not wait for video-aligned
machine resume. `mousefreeze` keeps A 257 running samples behind B so it
can schedule A's matching packet without predicting the freeze boundary;
A's emulated clocks never count B's frozen time. Its load restores the
current paused snapshot: only the pending host movement is new, so exact
CPU-visible equivalence is expected. A frozen save does not include the
pending packet. Multiple packets within one uninterrupted hold are not
queued: an even number of toggle changes is lost, an odd number applies
only the last delta. This is a host-input sampling limit, not saved state.

## How the model is built (`sim/build.sh`)

All steps work on copies under `sim/build`; `rtl/`, `sys/` and `c64.sv` are
never modified.

1. **VHDL to Verilog.** `scripts/vhdl_fixups.py` (missing `when others`,
   `label: work.ent` without `entity`), then ghdl-yosys-plugin with
   `opt_clean` (flip-flops keep their VHDL names) for three tops:
   `fpga64_sid_iec` (CPU, VIC-II, buslogic, keyboard, palette; `dprom` is
   black-boxed via `sim/rtl/bb_dprom.vhd`), `video_sync`, `iecdrv_via6522`.
   Output in `sim/build/gen`.
2. **Verilog fixups** (`scripts/verilog_fixups.py`): initialized unpacked
   `wire` tables become `localparam`; `function f(wire x)` becomes `input`;
   block-local `reg x = 0;` initializers dropped (zero) or hoisted to module
   scope (non-zero); instances of GHDL modules get case-matched port names,
   lower-case module names and the VHDL default for unconnected `std_logic`
   inputs (T65 `BCD_en := '1'`). Two one-off patches in `build.sh`:
   `iecdrv_mem` `ram_init_file` becomes `$readmemh`, and one blocking
   `bank_no = 0;` in cartridge.v becomes non-blocking.
3. **ROMs**: every `.mif` is converted to `<path>.mif.hex` in the run
   directory (`scripts/mif2hex.py`).
4. **File list**: `sim/build/filelist.f` (full design) and
   `sim/build/filelist-nodrv.f`, reusable by other flows (e.g. the B7
   flip-flop inventory with `verilator --xml-only -f sim/build/filelist.f`).
5. **Verilator** `--x-assign 0 --x-initial 0 --savable`, `-O3`.

Simulation models in `sim/rtl`:

| File | Replaces | Notes |
| --- | --- | --- |
| `sim_clocks.sv` | `pll`, `pll_cfg`, `ltc2308_tape` | clocks are public regs driven by the harness; PLL reconfiguration accepted, never stalls; fixed PAL clock frequency even when the VIC is NTSC |
| `sim_hps_io.sv` | `sys/hps_io.sv` | same ports used by c64.sv, every output is a public reg written by the harness (status, joysticks, ps2_key, ioctl, SD) |
| `sim_video.sv` | `video_mixer`, `video_freak` | no scaler; uses the real `sys/video_freezer.sv` so `freeze_sync` keeps toggling while frozen |
| `sim_sdram.v` | `rtl/sdram.v` (default `SDRAM=fast`) | behavioral 32 MiB, same visible access latency; no banks or chip timing |
| `sim_mt48lc16m16.sv`, `sim_sdram_chip.vh` | external MT48LC16M16A2 (`SDRAM=real`) | real `rtl/sdram.v`, 4 banks, 8192 rows, 512 x16 columns, DQM, CAS=2, auto-precharge and timing/protocol checker |
| `sim_altddio_out.sv` | `altddio_out` | registered double-edge SDRAM clock output, inverted relative to clk64 as on the board |
| `sim_dprom.v` | `rtl/dprom.vhd` | `$readmemh("<INIT_FILE>.hex")` |
| `sim_altera.sv` | `scfifo`, `dcfifo` | behavioral; dcfifo has separate destination-clock pointer pipelines, three stages by default (`--fifo-sync 2` or diagnostic `0`) |
| `nodrives/iec_drive_stub.sv` | `iec_drive` | DRIVES=0 variant only |
| `bb_dprom.vhd` | | black-box entity for the GHDL step |
| `sim_public.vlt` | | signals of emu exposed to the harness |

Harness clocks: clk64 = 63.0559 MHz, clk_sys = clk64 / 2 with aligned
rising edges (31.52795 MHz, PAL), clk48 = 47.29193 MHz with `--opl`, and
CLK_50M with `--clk50` or NTSC at power on. clk48 is exactly 3/2 clk_sys (half periods 4:3 in
femtoseconds), as on the board where both divide the VCO of the core PLL: a
pause of whole C64 cycles keeps the phase of clk48. DDRAM is a C++ model in
the harness (sparse 64-bit words, random waitrequest, read bursts after a
latency, write bursts). Drive track cache traffic (the drive window, bytes
0x30000000-0x30FFFFFF) draws its waitrequest and latency from its own random
sequence that steps only on clocks where the drives run, and its read beats
arrive only then: a paused or saving instance sees the drive DMA exactly as
one that never stopped. The two instances of `pausetest`/`ssdiff` share the
host state at the fork. Slots are at word 0x05580000 + n * 0x2A0000 (DDR3
0x2AC00000, 21 MiB each, D13).

### Real SDRAM controller and chip checking

```bash
SDRAM=real DRIVES=0 JOBS=6 sim/build.sh
SDRAM=real sim/tests/savestate.sh
SDRAM=real sim/tests/pause.sh
SDRAM=real JOBS=6 sim/tests/ssdiff.sh
SDRAM=real LORENZ=<dir> VICII=<dir> JOBS=6 sim/tests/ssdiff.sh
sim/tests/sdram.sh                 # chip self-checks + RASCAS_DELAY=1 overlay negative control
```

`SDRAM=real` selects `obj-sdram-real` / `obj-nodrv-sdram-real`, including
separate READY caches. Set it on both the build and run commands.
`RTL_OVERLAY` also applies to `sdram.v`. Only the generated controller copy
is adjusted: Verilator 5.020 cannot lower procedural assignments of `Z`, so
its registered DQ output becomes a registered value and enable plus a
continuous tristate assignment. The controller state machine is unchanged.
The chip samples the physical command pins on SDRAM_CLK (the falling edge
of clk64), drives read data after two chip clocks and captures writes on
the WRITE command. Its public byte array retains the controller's unusual
address mapping: bit 24 selects the DQ lane, bit 23 column bit 8, bits
22:21 the bank, bits 20:8 the row and bits 7:0 the column low bits.
Harness RAM pokes mark the corresponding bytes initialized; ioctl CRT,
REU and TAP transfers still pass through the controller. The savestate
transfers of D13 (256 consecutive BL=1 columns of one row) need two READs
in flight (one per clock, data two clocks later) and a row open for 4.1 us:
the model keeps up to two READs pending and checks tRAS max (120 us).

Timing comes from [Micron 256Mb SDRAM, Rev. W (05/15), tables 12–13 and
the initialization/auto-precharge sections](https://www.alliancememory.com/wp-content/uploads/Micron_256M_SDRAM_PartNo.MT48LC16M16A2.pdf).
The checker uses the conservative -75 limits (covering the -6A/-7E
limits below), at 63.0559 MHz / 15.859 ns per clk64. Minimum delays round
up to clocks; the 64 ms refresh deadline rounds down.

| Parameter | -6A | -7E | -75 used | clk64 |
| --- | --- | --- | --- | --- |
| tRCD / tRP | 18 ns | 15 ns | 20 ns | 2 |
| tRAS min | 42 ns | 37 ns | 44 ns | 3 |
| tRC | 60 ns | 60 ns | 66 ns | 5 |
| tRFC | 60 ns | 66 ns | 66 ns | 5 |
| tWR, explicit precharge | 12 ns | 14 ns | 15 ns | 1 |
| tWR, auto-precharge | 1 clk + 6 ns | 1 clk + 7 ns | 1 clk + 7.5 ns | 2 |
| tMRD | 2 clk | 2 clk | 2 clk | 2 |

The checker counts bank-state errors, the timings above, tRAS max, unsupported
mode settings and commands before PRECHARGE ALL, mode programming and two initial
AUTO_REFRESH commands have completed. Refresh retention uses a rolling
8192-refresh/64 ms window: legal burst refresh is not rejected just because
a gap exceeds the uniform 7.8125 us average. Every chip clock contributes
to the longest refresh gap, including clocks during an unfinished gap.
The first 16 violations include clk64, nanoseconds, command, bank, row,
address and `ss_sd_own`; summary totals, per-rule counts, clocks, refreshes,
longest gaps and unwritten reads are split into `normal` and `engine`.
`normal` means `ss_sd_own=0`, including pauses; `engine` means ownership
is asserted, whether the engine is accessing SDRAM or waiting for DDR3.
Counters are part of READY snapshots, so summaries include boot history.
An unwritten byte reads as zero and is information, not a violation; both
DQ lanes are counted when unmasked, even if the controller selects only one.
Any protocol/timing violation makes the harness exit unsuccessfully.

`sdram.sh` checks all banks and both DQ lanes, write masking, two-clock
read masking, CAS latency and auto-precharge in a small chip bench. It
deliberately violates tRCD and suppresses refresh, asserting the respective
engine-owned counters. It then builds a throwaway real controller with
`RASCAS_DELAY=1` through `RTL_OVERLAY` under `sim/build/sdram-check` and
requires a nonzero tRCD count from a bounded cold boot of 18 frames (the
power-on REU fill of D13, engine-owned, takes the first ~14.5); failure to
reach READY alone is not accepted as proof. Synthesized sources are untouched.

Negative-control result (2026-11-06): chip data-path checks PASS; one
engine-owned tRCD violation and one engine-owned refresh-deadline violation,
both asserted by the bench. The RASCAS_DELAY=1 overlay produced 143,603
normal-running tRCD violations and zero engine-owned violations (no save
in that cold boot). The first was READ at clk64 1,258,009 / 19,950,694.54 ns,
bank 0, row 0x00ff, pin address 0x0400. The overlay is not production RTL.

Negative-control result (2026-11-15, D13 final RTL): chip checks PASS; the
overlay produced 328,119 normal tRCD violations; the engine-owned power-on
fill (9,118,336 clk_sys) had none (133,923 refreshes, longest gap 456
clk64 / 7231.68 ns).

Real-controller acceptance (2026-11-07, `DRIVES=0`, `JOBS=6`):

| Run | Scenarios | Result | Normal violations | Engine violations |
| --- | --- | --- | --- | --- |
| `savestate.sh` | save/load and OSD self-test | PASS | 0 | 0 |
| `pause.sh` | all 11, including tapevar, REU, EasyFlash, GeoRAM and OPL | ALL PASS | 0 in every scenario | 0 (no engine ownership) |
| quick `ssdiff.sh` | 15 differentials + 6 field snapshots | PASS | 0 in every scenario | 0 in every scenario |
| long `ssdiff.sh`, Lorenz + VIC-II | 53 differentials (15 quick + 29 Lorenz + 9 VIC-II), 6 field snapshots | PASS | 0 in every scenario | 0 in every scenario |

All 92 scenario logs contain checker summaries. The longest refresh gap in
every normal bucket was 256 clk64 (4059.89 ns, including cached boot);
every engine-owned savestate bucket was 64 clk64 (1014.97 ns).
No production-controller violations were found. The GeoRAM scenario checked
rebuilt registers on 220,165,927 frozen clk_sys cycles across its save/load
sequence. Logs: `sim/build/run/sstest.log`,
`sim/build/run/pause_*.log`, `sim/build/sdram-quick/*.log`,
`sim/build/sdram-long/*.log`; negative controls in `sim/build/sdram-check`.
Full-drive and NTSC real-controller scenarios were not run.

## Numbers (4 vCPU cloud container)

| | Full model | DRIVES=0 |
| --- | --- | --- |
| VHDL conversion | ~5 s | same |
| Verilator + C++ build, `-j4` | ~35-60 s | ~35 s |
| Speed | ~87k clk_sys/s = ~2.7k C64 cycles/s | ~160k clk_sys/s = ~5k C64 cycles/s |
| Power on to READY, DolphinDOS (568k C64 cycles) | 3.5 min | 1.9 min |
| Power on to READY, standard KERNAL with RAM test (2.24M C64 cycles) | ~14 min | 7.5 min |
| pausetest (two instances in one thread) | | ~84k clk_sys/s per instance |

One second of C64 time costs ~6 min with drives, ~3.3 min without. The
READY snapshot removes the boot from every later run; a cold boot now
starts with the power-on REU fill (D13, ~9.1M clk_sys, ~1 min DRIVES=0). About
40% of the full model's time is spent in the four drive instances even when
nothing is mounted (gprof, `PROFILE=1 sim/build.sh`). `kill -USR1` on a
running harness prints clk_sys and frames of each instance (a slow run or a
hung one). On a loaded host the speed drops a lot: 2026-11-14, with the
other acceptance runs on the same 14 CPUs, ~21k clk_sys/s DRIVES=0.

## Known limitations

- NTSC VIC geometry is exercised, but PLL reconfiguration does not change
  the harness's PAL clock frequencies: real NTSC clock rate/PLL transients
  and mixed-clock timing at that rate remain untested.
- Mouse packets are not queued during an engine freeze; the single-packet
  save/load cases are covered, but multiple packets can coalesce as described
  above. Physical paddle/USB transport timing is outside the host model.
- `pausetest --load-slot` with the pause soon after the load (`--t0
  300000`): the running samples of A and B are compared exactly (PASS), but
  the pause checks around them are not clean. A load to another VIC
  position resumes up to a frame after the release (`video_sync`), so the
  pause request at t0 can come while B still waits for that resume and the
  counted pause takes in the tail of the load's stop: "FAIL: paused time is
  not a whole number of C64 cycles" (A12 model, and D13 after the merge of
  the load sync fix, 2026-11-16; D13 before it: "FAIL video: 504/169344
  dots per line/frame"). A t0 past the resume (more than a frame) avoids
  it. `pausetest --sync-check --t0 300000` can likewise take the pause in
  the first recorded frame ("FAIL video: pause not found in the
  recording", the video check needs a frame before the pause).
- The default SDRAM model does not check chip timing; use `SDRAM=real`.
  The command-level model covers this controller's BL=1, CAS=2 operation,
  not arbitrary bursts, power-down or self-refresh (unsupported commands
  are violations). It is a two-state digital model: no analog setup/hold,
  board skew, DQ contention voltage, retention decay or temperature effects.
  Power rails and the initial 100 us power-up delay are assumed settled
  before the simulated interval; board power-up/PLL-lock sequencing is not
  verified. PRECHARGE ALL, mode programming and two initial refreshes are checked.
  Pad and board timing are invisible to it: the first D13 transport read one
  column per clk64 with 0 violations in every scenario and still saved
  corrupted bytes on the board (bits of the next column at the capture edge
  of the DQ input register, 2026-11-14); only the board shows where the
  capture window of `sdram.v` ends (a board test of a known memory pattern).
- Drives read disks from the DDR3 model or, for the 1581, from the SD
  block interface: `--disk file.d64|.g64|.d81` puts the image on drive 8 at
  power on as Main 20261010 does (D64 synthesized to G64 at DDR3 0x30000000,
  a D81 kept as a file with extension index 3, so the drive is a 1581;
  `img_mounted` pulse), so the DOS and the mount sequence are done at READY
  (the READY snapshot is kept per disk name). A DolphinDOS `LOAD"*",8` typed
  at READY lights the drive LED ~18.7M clk_sys later and has the head on
  track 17 of `a8.d64` at ~20.6M. On `a10.d81` (`mkd81.py`) the 1581 spins
  up, steps from ~53.6M (one track per ~189k clk_sys), is on the directory
  track 40 at ~60.8M and reads its 10 sectors from ~62.5M to ~68.6M; a
  DolphinDOS `LOAD"$",8` ends at ~77M. The 1581 asks for 512-byte sectors
  (`sd_blk_cnt` 1, two 256-byte blocks): the harness serves them from the
  file and keeps the writes in an in-memory copy, with a host latency and a
  byte pace that count only clocks where the drives run (like the drive DDR3
  traffic). `DRIVE=1` adds the 1541 and 1581 scenarios to `pause.sh` and
  `ssdiff.sh` (full model, hours per run). 1541 write-backs to the SD
  (`sd_wr`) are acknowledged and dropped; D71 is not served. Full model
  only. Smoke: Lorenz `Disk1.d64`, `LOAD"$",8` under DolphinDOS ends in
  `LOADING` / `READY.`; `--trace-drive` prints the drive 8 LED and head
  moves with their clk_sys, and the SD sector transfers of a D81.
- OPL3 clock domain (clk48) is off by default; with `--opl`
  the READY snapshot is separate per FIFO latency. The FIFO models digital
  pointer visibility delay, not metastability, Gray-bus skew, or Altera's
  asynchronous-clear deassertion synchronizers. `--fifo-sync` specifies
  effective destination-clock stages, not the megafunction's encoded
  `rdsync_delaypipe`/`wrsync_delaypipe` parameter values. `ssdiff --opl` compares the audio up
  to B's first load (after it the OPL plays from the replay,
  `docs/SAVESTATES.md`) and checks the replay instead, with a model of the
  queue the FM firmware reads (fed from the dcfifo read pointer): B's queue
  consumed and the OPL output back within one frame, at that point the
  registers and the index latch the firmware took equal B's shadow and index
  register, and at the end the register files of A and B are equal. With
  `--rewind` (`oplrewind` in `ssdiff.sh`) the same checks follow the load of
  the older state.
- No HPS RTC: `RTC` is a fixed date.
- The harness counts frames on the core's VSYNC, which stops while the
  machine is paused; pause durations are counted in clk_sys cycles.
- The screenshot is taken from the core's pixels (no scaler); it is the
  C64 picture with borders, 382x270 for PAL.
