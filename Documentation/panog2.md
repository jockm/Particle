# The Pano Logic G2

The Pano Logic G2 is a thin client, sold in quantity when Pano Logic closed, whose board is built around a large Spartan-6. Particle is being brought up on the **rev C** board: a Spartan-6 **XC6SLX100-3** (FGG484 package; ISE part `xc6slx100-3-fgg484`). Rev B boards have the XC6SLX150-2 instead; nothing here has been tried on one.

What is known about the board comes from the reverse-engineering work of others: [tomverbeure/panologic-g2](https://github.com/tomverbeure/panologic-g2) and its wiki, and LiteX's `pano_logic_g2` platform in [litex-boards](https://github.com/litex-hub/litex-boards).

## Clock

The board's 25 MHz oscillator drives the Marvell Ethernet PHY, not the FPGA. The PHY's `125CLK` output goes to FPGA pin **Y13**: 25 MHz while the PHY is held in reset, 125 MHz once it is out (its PLL multiplies the 25 MHz). The FPGA pin of the PHY's reset is not yet known here. A design that leaves it alone gets **25 MHz**: the UART tests, built for 25 MHz, talk at 115,200 and 1,000,000 baud (bitgen pulls unused pins down, which presumably holds the PHY in reset).

## Pins used so far

| Signal | Pin | Notes |
|---|---|---|
| Clock | Y13 | See *Clock* |
| Red LED | E12 | |
| Green LED | F13 | |
| Blue LED | H13 | |
| Pano button | H12 | Its polarity isn't known yet; `panog2_uart` takes its level after loading as "not pressed" |
| UART, Pano → host | C14 | DVI DDC SCL (see *Serial console*) |
| UART, host → Pano | C17 | DVI DDC SDA |

All are `LVCMOS33`. The three LEDs are one light, behind the Pano button on top of the case; a high output lights each colour (`panog2_blink` showed green, blue, red for F13, H13, E12, one at a time).

## Serial console

The console is on the DVI connector's DDC pins, as in LiteX's Pano G2 platform and its Linux-on-Pano guide (LiteX's default; the micro HDMI connector's DDC pins are another choice):

| DVI signal | DVI pin | VGA pin (through a DVI-to-VGA adapter) | Direction | FPGA pin |
|---|---|---|---|---|
| DDC SDA | 7 | 12 | host → Pano | C17 |
| DDC SCL | 6 | 15 | Pano → host | C14 |
| Ground | 15 | 10 | | |

The lines idle at 5 V on the connector (measured), so the host's serial adapter must take 5 V logic: a SparkFun Serial Basic (CH340G) set to 5 V is in use. 1,000,000 baud works (the make targets' default), as the LiteX guide found.

## Tools

The FPGA is built with ISE 14.7 (Spartan-6 isn't supported by Vivado), in Xilinx's ISE VM, and loaded over JTAG with iMPACT through a Platform Cable USB (DLC9G) passed through to the VM. The host reaches the VM as the ssh host `ise-vm`; `scp` works to it. The make targets (`pano-vm-check`, `blink-pano`, `uart-pano`, `uart-rohd-pano`, `particle-pano`, `parcore-pano`, `pano-prog`, `pano-term`) are in [configuration_guide.md](configuration_guide.md#the-pano-logic-g2); the scripts they copy into the VM are in `hdl/particle/boards/panog2`:

| File | What it is |
|---|---|
| `panog2_blink.v`, `panog2_blink.ucf` | The first test: the three LEDs lit in turn, a step every 2^24 cycles (about 0.67 s at 25 MHz, 0.13 s at 125 MHz) |
| `ise_build.sh` | The ISE flow in the VM: XST, ngdbuild, map, par, trce, bitgen (`StartupClk:JtagClk`, for loading over JTAG) |
| `panog2_uart.v`, `panog2_uart.ucf` | The serial console test: an echo, and a banner after loading and at each button press; green flashes for a character received, blue for one sent |
| `lib/panog2_board.dart` (in `hdl/particle`) | The Verilog-2001 top level `panog2_board` around one Particle core (`ParticleSingleCoreTop`): the console on FIFO channel 0, the button as reset (its idle level learnt after configuration), and the LED: red while in reset, green blinking while the core runs, blue for console traffic. `make particle-pano` builds it with `PANO_PROGRAM` (default `apps/asm/panog2_echo.asm`, a banner and an echo) |
| `bin/generate_parcore_panog2.dart` (in `hdl/parcore`) | Parcore in the same `panog2_board` wrapper (with `buttons` and `coreLeds`): the light shows Parcore's LED 7 red, LED 0 green and LED 1 blue, the guest's UART is the console, the boot image is in the on-chip ROM, and pmon's console isn't wired yet. `make parcore-pano` builds it (see [parcore_architecture.md](parcore_architecture.md#the-pano-logic-g2-design)) |
| `lib/panog2_uart_rohd.dart`, `bin/generate_panog2.dart` (in `hdl/particle`) | The same echo (no banner) from Particle's own UART, `ParticleFtdiUart`, with the same ports, so it uses `panog2_uart.ucf`. `make uart-rohd-pano` generates its SystemVerilog, converts it with `sv2v`, and builds that: the path Particle and Parcore will take to ISE |
| `impact_prog.sh` | iMPACT in batch mode: load a bitstream, or list the JTAG chain (`--identify`) |
| `vm_check.sh` | Checks ISE's tools in the VM, then lists the JTAG chain |

Loading over JTAG changes only the FPGA's configuration; the board's SPI flash, holding Pano's own firmware, is untouched, and a power cycle brings that back.

## Results

| Design | LUTs | Fmax (ISE's estimate) | On the board |
|---|---|---|---|
| One Particle core (`particle-pano`), 64 KiB block RAM | 3,447 of 63,288 (5%), 1,045 slices, 32 RAMB16BWER | 43.8 MHz (22.8 ns) | Runs at 25 MHz: `memprobe.asm` and `panog2_echo.asm` correct |

## What ISE needs from the generated Verilog

* No SystemVerilog: ROHD's output goes through `sv2v` first.
* Block RAM with byte writes: each byte lane's write needs its own flat condition (`if (wEn && bEn[0])`). With the byte writes inside a shared `if (wEn)`, XST makes `wEn` the enable of the whole port, so the port's read register changes only on writes (it then holds the old contents of the last word written: every load returned that). `ParticleBlockRamTdp` is written that way. `apps/asm/memprobe.asm` checks a core's loads and stores on a new board.

## Still to do

* Parcore on the G2 (`make parcore-pano`): its size and speed in ISE, and the guest on the board. Then:
  * pmon's console, on the micro HDMI connector's DDC pins (AB19 transmit, AA21 receive in LiteX's platform; 502);
  * booting from the board's flash (the SPI flash clock through `STARTUP_SPARTAN6`, as `USRMCLK` on the ECP5), once it's known where Pano's own firmware sits in it (505);
* A Spartan-6 PLL, for a faster clock than the 25 MHz on Y13.
* The PHY's reset pin, for a known 125 MHz clock.
