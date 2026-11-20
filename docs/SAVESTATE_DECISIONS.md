# Savestate: decisions

Decisions that change the plan ("Piano savestate e pausa per C64_MiSTer").
Each one has a date, the data it is based on and what it changes.

## D1 - Full scope, resource budget raised to ~80% ALM (2026-11-01)

**Data.** First CI compiles (Quartus 17.0.2 Lite, DE10-Nano 5CSEBA6):

| Build | ALM | M10K | Worst setup slack |
| --- | --- | --- | --- |
| Upstream `88354ba` | 28,052 / 41,910 (67%) | 431 / 553 (78%) | +0.465 ns |
| `pause` | 28,100 / 41,910 (67%) | 431 / 553 (78%) | +0.369 ns |

The plan assumed the core at 50-55% and set "ALM below 70%" for the full
savestate. With the estimated 4-7k ALM for engine, chain and muxes the
core lands around 77-84%.

**Decision.** Keep everything in the savestate: two 1541, two 1581, REU,
GeoRAM, EasyFlash, OPL3, tape, RTC. No reduced "savestate build" and no
module left out: a partial state is a source of bugs on load.

**Changes to the plan.**
- Definition of done, Savestate v1 / complete: "ALM below 70%" becomes
  "ALM around 80% or less, timing closed without seed tricks".
- Risk table: the fallback "REU and GeoRAM out of v1, OPL3 replay forever"
  is no longer an option for resources.
- M10K (78% today) is the tighter resource: the engine must not add block
  RAM buffers beyond the minimum (the scan chain needs none; region copies
  stream directly to DDR3).
- Every chip WP reports its ALM/M10K delta in the PR (CI step summary);
  above ~80% ALM, or when timing stops closing, stop and re-plan before
  merging more state.

## D2 - Cartridge memory in the slot, 8 MiB slots (2026-11-01)

**Decision** (delegated by the user). The slot holds the cartridge memory
that lives in SDRAM and that programs can change: the cartridge RAM banks
(0x010000, 64 KiB, with a CRT attached), the EasyFlash flash (0x200000,
1 MiB, with an EasyFlash CRT), GeoRAM (4 MiB) and the REU. The CRT hardware
type and the System ROM (KERNAL) selection join the config mask, so a slot
of another cartridge type or KERNAL is refused. Whole regions are saved (no
dirty bitmap) and the slot grows to 8 MiB to hold them.

**Changes (done in A2).** `savestate/map.yaml`: `slot_bytes: 0x800000`,
regions CART_RAM (0x13) and CART_FLASH (0x14), config mask `kernal` and
`cart_type`, payload header `chain_bits`. CONF_STR `SS3E000000:800000`;
self-test scratch slot moved to 0x3D800000; drive cache writes into
0x3D800000-0x3FFFFFFF dropped. Times: GeoRAM ~1.1 s, EasyFlash ~0.27 s per
save. **Left:** the 16 MiB REU still does not fit (needs ~17 MiB slots, WP
A7); the ROM of non-EasyFlash cartridges is not in the slot (same type with
another .CRT file is not detected); bank registers of the cartridge come
with the CART segment (A7).

## D3 - Keys released on load (2026-11-01)

**Decision** (delegated by the user). After a load every key is released:
no key stays stuck from the moment of the save or the load. The C64-side
state (CIA ports, keyboard scan) stays as saved.

**Changes (done in A2).** `ss_load_done` pulses the keyboard reset of
fpga64 (`kbd_reset`), which clears the PS/2 key matrix. Joystick and paddle
lines are live host inputs, nothing is latched.

**A7.** Since the load clears the matrix anyway, the PS/2 key matrix
(fpga64_keyboard: keys, modifiers, the shifted-key delay) and the
joystick-to-key macros of c64.sv (host input typed as key events) are not
on the chain: `state_classes.yaml` marks them as host input with this
reason. INPUT carries only the 1351 mouse (position and the pot noise LFSR,
29 bits).

## D4 - No ALM ceiling, timing must stay positive (2026-11-02)

**Decision** (user). The core is experimental and will never go to
MiSTer-devel: the ~80% ALM limit of D1 is lifted. What stays: worst setup
and hold slack positive on every clock, without seed tricks. Quartus 17.0.2
and the simulations run locally.

