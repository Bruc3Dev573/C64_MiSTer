# Machine stop and OSD pause

The stop of the machine that the savestates use, and the upstream OSD
option **Pause When OSD is Open** on top of it (work package A0 of the
savestate plan). This branch has no pause button: the pad **Pause** button,
the keyboard **Pause/Break** key and the Pause Dim Video and Pause Mute
Audio options of A0 are not part of it.

## Using it

| Control | Effect |
| --- | --- |
| OSD > Hardware > **Pause When OSD is Open** | As upstream: the machine stops while the OSD is open and HDMI holds the last whole frame; the analog output keeps its sync and shows the last frame |

## How it works

`freeze` (clk_sys) follows `OSD open & Pause When OSD is Open`, as upstream,
and changes only on `freeze_sync`, i.e. on a frame boundary of the scaler,
so HDMI holds a whole frame. `fpga64_sid_iec` stops the machine on the
refresh cycle (`sysEnable` low, `sysCycle` held at `CYCLE_EXT4`); its
`pause_out` (`c64_pause`) holds the 1541/1581 drives, `video_sync` and the
blocks of "Leaks closed". The savestate engine stops the machine through the
same pause input (`ss_freeze`, `docs/SAVESTATES.md` "Freeze"). A save or a
load stops it for 2-3 frames, and up to ~0.6 s for a save of a full 16 MiB
REU (D13).

### Picture and sync while stopped (analog output)

HDMI keeps a frame in the scaler, but the analog output comes straight from
the core, and the VIC stops with the machine. So while stopped:

- `video_sync` keeps its dot and line counters running with the active VIC
  geometry: PAL 6569 is 504x312 dots, NTSC 6567R8 is 520x263;
- `pause_fb` (rtl/pause_fb.sv) records the VIC color index of every visible
  dot while the machine runs (4 bits x 382x270 PAL / 404x250 NTSC, ~51 M10K)
  and plays it back on the same dots while stopped, through the same
  palette. The dots after the stop point hold the previous frame, the ones
  before it the current one: what the screen showed.
- The machine resumes only when the free-running position is back on the
  position of the stopped VIC (`resume_ok`, at most one frame after the
  release), so the VIC continues exactly where the output is: no sync jump
  on resume. The fallback watchdog releases after 4,194,303 alignment-wait
  clocks (~133 ms PAL); that fallback can jump the sync and is not normal
  alignment.

While `HDMI_FREEZE` is high (OSD pause, savestate operation) the
freezer of `sys/video_mixer.sv` blanks the picture and regenerates the sync
it measured before; `pause_fb` shows on the output, and goes into the scaler,
in the stopped clocks without it, e.g. the realignment wait after a release.
`HDMI_FREEZE` changes only on a frame boundary of the scaler (`freeze_sync`),
for the OSD pause and for a savestate operation alike: the savestate part
(`ss_hdmi_frz`) follows `ss_frz_ack` on the next `freeze_sync` toggle. When the
savestate part followed `ss_frz_ack` at once, a release mid-frame let ascal
take the frame it was writing as complete, and HDMI showed one frame whose
top lines came from an old buffer (on the board: 5 of 22 saves and loads on one
build, 0 of 28 with the fix).

The position of the stopped VIC comes from its raster counters, through
read-only taps (`vic_x`/`vic_y` of `fpga64_sid_iec`: rasterX, and rasterY
with the delayed step of the last line to line 0 applied), on every dot
while stopped. The machine stops one pixel after the last running dot (X =
8n+6); the dot counter is 0 at X 397 (the VIC hsync), the line counter steps
there and the raster line at X 404 PAL / 420 NTSC, line 0 of the counter
starts on raster line 300 PAL / 12 NTSC (the VIC vsync). For a plain pause
that is the position the counters hold, so the pause is unchanged. A
savestate load moves the VIC to the saved position and the target moves
with it: the machine resumes when the free-running output reaches the
loaded position, at most one frame after the engine releases it, and the
sync stays continuous (slot loads, the OSD self-test). Until
the fix of 15 November the target stayed on the stop before the load: the
loaded VIC's first hsync and vsync came at another phase, one irregular line
and frame, so the scaler resynchronized and `video_calc` in `sys/hps_io.sv`
saw a frame of another height (e.g. 382x540) and reported a new resolution
15 frames later (Main showed the video info on every load with
`video_info`). The offsets hold while the machine runs, for both standards
and every VIC-II menu variant (the menu changes NMOS/HMOS color-register
behavior only); the sim checks them on every line and frame (sim/README.md,
output sync monitor).

