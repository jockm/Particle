# The Pano Logic G2

The Pano Logic G2 is a thin client, sold in quantity when Pano Logic closed, whose board is built around a large Spartan-6. Particle is being brought up on the **rev C** board: a Spartan-6 **XC6SLX100-3** (FGG484 package; ISE part `xc6slx100-3-fgg484`). Rev B boards have the XC6SLX150-2 instead; nothing here has been tried on one.

What is known about the board comes from the reverse-engineering work of others: [tomverbeure/panologic-g2](https://github.com/tomverbeure/panologic-g2) and its wiki, and LiteX's `pano_logic_g2` platform in [litex-boards](https://github.com/litex-hub/litex-boards).

## Clock

The board's 25 MHz oscillator drives the Marvell Ethernet PHY, not the FPGA. The PHY's `125CLK` output goes to FPGA pin **Y13**: 25 MHz while the PHY is held in reset, 125 MHz once it is out (its PLL multiplies the 25 MHz). The FPGA pin of the PHY's reset is not yet known here. A design that leaves it alone leaves it pulled down by bitgen's default for unused pins, so presumably held in reset (25 MHz); `panog2_blink` shows which by its speed.

## Pins used so far

| Signal | Pin | Notes |
|---|---|---|
| Clock | Y13 | See *Clock* |
| Green LED | F13 | |
| Blue LED | H13 | |
| Third LED | E12 | In LiteX's platform; probably the red one |
| Pano button | H12 | Not used yet |
| DVI DDC SCL / SDA | C14 / C17 | LiteX uses them as a serial port (tx C14, rx C17): a candidate for a custom cable |

All are `LVCMOS33`.

## Tools

The FPGA is built with ISE 14.7 (Spartan-6 isn't supported by Vivado), in Xilinx's ISE VM, and loaded over JTAG with iMPACT through a Platform Cable USB (DLC9G) passed through to the VM. The host reaches the VM as the ssh host `ise-vm`; `scp` works to it. The make targets (`pano-vm-check`, `pano-blink`, `pano-prog`) are in [configuration_guide.md](configuration_guide.md#the-pano-logic-g2); the scripts they copy into the VM are in `hdl/particle/boards/panog2`:

| File | What it is |
|---|---|
| `panog2_blink.v`, `panog2_blink.ucf` | The first test: the three LEDs lit in turn, a step every 2^24 cycles (about 0.67 s at 25 MHz, 0.13 s at 125 MHz) |
| `ise_build.sh` | The ISE flow in the VM: XST, ngdbuild, map, par, trce, bitgen (`StartupClk:JtagClk`, for loading over JTAG) |
| `impact_prog.sh` | iMPACT in batch mode: load a bitstream, or list the JTAG chain (`--identify`) |
| `vm_check.sh` | Checks ISE's tools in the VM, then lists the JTAG chain |

Loading over JTAG changes only the FPGA's configuration; the board's SPI flash, holding Pano's own firmware, is untouched, and a power cycle brings that back.

## Still to do

* Particle and Parcore on the G2: ROHD's SystemVerilog converted to Verilog-2001 with `sv2v` (ISE's XST reads no SystemVerilog), Spartan-6 equivalents of the ECP5 parts (the PLL, and the SPI flash clock through `STARTUP_SPARTAN6` instead of `USRMCLK`), and the full pin file.
* The PHY's reset pin, for a known 125 MHz clock.
* A serial port for the console: the DVI DDC pins or another cable.