**Changes.** D1's "stop and re-plan above ~80%" becomes "stop and re-plan
when timing stops closing". Every chip WP still reports its ALM/M10K delta.

## D5 - Savestates follow the file loaded from the OSD (2026-11-03)

**Data** (board test, Main source `user_io.cpp`). Two gaps, both found
on the board because no slot file ever reached the SD:

- Main reads the `SS<base>:<size>` token only from the second CONF_STR
  field, comma separated with `UART`. The core had it in a field of its own,
  so Main saw no savestate area at all (`ss_base = 0`).
- Main maps the four slots, reads them from the SD and writes them back only
  after a file is loaded through an `FS` option (`opensave`). The core had
  `F1`. Disk images are mounted (`S0`, `S1`), which never calls `process_ss`.

Until then the slots lived in DDR3 only (they survive a core reload,
measured, but not a power cycle).

**Decision.** CONF_STR `C64;SS3E000000:800000,UART9600:2400;` and `FS1`:
PRG, CRT, REU image and TAP loads name the slot files
(`savestates/C64/<file>_1.ss` ...). With only a disk mounted the slots stay
in DDR3 for the session; naming them after a mounted image needs a change in
Main, which the plan excludes. Documented as a limit.

**Board result (A4 rbf with the fix, Main 260923, `debug=2` log).** Main now
reads the area (`Got save state parameters: base=0x3E000000, size=0x800000`),
but still writes no slot file: for a core named `C64` Main sends every `F`
file through `c64_open_file()` (`support/c64/c64.cpp`, EasyFlash save
handling), which calls `user_io_file_tx(name, index)` without `opensave`, so
`process_ss()` never runs. No CONF_STR change reaches it while the core keeps
the name `C64` (renaming it would drop the EasyFlash write-back and move the
games, config and savestate folders). Slot files need a one-line change in
Main (`c64_open_file` passing `opensave` on to `user_io_file_tx`), outside the
plan: open with the user. The CONF_STR stays as above, it is what such a Main
needs; until then the slots live in DDR3 (core reload survives, power cycle
does not).

**Update, same day: modified Main.** As for the MegaCD and PC Engine CD
savestate cores, the core comes with its own Main: branch `c64-savestates` of
`Bruc3Dev573/Main_MiSTer`, official Main 20261010 (`738cb7a`) plus commit
`a595fb1`:

- `c64_open_file()` passes `opensave` on to `user_io_file_tx()`, and calls
  `process_ss()` itself for an EasyFlash CRT (that path never reaches
  `user_io_file_tx()`).
- A disk mounted in drive 8 names the slot files too
  (`savestates/C64/<disk>_1.ss` ...), as Main already does for Apple-II.
  Drive 9 does not, so a second disk does not move the slots.

Loading a file or mounting a disk clears the four DDR3 slots and reads the
files of the new name, as for every core with an `SS` area. Built with the
official toolchain (gcc 10.2-2020.11), installed per core with
`[C64]` / `main=MiSTer_C64_SS` in `MiSTer.ini`. On the board: slot files
written for the PRG (`sstod_1.ss`, `sstod_2.ss`, well formed), slot 1 loaded
back after a reboot of the board, `Disk1_1.ss` written with only a D64
mounted.

## D6 - 1541 track buffer in the slot, disk image as media (2026-11-03)

**Data.** The plan (A8) reloads the current track from the DDR3 image after
a load and holds the drive until the buffer is full. The track buffer
(`c1541_direct_gcr`, 8 KiB per unit) also holds the head writes that the
drive has not written back yet: the write-back to DDR3 comes on a head step,
on motor off or 500 ms after the last write, so a save inside that window
has data that exists only in the buffer.

**Decision.** The buffer is a slot region (TRACK_DRV8/9) and the track cache
state (track in the buffer, G64 offset, pending reload, write-back edge
detector) is on the chain. A load restores the buffer exactly: no DDR3
refill, no drive hold, no watchdog, no dependency on DDR3 timing. Cost:
16 KiB per slot, ~1.5 ms per save. The image itself stays media (as the
tape): not in the slot, a load needs the same image mounted. The queue of
DDR3 tracks not yet copied to the SD file is host side and never reset by a
load. Each mount gets an identity; a load whose slot has another one drops
the saved write-back and reloads the track from the mounted image, so the
saved buffer is never written into another image (also the same image
mounted again, e.g. after a reboot: then only the head writes of the save
still in the buffer are lost).

