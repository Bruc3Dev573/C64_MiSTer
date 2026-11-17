# A1 - State inventory

Work package A1 of the savestate plan: every flip-flop and inferred memory of
the design is classified in `savestate/state_classes.yaml`, and the scan-chain
`fields` of each segment in `savestate/map.yaml` hold the classified bits.
Scope is decision D1: everything is saved, nothing is left out.

## How to reproduce

```
lint/run_inventory.sh --fail-unclassified   # B7 on the whole design, exit 0
python3 tools/ss/inventory_fields.py VIC     # fields of a segment from lint/build/inventory.csv
python3 tools/ss/gen_ss_map.py               # regenerate the map artifacts (--check in CI)
```

The lint now fails when a segment's `fields` do not add up to the arch bits
of its rules, and when a rule names a segment or region missing from the map.
CI runs it with `--fail-unclassified`.

Lint fixes made on the way (they changed the counts):

- generate scopes were lost (`drives[0]`/`drives[1]`, `chip[0]`/`chip[1]`
  shared one path); paths now come from the Verilator `hier` attribute;
- block variables with the same name in different `always` blocks of one
  module collapsed into one entry (c64.sv has four `to`, two `act`, two `div`,
  two `old_download`); the later ones are now `to#2`, `to#3`... in source order;
- brackets in rules are literal (`drives[0]`), `*` and `?` are the wildcards.

## Totals

Design: 2360 storage elements, 14647 flip-flop bits, 99 memories.

| Class | Entries | Bits |
| --- | ---: | ---: |
| arch | 1668 | 10890 (9814 FF + 1076 in small register arrays) |
| region | 28 | 522752 (65.3 KB in 14 regions, plus RAM/GeoRAM/REU in SDRAM) |
| rebuilt | 259 | 2044 FF + 2 tables |
| ignored | 405 | 2789 FF + ROMs, overlays, SDRAM model, media indexes |

### Scan-chain segments

| Segment | Arch bits | Words | Contents |
| --- | ---: | ---: | --- |
| CPU | 200 | 5 | cpu_6510 port (iodir/iodata/currentio) + T65 |
| VIC | 1444 | 24 | whole VIC-II except vBlanking |
| CIA1 | 283 | 6 | whole mos6526 |
| CIA2 | 283 | 6 | whole mos6526 |
| SID1 | 1233 | 21 | chip[0] voices + element 0 of the sid_top register files + shared filter/table pipeline |
| SID2 | 942 | 16 | chip[1] voices + element 1 of the sid_top register files |
| REU | 261 | 6 | whole reu.v except two '=' temporaries |
| CART | 331 | 7 | cartridge.v registers, ez_rom + 2x am29f040, DigiMax DAC (c64.sv) |
| TAPE | 321 | 7 | tape_subsystem transport, c1530 player, tape counter values, FIFO pointers, use_tape |
| INPUT | 186 | 4 | keyboard matrix, joystick-to-key macros (c64.sv), c1351 mouse |
| DRV8_1541 | 1026 | 18 | unit 8 + c1541_multi glue shared by both units |
| DRV9_1541 | 953 | 16 | unit 9 |
| DRV8_1581 | 1117 | 19 | unit 8 + c1581_multi glue |
| DRV9_1581 | 1041 | 18 | unit 9 |
| OPL3 | 788 | 14 | timers, Z80, FM sequencer, queue pointers |
| SYS (new) | 76 | 3 | fpga64_sid_iec glue: bus cycle, clock enables, DMA/turbo, TOD time base, KERNAL select |
| TOP (new) | 148 | 4 | c64.sv: reset sequencer, SDRAM io_cycle slot, drive clock enable, IEC activity, IO strobes |
| RTC (new) | 257 | 6 | PCF8583 (rtcF83) and its enable |
| **total** | **10890** | **200** | 170.2 words of bits; each segment keeps one spare word |

