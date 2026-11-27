# pmon: the Parcore Conductor's Console

pmon is the conductor's console (Road to GHz item 16, decisions 436–445): a text monitor for a person at a terminal, and a framed binary protocol for the host tool, sharing one UART. It runs in the conductor's supervisor loop alongside the watchdog, once the conductor has booted the image and released the cores, so it can look at a running or hung pipeline, hold and release cores, read and write their TCMs, and read the flash. In a build with `PARCORE_REAL_FLASH=1` it can also erase and program the flash (448–452); that is **off by default**, see [Writing the Flash](#writing-the-flash).

* Firmware: `firmware/parcore/conductor/pmon.inc`, included by `conductor.asm`; the supervisor loop that calls it is `watchdog.inc`, and the flash commands use the boot's SPI routines in `spi.inc`.
* Hardware: the console UART in `ParcoreTop` (`CONSOLE_DATA`, `CONSOLE_STATUS`; see [Registers](#registers)).
* Host tool: `apps/tools/pmon` (`make pmon`, built to `build/tools/pmon`).
* Tests: `hdl/parcore/test/parcore_pmon_test.dart` (the whole ULX3S design in Verilator, once with the image ROM and once with `PARCORE_REAL_FLASH` and a writable flash model) and `apps/tools/pmon/test/protocol_test.dart` (the host tool, against a model of the firmware).

## Wiring

The console uses the ULX3S header's `gp[0]` and `gp[1]`, on the row just below 3.3 V and ground (440). They are the board wrapper's second UART (`gpio_tx_pin`, `gpio_rx_pin`):

| Pin | Ball | Signal | Connect to |
|---|---|---|---|
| `gp[0]` | B11 | Parcore transmits | the adapter's RX |
| `gp[1]` | A10 | Parcore receives | the adapter's TX |
| GND | | | the adapter's GND |

The adapter must be 3.3 V. An ESP-Prog works: its UART is the FT2232's second channel, usually the second of the two serial ports it shows (on macOS, the `/dev/cu.usbserial-…` ending in 1). The line is 115200 baud, 8 data bits, no parity, one stop bit, no flow control (443).

## Using It

```
make parcore-console PMON_PORT=/dev/cu.usbserial-XXXX1     # the text monitor; Ctrl-] leaves
make parcore-status  PMON_PORT=...                         # the cores' states and PCs
make parcore-load    PMON_PORT=... PMON_FILE=x.bin PMON_CORE=1 [PMON_OFFSET=0x100]
```

`PMON_PORT` is never guessed: the ULX3S's own USB port looks the same as the adapter's. The tool can be run directly as well (`build/tools/pmon --help`); it reads the port from `PMON_PORT` if `--port` isn't given.

Any terminal program works too (115200 8N1). After booting, pmon prints its banner and the prompt `pmon> `.

## The Text Monitor

A line is up to 32 characters, echoed as typed; backspace (or DEL) takes one back. Numbers are hex, without `0x`. Commands are one letter, upper or lower case:

| Command | Does |
|---|---|
| `s` | Status: `CORE_STATE`, `CYCLES` and `RST_CTRL`, then the PCs of cores 0–3 |
| `h MASK` | Hold cores in reset: `RST_CTRL |= MASK & 0x3F` |
| `g MASK` | Let cores go: `RST_CTRL &= ~(MASK & 0x3F)` |
| `r ADDR [N]` | Read N words (1 by default) from ADDR, rounded down to a multiple of 4 |
| `w ADDR VALUE` | Write a word |
| `b` | Boot again from flash (as FIRE1 does) |
| `?`, `help` | Help |

Anything else answers `?`. The conductor's own TCM is at 0; core *n*'s TCM is at `0x1000_0000 + (n << 16)`, and can be read and written only while core *n* is held (`h`). `r` and `w` check nothing: they read and write any address, I/O registers included.

When the watchdog finds the pipeline hung, it prints `HANG: cores 1-3 have stopped` and the status, then keeps the console going while LED 7 blinks fault code 6.

## Frames

Any byte other than SOH (0x01) is a character of the text monitor; SOH starts a frame (445). All values are little-endian except the CRC:

| Field | Bytes | |
|---|---|---|
| SOH | 1 | 0x01 |
| command | 1 | an ASCII letter |
| address | 4 | for `H` and `G`, the core mask; for `F`, `E` and `P`, a flash address |
| length | 2 | for `W` and `P`, the data's length; for `R` and `F`, the length to read; else 0 |
| data | length | `W` and `P` only |
| CRC-16 | 2 | high byte first |

The CRC is CRC-16/CCITT-FALSE (polynomial 0x1021, starting at 0xFFFF, not reflected, no final XOR) over the command to the end of the data; run on through its own two bytes it comes to 0. The answers:

| Command | Does | Answer |
|---|---|---|
| `H` | Hold the cores in the mask | ACK |
| `G` | Let them go | ACK |
| `W` | Write the data at the address | ACK |
| `R` | Read the length's bytes at the address | ACK, the data, its CRC-16 |
| `S` | Status | ACK, 28 bytes (`CORE_STATE`, `CYCLES`, the PCs of cores 0–3, `RST_CTRL`), their CRC-16 |
| `B` | Boot again from flash | ACK, then the conductor reboots |
| `F` | Read the length's bytes of the flash (or the on-chip ROM) at the address | ACK, the data, its CRC-16 |
| `E` | Erase the flash's 4 KiB sector at the address (a sector's start) | ACK, once the flash is done |
| `P` | Program the data into the flash at the address, within one 256-byte page | ACK, once the flash is done |

ACK is 0x06; an error is NAK (0x15) and a code:

| Code | Error |
|---|---|
| 1 | The frame's CRC is wrong |
| 2 | Unknown command |
| 3 | `W`, `R`, `F`, `P`: the address or length isn't a multiple of 4, or the length is over 256; `P` across a page; `E` not at a sector's start |
| 4 | `W` into a core's TCM while the core isn't held |
| 5 | `E`, `P`: below 0x40_0000 (the bitstream's) or past 16 MiB |
| 6 | `E`, `P`: the flash can't be written (not a `PARCORE_REAL_FLASH=1` build) |
| 7 | `E`, `P`: the flash was still busy after 2²⁷ cycles (5.4 s at 25 MHz; `PMON_FLASH_SHIFT`) |

pmon writes a `W`'s data as it arrives, so a `W` with a bad CRC has written its data anyway (into a held core's TCM: harmless); the host sends it again. A `P`'s data goes into a buffer and is checked first, so a `P` with a bad CRC programs nothing. A frame whose bytes stop for 2²¹ cycles (84 ms at 25 MHz; `PMON_TIMEOUT_SHIFT`) is dropped unanswered (438), and pmon goes back to waiting for SOH.

## The Host Tool

`apps/tools/pmon` is Dart, without dependencies: `lib/protocol.dart` has the frames and the client, `lib/serial.dart` the serial port (set up with `stty`, then read and written as a file; macOS and Linux), and `bin/pmon.dart` the commands:

```
pmon [--port PORT] [--baud BAUD] COMMAND ...
  status                    hold MASK / go MASK
  read ADDR [LENGTH]        write ADDR WORD ...
  load FILE --core N [--offset OFF] [--no-verify] [--no-go]
  flash FILE [--offset OFF] [--no-verify]
  fread ADDR [LENGTH]       boot
  console
```

`load` holds the core, writes the file in 256-byte frames, reads it back to check it, and lets the core go. `flash` writes a file into the flash at the offset (0x400000, the boot image's place, by default; a sector's start): it erases the sectors the file covers, programs it a page at a time (leaving pages of 0xFF as erased), and reads it back. `fread` prints the flash in hex. A frame that gets no answer within 0.5 s, NAK 1, or an answer with a bad CRC is sent again, after 150 ms (so that pmon has dropped any frame it was part way through), up to three more times; any other NAK stops the command. `console` passes the terminal to the port and back until Ctrl-].

At 115200 baud a frame of 256 bytes takes about 23 ms, so a load runs at about 10 KiB/s, and as much again to verify.

## Registers

The console UART, in the conductor's I/O space:

| Address | Register |
|---|---|
| `0xF000_0050` | `CONSOLE_DATA`: a write sends the byte in bits 7:0 (dropped if the transmitter is busy); a read takes the oldest byte received |
| `0xF000_0054` | `CONSOLE_STATUS` (read only): bit 0 a byte has been received, bit 1 the transmitter is busy |

Bytes received wait in a 16-byte FIFO, so that those arriving while pmon is sending (an echo, a command's answer) aren't lost; past 16 they are. The baud rate is set when the design is built (`ParcoreTop(consoleBaud:)`, 115200 by default; the divisor is the clock over the baud rate). The receive pin goes through a two-flip-flop synchroniser.

## Writing the Flash

**Off by default.** A normal build boots from an image ROM built into the bitstream, which answers like a flash but can't be written: `F` reads it, and `E` and `P` answer NAK 6. With `PARCORE_REAL_FLASH=1` (449), the bitstream has no ROM: the conductor's SPI lines go to the ULX3S's own flash (its clock through the ECP5's `USRMCLK`, the configuration clock pin; `HOLD#` and `WP#` held high), `STATUS` bit 9 says so, the conductor boots the image from the flash at 0x400000, and pmon can erase and program it. Nothing of this has been run on a board yet; it is tested in simulation against `SpiFlashRom`'s writable mode, a model of the flash (452).

```
make parcore-bit PARCORE_REAL_FLASH=1     # the bitstream (its LPF has MASTER_SPI_PORT=DISABLE)
make parcore-flash-image-jtag             # the image into the flash at 0x400000, over JTAG
make parcore-prog                         # or parcore-flash, to keep it
make parcore-flash-image PMON_PORT=...    # later: a new image through pmon, then FIRE1 or b
```

pmon only writes from 0x40_0000 up to 16 MiB (450): below is the bitstream. The flash commands are the standard ones (write enable 0x06, read status 0x05, page program 0x02, 4 KiB sector erase 0x20, read 0x03), which any flash fitted to a ULX3S should answer. `E` and `P` wait for the flash to finish before answering, so an `E` can take a few hundred milliseconds; the host tool allows 6 s.

## Memory

The conductor's TCM is 8 KiB (453; 4 KiB from 436): its code from 0x100 (with pmon, the watchdog and flash writing, it ends at about 0x1090), up to `SECTION_TABLE` at 0x1C00 (`make firmware` checks it: `conductor-size`). Then the boot's section table (96 bytes), the line typed at 0x1C80 (a character a word, 128 bytes), a `P` frame's data at 0x1D00 (256 bytes), and the stack, 512 bytes from 0x2000 down.
