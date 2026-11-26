# Network on Chip: Design Note (Draft)

Status: agreed design (road map item 15, decisions 339 and 374–380). Steps 1 and 2 are built: step 1 (385–389) as `ParticleNetworkInterface`, step 2 (392–397), the one-way ring, as `ParticleRingRouter` and `ParticleRingInterface`, which Parcore now uses.

## Why

Before step 1, every pair of cores that talks had its own FIFO: Parcore's `ParcoreInterconnect` held five, each one block RAM, wired between fixed cores, and `MBOX` goes to one fixed target per core. That doesn't scale: all-to-all needs on the order of N² FIFOs, the wires lengthen as the chip grows, and the connections are fixed when the HDL is generated. A network on chip lets any core send to any other, lets the conductor arrange the cores at boot, and keeps every wire short.

What must not change:

* **The ISA.** `FIFO.R`, `FIFO.W`, `FIFO.STAT`, `FIFO.TRYR` and `FIFO.TRYW` keep their meaning, and firmware keeps naming its local channels (0–3). Parcore's stage firmware shouldn't need to change.
* **Order.** Words sent on one channel arrive in the order they were sent. Parcore's packets depend on it.
* **Nothing is lost** inside the network.

## Overview

Each core gets a **router** and a **network interface (NI)**:

```
            ┌──────────── ring ────────────┐
            ▼                               │
  conductor ─► core 0 ─► core 1 ─► core 2 ─► core 3
     │R│        │R│        │R│        │R│        │R│
     NI         NI         NI         NI         NI
     │          │          │          │          │
   core       core       core       core       core
```

* **Routers** pass packets along the links. Every hop is a register, so no wire crosses the chip.
* **The NI** sits where today's FIFO subsystem sits, on the core's FIFO port, so the core doesn't change. It holds:
  * a receive buffer per input channel (block RAM, 256 words, as today);
  * a **channel table** mapping each local channel to its destination: a core and that core's channel;
  * a credit count per output channel (see Flow control).
* **Local devices** stay local. A channel can be mapped to a device in the NI instead of to the network, such as core 3's channel 3, the FTDI UART.

## Topology

First a **one-way ring**: each router has one input from its neighbour, one output to the next, and a port to its own NI. That's the smallest router, and Parcore's traffic suits it. Its flows with the ring in the order conductor → core 0 → core 1 → core 2 → core 3 → conductor:

| Flow | Today | Hops on a one-way ring |
|---|---|---|
| Core 0 → core 1 (`ifToId`) | FIFO | 1 |
| Core 1 → core 2 (`idToEx`) | FIFO | 1 |
| Core 2 → core 3 (`exToMem`) | FIFO | 1 |
| Core 3 → core 1 (`memToWb`) | FIFO | 3 |
| Core 3 → core 0 (`memToIf`, store mirror) | FIFO | 2 |
| Core 2 → core 0 (`MBOX`, redirect) | wire | 3 |

Each hop adds a cycle. Only the backward flows get longer; core 1 waits on `memToWb` for 1.1% of its cycles today. A two-way ring, and then a 2D mesh when there are more cores, are later steps, with the same NI.

## Packets

One packet is one flit, so one packet crosses a link each cycle:

| Field | Bits | Meaning |
|---|---|---|
| type | 3 | `DATA`, `CREDIT`, `FLUSH`, `MBOX`, `CONFIG` |
| destination core | 8 | up to 256 cores (a mesh later splits it into x and y) |
| destination channel | 4 | channels 0–15 (the ISA uses 0–3 today) |
| source core | 8 | for credit returns and for `MBOX` |
| payload | 32 | the word (data, credit count, vector and value, or table entry) |

That's 55 bits per link: wide, but only to the neighbour. On a one-way ring of N cores it's N links.

## Flow control: credits from end to end