**The plan's 0-127 word space is too small**: the arch bits alone are 171
words. The map now spans words 0-255 (`MAX_WORDS = 256` in
`tools/ss/gen_ss_map.py`), segments are contiguous in chain order. This needs
a decision (Q1). `DRV_1581` became `DRV8_1581` and `DRV9_1581` (the design has
two 1581 units, the plan had one segment).

### Regions

New regions: `EXTRAM_DRV8/9` (1541 8 KB RAM expansion, optional),
`TRACK_DRV8/9` (1541 GCR track buffer, 8 KB), `FDC_BUF_8/9` (WD1772 sector
buffer, 1 KB), `OPL3_RAM` (8 KB, optional), `OPL3_FIFO` (1024 x 10 bit,
optional), `TAPE_FIFO` (64 bytes). Without the optional ones the slot needs
105,792 bytes of regions plus 1,362 bytes of chain.

## Engine preconditions used by the classification

The 'rebuilt' and some 'ignored' reasons depend on these; the engine (B1-B3)
must guarantee them.

- **P1** Block RAM clocks keep running while the machine is paused, and after
  a load the machine stays paused at least 2 clocks of each memory clock
  before it resumes: the port registers (address/data/we/q) are then rebuilt
  from the restored port inputs.
- **P2** Capture starts at least 2 clocks after the machine stopped, so no
  block RAM write is in flight (`wren_*_d = 0`).
- **P3** No DDR3 burst (1541 `c1541_track` DMA idle, arbiter unlocked) and no
  SD transfer (`sd_rd`/`sd_wr`/`sd_ack` low for the 1541 write-back and the
  1581 FDC) is in flight at capture and at load.
- **P4** Host strobes are idle (img_mounted, sd_ack, ioctl). Edge detectors of
  host signals are 'ignored': they follow the live signal; restoring them
  could only fake an edge.
- **P5** No save during a download/upload, PRG injection, RAM erase or reset
  (the host loader state in c64.sv is 'ignored').
- **P6** The same media (disk images, TAP, CRT) are attached when a slot is
  loaded; media and their indexes are not in the slot (Q2, Q3).

## Per module

### c64.sv (emu)

