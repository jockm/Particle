# Particle Instruction Simulator & Debugger (`psim`)

`psim` is an instruction-accurate, cycle-counting simulator and interactive debugger (`p4db`) for the Particle processor architecture, written in Dart (`apps/tools/psim`, built into `build/tools/psim` by `make tools`). It models the 32-bit datapath, the register file with its shadow bank, byte-addressed memory, the streaming FIFO channels, and the direct stride trap vectors.

It runs a single core from a binary image, or several cores together (a *cluster*) described by a JSON file: their FIFO channels routed between cores, a shared memory window, and `MBOX` traps from one core to another.

---

## 1. Command-Line Usage

```bash
# One core
build/tools/psim <binary_file> [options]

# A cluster of cores
build/tools/psim -C <cluster.json> [options]
```

| Option | Parameter | Description |
| :--- | :--- | :--- |
| `binary` | `<path>` | Binary image to load and run on a single core. Without it (and without `-C`), psim starts the debugger with empty memory. |
| `-C`, `--cluster` | `<file.json>` | Run the cluster described by the file (see §3). Not with a binary. |
| `-b`, `--base` | `<addr>` | Load address of the binary (default `0x00000100`, the reset vector). |
| `-d`, `--debug` | — | Start the `p4db` debugger instead of running (§4). |
| `--max-cycles` | `<n>` | Stop after `n` cycles (default 10,000,000). |
| `--no-exit-on-reset` | — | `TRAP 0` jumps to the reset vector like any other trap, instead of ending the run. |
| `--no-pointer-modes` | — | The core has no pointer modes: those loads and stores raise vector 15, as in a core built with `enablePointerModes: false`. |
| `--no-subword` | — | No byte or halfword loads and stores (vector 15). |
| `--no-shadow-bank` | — | No shadow bank: `XCHG`, `XCHGALL` and `XCHGMOST` raise vector 15. |
| `--no-long-branches` | — | No 2-word PC-relative instructions (`BRA`, `BRA.Z`/`NZ`/`N`/`P`, `RJUMP disp16`, `BEQ`, `BNE`, `LEA`): they raise vector 15. |
| `--no-imm-bextr` | — | No immediate `BEXTR`/`SBEXTR` (`0x8D`): it raises vector 15. |
| `--no-wait-halt` | — | No `WAIT`/`HALT` (`0xEA`/`0xEB`): they raise vector 15. |
| `--no-mbox-receive` | — | The core ignores `MBOX` traps from other cores. In a cluster, set these per core in the cluster file instead (below). |

### Exit codes

| Code | Meaning |
| :--- | :--- |
| 0 | The run ended with `TRAP 0` (in a cluster: every core did). |
| 15 | A `TRAP 15` instruction (an out-of-bounds or sentinel trap). |
| 16 | A simulator error: file not found, bad arguments, or a cluster file that cannot be used. |
| 17 | The cycle limit was reached. |
| 18 | The PC ran past the end of memory. |
| 19 | A cluster deadlocked: every running core is waiting on an empty FIFO. |

In a cluster, the exit code is 0 when every core ended with `TRAP 0`; otherwise it is the code of the lowest-numbered core that ended another way.

---

## 2. Simulation Conventions

These are specific to the simulator (see also §5 of `particle_spec.md`):

* **Console**: Channel 0 is the console. `FIFO.W` to channel 0 prints `Rr[7:0]` to stdout (unless a cluster routes channel 0 to another core).
* **Ending a run**: `TRAP 0` ends the run on that core, printing `R1` (unless `--no-exit-on-reset`). `TRAP 15` ends it as an out-of-bounds or sentinel trap. Every other trap, including a misaligned access (vector 14), goes to its vector as on hardware. A misaligned load, store or `TAS` changes no register and no memory (not even a pointer update) before taking vector 14, whose R14 is the faulting instruction's address.
* **FIFOs**: Each core has 4 channels of 256 entries; a channel number is taken modulo 4. `FIFO.R` on an empty channel stalls: the PC stays on the instruction, and the stalled cycles count. A write to a full channel is dropped (`FIFO.TRYW` reports it in `R14`).
* **Memory**: 128 KiB per core by default; data addresses wrap within it.
* **Unlisted opcodes** take vector 15 with R14 = their address, as on hardware.
* **R0** always reads 0; writes to it are discarded.
* **Alignment**: misaligned 16- and 32-bit accesses, and an odd PC, raise vector 14 before any state changes.

---

## 3. Clusters