**Changes.** `docs/SAVESTATES.md` ("1541: track buffer and disk image"),
regions TRACK_DRV8/9 always present, `c1541_track` and `c1541_drv`
(`mount_id`, `ss_mount_id`, `remount`).

## D7 - OPL3 register shadow as a region, replay of the registers that differ (2026-11-04)

**Data.** The plan (A9) puts a shadow of the OPL registers on the chain
(words 91-95) and replays it after a load, as the MegaCD `fm_savestate`. In
this core the Sound Expander has a C64 side in clk_sys (index register,
timers, status) and an FM part on clk48 (NextZ80 firmware with 8 KiB RAM,
the register queue from the C64, the sample sequencer). The C64 reaches one
bank of 256 registers (`addr[1]` is tied to 0): on the chain the shadow
would be 2048 flip-flops with their muxes, as a memory it is 256 bytes.
After a reset the firmware boots for 11.6 ms (simulation) before it takes
its queue.

**Decision.** The C64 side is segment OPL3 (117 bits, exact). The shadow is
a 256-byte memory in `opl3.sv`, saved as region OPL3_REGS (tag 0x12,
present with the Sound Expander on); a second 256-byte copy, `fmreg`, holds
what the FM part has or will take from its queue. On `ss_load_done` the
registers where the loaded shadow differs from `fmreg` are queued into the
running FM part (from $C0 round, so the key-on registers come last), then
the saved index; the machine and the next savestate operation wait the 1025
clocks this takes. The FM registers are those of the save once the queue is
taken (0.67 ms after the resume in the ssdiff scenario); envelopes and
phases go on from the state before the load. A first version reset the FM
part and replayed the whole shadow (the sound then depends only on the
slot): every load left 12 ms or more of silence and restarted every note
from its attack. A load queues two entries per register
that differs (the OPL2 bank has ~120 registers that programs use), so the
replays of two loads made while paused fit in the queue (1024 entries). The
FM part stays out of the slot (regions OPL3_RAM and OPL3_FIFO now stage
full); A11 decides whether it gets serialized (D9: it does not).

**Changes.** `savestate/map.yaml` (OPL3 in 3 words, OPL3_REGS), `opl3.sv`,
`opl3fm.sv` and `opl3seq.sv` (clk48 holds exactly with the pause,
`docs/PAUSE.md`), `c64.sv` (engine hold and request manager busy during the
replay, OPL sample taken on the C64 cycle grid), opl.prg in `pause.sh` and
`ssdiff.sh`; `docs/SAVESTATES.md` ("OPL3: register shadow and replay").

## D8 - 1581: sector buffer in the slot, D81 image as media, sector requests held with the drive (2026-11-04)

**Data.** The plan (A10) lists "FDC and 8520 state, 8 KiB RAM, track". In
this core the 1581 has no track cache: the WD1772 model (`fdc1772`) asks the
host for one 512-byte sector at a time over the SD block interface and keeps
it in its 1 KiB buffer (the FIFO); the floppy model only times the rotation
(which sector header passes under the head) and the head steps. The host
serves a request in real time, also while the machine is stopped: with the
request handshake held as the rest of the drive, a request left visible
during a pause makes Main transfer the same sector again and again until the
drive runs (a 1581 write paused in that window would rewrite its sector on
the SD card for the whole pause).

**Decision.** The sector buffer is a slot region (FDC_BUF_8/9, 1 KiB each)
next to the RAM (RAM_1581_8/9, 8 KiB each), both always present; the WD1772
with its request handshake, the floppy mechanics, the 8520, the VIA and the
T65 are on the chain (DRV8_1581, DRV9_1581). The sector requests reach the
host only while the drive runs: a request raised on the last running clock
before a savestate stays in the chain, a pause shows the host no request
(one already taken by the host is seen, or done once more, when the drive
runs again). The savestate boundary waits until no request is pending
towards the host and none starts on the sampling edge. The D81 image is media,
as the tape and the 1541 images: not in the slot, a load needs the same
image mounted. There is no mount identity as for the 1541 (D6): the buffer
is no write-back cache, a sector the drive writes goes to the SD within its
write command. Cost: 18 KiB per slot.