A sender's NI holds, for each output channel, the number of free words in the receiver's buffer: 256 at reset. It sends a `DATA` packet only when it has a credit, and spends one. The receiver's NI sends a `CREDIT` packet back as words are read. It returns them in batches (say, every 16 reads, or when idle) so credits don't double the traffic.

Every packet in the network therefore has room waiting at its destination. A router never has to stop a packet, so the ring never blocks and can't deadlock: there's no backpressure between routers at all.

The router itself:
* A packet for this core goes to the NI, which always accepts it.
* Any other packet goes on to the next router.
* The NI may put a packet onto the ring only when the incoming slot is empty.

That's about a register and a multiplexer per link bit, so roughly 100–150 LUT4s per router.

What firmware sees doesn't change:
* `FIFO.W` to a channel with no credit is dropped, as a `FIFO.W` to a full FIFO is today.
* `FIFO.TRYW` reports it in R14.
* **Injection queue (397):** a word that can't go on the ring at once waits in a queue of 8 in the NI; `FIFO.W` waits only while that queue is full, as `FIFO.R` waits while empty, and `FIFO.TRYW` returns 0. In Parcore the ring is lightly used, so this should almost never happen; it may need revisiting for ParticleMan, where several CSP tasks may communicate at once.
* `FIFO.STAT` on an output channel reports full when a write wouldn't be taken (no credit, or the injection queue full), and a count of 256 minus the credits: the words the channel holds, counting those in flight. Today's checks, like Parcore's "fewer than 128 words", keep their meaning.

## Flush

Today, `pipelineFlush` empties `ifToId` at once, driven by a wire from core 2's `MBOX` and from the conductor. With a network, words can still be on their way when the flush happens, and would arrive after it.

The proposal is an in-band **`FLUSH` packet**, sent by the sender's NI on that channel, triggered by the sending core.
* Order is kept, so everything sent before the `FLUSH` is already in the receive buffer when it arrives. The receiving NI then discards the buffer.
* The receiving NI owes the sender a credit for every word it discards, and returns them as for words read. (The sender does not reset its credits to 256 when it sends the `FLUSH`, as first planned: a `CREDIT` packet sent just before the `FLUSH` arrived could still be on its way, and would then give the sender more credits than the buffer has room for.)
* In Parcore, core 0 sends the `FLUSH` in its redirect handler, before the marker packet. Everything it pushed on the wrong path is discarded, including words pushed after core 2's redirect but before core 0 took it. Core 1's handling of a part-read packet (markers, a negative W3) stays as it is.
* The core needs a way to trigger it. The proposal is a small register in the NI at an MMIO address: storing a channel number sends a `FLUSH` on it. That avoids a new instruction.

## The channel table and `CONFIG`

Each NI's table maps local channels 0–15 to one of:
* a destination core and channel;
* a local device;
* nothing.

The conductor writes the tables at boot by sending `CONFIG` packets, one per entry. That way the cores can be arranged at boot without new wires, and a design with 100 cores is configured by firmware, not by the HDL. The HDL can also give each table a default at reset, so step 1 (below) works with no conductor changes.

## `MBOX`

`MBOX` becomes a packet type, with the vector and the sender's value in its payload and the source core in its header.
* The receiving NI always accepts it, so it can't block the ring either.
* What happens on arrival is the `MBOX` redesign (item 14): masking, no lost messages (a small queue instead of "a newer one replaces an older one"), and any target. Until then, it keeps today's behaviour.
* The destination comes from the core's `MBOX` table entry, as psim's `mbox_target` does today.

## Broadcast (380)

Destination core `0xFF` means every core. On a one-way ring a broadcast is cheap: the packet goes once round the ring, every router hands a copy to its NI and passes it on, and the sender's router takes it off when it comes back (its source core is the router's own).

Only the types every NI always accepts can be broadcast: `MBOX` and `CONFIG`. A broadcast `DATA` packet would need a credit at every receiver at once, so it isn't allowed; a sender's NI drops it, as it drops a `FIFO.W` without a credit.

