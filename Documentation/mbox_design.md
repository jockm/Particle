# `MBOX` over the Network: Design Note (Draft)

Status: agreed (398–408). psim implements all of it (cluster tests `mbox_queue`, `mbox_any`, `ring_mbox_queue`, `ring_mbox_any`, `ring_config`). The HDL implements step 3a (see 408): `EPC`, `RETI`, masking and `MBOX Rr, Rl` in the core; the queue, `ACK`/`NACK` and the value and source registers in the network interface; Parcore's redirect over the ring. Step 3b (writable tables, `CONFIG` from the conductor, broadcast) is next; until then the HDL drops an `MBOX` to core `0xFF`. It covers step 3 of the [network on chip](noc_design.md) (`MBOX` as packets, `CONFIG` from the conductor, broadcast) together with the `MBOX` redesign, item 14 of [Road to GHz](road_to_ghz.md), because each needs the other.

## Today

* `MBOX Rr, Imm4` (`0xE5`) raises vector `Imm4` on one other core, fixed by the HDL (in Parcore, core 2 → core 0) or by psim's `mbox_target`, and sends `Rr`.
* The target takes the trap before its next instruction, abandoning a stalled `FIFO.R` or divide. Trap entry stores the value at `MBOX_VALUE` (`0xFC`, the word below the trap table) and puts the return PC in R14.
* A newer `MBOX` that arrives before the trap is taken replaces the older one.
* The strobe is a wire: one cycle, across the chip.

The five problems item 14 records: trap entry destroys the interrupted code's R14; there's no masking; messages can be lost; the target is fixed; and the wire doesn't scale.

## What changed since item 14 was written

Item 14 planned that an `MBOX` trap would switch to the shadow bank, with the return PC in S14, and a new `RETI` would swap back. Since then the lean cores (366b) have left the shadow bank out of every Parcore core, core 0 included, and ParticleMan will want small cores too. So the return path needs to work without a shadow bank.

## Proposal

### 1. Return: an `EPC` register and `RETI`

* An `MBOX` trap puts its return PC in a new register, `EPC`, instead of R14, so the interrupted code's R14 is kept. `RETI` (`0xE3`) jumps to `EPC` and unmasks (part 2).
* A handler saves the registers it uses. A core with a shadow bank can use `XCHGMOST` for that, as today; a core without one saves a few words in memory.
* Only `MBOX` traps change. They're the asynchronous ones, where the interrupted code can't know R14 will be overwritten. Faults and `TRAP` keep putting the return PC in R14, so existing firmware and `lib/vectors.inc` don't change.
* Cost: 32 flip-flops and a small multiplexer in the core.

### 2. Masking