**Changes.** `savestate/map.yaml` (DRV8_1581, DRV9_1581, the buffer region on
the SD-side port a, the RAM written on port a and read on port b),
`c1581_multi`, `c1581_drv`, `fdc1772`, `floppy`, `iecdrv_mos8520`,
`iec_drive`, `c64.sv`; the harness serves D81 sectors (`--disk file.d81`);
`docs/SAVESTATES.md` ("1581: sector buffer and disk image").

## D9 - OPL3 FM part stays at the replay (2026-11-05)

**Data** (A11). The FM part of the Sound Expander (`opl3sw`, clk48) holds, in
the state inventory of the simulation build: NextZ80 92 flip-flop bits plus
its register file (14 x 16 = 224 bits), the sequencer `opl3seq` 276 bits and
the `opl3sw` glue 48 bits (Z80 clock enable, 44.1 kHz counter, structure
base, sequencer reset): 640 bits a serialized FM part would put on a chain,
plus its 8 KiB RAM (firmware, data, operator state) and the register queue
(Altera dcfifo, 1024 x 10 bits, two clocks). In the A11 fit it is 1,209 ALMs,
905 registers and 37 M10K (Z80 712 ALMs and 363 registers, 301 of them the
register file; sequencer 401 and 320; queue 42 and 130).

Serializing it means a chain or byte port in clk48 with a handshake to the
engine in clk_sys (the plan keeps the chain in clk_sys only), a dual-clock
queue of our own whose content can be read without popping it, and a
clock-crossing port on the 8 KiB RAM. Estimate: ~350 ALMs for the 640 bits
at the 0.55 ALM per chain bit measured in A10 (+1,161 ALMs for 2,096 bits),
~500 ALMs with the crossing and the queue (+40 % of the FM part); one LUT
level in front of every Z80 and sequencer register on clk48 (worst setup
slack of clk48 in A11 +2.67 ns, inside the Z80); 10 KiB more per slot, 1-2 ms
per save.

The C64 reads none of it: index, timers, status and IRQ are on the chain and
exact. What a load changes is only heard. Measured in simulation (the sound
`alo` of B after its first load against the uninterrupted A, ssdiff opl.prg,
10 ms windows):

| Scenario | Queue consumed | Samples that differ | Energy of the difference | Level of B vs A, every 10 ms window |
| --- | --- | --- | --- | --- |
| `opl`: B loads C0, then C1 (the state it is paused at) | 21,234 clk_sys (0.67 ms) | 76 % of 4.0M | -30.4 dB re A's sound | within 0.1 dB from the first window |
| `oplrewind`: B paused at C1 loads C0 | 12,666 clk_sys (0.40 ms) | 99.6 % of 5.0M | +4.2 dB (same notes, phases uncorrelated) | within 0.7 dB from the first window |

So after a load the registers are those of the save within a frame and the
loudness follows the exact run from the first 10 ms on. What differs is the
phase of the operators and of the LFOs, which a listener does not hear on a
held note, and the envelopes, which go on from the state before the load (in
this music within 0.7 dB of the exact run); a note keyed on only in the saved
state starts its attack at the load.

**Decision.** The replay of D7 is final: the FM part is not serialized.
Regions OPL3_RAM and OPL3_FIFO leave the map (with the A1 placeholder EZ_RAM:
the EasyFlash RAM is in CART_RAM); OPL3 keeps words 173-175, words 176-186
stay free. The slot format and the chain length are unchanged.

**Changes.** `savestate/map.yaml` (three dead regions removed, 17 regions),
`state_classes.yaml` (reason of the FM part), the ssdiff harness (`--opl`
prints the sound comparison above), `docs/SAVESTATES.md`.

## D10 - Rewind: 64 snapshots in a DDR3 ring, one per 1.06 s, off with large cartridge memory (2026-11-05; removed from this branch 2026-11-16)

**Removed from this branch.** The rewind is left out: the ring of
`statemanager.sv`, the engine input `ring` and output `ring_fits`, the
rewind trigger and messages 24-26 of `savestate_ui.sv`, O[105], the ring in
the drive write guard of `ss_ddram_arb.sv` (it starts again at the scratch
slot, 0x3D800000) and the `--ring` scenarios of the harness are gone. The
slot format and the chain are unchanged, so slots saved by an A12 build
still load. What follows is the record of A12.