- arch: TOP 148 bits (reset_n, reset_counter, reset_wait, do_erase,
  io_cycle_ce/we/addr/data/D, drive_ce + its accumulator `sum`, disk_access
  and its timer `to#2`, IEC/parallel edge detectors, ce_sys_div, ext_cycle_d,
  old_ioe/old_iof/ioe_we/iof_we); INPUT (joy_last, joy_finish, act, to,
  start_strk, reset_keys); CART (DigiMax dac[4], act#2); TAPE (use_tape,
  to#3); RTC (use_rtc, to#4).
- rebuilt: `msum` (from ntsc every clock), `dac_l/dac_r` (from dac/act every
  clock), `joy_key` ('=' temporary).
- ignored: PLL reconfiguration (cfg_*, ntsc_r, state, delay, osd_s*,
  close_osd); PAL/NTSC synchronisers (config); host loader/eraser (ioctl_*,
  inj_*, erase*, force_erase, rd_cyc, CRT header parser cart_blk_len/hdr/
  bank_*/id_hi); attached-cartridge identity (cart_id, cart_exrom, cart_game,
  cart_attached, ext_crt: media, Q2); EasyFlash write-back to the SD file
  (ezfl_*); `key` (PS/2 event pipe, its strobe must follow the host); mount
  status (drive_mounted, old_img_mounted); video output (hq2x160, ce_pix,
  div, lores, vcrop, wide, ovl_color); pause framework (user_pause, freeze,
  pause_dim, pause_att, div#2, edge detectors); debug overlay (dbg_*,
  repeat_*, dir_*); audio mix (cin, cout, alm/arm/alo/aro); SID filter file
  loader (sid_ld_*); external UART synchronisers; tape LED (act_cnt).

### fpga64_sid_iec

- SYS 76 bits: all glue registers. `417/sum` is the process variable `sum`
  of the TOD time base; the IEC input latch `cia2_pai[7:6]` was an unnamed
  ghdl net (`633`) and is now the named signal `cia2_pai_iec`.
- buslogic: KERNAL/charset select (`c64*_ena`, latched at reset from
  status[15:14]) is arch; ROM contents ignored; ROM `q0` rebuilt.
- Color RAM: region; its `q` rebuilt.

### CPU (cpu_6510 + T65): all arch, 200 bits

VICE MAINCPU + C64 CPU port: A/X/Y/S/P/PC (T65 `debug/a`, `debug/x`,
`debug/y`, `s`, `p`, `pc`), IR, MCycle, interrupt pipeline (irqcycle,
nmicycle, nmiact, nmi_entered, irq/nmi request), bus latches. VICE also saves
the bit 6/7 fall-off timers of the CPU port; cpu_6510 has no fall-off model.

### VIC-II: 1444 arch bits

Everything (registers, raster/cycle counters, video matrix line `charstore`
468 bits = VICE vbuf/cbuf, sprite DMA/MC/MCBASE/shift state, collisions,
light pen, border flip-flops, pixel pipeline). Rebuilt: `vsync`
(vBlanking = rasterY == rasterBlank every clock). `hblanking`, `hblack`,
`colorindex` only feed the video output but are kept (6 bits).

### CIA1/CIA2: all arch, 283 bits each

Matches VICE CIA: ports/DDR, timers + latches + control, ICR/IMR and the IRQ
pipeline, TOD (time, latch, alarm, 50/60 Hz divider), serial port.

### SID (sid_top, DUAL)

- arch: register files (`Voice_*`, `Filter_*`, `Fc_offset`, `bus_data` split
  [SID1, SID2]), voices (oscillator, noise LFSR/age, pulse, envelope
  generator, DAC pipeline dac_out/env_dac/dca_out, wave_out for OSC3,
  floating-DAC keep_cnt), combined waveform samples `_st_out/p_t_out/ps__out/
  pst_out` (read by the voices at ce_1m, computed in the previous SID cycle),
  state/v/f_acc_t, sid_filter integrators and pipeline.
- rebuilt: `norm_dac` (every clock from the waveform), sid_tables `f0`,
  `f0_adj`, `*_out` (registered table lookups, every clock).
- ignored: `audio`, `audio0` (output samples, audio mixer only),
  `f6581_curve` (filter curve file, configuration).

### Keyboard, mouse (INPUT)

- arch: key matrix (`key_*`, `phys_*`, `mod_key*`, `key_8s`, `delay_cnt`,
  `restore_key`), mouse x/y and pot noise LFSR.
- rebuilt: `pao/pbo` (matrix output, every clock), tape hotkey pulses.
- ignored: `ps2_stb`, mouse `old_status` (host strobe edge detectors).

### REU: 261 arch bits

All registers, DMA state machine and the 2-byte swap/verify buffer. Rebuilt:
`addr_mask` and `error` ('=' temporaries recomputed every clock). REU RAM is
the REU_RAM region.

### Cartridge (CART)

- arch: banking/enables, freeze logic, GeoRAM bank, EasyFlash flash state
  machines (am29f040 unlock/state/busy_cnt/pending SDRAM write requests),
  ez_rom glue.
- ignored: `lobanks/hibanks` (+maps, bank_cnt, old_loading): bank table of
  the CRT in SDRAM written only by the host loader (media); `old_id` (copy of
  cart_id).

### Datassette (TAPE)

- arch: transport (play address, end, sense, ff/rew, seek, read cycle,
  FIFO write request), c1530 player (pulse/wave counters, motor), scfifo
  pointers, tape counter values (abs_count, d_*, pos_acc, threshold,
  dividers, used for ff/rew seeking).
- region: TAPE_FIFO (scfifo contents).
- rebuilt: `tap_time_map.rd_data` (RAM read register).
- ignored: tap_scanner + tap_time_map (index of the TAP image, media),
  tap_version (file header), command edge detectors, counter overlay pixels.

### RTC: 257 arch bits

PCF8583 registers/RAM (`tm`, 17 bytes), second counter, I2C state, plus
use_rtc and its timer in c64.sv.

### OPL3 (SFX Sound Expander): 788 arch bits

- arch: C64 interface (index, timers, IRQ), timer accumulators, opl3sw (CE,
  44.1 kHz counter, struct base, sequencer reset), NextZ80 (registers incl.
  the 14 x 16 register file, fetch/stage), opl3seq (LFO/EG counters, micro
  sequencer, accumulators), dcfifo pointers.
- region: OPL3_RAM (program, data, operator state), OPL3_FIFO (queue).
- rebuilt: RAM read registers, register-file loop index.
- ignored: `pause_s` (pause synchroniser).

### 1541 units

- arch: 6502 + 2 VIAs, mount/write-protect sequence, head position and
  stepper, save-track trigger and read timer, direct_gcr (rotation,
  bit/byte counters, shift register, wobble, flux and noise reload, LFSR),
  c1541_track foreground identity (cur_track, cur_track_offset, track_new,
  update, old_save_track and its synchronisers). Shared glue (ph2 divider,
  ROM fetch state/mem_a/drv_data, IEC synchronisers) goes to DRV8_1541.
- region: RAM_DRV8/9, EXTRAM_DRV8/9, TRACK_DRV8/9.
- rebuilt: RAM/ROM/track-buffer port registers (P1, P2), `rec` reciprocal
  table, DDR3 DMA registers `dma_*` and `ddr_offset_q` (P3), `rom_sz`.
- ignored: SD write-back of the DDR3 image (dirty_tracks, bg_*, bg_buffer,
  scan_track, lba, sd_*), DDR3 arbiter (P3), mount/ack edge detectors,
  `dirty_sync` (write LED only), drive ROM contents/size, `dtype`
  (config_mask).

### 1581 units

- arch: 6502, 8520 CIA, VIA, WD1772 (command/status, track/sector, step
  timing, CRC, transfer counters, IRQ/DRQ, SD request handshake), floppy model
  (rotation, index, spin-up, step), disk change and write protect. Shared
  glue goes to DRV8_1581.
- region: RAM_1581_8/9, FDC_BUF_8/9.
- rebuilt: port registers, loop index.
- ignored: mounted image geometry `fdn_*`, mount/ack edge detectors, ROMs.

### Framework

video_mixer, video_freak, video_sync (`emu.sync`), drv_overlay, SDRAM
controller/model: ignored. `emu.hps_io.*` matches nothing in the sim build
(hps_io is replaced by a model) and stays for synthesis.

## Rebuilt items (full reasons in state_classes.yaml)

| Item | Why it is rebuilt |
| --- | --- |
| block RAM port registers (drive RAM/ROM/extram, track buffer incl. `b_sel_d*`, 1581 RAM, FDC buffer, OPL3 RAM, Color RAM, tape time map, ROM `q0`) | inside the M10K in hardware; rewritten every clock from port inputs that are saved; settle in 2 clocks while paused (P1, P2) |
| `vic.vsync` | vBlanking = (rasterY = rasterBlank) every clock |
| SID `norm_dac`, sid_tables `f0`, `f0_adj`, `*_out` | registered DAC/table outputs, rewritten every clock from saved state, sampled clocks later |
| keyboard `pao/pbo` | matrix output, rewritten every clock from CIA ports, matrix, joysticks |
| keyboard `tape_*` | one-clock hotkey pulses, cleared every clock |
| `emu.msum`, `c1541.rom_sz` | rewritten every clock from configuration |
| `emu.dac_l/dac_r` | rewritten every clock from the saved DigiMax registers |
| `emu.joy_key`, `reu.addr_mask`, `reu.error` | '=' temporaries computed before use every clock |
| `c1541_direct_gcr.rec` | constant reciprocal table |
| `c1541_track.dma_*`, `ddr_offset_q` | DDR3 DMA transfer registers, set at the start of each transfer, idle at capture (P3) |
| loop indexes (`iec_drive.i`, `fdc.i`, Z80 `CPU_REGS.i`) | for-loop variables, not storage |

## Open questions

- **Q1 Word space.** 10,890 arch bits do not fit in 128 words. The map now
  uses 0-255 (200 words allocated). Alternatives: accept 256, or cut chain
  bits by moving more pipeline registers to 'rebuilt' chip by chip (each needs
  a proof), which would not reach 128 anyway.
- **Q2 Cartridge media.** The CRT image, the cartridge RAM (EasyFlash 256
  bytes, Action/Retro Replay RAM) and the EasyFlash flash written by programs
  all live in the SDRAM CRT area (0x200000-0x3FFFFF) through
  `cartridge.v get_bank()`. No region covers it, and `EZ_RAM` is declared as
  a BRAM region that does not exist. Proposal: a `CART_SDRAM` region (the
  RAM banks at least, the whole CRT area when the flash was written), and
  `cart_id` in the slot header/config_mask to refuse a slot with another
  cartridge. Until then cart identity and bank tables are 'ignored' (media).
  Resolved: D2 added CART_RAM (which holds the EasyFlash RAM) and CART_FLASH
  and the CRT type in the config mask; A11 removed `EZ_RAM`, `OPL3_RAM` and
  `OPL3_FIFO` from the map (the FM part stays at replay, D9).
- **Q3 Disk images.** The 1541 G64 image lives in DDR3 (0x06000000 /
  0x06040000) and is modified by the drive; dirty tracks are written back to
  the SD in the background. The slot holds only the current track buffer.
  After a load the drive sees the live DDR3 image (with writes made after the
  save). Same for the 1581 (sectors on SD). Decide whether a slot carries the
  disk (VICE optionally does) or is refused when the image changed.
- **Q4 1541 GCR pause leak.** `c1541_direct_gcr` runs on the ungated `ce`
  while the machine is paused: the disk keeps rotating (and writing, in write
  mode) against the stopped drive CPU, and the track buffer port b keeps
  changing during capture (P2 does not hold there). Gate its `ce` like ph2
  (A8).
- **Q5 OPL3 clock domain and FIFOs.** The Z80, sequencer and OPL3 RAM run in
  clk_opl (48 MHz), the chain in clk_sys: needs a CDC or a second chain. The
  dcfifo (OPL3 queue) and scfifo (tape) contents cannot be read without
  popping: drain-and-refill or replace them with in-house FIFOs (A9/A7).
- **Q6 Stuck keys.** The keyboard matrix and the joystick-to-key macros are
  saved; a key held when saving stays pressed after a load until it is
  pressed and released again. Alternative: clear the matrix after load (then
  'ignored'). Same question for the mouse position.
- **Q7 ghdl names.** VHDL modules are inventoried from the ghdl synthesis.
  Unnamed nets and process variables get numbers (`417/sum`,
  `2796/mshift`) that change when the VHDL changes; the chip WPs should name
  them, or the rules will need updates (A3 named `417/sum` `tod_sum`). The
  13-bit T65 `s` was a lint bug, fixed in A3: a ghdl mux function argument
  named `s` shadowed the 16-bit register.
- **Q8 Engine registers.** The savestate engine instantiated in c64.sv will
  add unclassified flip-flops: add an 'ignored' rule for its instance. Edits
  to c64.sv can also shift the `#n` suffixes of same-named block variables.
- **Q9 Configuration latched at reset.** The KERNAL select (`c64*_ena`, from
  status[15:14]) is saved; if the OSD differs at load the slot's choice holds
  until the next reset. Consider a config_mask entry. Drive ROM images
  (DolphinDOS etc.) and the SID filter curve file are configuration and not
  checked.
- **Q10 Two units per drive type.** Both a 1541 and a 1581 exist for each
  unit; the inactive one is held in reset but is still saved (1,117 + 1,041
  bits of 1581 when only 1541s are used).
