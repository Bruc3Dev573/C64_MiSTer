# Savestates: engine, slot format, DDR3 (WP A2), chip segments (A3-)

Branch `savestates`. The engine and its plumbing; the state of the chips
(scan-chain segments) comes with the chip work packages A3-A11. Live today:
CPU (6510 + T65) and SYS (fpga64 glue) since A3, CIA1 and CIA2 since A4,
VIC-II since A5, SID1 and SID2 since A6; since A7 REU, cartridge (with
EasyFlash flash and DigiMax), datassette (TAPE), 1351 mouse (INPUT), the
c64.sv glue (TOP) and the PCF8583 RTC; since A8 both 1541 drives (CPU, two
VIAs, head and GCR logic, track cache, RAM, RAM expansion and track
buffer); since A9 the Sound Expander (OPL3: its C64 side on the chain, the
register shadow in the slot; at a load the running FM part gets the
registers that differ); since A10 both 1581 drives (CPU, 8520, VIA, WD1772
controller and floppy mechanics, RAM and sector buffer); A11 lets a save land
inside an EasyFlash program or erase and tests the EasyFlash flash, its RAM
and GeoRAM, and keeps the FM part of the Sound Expander at the replay (D9).
The rewind ring of A12 (D10) is not part of this branch.
Decisions: `SAVESTATE_DECISIONS.md`.
Map: `savestate/map.yaml` (generated constants in `rtl/savestate/`).

## Using it

| Control | Effect |
| --- | --- |
| OSD **Savestate Slot** (O[101:100]) | Selects slot 1-4 |
| OSD **Save state** / **Restore state** (R[102], R[103]) | Save to / load the selected slot |
| OSD **Savestates to SDCard** (O[99]) | On: Main copies each saved slot to the SD card. Off: the change counter is not written, the slot stays in DDR3 only |
| OSD **Savestate self-test** (R[104]) | save/save and save/load/save on a scratch slot, compares the CRCs, shows PASS or FAIL |
| Keyboard **Ctrl+Alt+F1..F4** | Selects slot 1-4. The C64 uses F1-F8, so the keyboard does not save or load a slot; the F key of the combination never reaches the C64 |
| Pad **Savestates** (new button, default Select) + Left/Right | Previous / next slot |
| (after any load) | All keys are released (D3) |
| Pad **Savestates** + Down / Up | Save / load the selected slot. While the button is held (and 10 ms after) the C64 does not see the pads |
| Keyboard **Pause/Break** | User pause, unchanged (`PAUSE.md`) |

Messages (OSD info): slot selected, saved, restored, or the reason of a
refusal: no safe point (save abandoned), REU too large for the slot, slot
empty or invalid, other core version, other hardware settings, slot damaged
(CRC), busy, DDR3/RAM timeout.

## Blocks

| File | Role |
| --- | --- |
| `rtl/savestate/savestates.sv` | Engine, ported from the TurboGrafx16 core (`savestates.vhd`, NES_MiSTer framework by Robert Peip): header protocol, settle, forced-boundary rules; chain + TLV regions + payload header with CRC instead of the 128-register shadow bus |
| `rtl/savestate/statemanager.sv` | Request queue (one pending save and load, slot captured at the request, saves first) + OSD self-test |
| `rtl/savestate/savestate_ui.sv` | Keyboard, pad, OSD, info messages |
| `rtl/savestate/ss_freeze.sv` | Second freeze level: boundary wait on idle signals, watchdog |
| `rtl/savestate/ss_sdram_port.sv` | SDRAM transfers of 256 bytes while frozen (RAM, REU pages, GeoRAM, cartridge memories; run by the engine sequencer in `rtl/sdram.v`) and the power-on REU fill (D13) |
| `rtl/savestate/ss_reu_map.sv` | REU page map: one bit per 4 KiB page written since power on (D13) |
| `rtl/savestate/ss_ddram_arb.sv` | DDR3 arbiter: drive track cache / engine, drive window guard |
| `rtl/savestate/ss_chain.sv`, `ss_chain_pkg.vhd` | Chain segment helpers for the chip WPs (SV and VHDL) |

## Freeze

Two levels on the same machine stop (`sysEnable` in `fpga64_sid_iec`,
`docs/PAUSE.md`):

1. **pause**: user pause / OSD pause, as before, frame aligned for HDMI.
2. **freeze_req / freeze_ack**: while the engine asks for it, the pause
   input of fpga64 is the AND of the idle signals. fpga64 samples it once per
   C64 cycle group on the clock where it raises `refresh`, so the machine
   stops exactly on a sample where everything was idle; `ss_freeze` then holds
   it until the engine is done and acknowledges. A machine that was already
   user-paused mid-instruction runs again until the next boundary (a few C64
   cycles; HDMI stays frozen during a savestate), starting on the sample
   after `video_sync`'s `resume_ok` (input `run_ok`), so the video output
   keeps its sync (`PAUSE.md`).

Idle signals (`ss_idle` in `c64.sv`, bit order):

| Bit | Condition | State |
| --- | --- | --- |
| 0 | C64 CPU between instructions: T65 `Sync` (next cycle is an opcode fetch), new port `ss_cpu_sync` of `cpu_6510`/`fpga64_sid_iec` | wired |
| 1 | no reset pending: `reset_n`, no RESET/OSD reset/USER button, no `reset_wait` | wired |
| 2 | REU not in DMA (`dma_req` low) | wired |
| 3 | 1541 x2: CPU between instructions (T65 `Sync`) or unit held in reset, and no foreground track transfer running or about to start (`c1541_track` `ss_idle`: DMA idle or a background SD flush, no pending reload, the track and write-back synchronizers settled, no head step on its way); 1581 x2: CPU between instructions or unit held in reset, and no sector request pending towards the host or starting on the next clock (`fdc1772` `ss_idle`) | wired (A8, A10) |
| 4 | no SD block transfer of the drives (`sd_rd`, `sd_wr`, `sd_ack` low, i.e. `c1541_track` idle towards Main and no 1581 sector transfer) | wired |
| 5 | no ioctl download/upload, no PRG RAM init, no RAM erase | wired |
| 6 | SDRAM: no io-cycle write/read of the host pending (`ioctl_req_wr/rd`). The EasyFlash write-back of a program or erase may be pending: it is on the chain (A11, "EasyFlash and GeoRAM") | wired |
| 7 | tape: no TAP prefetch byte in flight (new `ss_idle` port of `tape_subsystem`: `read_cyc`, FIFO write) | wired |
| 8 | drive track cache: no DDR3 request, no read beat outstanding (arbiter) | wired |

While frozen the SDRAM sees no access from the machine (io_cycle,
ext_cycle and ram_ce are low with `sysCycle` held at `CYCLE_EXT4`) and the
refresh keeps running every 32 clocks; the engine waits SETTLE (100) clocks
after the acknowledge before it touches anything.