**Data** (A12). The plan asks for 60 snapshots at 1 Hz in 6 MB without REU,
loaded back on a key. A slot without REU, GeoRAM and EasyFlash is 124,040
bytes today (chain 10,445 bits, RAM 64 KiB, Color RAM, the drive regions),
189,584 with a cartridge (CART_RAM 64 KiB), 264 more with the Sound Expander;
a save takes 913k clk_sys (29.0 ms, full model, A10), 17 ms more with a
cartridge, 130 ms more with a 512 KiB REU, 0.5 s with 2 MiB, 1.1 s with
GeoRAM, 0.27 s with the EasyFlash flash (D2). The machine stops for the save
and resumes only where the free-running video position meets the stop point
(A0), i.e. after whole frames: a 29 ms save stops it for 2 frames (39.9 ms
PAL, 33.4 ms NTSC; simulation, `ssdiff --ring invis`: 1,257,600 clk_sys per
snapshot, 2.00 frames, for a save of 802k clk_sys). Main writes slot files
only for its SS area (0x3E000000-0x3FFFFFFF, four 8 MiB slots) and clears
those slots on a file load; the drive track cache uses
0x30000000-0x303FFFFF, the self-test scratch slot 0x3D800000-0x3DFFFFFF.

**Decision.**
- Ring: 64 entries of 256 KiB at DDR3 0x3C000000-0x3CFFFFFF (16 MiB,
  aligned), outside the SS area: Main never reads, copies or clears it, and
  the arbiter drops drive writes from 0x3C000000 up. An entry is a slot made
  by the same engine (TLVs, CRC, config mask, chain length) with input
  `ring`: the change counter is neither written nor counted, and a ring load
  does not take it from the entry, so the four slots and what Main sees of
  them do not change with the ring.
- Period: a snapshot every 2^25 - 1 clk_sys of running time (1.064 s PAL,
  1.025 s NTSC; paused and frozen time does not count): 64 entries keep 68 s
  PAL (65.6 s NTSC), more than the 60 s of the plan. A snapshot comes after
  every other request (slot save, slot load, rewind, self-test) and waits
  while the machine is stopped; it shows no message, a failed one (no safe
  point within the watchdog) is not counted.
- Cost: 2 frames of stop per snapshot (3 with a cartridge): the C64 runs at
  96.4 % of real time PAL (94.7 % with a cartridge), HDMI shows one frame for
  2 frames more and the sound holds its level for 40 ms once per snapshot;
  the running program sees nothing (the pause rules; `ssdiff --ring invis`).
  A longer period would lengthen the step of a rewind (or shorten the
  history), a shorter one cost more; for an option that is Off by default
  this stutter is accepted. The Pause Mute Audio fade now follows only the
  user/OSD pause, so a snapshot or a savestate holds the sound instead of
  dipping it for ~70 ms.
- Off with a REU (any size), GeoRAM or an EasyFlash cartridge: a snapshot
  does not fit 256 KiB (engine output `ring_fits`) and would stop the
  machine for 0.13-1.1 s of every second. No snapshot is taken, the engine
  refuses a ring save that does not fit (too big), a press shows "Rewind off".
  Larger entries were not taken: DDR3 has room (the ring could hold 4 MiB
  entries), the stop time is the limit, and a dirty-page bitmap for the
  cartridge memories is outside the plan (D2).
- Rewind (Ctrl+Alt+F5, pad Savestates + Fire 1, free: the C64 sees neither
  the F5 nor the pads while Savestates is held): loads the newest entry, or
  the one before it when the newest is less than half a period (0.53 s) old
  or is where the previous rewind went (no snapshot since). A press always
  goes back at least 0.53 s, presses in a row step one entry (1.06 s)
  further each. The entries after the loaded one are dropped, the next
  snapshot follows the loaded entry a period after the load.
- The ring empties when Rewind is switched off, on a reset, a file load (any
  ioctl download) or a disk mount (the entries need the old media), and while
  the configuration does not fit. A slot load does not empty it: a rewind
  then goes back to before the load.

**Changes.** `statemanager.sv` (ring, period, rewind rule), `savestates.sv`
(`ring`, `RING_BYTES`, `ring_fits`), `savestate_ui.sv` (keys, messages),
`ss_ddram_arb.sv` (guard from 0x3C000000), `c64.sv` (O[105] Rewind, info
messages 24-26, Pause Mute Audio on the user pause), the harness
(`ssdiff --ring`, DDR3 model), a board test script;
`docs/SAVESTATES.md` ("Rewind"). The slot format and the chain are unchanged.