Uses: the conductor setting the same table entry everywhere, or telling every core to stop, restart or reload (an `MBOX` to all); and later a barrier, each core answering the conductor when it gets there.

## Cost

| Part | Today (per FIFO) | With the NoC (per core) |
|---|---|---|
| Buffers | 1 block RAM per FIFO | 1 block RAM per input channel (two channels can share one 512-word block RAM) |
| Logic | about 180 LUT4s per FIFO | router about 100–150; NI (credits, table, status, buffer pointers) estimated about 200–300 |
| Latency | 1–2 cycles | 1 cycle to inject, 1 per hop, 1 to eject |

## Steps

1. **The NI and the channel table over today's direct links**, with nothing behaving differently. Parcore's FIFOs become NI receive buffers with fixed tables, and every test must give the same cycle counts. *Done:* the links are direct wires and credits come back in the same cycle (386); the tables are fixed by `ParcoreTop` (387); `pipelineFlush` stays a wire, an input of the NI (388); one block RAM per input, as before (389). The single-core ULX3S design keeps its FIFO subsystem for now (385).
2. **The one-way ring of routers**, with credits and `FLUSH`. Parcore moves onto it, and the profile shows what the extra hops cost. *psim first (396), done:* `"topology": "ring"` in a cluster file, with the cluster tests `ring_stream`, `ring_flow` and `ring_flush`. *HDL, done:* `ring_router.dart`, `ring_interface.dart`; the core's `fifoPushWait`; core 0 stores to the `FLUSH` register before its markers. On Parcore's benchmark the ring costs 1.5 cycles per RISC-V instruction (77.0 against 75.5), mostly core 1 waiting longer for its writebacks (3 hops). Two limits: a second store to the `FLUSH` register while one still waits for room in the injection queue is dropped (harmless on the same channel, since writes wait meanwhile); and resetting one core resets its interface but not its senders' credits, so cores that talk must be reset together (the conductor does). Decided for the HDL: the ring order conductor → core 0 → 1 → 2 → 3 (392); credits returned 16 at a time, or sooner when the slot is free (393); the `FLUSH` register at `0xFFFF_FF00`, written by core 0's redirect and FENCE.I handlers, replacing the `pipelineFlush` wire (394); the conductor's flush bit goes, and a core's NI resets with its core (395).
3. **`MBOX` as packets** (with item 14), and `CONFIG` from the conductor. The design is in [mbox_design.md](mbox_design.md). *psim, done. HDL step 3a, done:* `MBOX`, `ACK` and `NACK` packets (types 3, 5, 6), the receive and answer queues in `ring_interface.dart`, and core 2's redirect to core 0 over the ring in place of the wire. On Parcore's benchmark that costs 0.2 cycles per RISC-V instruction (77.2 against 77.0, about 8 cycles for each of the 273 redirects), more than the 0.1% estimated in 403. *Step 3b, next:* the writable tables, the conductor's interface with `CONFIG`, and broadcast.
4. **A two-way ring or a mesh** when the core count calls for it.

psim models each step first. It already routes channels between cores from a JSON configuration (`cluster_config_example.json`). It would gain a `"topology": "ring"`, with a latency per hop and credits, so firmware can be checked against the network's timing before the HDL exists.

## Decisions

* **374:** a one-way ring first; a two-way ring, then a mesh, later.
* **375:** credits from end to end; no backpressure between routers.
* **376:** an in-band `FLUSH` packet, triggered by a store to an NI register, replaces the `pipelineFlush` wire.
* **377:** the conductor writes the channel tables with `CONFIG` packets; the HDL gives defaults at reset.
* **378:** a `FIFO.W` without a credit is dropped, as today.
* **379:** the packet fields as above: 8 bits of core, 4 bits of channel, a 32-bit payload; 55 bits per link.
* **380:** broadcast to destination core `0xFF`, for `MBOX` and `CONFIG` only.