**Watchdog**: no boundary within 2^27 clk_sys (4.3 s) forces the freeze on
the next sample. A forced **load proceeds** (it overwrites the machine). A
forced **save is abandoned** before the slot is touched (message "no safe
point"); the `block` output of `ss_freeze` keeps the idle bits that were low
(checked by the unit bench `tb_savestates`; not connected in `c64.sv`).

## Slot format

`C64;SS2AC00000:1500000,UART9600:2400;` in CONF_STR (Main reads the token
only from the second field): four slots of 21 MiB at DDR3 0x2AC00000
(decision D13: the 16 MiB REU with GeoRAM must fit; D2 had 8 MiB at
0x3E000000). Slot files on the SD
need Main to map the slots after a file load (`FS1` option). The official
Main loads every C64 file through `c64_open_file()`, which skips that step,
so there the slots live in DDR3 only: they survive a core reload, not a power
cycle. The Main of branch `c64-savestates` of `Bruc3Dev573/Main_MiSTer`
(official 20261010 plus two commits, release
`20261010-c64-savestates-r2`) writes them, named after the loaded
file or the disk in drive 8; a disk in drive 9 names them only while drive 8
is empty (decision D5).
All words are 64-bit little endian.

| Word | Content |
| --- | --- |
| 0 | `{STATESIZE[31:0], change counter[31:0]}`: STATESIZE = 32-bit words of the whole image **including** this header (Main copies at least that much; it is cleared by the first write of a save and written last, so a torn save leaves a slot that the load refuses) |
| 1 | `{build hash[31:0], live chain bits[15:0], format version[15:0]}`; format version 2 (D13), a load also takes version 1 |
| 2 | `{config mask[31:0], CRC-32[31:0]}`; CRC-32 (IEEE, as zlib) of the bytes from word 3 to the end marker, computed in fabric while streaming |
| 3.. | TLV regions: header `{length in bytes[31:0], 24'd0, tag[7:0]}`, then ceil(length/8) data words (byte k of the region = byte k%8 of word k/8) |
| last | end marker, tag 0 length 0 |

Region order: CHAIN (tag 0x40, `SS_CHAIN_WORDS` = 256 words = 2 KiB: word w
carries `SS_WORD_NBITS[w]` chain bits from bit 0, the padded word layout of
the map.yaml segments), then the map.yaml regions in map order that are
present in this build and configuration. The region table (tags, sizes,
`SS_RGN_<NAME>` indexes) is generated from map.yaml, and `c64.sv` declares
every region of it: RAM (0x01, 64 KiB), COLORRAM (0x02, 1 KiB, low nibble),
the regions of both 1541 units (RAM_DRV8/9, EXTRAM_DRV8/9, TRACK_DRV8/9,
always), of both 1581 units (RAM_1581_8/9, FDC_BUF_8/9, always) and the
optional ones (the REU, GeoRAM, CART_RAM, CART_FLASH, OPL3_REGS) when present.
The REU is saved as REU_PAGES (tag 0x15, D13): for each 4 KiB page written
since power on (`ss_reu_map`), a record word `{4096, page index}` and the 512
words of the page, page indexes strictly increasing; a format 1 slot holds
the whole REU under REU_RAM (tag 0x09) and still loads.
The EasyFlash RAM is no region of its own: it is in SDRAM, inside CART_RAM
(A11; the A1 placeholders EZ_RAM, OPL3_RAM and OPL3_FIFO are gone, D9).

**Live segments.** map.yaml describes the whole chain, but only instrumented
chips are on it. The engine parameter `LIVE` has one
bit per segment (`SS_SEG_<NAME>`, generated): only live segments are shifted,
the words of the others are written as zeros and skipped on load. The live
chain length is what word 1 records and what a load compares, so a slot made
before a chip became live is refused by later builds instead of loading
zeros into it. Since A10 the live chain is 10445 bits (A11 adds none; table in
"Scan chain").

A **load** reads words 0-2 (size, format version, chain length, config mask),
then reads the whole payload once to check the TLV structure, the REU page
records (order, index, length), the CRC and that every region present in
this configuration is in the slot. Only then does it write anything: chain,
then regions; the REU pages the slot holds are written and every page the
machine has written since power on that the slot does not hold is zeroed,
so the REU is exactly the one saved. Unknown tags are skipped, as are known
regions not present here. A refused load leaves the machine as it was.

Config mask bits (map.yaml): REU size, GeoRAM, drive type of units 8 and 9
(1 = 1581, from the mounted image; A8), SID models, NTSC, VIC-II variant,
CIA model, OPL, System ROM (KERNAL) selection and CRT hardware type (255 =
no cartridge) (D2). The build hash is
`BUILD_DATE` as BCD (0x00yymmdd); it is recorded, not compared: chain length
and format version decide compatibility.

Main protocol: unchanged from the NES/PCE cores (slot change counter in word
0 bits 31:0; with "Savestates to SDCard" off the counter bytes are not
written, so Main does not copy the slot).

## Memory regions

| Region | Port | Speed |
| --- | --- | --- |
| RAM 64 KiB | SDRAM at 0x0000000 through `ss_sdram_port` (D13): while frozen the port owns the SDRAM (`c64.sv` masks the machine's ce) and `sdram.v` runs transfers of 256 bytes of one row and DQ lane (two AUTO REFRESH, ACTIVE, 256 columns, the last with auto-precharge; WRITE on every clk64, READ on every other one), 267 clk_sys per read transfer, 140 per write transfer | ~2.2 ms |
| Color RAM 1 KiB | borrows the port of the `spram` in `fpga64_sid_iec` (address/data/we mux, active only with `sysEnable` low) | 3 clocks per byte |
| REU 512 KiB / 2 MiB / 16 MiB | SDRAM at 0x1000000 (DQ lane 1), when the REU is enabled: only the 4 KiB pages written since power on (REU_PAGES), 16 transfers per page | save 136 us per page, load 92 us (verify pass included); all 4096 pages (16 MiB): save 0.566 s, load 0.384 s |
| GeoRAM 4 MiB | SDRAM at 0x0C00000 (`{3'b011, geo_bank}`, the page register on the CART segment), when GeoRAM is enabled and no CRT is attached | ~139 ms |
| CART_RAM 64 KiB | SDRAM at 0x0010000 (cartridge RAM banks, `get_bank`), with a CRT attached; holds the EasyFlash RAM ($DF00-$DFFF: bank 0, 0x0011F00) | ~2.2 ms |
| CART_FLASH 1 MiB | SDRAM at 0x0200000 (EasyFlash flash, `ezmem_addr`; programs erase/program it), with an EasyFlash CRT | ~35 ms |
| RAM_DRV8/9 2 KiB, EXTRAM_DRV8/9 8 KiB, TRACK_DRV8/9 8 KiB | port a of the block RAMs of each 1541 unit (`c1541_logic` RAM and RAM expansion, `c1541_direct_gcr` track buffer by byte lane), muxed while the engine owns the machine; always present | 3 clocks per byte, ~6 ms for the six |
| RAM_1581_8/9 8 KiB, FDC_BUF_8/9 1 KiB | the RAM of each 1581 unit through its CPU ports (written on port a, read on port b on the clock of the request, so it stays one simple dual-port RAM) and the WD1772 sector buffer of `fdc1772` on its SD-side port a, muxed while the engine owns the machine; always present | 3 clocks per byte, ~3 ms for the four |
| OPL3_REGS 256 bytes | register shadow of `opl3.sv` (its write port is shared with the C64 writes, its read port with the replay), with the Sound Expander on | 2 clocks per byte |

Times are for the save (the SDRAM regions at 35 ms per MiB, from the 267
clk_sys per read transfer of `tb_ss_transport`); a load reads the slot twice
from DDR3 (verify, then restore) and writes the SDRAM at 18 ms per MiB (140
clk_sys per write transfer). The SDRAM READs are one every other clk64: one
per clk64 passes every checker of the simulation but saved corrupted bytes
on the board (`sdram.v`, sim/README.md "Known limitations"). The other CRT types keep
their ROM in SDRAM as loaded from the file: not saved, the config mask holds
the CRT hardware type so a slot of another cartridge type is refused (the
same type with another file is not detected). Whole regions are saved except
the REU (written pages only): every configuration fits the 21 MiB slot.

After a load `ss_load_done` also pulses the keyboard reset of fpga64
(decision D3): every key is released, so no key stays stuck from the moment
of the save or of the load. Joystick and paddle lines are live host inputs
(nothing latched). The C64-side state (CIA ports, keyboard scan) stays as
saved once those segments are on the chain.

The engine streams 64-bit words between the regions and DDR3 through a
64-word FIFO (MLAB), DDR3 in bursts of 32 words, CRC-32 over 8 bytes per
clock; the REU page map is one M10K.

### 1541: track buffer and disk image (A8)

The GCR track buffer of each unit (`c1541_direct_gcr`, 8 KiB, the track
under the head as the DMA loaded it from the DDR3 image, plus the head writes
not yet written back) is saved as a region (TRACK_DRV8/9), together with the
track cache state on the chain: which track the buffer holds, its G64
offset, a pending reload and the write-back edge detector. Re-fetching the
track from DDR3 after a load (the plan's first option) was not taken: a
buffer modified by the drive after its last write-back exists only there,
so the slot would lose those writes, and the refill would have to hold the
drive while the DMA runs. With the region a load is exact and needs no
drive hold or watchdog. Cost: 16 KiB per slot.

The disk image itself is media, like the tape: it is not in the slot and a
load needs the same image mounted. Tracks the drive wrote back to DDR3 after
the save stay as they are (the drive sees the saved buffer of its current
track until it steps); the queue of DDR3 tracks not yet copied to the SD
file (`dirty_tracks`, host side) is never touched by a load, so writes that
reached DDR3 always reach the SD. Each mount gets an identity (a
free-running count sampled at the mount, `mount_id`); the slot carries the
one of the save. A load with another identity (another image, or the same
one mounted again, e.g. after a reboot) drops the saved write-back
(`track_modified`, a write-back still in the synchronizer) and reloads the
current track from the mounted image, so the saved buffer is never written
into another image. Head writes of the save that were not yet written back
are lost in that case only.

Mounts made while the engine owns the machine reach the drives after it:
a mount writes chain registers of the unit (mount sequence, pending reload).

### 1581: sector buffer and disk image (A10)

The 1581 has no track cache in this core: the WD1772 model (`fdc1772`) asks
the host for one 512-byte sector at a time over the SD block interface
(`sd_lba` in 256-byte blocks, `sd_blk_cnt` 1) into its 1 KiB buffer, and the
floppy model (`floppy`) only times the rotation and the head steps (decision
D8). The slot holds the buffer (FDC_BUF_8/9, on its SD-side port a) and the
drive RAM (RAM_1581_8/9, written on the CPU write port a, read on the CPU
read port b); the WD1772 registers, command state machine, data transfer and
request handshake, the floppy position, spin-up and step timers, the 8520,
the VIA and the T65 are on the chain. The D81 image is media: not in the
slot, a load needs the same image mounted (no mount identity: the buffer is
no write-back cache, a sector the drive writes reaches the SD within its
write command).

- The units stop with the machine as the 1541 (`stop` of `c1581_multi`,
  `c64_pause` one clock later): every process of the WD1772, the floppy and
  the 8520 holds, the ph2 and 8 MHz pulses wait in their registers (the A0
  gate `ena` is gone), the CPU steps on `ph2_r & ~stop`, the CPU writes the
  RAM and the WD1772 its buffer only while the drive runs.
- The sector requests reach the host only while the drive runs (`sd_rd`,
  `sd_wr` masked with `stop` in `c1581_drv`). The handshake runs on the drive
  clocks, so a request raised on the last running clock after the boundary
  sample (the drive stops one clock after `c64_pause`) waits in the chain
  instead of starting a transfer while the engine owns the buffer port, and
  a user pause shows the host no request; a transfer the host had already
  taken lands in the buffer during the pause and its end is seen, or the
  request repeated once, when the drive runs again. The boundary (idle bit 3)
  waits until no request is pending towards the host and none starts on the
  sampling edge.
- The engine takes the RAM ports (`hold` of `c1581_multi`) from the second
  stopped clock, as for the 1541 (rule "A RAM write registered on the last
  running clock completes with the CPU data"); it reads the RAM through the
  CPU read port b, only on the clock of its request: a read on port a made
  Quartus keep a second copy of the 8 KiB (+16 M10K for the two units).
- The ROM fetch of the units (`state`, `mem_a`, `drv_data`) is rebuilt, not
  saved: the 1581 CPU reads its ROM byte 7-8 clocks after the fetch starts on
  `ph2_f`, too soon for the restart after a stop that the 1541 uses, so the
  fetch repeats while the drives are stopped; after any stop (a whole C64
  cycle or more) and after a load (the chain moves long before the release)
  the bytes are those of the held CPU addresses.
- Mounts reach the units as a pulse that waits while the engine owns the
  machine (as for the 1541): a mount clears the disk change line (8520 PA7),
  a chain register.

### OPL3: register shadow and replay (A9)

The Sound Expander has two parts. Its C64 side (`opl3.sv`, clk_sys: the
index register, both timers and the status and IRQ flags they set) is all
the C64 can read: it is segment OPL3 and comes back exactly. The FM part
(`opl3sw`, clk48: the NextZ80 firmware and its 8 KiB RAM, the register queue
from the C64, the 44.1 kHz sample sequencer) is only heard. It is not saved
and a load does not reset it (decision D9: it stays out of the slot):

- `opl3.sv` keeps a shadow of the value of every register the C64 writes
  (256 bytes, one register bank: `addr[1]` is 0 in this core), saved as
  region OPL3_REGS (tag 0x12, present with the Sound Expander on), and a
  second copy, `fmreg`, of the values the FM part has or will take from its
  queue. Both follow the C64 writes and a reset of the chip clears both, as
  the firmware clears its registers.
- On `ss_load_done` (Sound Expander on) the registers where the loaded
  shadow differs from `fmreg` are queued as C64 writes, index then value,
  from $C0 round to $BF so the key-on registers $B0-$BD come after the
  operator settings; then the saved index, so a value the C64 writes after
  the load lands in the register it selected before the save. This takes
  1025 clocks: the engine keeps the machine frozen (`hold`) and the request
  manager starts no other operation until it is done (`ss_replay`), so C64
  writes after the load queue behind the replay.
- The firmware takes the queue at its own pace once the machine runs:
  register writes still queued from before the load first, then the
  replay. The FM registers are then those of the save; envelopes, phases
  and LFOs go on from the state before the load, so a note keyed on in both
  states sounds on, a note keyed only in the saved state starts its attack
  and the others are released. In simulation (ssdiff opl.prg) the queue is
  consumed 21,234 clk_sys (0.67 ms) after the resume.

Resetting the FM part and replaying the whole shadow (the first version)
gives a sound that depends only on the slot, but after the reset the
firmware boots for 11.6 ms (simulation: 367,204 clk_sys from the reset to
the sequencer start) before it takes the queue, so every load left a gap of
silence and restarted every note from its attack.

So the C64 side and the shadow are exact (a slot saved after the load equals
the loaded one) and a save without a load leaves no trace in the audio (the
FM part holds with the machine, docs/PAUSE.md); the FM output after a load
has the registers of the save, not its envelope and phase state.

This is final (D9, A11): serializing the FM part would put ~640 clk48 bits,
its 8 KiB RAM and the dual-clock queue in the slot (~500 ALMs, a second clock
domain on the chain) for a sound that the C64 cannot read. Measured with
opl.prg, the sound of a loaded state keeps the loudness of the exact run
within 0.7 dB in every 10 ms window; the operator phases differ.

### EasyFlash and GeoRAM (A11)

EasyFlash (CRT types 32 and 33): the slot holds the flash (CART_FLASH, the
1 MiB SDRAM image that programs erase and program) and the EasyFlash RAM
($DF00-$DFFF, inside CART_RAM: cartridge RAM bank 0 at 0x0011F00). The CART
segment holds the bank and mode registers ($DE00, $DE02) and both am29f040
chips: unlock sequence, command state (autoselect, erase setup, program
data), the busy counter of a program (32 clk_sys) or an erase (1M clk_sys per
sector, 8M for the chip), the SDRAM write-back of the command (address,
count, data, read stage, `ss_mem_req`) and the arbiter of the two chips.

- An erase writes its sector back one byte per io_cycle window: 64 KiB take
  ~1.2M clk_sys, longer than the busy count; a chip erase ~9.6M. Up to A10
  the boundary waited for the write-back (idle bit 6, `cart_mem_req`), so a
  save asked during an erase was taken only after it (up to 0.3 s later) and
  the busy counter on the chain was always 0 at a boundary. The boundary no
  longer waits: the write-back uses only the io_cycle windows, which stop
  with the machine, and the read of its read-modify-write ends inside the
  window (3 clocks) before the machine stops at EXT4. It holds with the rest
  of the flash and goes on after the resume or the load where it was cut; the
  slot has the sector partly erased together with the count.
- The CRT bank table (`lobanks`/`hibanks`, written by the loader) is media:
  a load needs the same CRT attached (D2). The copy of the flash to the CRT
  file on the SD (OSD "Save EasyFlash", host side, `ezfl_mod` set by any
  write-back) is not touched by a load: a load that changes the flash marks
  nothing, the file gets the flash with the next write-back and save.

GeoRAM (4 MiB, OSD option, no CRT attached; cartridge type 99): the RAM is
region GEORAM (SDRAM 0x0C00000, ~71 ms per save), the block and page
registers ($DFFF, $DFFE) are `geo_bank` on the CART segment. The window
$DE00-$DEFF is a plain SDRAM access of the C64 cycle: nothing is pending at a
boundary.

### Slot size and the REU

Decision D13. A 21 MiB slot holds the largest configuration, REU 16 MiB +
GeoRAM 4 MiB + the rest: 2,641,076 words (20.15 MiB) with every REU page
written. The REU is saved page by page: `ss_reu_map` (4096 bits) marks every
4 KiB page of the REU lane (SDRAM 0x1000000-0x1FFFFFF) that the machine
writes (REU DMA, REU file load: every write of the SDRAM mux with address
bit 24 while the engine does not own it); the bits stay across core resets,
as the REU data does. A save scans the map and writes one REU_PAGES record
per marked page. A load restores the pages of the slot (and marks them) and
zeroes every marked page the slot does not hold (and clears its bit): the
REU content is exactly the saved one, because an unmarked page is zero.

That holds because the REU lane is zero at power on: after FPGA
configuration `c64.sv` holds the machine in reset (`ss_reu_clr`, ioctl waits;
its cycle grid and video run, its SDRAM ce is masked) while `ss_sdram_port`
zero-fills the 16 MiB lane with 65,536 transfers (~9.1M clk_sys, 0.29 s added
to the first boot), then hands the SDRAM back on a refresh pulse, where the
machine's ce is low: no access starts mid-cycle and the video never stops
(`pausetest --sync-check`). A first version paused the machine for the fill
instead: its release, the first resume after power on, moved the output
sync by 2 dots once (one line of 506 dots). Before D13 the REU
held whatever the SDRAM powered up with.

A slot made with another REU size is refused by the config mask. A format 1
slot (8 MiB era, whole REU under REU_RAM) loads: every page counts as
written. The largest state fits a 21 MiB slot, so RES_TOOBIG ("REU too
large for the slot") stays only as a guard of the engine.

## DDR3

| Byte address | Use |
| --- | --- |
| 0x29700000 - 0x2ABFFFFF | self-test scratch slot (not declared to Main, never copied to SD; D13) |
| 0x2AC00000 - 0x2FFFFFFF | savestate slots 1-4, 21 MiB each (D13) |
| 0x30000000 + G64 offset | drive 8 image (1541 track cache, `c1541_track`, word base 0x06000000) |
| 0x30200000 + G64 offset | drive 9 image (word base 0x06040000) |

Below 0x29700000: the ascal triple buffer (0x20000000-0x217FFFFF), the Main
frame buffer (0x22000000-0x237BAFFF) and the screenshot buffer (0x20000000 +
6 MiB); Linux ends at 0x1FEFFFFF (D13). The drive addresses are `base + G64
track offset / 8`; the offsets come from the G64 header written by Main (an
image of a few hundred KiB), so they stay below 0x30400000. A corrupt G64
header could still point anywhere: `ss_ddram_arb` accepts drive writes only
inside 0x30000000-0x30FFFFFF and drops the others (accepted, not written),
so neither the slots nor the scratch slot can be hit. The 1581
does not use DDR3.

`ss_ddram_arb`: two Avalon masters, the drives and the engine, arbitrated
burst by burst. The owner changes only when it has no burst in progress and
no read beat outstanding; the waiting side sees DDRAM_BUSY. The engine
writes and reads bursts of 32 words (D13), so a drive request waits at most
one engine burst. The drive debug overlay snoops only the drive's own read
data. The track cache issues no new DDR3 request while the machine is
stopped (A8); read beats already requested are taken.

## Scan chain (for the chip WPs)

One serial chain in clk_sys, one 2:1 mux per flip-flop, no shadow bus:

    engine.chain_so -> [OPL3] -> ... -> [VIC] -> [CPU] -> engine.chain_si

The first map.yaml segment sits next to the engine input: bit 0 of a
segment is the first bit out and field offsets are bit indexes of the
segment vector. While `ss_chain_en` is high every clock moves the whole chain
by one bit; a save rotates it by exactly SS_CHAIN_BITS (the state is left as
it was), a load shifts the slot bits in. `ss_load_done` pulses once after a
load, before the machine is released (rebuild transients there).
`rtl/savestate/ss_chain.sv` has the pattern (`ss_chain_seg`, `ss_chain_reg`),
`ss_chain_pkg.vhd` the VHDL one (`ss_shift`, entity `ss_chain_vseg`). A chip
WP wires its segment between its neighbours that are already live (map
order), sets its bit in `LIVE` of `ss_engine` in `c64.sv`, and from then on
its bits travel in the slot. The segment length must equal its map.yaml
bits (the generated `SS_<SEG>_BITS`): the engine shifts exactly the live
total, a wrong length rotates the neighbours.

Rules every segment follows (they come from the engine, not from the chip):

- **Hold while the engine owns the machine.** A save shifts the chain in
  chunks (one 64-bit word, then a DDR3 write) and the clocks between chunks
  run the normal logic. A register on the chain must not change while
  `ss_frz_ack` is high (port `ss_hold`), otherwise it overwrites the bit of
  another register that is passing through. Logic gated by the chip enables
  holds by itself (the machine is stopped); logic that runs on every clock
  needs the hold (T65 SO pin sampler). The same holds for a register off the
  chain that is rewritten every clock from chain registers and keeps part of
  its value: cpu_6510 currentIO (the input bits of the port keep their level)
  would latch a bit of ioDir/ioData passing through.
- **Logic that steps on every clock but follows the machine grid stops with
  the machine.** The SID table/filter pipeline steps for 16 clocks after
  ce_1m, across the grid point where the machine stops; the REU state machine
  moves between its dma_cycle/ram_cycle waits on any clock; the cartridge
  logic and the EasyFlash flash chips react to bus strobes and count (Epyx
  capacitor, flash program/erase time) on every clock. Holding them only on
  `ss_hold` lets them move while the machine is stopped (user pause, the
  clocks before and after the engine), so a resume or a load lands a few
  clocks off (REU: one step of the DMA state machine ahead; SID: the output
  samples change before the resume). They hold on the condition that stops
  the machine (`not sysEnable`: `sid_hold` in fpga64, `c64_pause` in c64.sv,
  port `stop`/`pause`) and resume exactly where they were cut. This also
  holds them while the chain shifts. Found by `sim/tests/pause.sh` (user
  pause, no savestate) with reu.prg: a pre-existing pause divergence.
  When the logic follows a pipelined clock enable, the hold follows the grid
  of the logic that consumes it. fpga64 freezes on sysCycle EXT4 and runs
  EXT5 (where it samples the IEC lines) on the second clock after
  `c64_pause` falls, and `drive_ce` is 0 on exactly the clocks where
  `c64_pause` was high one clock before. So the 1541 logic that runs on every
  clock (VIA edge detectors and port input registers, T65 SO sampler, IEC
  synchronizers, ROM fetch, head step and write-back timer, track cache)
  holds on `c64_pause` delayed by one clock (`stop` of `c1541_multi`), the
  same clocks as the C64: a drive never runs a clock the C64 has not run.
  The ph2 pulses made from the last `drive_ce` wait in their registers (on
  the chain) until the drives run again; the RAM writes they strobe wait
  with them (next rule). The drive CPU is enabled by `ph2_f & ~stop`: the
  T65 `SS_Hold` freezes only its SO sampler, so a held pulse (or a chain bit
  passing through `ph2_f` during a save or load) would step it while frozen.
  The disk activity detector of c64.sv holds on the
  same delayed pause (`drv_pause`). The ROM fetch restarts on the first
  running clock (`stop_end`): the block RAM read pipeline runs on every
  clock and would leave a stale byte after a stop or a load mid-fetch. The
  1581 units (A10) stop the same way; their ROM fetch repeats while stopped
  instead (the 1581 CPU reads its byte 7-8 clocks after the fetch starts,
  too soon for a restart).
  A block in another clock domain stops with the same rule (A9, OPL3 on
  clk48): one clock enable from the synchronized pause holds all of it,
  also in the middle of a sample (sequencer, its RAM ports, sample strobe,
  the Z80 on the same phase of its own enable), and what crosses back is
  sampled on the C64 cycle grid (the OPL output once per running cycle, on
  DMA0), so the few clocks between the machine stop and the stop of that
  domain leave no trace. clk48 is 3/2 clk_sys from the same PLL, so a stop
  of whole C64 cycles keeps its phase. An inferred block RAM keeps its
  template when it holds: the enable goes on the write enables and on a hold
  register after the read data (`opl3_mem`). An enable on the read registers
  of that mixed-width RAM made Quartus build its 8 KiB out of logic (175k
  LUTs, no fit).
- **Copy registers that drive free-running logic.** A register whose output is
  sampled on every clock outside the machine (cassette lines to the RTC and
  `use_rtc`, the CIA TOD input) must not toggle while the chain shifts. It
  stays off the chain; the chain carries a copy (`ss_<name>`) that follows it
  until `ss_hold` and is written back on `ss_load_done`. The copy must follow
  until `ss_hold`, not until the machine stops: the output can change on the
  last running clock, and a copy frozen on `stop` would keep the value before
  it. Its rule in `state_classes.yaml` is 'rebuilt' with that reason, the
  copy is 'arch'. When the free-running logic needs the value only while the
  machine runs, it reads it only then instead: `video_sync` restarted its
  output dot divider on every rising edge of the VIC hsync (`hBlanking`, on
  the chain), so each save and load moved the analog output and the scaler
  input by 40-100 dots until 15 November.
- **Level resets yield to the engine.** A reset that can be held high while
  frozen (the RTC is in reset while the tape is in use, the tape logic while
  no tape is inserted) would clear chain cells between two chunks of a save
  and corrupt the bits passing through: it applies only when `ss_hold` is low
  (or only while running), and asynchronous resets of chain registers become
  synchronous (c1530, am29f040). The drive T65s keep their asynchronous
  reset: the unit reset is released while the engine owns the drives instead
  (`hold` of `c1541_multi` and `c1581_multi`).
- **A RAM write registered on the last running clock completes with the
  CPU data.** `iecdrv_mem` registers the address and the write enable and
  writes its data input one clock later. The drive units hand port a of
  their RAMs to the engine (address, data and write enable muxed on `hold`);
  in A8 the mux switched on the first stopped clock, so a CPU write
  registered on the last running clock (or repeated from a `ph2_r` held
  during a pause) completed with the engine's write data: a save could
  corrupt one 1541 RAM byte (found by analysis while instrumenting the
  1581, A10; a load rewrote it). The CPU write enable is gated with `~stop`
  (the write waits in its held ph2 pulse and completes after the resume, on
  the same drive clock as without the stop) and the engine takes the port
  only once the drive has fully stopped: `hold = ss_hold & &stop_r`, from
  the second stopped clock, in `c1541_multi` and `c1581_multi`.
- **A chain register must not reset or enable logic off the chain.** While
  the chain shifts, a register carries the bits of its neighbours for a few
  clocks. `tape_end` reset the TAP scanner (map and `ready`, not on the
  chain, media): a 1 passing through it on a save or a load wiped the map,
  `tap_loaded` fell and the tape stopped feeding the FIFO (the turbo loader
  failed after a load on the board). Such a use yields to `ss_hold`.
- **Rebuilt values come from the loaded state.** A register rebuilt at the
  start of the freeze from live state must not carry the old state across a
  load. The tape read address of the next io_cycle (`tap_play_addr +
  TAP_ADDR`) needs no rebuild: the boundary waits for `read_cyc = 0` and no
  host request (`ss_idle` bits 7 and 6), so no tape read is addressed across
  a freeze (checked with the line removed: `vartap` and the tape rewind
  scenarios pass).
- **Outputs sampled outside the machine do not move while the chain shifts.**
  The IEC, parallel cable and LED outputs of the 1541 units are combinational
  from the VIA registers: `c1541_multi` holds them (`out_h`) while `hold`
  is high, so an external IEC device on the user port never sees the bits
  passing through. After a load they show the loaded values from
  `ss_load_done` on, before the engine releases the machine.
- **Edge detectors of pins driven by other segments follow through the hold.**
  The CIA FLAG detector (`old_flag`, rebuilt) keeps following its pin while
  the engine owns the machine and latches no edge then (`flag` is on the
  chain). A load that changes the pin (the 1541 strobe of the parallel cable,
  the cassette read line) therefore fakes no FLAG edge at the release; an
  edge from an external user port device during a save is not latched.
- **Never shift the freeze or the enables.** The bus cycle grid of
  `fpga64_sid_iec` (preCycle, sysEnable, refresh, chip enables, CPU bus
  ownership) and asynchronous resets are not on the chain: they are rebuilt
  because a savestate stops and releases the machine on one grid point
  (reasons in `state_classes.yaml`).
- **Enumerated registers are stored as vectors** (`'pos`): a chain cell must
  hold any bit pattern, an FSM encoding chosen by synthesis may not.
- While the chain shifts the CPU address and write lines move, but every chip
  select is gated by `cpuHasBus` (0 while frozen) and the RAM strobes by the
  cycle grid; `nmi_ack` (cartridge freezers) is masked by `ss_en`.

Live segments:

| Segment | Bits | WP | Notes |
| --- | ---: | --- | --- |
| CPU | 201 | A3 | T65: every register (enum registers as vectors, `S` 16 bits) except the reset synchroniser `Res_n_i/Res_n_d`; cpu_6510: ioDir, ioData, `ss_currentio` (copy of currentIO, keeps the input bits of the port that hold their level) |
| VIC | 1444 | A5 | Whole 656x: register file, sprite engine, raster/row/column counters, char/pixel pipeline; `vicCycle` as a 4-bit vector, the former process variable `MShift` as `MShift_r`, the output registers behind `do`, `colorIndex`, `vicRefresh`. Every process that runs on each clock holds on `ss_hold` (BA counter, address register, refresh counter, raster IRQ/lightpen, IMMC/IMBC clears, register writes). Rebuilt: `vBlanking` |
| CIA1, CIA2 | 282 each | A4 | Whole mos6526 (timers, ICR/IMR, TOD with alarm and latch, serial port, CNT, ports). `pa_out`, `pb_out`, `pc_n` drive the keyboard, IEC and parallel cable on every clock: the chain carries copies written back on `ss_load_done`. TOD sampler and the 8521 IRQ path hold on `ss_hold`; the FLAG detector latches no edge then, and `old_flag` (rebuilt) keeps following the pin (A8: no false edge when a load changes the drive strobe) |
| SID1 | 1274 | A6 | sid_top chip 0: register file, `bus_data`, combined-waveform outputs, voices 1-3 (oscillator, noise LFSR and age, pulse, DAC hold, envelope), the shared table/filter pipeline (`state`, `v`, `f_acc_t`, sid_filter integrators and MAC) and the output samples `audio0`, `audio[0..1]`. Rebuilt: `Fc_offset` (OSD), `norm_dac`, sid_tables outputs |
| SID2 | 929 | A6 | sid_top chip 1: register file, `bus_data`, combined-waveform outputs, voices 1-3 |
| REU | 261 | A7 | Whole reu.v; holds while the machine is stopped (`stop`). Its outputs (DMA request/address/data/write, SDRAM address/data/write, IRQ, register read data) never shift: copies `ss_*` on the chain, written back on `ss_load_done` |
| CART | 331 | A7 | cartridge.v registers (banking, freezer, Epyx capacitor counter, GeoRAM bank, ...), the EasyFlash arbiter and both am29f040 flash chips (command/unlock state, program/erase counters and SDRAM write-back; synchronous reset now, `mem_req` as the copy `ss_mem_req`), then the DigiMax registers of c64.sv. All of it holds while the machine is stopped; since A11 a save can land inside a program or erase write-back ("EasyFlash and GeoRAM") |
| INPUT | 29 | A7 | 1351 mouse: position and the pot noise LFSR (the LFSR steps with the machine). The PS/2 key matrix and the joystick-to-key macros are host input cleared at every load (D3): not saved |
| TAPE | 833 | A7 | `use_tape` timeout (c64.sv, `use_tape` as the copy `ss_use_tape`), tape transport (play/record position, FF/REW, seek, end, prefetch pipeline), tape counter model (held while stopped), c1530 player and its 64-byte FIFO. The FIFO is now registers (an Altera scfifo hides its pointers); the c1530 reset is synchronous. The TAP image, its time map and version are media: a load needs the same tape inserted |
| TOP | 69 | A7 | Phase of the drive clock enable (`drive_sum`; `drive_ce` is 0 while stopped and never shifts) and the disk activity detector (turbo off, parallel cable routing) with its timeout; the detector holds on `drv_pause` (`c64_pause` one clock later, the stop of the drives, A8). Rebuilt: reset sequencer (constant at every freeze), io_cycle slot, IO strobes, ext_cycle_d, `drv_pause` |
| SYS | 54 | A3 | TOD divider `tod_sum` (was a process variable) and `ss_todclk` (copy of todclk), IEC input latch, `dma_active`, turbo, `lastVicDi`, `vicBus`, `vicAddr1514`, KERNAL select of buslogic. Rebuilt: preCycle, rfsh_cycle, sysEnable, refresh, reset, the chip enables, pulseWr_io, cpu_cyc_s, io_enable, phi0_cpu, cpuHasBus |
| RTC | 256 | A7 | PCF8583 (I2C state, time registers, 1/100 s divider) and its `use_rtc` timeout; `sda_o` and `use_rtc` as copies. The clock seen by the C64 restarts from the saved time after a load (virtual RTC): the host time is taken only at core load. Everything holds while stopped |
| DRV9_1541 | 961 | A8 | 1541 unit 9: track cache (`c1541_track`: track in the buffer and its G64 offset, pending reload, write-back edge detector, track/save synchronizers), head and GCR logic (`c1541_direct_gcr`: head position, rotation, shift register, encoder/decoder counters, wobble, noise reload values and the noise LFSR, now stepping on the drive clock enable), VIA2, VIA1 (whole 6522 with the hoisted timer/shift-register block registers), T65, then `c1541_drv`: mount sequence, head stepper and track, write-back flags and timer, `ss_mount_id` (identity of the mount at the save). Rebuilt: `buff_we`, `disk_ready`, T65 `Res_n_i/Res_n_d`, block RAM port registers, DMA transfer registers (idle at the boundary). Host side (ignored): mounted image description, SD write-back queue |
| DRV8_1541 | 1026 | A8 | 1541 unit 8 (same layout), then the `c1541_multi` glue shared by both units: ph2 divider, ROM fetch pipeline (`state`, `mem_a`, `drv_data`), ATN/DATA/CLK synchronizers, the ph2 pulses (held while the drives are stopped). The former A0 pause gate (`ena`, `drv_run`) is gone: `drive_ce` stops with the machine (A7). Rebuilt: `stop_r`, reset synchronizer, output hold `out_h` (takes the loaded outputs on `ss_load_done`) |
| DRV9_1581 | 1039 | A10 | 1581 unit 9: floppy mechanics (`floppy`: index pulse, head track and step timer, sector and byte counters, spin-up counter and rate, data clock), WD1772 (`fdc1772`: bus edge detectors, irq/drq, the SD request handshake, command state machine with its step, delay and motor timers, data transfer with CRC and buffer pointer, registers; block variables now at module scope), 8520 (whole, `pa_out`/`pb_out` included: held at the unit outputs instead), VIA, T65, then `c1581_drv`: disk change line. Every process holds while the drive is stopped. Rebuilt: T65 `Res_n_i/Res_n_d`, block RAM port registers. Host side (ignored): image geometry and write protect, mount edge detectors; not connected (ignored): 8520 `pcr`/`pc_n`, VIA `phi2_ref` |
| DRV8_1581 | 1057 | A10 | 1581 unit 8 (same layout), then the `c1581_multi` glue shared by both units: ph2 divider, ATN/DATA/CLK/FCLK synchronizers, the ph2 and 8 MHz pulses (held while the drives are stopped; the A0 gate `ena` is gone). Rebuilt: `stop_r`, reset synchronizer, output hold `out_h` (takes the loaded outputs on `ss_load_done`), ROM fetch (`state`, `mem_a`, `drv_data`: repeated while the drives are stopped) |
| OPL3 | 117 | A9 | C64 side of the Sound Expander (`opl3.sv`): index register, `old_write`, both timers (preset, mask, active, overflow flag, counter, rate accumulator, activation edge, overflow pulse) and `irq_n`; synchronous reset that yields to `ss_hold`, all of it holds while the engine owns the machine (the timers count only while the machine runs). The register shadow is region OPL3_REGS; the FM part on clk48 runs on across a load and gets the registers that differ ("OPL3: register shadow and replay"). Rebuilt: `fmreg` (what the FM part has), shadow clear walk, replay step, region port |

Chain order (map word address): engine -> TAPE -> RTC -> TOP (c64.sv) -> SYS
-> (fpga64 `ss_ext_so`) OPL3 -> DRV9_1581 -> DRV8_1581 -> DRV9_1541 ->
DRV8_1541 (iec_drive) -> INPUT -> CART -> REU (`ss_ext_si`) -> SID2 -> SID1 ->
CIA2 -> CIA1 -> VIC -> CPU -> engine.
Inside `c1581_multi` and `c1541_multi`: unit 9, the glue, unit 8; inside a
1581 unit, from its chain input: `c1581_drv` (disk change line), T65, VIA,
8520, WD1772, floppy (whose bits leave first). TAPE moved to words 200-213
when its FIFO joined the chain (words 91-97 stay free); the TAPE_FIFO region
is gone. OPL3 keeps words 173-175 for its 117 bits (A9); words 176-186 are
free (the FM part stays out of the chain, D9).

Video output across a load: the machine resumes when `video_sync`'s
free-running output reaches the raster position of the loaded VIC (read-only
taps `vic_x`/`vic_y`, no chain bits; `PAUSE.md`), at most one frame after
the engine releases it, so the analog output and the scaler see no sync
jump and `video_calc` no change of resolution. The output dot divider
ignores the VIC hsync while the machine is stopped: the chain moves it
through the bits of its neighbours during every save and load. A request
that comes while the machine is stopped away from a boundary (user pause)
lets it run to the boundary only on the sample after `resume_ok`
(`ss_freeze` input `run_ok`), so that run does not move the output either.
Until 15 November all three failed: a load resumed on the pre-load stop
point (one irregular line and frame; Main showed the video info after loads
with `video_info`, the scaler resynchronized), every save and load moved
the output by 40-100 dots, and a save or load from a user pause jumped the
output by the paused time.

## Tests

| Command | What |
| --- | --- |
| `sim/ss/run_tb.sh` | `tb_savestates` (engine + arbiter + freeze controller + DDR3 model with random waitrequest, garbage readdata and burst reads + drive traffic during the operations + 75-bit test chain of three segments; D13: SDRAM transfer port model taking the first word with the request, REU pages saved as records and restored, unmapped pages zeroed, a damaged record order with a valid CRC refused, a format 1 slot with the whole REU loaded, DDR3 bursts of 32 and every drive beat delivered), `tb_savestates_dead` (same, one segment not live), `tb_statemanager`, `tb_ssui`, `tb_ss_transport` (D13, Verilator: `rtl/sdram.v` + checked chip model + `ss_sdram_port`: the power-on fill requested during the controller's init, normal accesses before, during (masked) and after ownership, write/zero/read transfers on random rows of both lanes and all banks, the other lane untouched, 0 violations in both owner buckets), `tb_ascal_vcpt` (D13, GHDL: the local change of `sys/ascal.vhd` against upstream, "Resources"), GHDL analysis of `ss_chain_pkg.vhd`; also in CI (savestate-checks) |
| `sim/tests/savestate.sh` | whole core (Verilator, DDR3 modelled): save at READY, change screen and Color RAM with a PRG, load: RAM and Color RAM restored exactly, screenshot equal; OSD self-test |
| `SDRAM=real DRIVES=0 sim/build.sh` | Build real `rtl/sdram.v` driving a command-level MT48LC16M16A2, then run each of `savestate.sh`, `pause.sh` and `ssdiff.sh` with `SDRAM=real`. Checks byte lanes, bank/row state, CAS=2, auto-precharge, initialization, tRCD/tRP/tRAS/tRC/tRFC/tWR/tMRD and rolling 8192-refresh/64 ms retention. Each instance reports violations and longest refresh gap separately while `ss_sd_own` is asserted and during normal running; a violation fails the run. Use the same option for the long `LORENZ`/`VICII` run. Timing sources and model limits: `sim/README.md`, “Real SDRAM controller and chip checking”. |
| `sim/tests/sdram.sh` | Chip self-check: all banks, both byte lanes, DQM on writes and reads, CAS=2, auto-precharge, intentional tRCD and refresh-deadline violations with engine ownership. Then a throwaway `RTL_OVERLAY` build with `RASCAS_DELAY=1`: requires actual tRCD violations, not just a failed boot (18 frames: the power-on REU fill comes first). On 2026-11-06: chip checks PASS; overlay rejected with 143,603 normal-running tRCD violations, zero engine-owned violations. On 2026-11-15 (D13, final RTL): chip checks PASS; overlay rejected with 328,119 normal tRCD violations, the engine-owned power-on fill 0 violations (9,118,336 clk_sys, 133,923 refreshes, longest gap 456 clk64). |
| `sim/tests/ssdiff.sh` | Field offsets from slots saved at a known point (`ss_slot.py --fields`): CPU PC/A/X/Y, CIA1 and VIC after the KERNAL init (regs.prg), SID1/SID2 register files (sid.prg), REU registers after a swap (reu.prg), CART bank registers (ocean.crt). B3 differential `ssdiff` at READY, in sid.prg (noise/pulse/triangle, gate toggles, filter sweep, OSC3/ENV3 read back), reu.prg (REU 512 KiB: swap and $FF00-triggered fetch in a loop, REU RAM in the slot), ocean.crt (Ocean bank switching from the cartridge ROM) and, with `LORENZ=<dir of Disk1-3.d64>` / `VICII=<dir of VICE VICII testprogs>`, inside 29 Lorenz 2.15 tests (CPU, CIA timers/TOD/ICR/serial) and 9 VIC-II tests: B saves slot 2, runs on, saves slot 1, loads slot 2, loads slot 1, saves slot 3 (= slot 1 byte for byte), resumes, and must stay sample-identical (bus, RAM strobes, RGB, audio mix) to the uninterrupted A; the 'rebuilt' grid registers and the T65 reset synchroniser are checked on every clock the engine owns B. `JOBS=n` runs tests in parallel. Test programs: `sim/scripts/testprgs.sh`; `--prg x.crt` loads a CRT through the OSD index |
| `sim/tests/pause.sh` | A0 user pause (no savestate): B paused, A not, sample-identical after the resume and regular video sync; READY (key, pad), tape LOAD on a pilot tone and on varied pulses with a 10-frame pause (`tapevar`), sid.prg, reu.prg, ocean.crt, ef.crt (the pause inside a sector erase, A11), geo.prg (A11), rtc.prg, opl.prg (`--opl`: the OPL output is in the compared audio, A9) |
| `sim/tests/ssdiff.sh` opl.prg, oplrewind (A9) | `--opl`, Sound Expander on (status 12, DolphinDOS): the OPL3 fields at the first wait of opl.prg (index $A0 before its value, timer presets and enables) and the OPL3_REGS region; ssdiff inside the music (timers polled by the CPU, index written before each wait), audio compared up to the first load, the rest of the sample exact. After the resume, with a model of the queue the Z80 reads: B's queue consumed within one frame (21,234 clk_sys), at that point the registers and the index latch the firmware took equal B's shadow and index register, and at the end the register files of A and B are equal. `oplrewind` (`--rewind`, audio left out): the FM part holds the registers of C1 when the state of C0 is loaded, so the replay has to queue the changed ones. Negative controls (overlay of `opl3.sv`): without the final index the latch check fails; without the replay `oplrewind` fails |
| `sim/tests/ssdiff.sh` tape scenarios | `pilot` (pilot tone), `vartap` (20000 pulses of varied length: a byte lost, repeated or corrupted anywhere in the tape path changes the cassette line, a pilot tone hides it) and `rewind` (`--rewind`: B saves slot 2 at C0, runs on, loads it and must replay A's samples from C0, i.e. a load of a state from another moment) |
| `sim/tests/ssdiff.sh` ef.crt, geo.prg (A11) | `ef`: EasyFlash CRT (`testprgs.sh`) that boots in Ultimax and loops from RAM: sector erase of ROML banks 0-7 with DQ6 polling (the poll count goes to the screen), 64 bytes programmed in bank 1 from the pass number and the EasyFlash RAM, read back and summed into the EasyFlash RAM; both save points and loads fall inside a sector erase (`CART.ez_rom_rom0_state` busy and `ez_rom_rom0_mem_req` set in both slots), so the busy counter, the partly done write-back and the partly erased flash come back. `geo`: GeoRAM 4 MiB on (status 52 at READY), pages written through $DFFE/$DFFF and $DE00 and read back one and eight passes later on both sides of the save points; the GEORAM region in both slots. The harness lets A run at most 1M samples ahead of B's comparisons, so the seconds a GeoRAM save takes queue no samples |
| `sim/tests/ssdiff.sh` reu16, reu16full, reu2m, crc16 (D13) | REU on at READY (`--status-ready 53,54`, 16 MiB; `54`, 2 MiB). `reu16`: reu.prg, the slots hold REU_PAGES with the few pages written. `reu16full`: `--reu-fill` (every page of the 16 MiB lane written and mapped): the worst-case save and two loads of 16 MiB inside the differential; both slots hold 4096 records. `crc16`: a damaged full 16 MiB slot refused after the verify pass, the machine untouched. 2026-11-15, default SDRAM model: all PASS (`reu16full` 3,949,258 running samples identical, slots of 4,233,508 words; `reu16` and `reu2m` 4,735,306; `crc16` refused with result 6, CRC/structure, chain and RAM unchanged) |
| `run_core.sh pausetest --no-cache --sync-check` | D13: the core output from power on to READY, across the power-on REU fill (machine in reset) and the hand-back of the SDRAM, keeps a regular h/v sync after the start-up frame (every irregular line and frame is listed, with the sample where the fill ended) and the picture changes; then the usual user pause differential. 2026-11-15: PASS, fill done at sample 2,279,532, the only irregular periods are those of the start-up frame (hsync 506 at sample 157,259, 417 at 157,676, vsync 308,867 at 463,604), identical in the A12 model with the same check; user pause PASS, video PASS |
| `run_core.sh pausetest --load-slot board.ss` | A/B pause test from a slot saved on the board (sim built with `BUILD_DATE=yymmdd` of the board build, same chain) |
| `DRIVE=1 sim/tests/ssdiff.sh` | adds the drive differentials on the full model, run at once: 1541, DolphinDOS parallel-cable `LOAD"*",8` of a 7-block file from a D64 made by `mkd64.py`, both save points (C0, C1) and the load while the head reads track 17 (`DRV8_1541.track` checked in both slots), drive RAM, RAM expansion and track buffer in the slot; 1581 (A10), DolphinDOS `LOAD"*",8` of a 3-block file from a D81 made by `mkd81.py`, both save points while the WD1772 reads the 10 sectors of the directory track (`DRV8_1581.fdc_track` 0x27 and `fdc_motor_on` checked in both slots), drive RAM and sector buffer in the slot; `drive1581rw` (`--rewind`): the load of a state saved while the WD1772 hands the bytes of a sector to the CPU (checked in its slot: transfer running) |
| `DRIVE=1 sim/tests/pause.sh` | adds the user pause during the same DolphinDOS disk LOADs (1541 and 1581, full model) |
| `sim/run_core.sh boot --prg f.prg --freeze-at <cycles or $ADDR> --slot out.ss` | write a slot image; `--load-slot in.ss` restores one |
| `sim/scripts/ss_slot.py slot.ss` | header, TLV list, CRC check with zlib, REU_PAGES record check (format 2), `--region TAG file` extracts a region, `--reu file` writes the REU as a 16 MiB image (format 1 or 2, absent pages zero), `--fields SEG` decodes a chain segment |

The DRIVES=0 quick suite also exercises NTSC 6567R8 at power on (SID and a
decimal ADC/SBC CPU loop), C128 turbo at 2x/4x and Smart
turbo at 3x/4x (with measured accelerated CPU cycles before and after
loads), moving 1351 mouse packets and live analog paddles while a CPU loop
reads POTX/POTY into screen RAM. `paddles` sets Pot 1/2 to Paddles
(status[27:26] = 2); all four host paddle outputs are harness-writable and
move every 8192 running clk_sys, without counting B's frozen time.
`mousefreeze` injects one packet 128 engine-hold clocks into a save and
one into a load, with A receiving each at the same running timestamp.
The mouse toggle detector holds during engine ownership, so a single
pending packet applies once after release (to restored coordinates on a
load), before the video-aligned resume. The save excludes that pending
host input. This scenario restores the current paused snapshot and checks
exact running-sample equality plus changing CPU pot reads before and after
resume, rather than requiring a slot including new host movement to equal
the earlier slot. Multiple packets in one hold are not queued: even toggle
counts drop all movement, odd counts apply only the last delta (D3).
`pause.sh` checks NTSC sync/frame replay as well as PAL. NTSC uses the
correct VIC line geometry but the harness clocks retain PAL frequencies.
NTSC automatically enables the CLK_50M configuration domain, and READY
checks the actual latched VIC mode. Without that clock, status bit 2 alone
silently leaves the VIC in PAL; the video geometry check detects this.

`ssdiff --reject reu-off|reu-on|crc|version|chain` checks the engine result
and OSD message, saves the halted machine before and after refusal to
prove its live chain and memory are unchanged, and compares its resumed
running samples with uninterrupted A. REU 512 KiB -> off and off -> 512 KiB
are real status changes, not edits to the slot's config mask. A CRC-field
bit flip must fail verification; a changed format version or chain length
must fail compatibility. `--build-hash` changes only the hash and requires
successful exact replay: compatibility intentionally does not require the
same build date.

OPL `opl`/`oplrewind` now use three destination-clock synchronizer stages
in the behavioral dcfifo; `opl2`/`oplrewind2` repeat them with two stages,
and `pause.sh` checks both. `--fifo-sync 0` is the old instantaneous model
for comparisons. The small FIFO bench checks visibility, full/empty,
pointer wrap and clear at all three settings; analog metastability and
clear-deassertion timing are not modelled.

Verification run 2026-11-07 (DRIVES=0): the complete `pause.sh`,
`savestate.sh`, `sim/ss/run_tb.sh` and quick `ssdiff.sh` passed, including
every hardening scenario above. No synthesized RTL change was needed.
Real-controller acceptance on 2026-11-07 (`DRIVES=0`, `JOBS=6`): savestate,
all 11 pause scenarios, quick ssdiff (15 differentials + 6 field snapshots)
and long ssdiff (53 differentials + 6 field snapshots, Lorenz/VIC-II) PASS.
Every scenario reported zero SDRAM violations in both ownership buckets.
Longest refresh gap: 256 clk64 / 4059.89 ns outside engine ownership,
64 clk64 / 1014.97 ns during engine ownership, including GeoRAM's long
save/load sequence. Full-drive and NTSC real-controller runs remain untested.

## Resources

Quartus 17.0.2, CI run of `48da424` (engine integrated with D2/D3, no chain
segment yet): 29,957 ALMs (71 %) against 28,100 for `pause`, i.e. about
+1.86k ALMs for engine, freeze controller, arbiter, SDRAM port, UI and
request manager; M10K 431 / 553 unchanged (no new block RAM); worst setup
slack +0.440 ns (`pause`: +0.369 ns).

A3 (CPU + SYS live, 255 chain bits), local Quartus 17.0.2 Lite compiles
(Actions are off): 30,373 ALMs (72 %) against 30,194 for `b43a424` (A2 with
the `pause` merge, whose `pause_fb` frame buffer took M10K to 483 / 553),
i.e. +179 ALMs; M10K unchanged; worst setup slack +0.596 ns
(`b43a424`: +0.282 ns), worst hold +0.211 ns. Timing met on all clocks.

A4 (CIA1/CIA2 added, 819 chain bits): 30,516 ALMs (73 %), setup +0.500 ns,
hold +0.231 ns; with the D5 CONF_STR 30,499 ALMs, +0.281 / +0.208 ns.
A4-A6 (`0bb1337`, 4466 chain bits): 31,528 ALMs (75 %), i.e. +1,155 over
A3 for the CIA, VIC and SID segments; M10K 482 / 553; worst setup slack
+0.110 ns on the HDMI clock (the core clocks keep +1.65 ns or more), worst
hold +0.205 ns. Timing met on all clocks (decision D4: no ALM ceiling).
A7 (REU, CART, TAPE, RTC, INPUT, TOP, 6245 chain bits): 32,753 ALMs (78 %),
M10K 481 / 553, setup +0.125 ns, hold +0.174 ns. A8 (both 1541 units, 8232
chain bits, six drive regions): 33,623 ALMs (80 %), M10K 501 / 553, setup
+0.206 ns, hold +0.242 ns. A9 (OPL3, 8349 chain bits, region OPL3_REGS):
33,755 ALMs (81 %), M10K 503 / 553 (the two 256-byte copies), setup
+0.346 ns (HDMI clock), hold +0.208 ns; the worst OPL path is inside the
Z80 on clk48 (+1.27 ns), clk48 -> clk_sys (`opl_s`) +5.9 ns. A10 (both 1581
units, 10445 chain bits, regions RAM_1581_8/9 and FDC_BUF_8/9): 34,916 ALMs
(83 %), 39,335 registers, M10K 503 / 553 (unchanged: the engine reads the
1581 RAMs on their CPU read port; a read on port a cost 16 more), setup
slack +0.505 ns, hold +0.243 ns. A11 (chain unchanged, 17 regions, the
boundary no longer waits for the EasyFlash write-back): 34,751 ALMs (83 %),
39,338 registers, M10K 503 / 553, worst setup slack +0.517 ns (HDMI clock),
worst hold +0.253 ns; clk_sys +2.622 / +0.255 ns, clk64 +1.658 / +0.253 ns,
clk48 +2.668 / +0.261 ns. A12 (rewind ring in the request manager, engine
input `ring`, UI; chain, slot format and M10K unchanged): 34,846 ALMs (83 %,
+95), 39,336 registers, M10K 503 / 553, worst setup slack +0.617 ns (HDMI
clock), worst hold +0.245 ns; clk_sys +2.114 / +0.256 ns, clk64 +1.812 /
+0.245 ns, clk48 +2.611 / +0.253 ns. D13 (block transport with READs every
other clk64, REU page map, 21 MiB slots, power-on fill under reset;
`C64_A12r.rbf`, md5 `237c89151a787440e45d2adbb2a46e11`): 35,725 ALMs (85 %,
+744 over A12v's 34,981), 40,088 registers, M10K 504 / 553 (+1: the REU page
map; the engine FIFO is an MLAB), worst setup slack +0.195 ns (HDMI clock),
worst hold +0.173 ns (HDMI clock); clk_sys +2.863 / +0.254 ns, clk64 +1.433 /
+0.252 ns, clk48 +2.969 / +0.417 ns. The `sdram.v` I/O registers stay packed into the
I/O cells as in A12: the same 68 register/pin pairs (16 DQ input, 16 DQ
output enable, 36 output registers). D13 with the load sync fix of
`savestates` (merge of `9a607eb`: `vic_x`/`vic_y` taps into `video_sync`,
`ss_freeze` `run_ok`; `C64_A12rs.rbf`, md5
`4a677c9291015139bc00c6b59692dbd8`, clean database): 35,801 ALMs (85 %, +76),
39,963 registers, M10K 504 / 553, DSP 60, worst setup slack +0.127 ns (HDMI
clock), worst hold +0.241 ns (clk64); HDMI +0.127 / +0.259 ns, clk_sys
+1.629 / +0.263 ns, clk64 +1.167 / +0.241 ns, clk48 +2.516 / +0.252 ns; the
same 68 I/O register/pin pairs.

**Local change of the framework (A11).** `sys/ascal.vhd` (the MiSTer scaler,
identical to Template_MiSTer master, which has no newer version of it) is
changed in one place: in the vertical scaler (`VSCAL`, cycle 8) the compare of
the output line counter `o_vacpt` with the input height `o_ivsize` that picks
the taps at the bottom edge of the picture is registered one clock earlier
(`o_vacpt_gt`, `o_vacpt_eq`). Both values change only in the output sync
periods (`o_vacpt` in state `sHSYNC`, `o_ivsize` at the end of the vertical
sync), so no displayed pixel sees the extra clock. Without it the first A11
compile missed the HDMI clock by 0.075 ns on that path (`o_vacpt[9]` ->
`o_vpixq_pre[2].g[6]`, clock skew -0.665 ns), with an RTL two lines away from
A10 (+0.505 ns): the margin of the scaler moves with the placement of the
core. A framework update has to keep or redo this change.

**Local change of the framework (D13).** The first D13 fit missed the HDMI
clock by 0.205 ns (28 paths, all `o_vcpt_pre3` -> `o_vcpt_pre3`: the line
counter of the output sweep `OSWEEP`, through the adder of `o_vcpt_pre3+1`
and its compare with the frame length `o_vtotal` into the synchronous clear
of the counter; 3 logic levels, data 6.214 ns, clock skew -0.523 ns), with
the core clocks at +1.5 ns or more. Template_MiSTer master (last change of
`sys/ascal.vhd`: `baaeff6` "ascal: reset o_state at vsync", 2026-08-22) is
identical to this file apart from the A11 change and has the same compare
(its line 2788). Second change, the same kind as the A11 one: the compare is
registered one clock before its use (`o_vcpt_pre3_end`). `o_vcpt_pre3`
changes only on a line-end clock (line ends are at least two clocks apart
for `o_htotal` >= 2, every real mode), so the register holds the compare of
the current line on every line-end clock; `o_vtotal` is the mode setting,
sampled without synchronization (`-- <ASYNC> ?`), so the change is the same
as a mode change that reaches ascal one clock later. `OSWEEP` has no reset:
the counter starts at 0 and the register at false, the compare of 0 for any
`o_vtotal` >= 2. `sim/ss/tb_ascal_vcpt.vhd` (GHDL, in `run_tb.sh`) checks
it on 4M clocks: the changed counter equals upstream fed with `o_vtotal` one
clock late on every clock (9,422 changes of `o_vtotal`, 615 on a line-end
clock, 31,746 frame wraps, VRR jumps, `o_htotal` changes) and equals
upstream on every clock while no change falls on a line-end clock; a
mutated copy (compare two clocks late) fails. After the change the HDMI
clock had +0.593 ns, and +0.195 ns in the final D13 fit (the later
`sdram.v` and fill changes moved the placement; the worst HDMI paths are the
polyphase filter paths of the scaler now). A framework update has to keep or redo both changes.

Measured in simulation (sstest): RAM + Color RAM save 19 ms, load 26 ms;
with the drive regions (A8) save ~810k clk_sys (26 ms), load ~1.14M clk_sys
(36 ms), with the 1581 regions too (A10, `savestate.sh --full`) save 913k
clk_sys (29.0 ms), load 1.30M clk_sys (41.3 ms); with GeoRAM 4 MiB + REU
512 KiB save 1.37 s, load 1.84 s (slot 4.57 MiB). The chain muxes come on
top with the chip WPs (one 2:1 mux per flip-flop).

D13 (block transport, `savestate.sh` DRIVES=0, both SDRAM models,
2026-11-15): save 258,051 clk_sys (8.2 ms), load 251,956 clk_sys (8.0 ms),
against 802k / 1.195M before (slot 124,040 bytes, mostly the drive regions
on their byte paths); the OSD self-test 1,025,420 clk_sys; the real
controller with 0 violations (engine-owned: 174,296 refreshes, longest gap
540 clk64). The first build, one READ per clk64, saved in 224,869 clk_sys.

D13 differentials (`ssdiff.sh`, default SDRAM model, 2026-11-15), save /
load in clk_sys: REU 16 MiB with every page written (`reu16full`, 4096
records) 17,842,227 (0.566 s) / 12,106,387 (0.384 s); REU 16 MiB with 8
pages written (`reu16`) 507,592 / 287,255; GeoRAM 4 MiB (`geo`) 4,649,221
(0.147 s) / 3,211,485 (0.102 s), against a 38.6M (1.22 s) save before;
EasyFlash (`ef`) 1,424,181 / 1,037,751, against 10.83M / 14.76M before; a
damaged 16 MiB slot is refused after the verify pass in 2,610,938 (83 ms).
The 16 MiB save misses the 0.4 s aimed at: one READ every other clk64 (the
board-safe cadence) moves one REU byte per two clk64, a floor of 16.78M
clk_sys (0.532 s). Format 1 slots saved by the A12 model (REU 512 KiB,
REU 2 MiB, sid.prg) load (621,714 / 1,732,038 / 251,669) and save again
as format 2 with the same RAM and REU image (128 / 512 pages; sid.prg
without a REU).