## D13 - REU 16 MiB in the slots: 21 MiB slots lower in DDR3, written REU pages only, block transport (2026-11-14)

(D11 and D12 are taken by the A13 branch. The rewind ring that D13 mentions
is not part of this branch, see D10; nothing else of D13 depends on it.)

**Data.**
- With 8 MiB slots at 0x3E000000 (D2) a save with the 16 MiB REU is refused
  ("REU too large for the slot"). The worst case is REU 16 MiB + GeoRAM
  4 MiB + the rest: 2,641,076 words (20.15 MiB) including one record word
  per REU page (GeoRAM excludes a CRT; EasyFlash with its RAM is smaller).
- The engine moved the SDRAM regions over the machine's byte path, ~5
  clk_sys per byte: a 512 KiB REU added 130 ms to a save, GeoRAM 4 MiB 1.1 s
  (A12: save 1.37 s and load 1.84 s with GeoRAM and a 512 KiB REU); a 16 MiB
  REU would take ~3 s to save and more to load.
- DDR3 above 0x20000000 already in use: the ascal triple buffer
  0x20000000-0x217FFFFF (sys_top.v:716-720, ascal.vhd), no MISTER_FB
  (sys_top.v:1747-1753, no MISTER_ define in C64.qsf), the Main frame buffer
  0x22000000-0x237BAFFF (Main video.cpp:37-38, 2450, 2724), screenshots
  0x20000000 + 6 MiB (scaler.h:31-32, scaler.cpp:43-50), the drive images at
  0x30000000/0x30200000, the A12 ring 0x3C000000-0x3CFFFFFF. Linux ends at
  0x1FEFFFFF (on the board: `mem=511M memmap=513M$511M`, `/proc/iomem`). Main
  accepts an SS area in [0x20000000, 0x40000000) (user_io.cpp:781, 985,
  2989; menu.cpp:2448).
- Main (user_io.cpp `process_ss`, lines 1997-2120) maps four slots of the
  token size, clears them (memset), reads a slot file up to that size (a
  smaller, older file loads) and writes `(STATESIZE + 2) * 4` bytes when
  they fit; the token is limited to 128 MiB per slot and base + 4 slots
  below 0x40000000.
- A13 (c5290fa) moved the SDRAM regions in 8-column bursts while frozen
  (`ss_sdram_port.sv`, an engine path in sdram.v).

**Decision.**
- Slots: `SS2AC00000:1500000`, four slots of 21 MiB at 0x2AC00000-
  0x2FFFFFFF, the self-test scratch slot at 0x29700000-0x2ABFFFFF. Main is
  unchanged. The drive images keep 0x30000000-0x30FFFFFF (the only window
  where the arbiter now accepts drive writes), the ring stays at 0x3C000000.
  After a merge with A13 its area 0x31000000-0x3CFFFFFF stays as it is and
  its scratch and slots (0x3D800000, 0x3E000000) move to these addresses.
- Accepted cost: Main clears the whole SS area through /dev/mem (O_SYNC,
  shmem.cpp:22,30) on every file load and drive-8 mount: 84 MiB instead of
  32 MiB, estimated +0.3 to +1.1 s at 50-200 MB/s (not measured). The board
  measurement (A12v against A12r, same PRG) decides.
- Format version 2. The REU is saved as REU_PAGES (tag 0x15): for every
  4 KiB page written since power on, one record word `{4096, page index}`
  and the 512 words of the page, page indexes strictly increasing. All other
  regions are unchanged (byte-identical to version 1). Version 1 slots
  (whole REU under REU_RAM, tag 0x09) still load, every page counting as
  written. A load verifies the records (order, index, length) with the CRC
  before it writes anything.
- REU page map (`ss_reu_map.sv`, 4096 bits in one M10K): a bit means "this
  page may differ from zero". Every write of the machine into the REU lane
  (SDRAM address bit 24: REU DMA, REU file load) sets it, engine traffic
  does not; it survives every core reset, as the REU data does. Only FPGA
  configuration clears all bits, and a load clears the bits of the pages it
  zeroes: a load writes the pages the slot holds and zeroes every mapped
  page it does not hold, so the REU is exactly the one saved.