The dot divider (`clk_cnt`) follows the rising edges of the VIC hsync only
while the machine runs. A save or a load shifts the VIC hsync (on the chain)
through the bits of its neighbours; the divider used to restart on each of
those edges, ran up to twice as fast during the shift and the free-running
output gained 40-100 dots per operation: the stop was not whole frames and
the first line after the resume was 2-26 clk_sys off.

A save or load requested while the machine is stopped away from a savestate
boundary (OSD pause, or the realignment wait after a release) lets the
machine run to the next boundary for a few cycles (`ss_freeze`). That run
starts only on the sample after `resume_ok` (`run_ok` of `ss_freeze`,
`ss_run_ok` in c64.sv), when the free-running output is on the stopped VIC,
so it needs up to one more frame and the output does not jump. Until 15
November it started at once: the output jumped back by the time the machine
had been stopped (modulo a frame), which the scaler saw when the pause ended
(the freezer's regenerated sync and the core's sync no longer matched).

The counters wrap at the active geometry; a running video-standard change
normalizes old coordinates outside the new frame (a stopped VIC position
outside it gives a valid target too). The mode input is the same
synchronized `ntsc` that drives the VIC, not the OSD request before PLL
reconfiguration. Old NTSC (512x262) and PAL-N mode inputs are tied off in
`fpga64_sid_iec`.

A normal pause is therefore a whole number of frames long. The sim
pausetest checks the output: hsync and vsync periods constant across the
pause, every paused sample equal to the one a frame earlier, the output after
the resume equal to the unpaused run shifted by the pause. The output sync
monitor of the harness also checks every save and load.

## Leaks closed

Blocks that kept running while the machine was stopped, so a pause shifted
them against the CPU:

| Block | Was | Now |
| --- | --- | --- |
| CIA TOD 50/60 Hz source (`fpga64_sid_iec`) | accumulator on free `clk32` | advances only while `sysEnable = 1` |
| C1530 player (`c1530`, via `tape_subsystem`) | pulse timers, motor momentum, FIFO reads on free `clk32` | new `ce`, gated by `c64_pause` |
| OPL3 timers (`opl3`, clk_sys) | free running | clock enable from `~pause` |
| OPL3 Z80 + sequencer (`opl3sw`, clk48) | free running | pause synchronized to clk48; 44.1 kHz strobe stops; Z80 held in WAIT through CE. A9: the sequencer finished the sample in progress while paused (its output and operator state moved during the pause, and a Z80 register update in progress could land in another sample), the Z80 clock enable restarted on a fixed phase, the mix took the clk48 output on every clock (a sample change in the clocks between the machine stop and the clk48 stop showed up early), and a reset of the Sound Expander while paused (switched off and on in the OSD) never reached the Z80, which samples RESET only on a step (the firmware then polled a sequencer held in reset forever). Now one clock enable from the synchronized pause holds all of clk48 (sequencer and sampler mid-sample, both RAM ports, the 44.1 kHz strobe, the Z80 on its enable phase), a reset is kept for the Z80 until its next step, and the mix takes the OPL sample once per running C64 cycle (DMA0); `pause.sh opl` is sample-identical with the OPL in the audio |
| EasyFlash flash chips (`am29f040`, `ez_rom`) | `busy_cnt` held; command/SDRAM write-back state on free `clk32` | whole state holds while `pause` (savestate WP A7) |
| REU (`reu`) | DMA state machine stepped between its `dma_cycle`/`ram_cycle` waits: one step ahead at the resume, the DMA data bus differed for one sample | holds while `c64_pause` (WP A7, found by `pause.sh` reu) |
| Cartridge logic (`cartridge`) | bus-strobe edge detectors, freezer, Epyx capacitor counter on free `clk32` | holds while `pause` (WP A7) |
| SID table/filter pipeline (`sid_top`, `sid_filter`) | 16 steps after ce_1m on free `clk32`: output samples updated during the pause | holds while `not sysEnable` (WP A6) |
| PCF8583 RTC on the cassette port (`rtcF83`) | internal time base on `drive_ce`; I2C side and the `use_rtc` timeout on free `clk_sys` | `drive_ce & ~c64_pause`; I2C side and timeout hold while `c64_pause` (WP A7) |
| Tape counter (`tape_counter`) | 1 kHz tick on free `clk_sys`: the counter (and the auto-unload near the end) moved during the pause | holds while `pause` (WP A7) |
| `use_tape`, disk activity (c64.sv) | 4 s / 0.5 s timeouts on free `clk_sys` | hold while `c64_pause` (WP A7); the disk activity detector on `c64_pause` one clock later (`drv_pause`), the clocks where the drives hold (WP A8) |
| Drive clock enable (`drive_ce`, c64.sv) | fractional divider on free `clk_sys`: the drives' 8-tick divider kept counting, so a pause shifted the drives against the C64 | divider holds and `drive_ce` is 0 while `c64_pause` (WP A7); the A0 gate of the drives (`ena`, `drv_run` in `c1541_multi`) is redundant and removed (WP A8) |
| 1541 drives (`c1541_multi`, `c1541_drv`, VIAs, T65, `c1541_track`) | logic on every clock kept running: VIA edge detectors, port input and read registers, T65 SO sampler, IEC synchronizers, ROM fetch, head stepper, the 500 ms write-back timer (counted the pause), track cache dispatch and its synchronizers; the GCR noise LFSR and its reload values stepped on every clock | hold on `c64_pause` delayed by one clock, the clocks where `drive_ce` is 0 and the C64 holds from EXT5 (pending ph2 pulses wait in their registers); noise LFSR on the drive clock enable; no new DDR3 request while stopped (WP A8) |
| 1581 drives (`c1581_multi`, `c1581_drv`, 8520, VIA, T65, WD1772 `fdc1772`, `floppy`) | the A0 gate (`ena`) stopped only the ph2 and 8 MHz pulses; logic on every clock kept running: 8520 edge detectors, TOD input and IRQ path, WD1772 bus edge detectors and sector request handshake, the floppy step, spin-up and rotation counters, IEC synchronizers, ROM fetch | hold on `c64_pause` delayed by one clock like the 1541 (pending ph2 and 8 MHz pulses wait in their registers); the A0 gate is removed; the ROM fetch repeats while stopped; sector requests reach the host only while the drive runs, so a pause starts no SD transfer (one the host made during the pause is taken, or repeated, when the drive runs again) (WP A10) |
| 1351 mouse noise (`c1351`) | pot LSB LFSR on free `clk_sys` | holds while `c64_pause` (WP A7) |
| Analog video (`video_sync`) | sync stopped with the VIC (black / no signal) | sync keeps running, last frame replayed from `pause_fb` |
| Output dot divider (`video_sync` `clk_cnt`) | restarted on every rising edge of the VIC hsync, also while a save or load shifted the VIC hsync through the chain: the free-running output gained 40-100 dots per operation | follows the VIC hsync only while the machine runs (15 November); the stopped position comes from the VIC raster, so a load moves it |

The pause lengths are whole multiples of the 32-clock C64 cycle (sysEnable is
re-evaluated once per cycle at `pred(CYCLE_EXT4)`), so every gated block sees
exactly the clocks it would have seen without the pause: a run with a pause of
N cycles must be the uninterrupted run shifted by N. This is the simulation
acceptance of A0 (`sim/tests/pause.sh`, with the OSD pause in this branch).

## Known limits

- The RTC still takes its initial time from the HPS. A virtual clock that is
  saved in the savestate is part of A7.
- RS-232 (UP9600 / VIC-1011) and external IEC devices are real-time links: data
  that arrives while paused is lost, as on real hardware with the CPU stopped.
