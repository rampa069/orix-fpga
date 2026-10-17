# Orix FPGA, an Oric Telestrat with the Twilighte board

A re-implementation of the [Oric Telestrat](https://fr.wikipedia.org/wiki/Oric_Telestrat)
with the Twilighte board, running [Orix](http://orix.oric.org), for the MiST family of FPGA boards.

The project started in 2020 from the Oric core by SEILEBOST and has gained components and
testing since. The Oricutron emulator, with its Twilighte board and CH376 plugins, is used
as the reference model.

## Boards

| Board | Project | FPGA | Video | CH376 |
|---|---|---|---|---|
| SiDi128 | `SiDi128/` (revision `orix`) | 10CL120 | VGA and HDMI | emulated |
| SiDi | `SiDi/` | EP4CE22 | VGA | emulated |
| NeptUNOplus | `NeptUNOplus/` | EP4CGX150 | VGA | emulated or physical |
| Poseidon EP4CGX150 | `Poseidon/` | EP4CGX150 | VGA | emulated or physical |

Ready to use cores, the Orix cartridge and an SD image are published on the
[releases page](https://github.com/rampa069/orix-fpga/releases).

## What is implemented

- **ULAs** HCS10017 (video and memory sequencing), HCS3119 and HCS3120.
- **CPU** 6502, 65C02 or 65C816, selectable from the OSD.
- **Two VIA 6522**, the **AY-3-8912** sound chip (or a YM2149), the **ACIA 6551** on the
  board UART pins and the **DS1501** real time clock, set from the MiST clock.
- **64 KB main RAM** in SDRAM, with a block RAM copy of the video area for the ULA.
- **Twilighte board**, with 512 KB of ROM banks (the cartridge) and 512 KB of RAM banks,
  paged through VIA2 and the 0x342 and 0x343 registers. The RAM banks have no battery on
  the real board, so the core clears them after power up and on a cold reset.
- **CH376 USB/SD controller**, in one of two ways.
  - Emulated, by a T65 softcore running FatFs (FAT12, FAT16 and FAT32) on a VHD image
    mounted from the OSD. Available on every board.
  - Physical, through a bridge to a real CH376 on the external bus of NeptUNOplus and
    Poseidon. The OSD chooses between both.
- **Video** over VGA (scandoubled, a centred 480 line mode for 31 kHz monitors) and, on
  SiDi128, HDMI in 16:9 or 4:3 without stretching.
- **Tape** input through the audio input of the board, which can also be heard.
- **Joysticks** on the two Telestrat ports, fire 2 and fire 3 included.

The WD1793 floppy controller exists in the sources but is not connected yet.

## Installing

1. Copy the core for your board (`ORIX_<board>_<date>.rbf`) to the SD card.
2. Copy `ORIX.ROM` next to it. It holds the Orix kernel and shell banks.
3. Unzip `ORIX.VHD` (a FAT32 image with the Orix software) to the SD card.
4. Start the core, load `ORIX.ROM` with **Load Cartridge** and mount `ORIX.VHD` with
   **Mount CH376 SD**.

On NeptUNOplus and Poseidon set **CH376** to **Real** in the System page to use a physical
CH376 instead of the image.

## OSD

| Page | Option | Values |
|---|---|---|
| | Load Cartridge | `.ROM` or `.R64` image of the ROM banks |
| | Mount CH376 SD | `.VHD` or `.IMG` FAT image |
| System | CPU | 6502, 65C02, 65C816 |
| System | Joysticks | Normal, Swapped |
| System | CH376 (NeptUNOplus, Poseidon) | Virtual, Real |
| Video | Scanlines | Off, 25 %, 50 %, 75 % |
| Video | HDMI aspect (SiDi128) | 16:9, 4:3 |
| Audio | PSG | AY-3-8912, YM2149 |
| Audio | Stereo | Off, ABC, ACB |
| Audio | Tape sound | Off, On |
| | Reset | |
| | Cold reset | also clears the board RAM banks |

Changing the CPU or the CH376 backend resets the machine. F11 resets and F12 opens the
OSD.

## Building

Each board directory holds a Quartus project. The cores are built with Quartus 21.1 (the
`raetro/quartus:21.1.1` container works), for instance

```
cd SiDi128 && quartus_sh --flow compile Telestrat -c orix
cd NeptUNOplus && quartus_sh --flow compile orix -c orix
```

The CH376 firmware is built with [cc65](https://cc65.github.io/). `make` in
`firmware/ch376` regenerates `rtl/ch376_fw_rom.vhd`, which is committed, so it is only
needed after changing the firmware.

## Simulation

The simulations use [nvc](https://www.nickg.me.uk/nvc/), Icarus Verilog and Verilator.

- `sim/ch376` tests the CH376 host interface and the whole emulated CH376 against FAT12,
  FAT16 and FAT32 images, checked afterwards with mtools.
- `sim/system` simulates the whole machine and writes a CPU trace, used to compare
  changes and to check the ULA video reads.
- `sim/video` checks the VGA and HDMI timing.

## Orix and the Twilighte board

- [Orix software](https://github.com/orix-software), the kernel, shell and commands
  ([kernel](https://github.com/orix-software/kernel),
  [shell](https://github.com/orix-software/shell)).
- [Orix documentation](https://orix-software.github.io/), with the user and developer
  manuals.
- [Twilighte board manual](https://github.com/orix-software/user_manual).

## Thanks to

- [jede](https://github.com/jedeoric), for Orix and the Twilighte board.
- [assinie](https://github.com/assinie), for the Orix SDK and the work on Orix.
- [Oricutron](https://github.com/pete-gordon/oricutron), the reference model of this
  core. The emulated CH376 firmware ports the protocol of its CH376 plugin.
- Ron Rodritty, [retrowiki.es](https://www.retrowiki.es)
- Chema Enguita
- SiliceBit
- The RW FPGA DEV Team
- The [Defence Force forum](https://forum.defence-force.org)

## Licence

GNU General Public License version 2, see `LICENSE`. FatFs (`firmware/ch376/fatfs`) keeps
its own licence.