- Behaviour change: the power-on content of the REU is zero. After FPGA
  configuration c64.sv zero-fills the 16 MiB lane with the engine transport
  while the machine is held in reset (its grid and video run, its SDRAM ce
  masked; ioctl waits) and hands the SDRAM back on a refresh pulse, where the
  machine's ce is low. The first boot takes ~0.29 s
  longer (~9.1M clk_sys). Before, the REU held whatever the SDRAM powered up
  with. `ss_reu_clr` holds the reset counter of c64.sv at its start value
  through the whole fill (reset_n low); a reset button or an OSD reset
  during it changes nothing (the counter is already held) or, still pressed
  at its end, extends the reset as usual; after the fill the machine runs
  the normal power-on reset (100,000 clk_sys, RAM erase). A core reload is a
  new FPGA configuration and starts a new fill. A first version paused the
  machine for the fill: its release, the first resume after power on, moved
  the output sync by 2 dots once (`pausetest --sync-check`), so the fill now
  runs under reset only, as A12's reset.
- Transport, only while the machine is frozen: transfers of 256 bytes on one
  DQ lane and one row (two AUTO REFRESH, ACTIVE, 256 columns, the last with
  auto-precharge). WRITEs go one per clk64 (each data word leaves the output
  register as for a single WRITE), READs one every other clk64, captured
  three clocks after the READ as in the normal path: 140 clk_sys per write
  transfer, 267 per read transfer (`tb_ss_transport`); the row stays open
  8.1 us at most (tRAS max 120 us), two AUTO REFRESH per transfer keep 8192
  within 64 ms with read transfers back to back. The first build read one
  column per clk64 (137 clk_sys per transfer): every simulation checker
  passed, but on the board the saved bytes had single bits of the next column
  (screen RAM "**** COMMODORE" saved as 28 2a 2a 2a 20 21 0f 0d 0d 0d ...),
  without a REU and with one, while A12v saved the same state exactly: the
  next column reached the DQ input register at the capture edge. A13 reads
  one column every other clk64 and was exact on the board. The command-level
  checker cannot see pad timing (sim/README.md); a board test checks a known
  pattern in RAM and in every REU bank byte
  for byte on the board, through a save and a load. The first transfer after
  the controller's init waits for one normal AUTO REFRESH (with its own, the
  two the chip needs before an ACTIVE). The engine streams 64-bit words
  through a 64-word FIFO, writes and reads DDR3 in bursts of 32 (the drives'
  DDR3 traffic interleaves burst by burst) and computes the CRC over 8 bytes
  per clock. A load reads the slot twice: verify, then restore. The byte
  regions (drives, Color RAM, OPL) keep the byte paths.
- Cost of the safe READ cadence: a save with a fully written 16 MiB REU
  takes 17.84M clk_sys, 0.566 s (65,536 read transfers; one REU byte per
  two clk64 puts the floor at 0.532 s), more than the 0.4 s aimed at; the
  load takes 12.11M clk_sys, 0.384 s, verify pass included (`ssdiff`
  `reu16full`).
- Rewind stays off with any REU (D10).

**Changes.** `rtl/sdram.v` (engine sequencer, gated by `ss_own`; the normal
path is unchanged while it is low), `ss_sdram_port.sv` (rewritten after A13:
transfers, power-on fill), `savestates.sv` (streaming engine: FIFO, DDR3
bursts, CRC 8 bytes per clock, REU_PAGES, verify pass), `ss_ddram_arb.sv`
(burst arbitration, drive write window), `ss_reu_map.sv` (new),
`statemanager.sv` (base and slot size), `c64.sv` (token, SDRAM mux, page
map, power-on fill), `savestate/map.yaml` (version 2, `slot_bytes`,
`ddr_base`, `reu_page_bytes`, `pages_tag`), the simulation (chip model:
two READs in flight, tRAS max; `tb_ss_transport`, harness `--reu-fill`,
`--sync-check`), `sys/ascal.vhd` (a second local timing change for the
HDMI clock, checked by `tb_ascal_vcpt`; SAVESTATES.md "Resources"),
a board test (memory saved and restored byte for byte on
the board), `docs/SAVESTATES.md`. Times measured in the simulation:
`docs/SAVESTATES.md` ("Memory regions", "Resources").