`psim -C <file.json>` runs several cores in lock step: each cycle, every running core executes one instruction, in id order. A core that ends its run stops; the cluster run ends when every core has stopped, the cycle limit is reached, or the cluster deadlocks.

* **FIFO routing**: a core's `fifo_connections.tx` routes each local channel to a receive channel on another core. A write to a routed channel (`FIFO.W`, `FIFO.TRYW`) goes into the target core's channel, where its `FIFO.R`/`FIFO.TRYR` read it. A channel that is not routed stays local, as on a single core. `FIFO.STAT` reports the core's own (receiving) channel.
* **Shared memory**: when `shared_memory_size` is not 0, the window from `shared_memory_base` is the same memory on every core. Loads, stores and `TAS` in it are seen at once by all cores, so `TAS` works as a lock between cores.
* **MBOX** (`Documentation/mbox_design.md`): `MBOX Rr, Imm4` raises trap `Imm4` on the core's default target (in a two-core cluster the other core; otherwise its `mbox_target`), and `MBOX Rr, Rl` on core `Rl[7:0]` with vector `Rl[11:8]` (`0xFF`: every other core). It goes into the target's queue (4 deep, plus one slot for a broadcast) and waits while that is full; the target takes it before its next instruction unless masked (`DI`/`EI`). Taking it sets `EPC` to the interrupted instruction (a stalled one runs again), masks, and leaves R14 and memory alone; the handler loads the value from `0xFFFF_FF04` and the sender from `0xFFFF_FF08`, and `RETI` returns to `EPC` and unmasks. An `MBOX` to a core that has stopped does nothing. With a single core, `MBOX` does nothing.
* **WAIT and HALT:** `WAIT` stalls the core until an `MBOX` is pending: unmasked it is taken, with `EPC` past the `WAIT`; masked (`DI`) the core goes on after the `WAIT` and the `MBOX` stays queued. A run in which every core still running is in a `WAIT` or an empty `FIFO.R`, with nothing in flight, is a deadlock (exit 19), and the message names each core's `WAIT`. `HALT` stops the core, as `TRAP 0` does (exit 0): on its own the run ends, and in a cluster the core stops and an `MBOX` to it does nothing. Cluster test `wait_halt`.
* **Deadlock**: when every running core is waiting (on an empty FIFO, or to send) and no `MBOX` trap can be taken, nothing can change. psim stops with exit code 19 and names each core and the channel it waits on.

### Cluster file

```json
{
  "shared_memory_base": "0x80000000",
  "shared_memory_size": 4096,
  "cores": [
    {
      "id": 0,
      "name": "producer",
      "mem_size": 131072,
      "binary": "build/producer.bin",
      "base_addr": "0x00000100",
      "initial_registers": { "R13": 0, "SP": "0x00010000" },
      "fifo_connections": {
        "tx": [ { "channel": 1, "target_core": 1, "target_channel": 1 } ]
      }
    },
    {
      "id": 1,
      "name": "consumer",
      "binary": "build/consumer.bin",
      "initial_registers": { "R13": 1 }
    }
  ]
}
```

| Field | Default | Meaning |
| :--- | :--- | :--- |
| `shared_memory_size` | `0` | Bytes of shared memory; `0` for none. |
| `shared_memory_base` | `0x80000000` | Address of the shared window. |
| `cores` | — | The cores, at least one. |
| `id` | its position | The core's number, used by routes, `mbox_target` and the exit code. |
| `name` | `core<id>` | The core's name in messages and the debugger. |
| `mem_size` | `131072` | The core's own memory, in bytes (a power of two). |
| `binary` | none | Binary image to load; a relative path is relative to the cluster file's folder. |
| `base_addr` | `0x00000100` | Where `binary` is loaded. |
| `initial_registers` | none | Starting values: `R0`–`R15` or `SP`. |
| `fifo_connections.tx` | none | Routes: local `channel` (0–3) to `target_channel` (0–3, default the same) on `target_core`. |
| `mbox_target` | the other core of a pair | The core this core's `MBOX` signals. |
| `pointer_modes`, `subword`, `shadow_bank`, `mbox_receive`, `long_branches`, `imm_bextr`, `wait_halt` | `true` | The core's optional features, as the options above: `false` leaves one out. |

Numbers may be JSON numbers or strings (`"0x80000000"`). Other fields are ignored.