* `DI` (`0xE9`) and `EI` (`0xE8`), first named `MBOX.OFF` and `MBOX.ON` (renamed in 409). They mask every asynchronous trap: today only `MBOX`. An `MBOX` that arrives while masked waits in the receive queue (part 3) until the core unmasks.
* Taking an `MBOX` trap masks; `RETI` unmasks. So handlers don't nest.
* After reset `MBOX` is unmasked, as today (Parcore's core 0 must take redirects from the start).

### 3. No lost messages

* The receiving network interface has an `MBOX` queue of 4 (vector, value, source core), in LUT RAM.
* The ring requires every packet to be accepted, so a full queue answers with a `NACK` packet to the sender, and an accepted `MBOX` with an `ACK`.
* The sender's network interface keeps its last `MBOX` until the answer comes. On a `NACK` it sends it again a little later. So each core has at most one `MBOX` in flight, and a second `MBOX` instruction waits (like a `FIFO.W` with a full queue) until the first is acknowledged.
* `ACK` and `NACK` are always accepted, so this can't deadlock.

### 4. Any target

* A new `MBOX Rr, Rl` (`0xE2`): `Rl` bits 7:0 are the target core, bits 11:8 the vector.
* `MBOX Rr, Imm4` stays, and goes to the core's default target: an entry of its network interface's table, set by the HDL at reset and by `CONFIG` (part 6). Parcore's firmware doesn't change.

### 5. The value and the source

* Trap entry no longer writes memory. The handler reads the value and the sender's core number from network-interface registers: `0xFFFF_FF04` (`MBOX_VALUE`) and `0xFFFF_FF08` (`MBOX_SOURCE`), next to the `FLUSH` register at `0xFFFF_FF00`.
* The `MBOX` leaves the queue when the trap is taken; the two registers hold its value and source until the next one is taken.
* Core 0's two handlers change one instruction each (`LDIS R14, 0xFF04` instead of `LDI R14, MBOX_VALUE`).

### 6. `CONFIG` from the conductor

* The conductor gets a network interface that can only send, with a `CONFIG` register: a store sends a `CONFIG` packet to a core, setting one table entry.
* Writable entries: each output channel's route (destination core and channel), each input's sender (where its credits go), and the default `MBOX` target. What exists stays fixed by the HDL: which receive buffers, how many output links, which channel is a local device.
* Each entry's reset value comes from the HDL, so Parcore works with no `CONFIG` at all, as today.
* The word stored to the `CONFIG` register (`0xFFFF_FF0C`, `NI_CONFIG`): bits 31:24 the core it goes to (`0xFF`: every core); 23:20 the entry (0 a channel's route, 1 the sender of a channel's input, 2 the default `MBOX` target); 19:16 the channel; 15:8 a core and 3:0 a channel, the entry's new value. A new route starts with 256 credits.
* Cost: about 100 flip-flops per network interface for the writable entries.

### 7. Broadcast (agreed in 380)

* `CONFIG` to core `0xFF` sets the entry in every core.
* `MBOX` to core `0xFF` (from `MBOX Rr, Rl` with `Rl` bits 7:0 = `0xFF`) raises the vector on every core. A broadcast can't be retried core by core, so each receiving interface keeps one queue slot for broadcasts. A broadcast that finds that slot still full is dropped there: the one exception to part 3, which question 405 asks about.

### Parcore

* Core 2's redirect `MBOX` to core 0 goes over the ring: 3 hops, so a redirect costs about 3 cycles more. Measured in 3a: 77.2 cycles per RISC-V instruction against 77.0, about 8 cycles more per redirect (the hops, a cycle in each network interface, and a cycle in core 0's receive queue).
* Core 0's handlers read `MBOX_VALUE` from the network interface, and never return (they restart the main loop), so `EPC` and `RETI` don't affect Parcore.
* The `MBOX` wire and `MBOX_VALUE` in memory go (done in 3a).

### psim first

As for step 2: psim models `MBOX` packets, `ACK`/`NACK`, the queue, masking, `EPC`/`RETI` and `CONFIG` on the ring, with new cluster tests, before the HDL.

## Decisions

* **398:** `EPC` and `RETI` for `MBOX` traps, keeping R14; faults and `TRAP` keep the return PC in R14.
* **399:** `MBOX.ON`/`MBOX.OFF` (renamed `EI`/`DI` in 409); masked on trap entry, unmasked by `RETI`, unmasked after reset.
* **400:** a receive queue of 4, `ACK`/`NACK`, the sender retrying on its own, one `MBOX` in flight per core.
* **401:** `MBOX Rr, Rl` (`0xE2`), and a configurable default target for `MBOX Rr, Imm4`.
* **402:** the value and source from network-interface registers, not memory.
* **403, 406:** Parcore's redirect goes over the ring: the benchmark's 273 redirects cost about 1,100 cycles, about 0.1%. Configurable direct links between chosen cores are possible as a build-time option, kept for later; the ring's latency growing with the core count is what step 4 (a two-way ring, then a mesh) addresses.
* **404:** `CONFIG` as in part 6.
* **405:** a broadcast `MBOX` is dropped at a core whose broadcast slot is still full.
* **407:** the network interface answers from a queue of its own (4, configurable). An `MBOX` that arrives while it is full gets no answer and isn't taken; its sender sends it again after a timeout (64 cycles in the HDL). After a `NACK` the sender waits 8 cycles.
* **408:** the HDL in two parts. 3a: the core, the `MBOX` queue, `ACK`/`NACK`, the registers, the redirect over the ring and core 0's firmware. 3b: the writable tables, the conductor's network interface with `CONFIG`, and broadcast.
* **409:** `MBOX.ON`/`MBOX.OFF` renamed `EI`/`DI` (the same opcodes); they mask every asynchronous trap, so a future timer (410) is masked the same way.