`topology` (at the top of the file) is `"point_to_point_fifo"` (the default: a write goes straight into the target core's FIFO) or `"ring"`: the network on chip of `noc_design.md`, step 2. On a ring:

* The cores form a one-way ring in the order they are listed. A packet moves one router a cycle; a router delivers a packet for its own core and passes the rest on, and its core may put a packet on only when no packet is passing. Routers keep running after their cores stop.
* A write on a routed channel spends a credit (256 to start: the receiver's buffer) and joins the core's injection queue (8 packets). Without a credit the word is dropped, as a `FIFO.W` to a full FIFO is; with the queue full, `FIFO.W` waits and `FIFO.TRYW` returns 0.
* Each word the receiver reads is a credit for the sender, sent back in a `CREDIT` packet once 16 are owed, or sooner when the receiver has nothing else to send. A receiving channel can have only one sender.
* `FIFO.STAT` on a routed channel gives the words held (256 minus the credits, so it counts words in flight and read words not yet credited), full when a write wouldn't be taken (no credit, or the queue is full), and empty when every credit is back.
* A store of a channel number to `0xFFFF_FF00` (the network interface's `FLUSH` register) sends a `FLUSH` on that channel. It follows the words sent before it; the receiver empties that channel's buffer and owes the sender a credit for each word it discarded.
* An `MBOX` is a packet. The receiver answers `ACK`, or `NACK` when its queue is full; the sender keeps its `MBOX` until the answer, sends it again 8 cycles after a `NACK`, and waits with its next `MBOX` until then. A broadcast goes round the ring once (each core takes a copy) and needs no answer.
* A store to `0xFFFF_FF0C` (`NI_CONFIG`) sends a `CONFIG` packet setting one entry of a core's table. The word: bits 31:24 the core (`0xFF`: every core), 23:20 the entry (0 a channel's route, 1 the sender of a channel's input, 2 the default `MBOX` target), 19:16 the channel, 15:8 a core and 3:0 a channel, the new value. A new route gets 256 credits. (In the HDL only an interface built with `configSender`, in Parcore the conductor's, has this register; psim lets any core use it.)
* The run prints the number of packet hops.


`Documentation/cluster_config_example.json` is a working file with every field: after `make test-sim-cluster` has built the programs, `build/tools/psim -C Documentation/cluster_config_example.json` runs it. The cluster tests (`make test-sim-cluster`, part of `make test`) are further examples: `apps/asm/cluster/` has a producer and consumer (`stream.json`), an `MBOX` that interrupts a stalled core (`mbox.json`), a counter in shared memory under a `TAS` lock (`shared.json`), and a deadlock (`deadlock.json`); `MBOX` queueing with masking and `RETI` (`mbox_queue.json`) and `MBOX` to chosen cores and a broadcast (`mbox_any.json`); and on a ring, a stream past a stopped core (`ring_stream.json`), flow control with a slow reader (`ring_flow.json`), `FLUSH` (`ring_flush.json`), the two `MBOX` tests again with `ACK`/`NACK` (`ring_mbox_queue.json`, `ring_mbox_any.json`), and `CONFIG` moving a route and the default `MBOX` target (`ring_config.json`).

---

## 4. Interactive Debugger (`p4db`)

`psim -d` (with a binary or a cluster) stops before the first instruction and gives a prompt. In a cluster, `r`, `m`, `w`, `wh`, `wb`, `b` and `fifo` work on the selected core (marked `*`).

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `s` | `[count]` | Step one cycle (or `count`). In a cluster, every core steps, and each core's PC is shown. |
| `c` | — | Continue until a breakpoint on any core, every core stops, the cycle limit, or (in a cluster) a deadlock. Selects the core that hit the breakpoint. |
| `b` | `<addr>` | Set a breakpoint on the selected core. |
| `r` | — | Show the PC, cycles, `R0`–`R15` and the shadow registers `S0`–`S15`. |
| `m` | `<addr> [count]` | Hex and ASCII dump of `count` bytes (default 16). Addresses in the shared window show shared memory. |
| `w` | `<addr> <v> ...` | Write 32-bit words. |
| `wh` | `<addr> <v> ...` | Write 16-bit halfwords. |
| `wb` | `<addr> <v> ...` | Write bytes. |
| `cores` | — | List the cores: PC, cycles, and `RUNNING`, `STALLED` (with the channel) or `HALTED`. |
| `switch` | `<n>` | Select core `n` (its position, as `cores` lists it). |
| `fifo` | — | The selected core's channels: entries, the head value, `EMPTY`/`FULL`, and where writes are routed. |
| `help` | `[cmd]` | List the commands, or describe one. |
| `q` | — | Quit. |
