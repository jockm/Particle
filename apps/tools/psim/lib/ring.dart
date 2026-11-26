// =============================================================================
// File: apps/tools/psim/lib/ring.dart
// Project: Particle RISC Architecture
// Description: A one-way ring network on chip for a cluster ("topology":
//              "ring"): step 2 of Documentation/noc_design.md.
// =============================================================================
//
// Each core has a router and a network interface (NI). The routers form a
// ring in the order the cores are listed; every link is a register, so a
// packet moves one router a cycle.
//
//   * A router hands a packet addressed to its core to the NI, which always
//     accepts it; any other packet goes on. Only when no packet goes on may
//     the NI put one of its own on the ring.
//   * A core's FIFO.W on a routed channel spends a credit (256 at the start:
//     the receiver's buffer) and joins the NI's injection queue (8 packets).
//     With no credit the word is dropped, as a FIFO.W to a full FIFO is;
//     with the queue full FIFO.W waits.
//   * Each word the receiving core reads is a credit for its sender, sent
//     back in a CREDIT packet once 16 are owed, or sooner when the NI has
//     nothing else to send.
//   * A store to the FLUSH register (0xFFFF_FF00) sends a FLUSH packet on a
//     channel. Order is kept, so what was sent before it is already in the
//     receiver's buffer when it arrives; the receiver empties the buffer and
//     owes its sender a credit for every word it discarded.
//
// MBOX doesn't use the ring yet (step 3).

import "dart:collection";

import "core.dart";

enum PacketType { data, credit, flush }

class Packet {
  final PacketType type;
  final int dest; // router index
  final int channel; // the destination's channel
  final int payload; // the word, or the number of credits

  const Packet(this.type, this.dest, this.channel, this.payload);
}

class RingNetwork {
  /// The NIs, in ring order.
  final List<RingInterface> nis = [];

  /// The packet on the link leaving each router, or null.
  late List<Packet?> _links;

  /// Packets that have moved over a link, for the statistics.
  int hops = 0;

  static const bufferWords = 256;
  static const injectionQueue = 8;
  static const creditBatch = 16;

  RingNetwork(List<ParticleCore> cores) {
    for (var i = 0; i < cores.length; i++) {
      final ni = RingInterface._(i, cores[i]);
      nis.add(ni);
      cores[i].network = ni;
    }
    _links = List.filled(cores.length, null);
  }

  /// Routes core [from]'s channel [ch] to core [to]'s channel [toCh]. A
  /// receiving channel can have one sender only: credits are per link.
  void route(int from, int ch, int to, int toCh) {
    final receiver = nis[to];
    final existing = receiver._senders[toCh];
    if (existing != null) {
      throw StateError("channel $toCh of core $to already has a sender (core ${existing.$1})");
    }
    nis[from]._routes[ch] = (to, toCh);
    receiver._senders[toCh] = (from, ch);
  }

  /// One cycle, after the cores have run theirs: every router takes the
  /// packet on its incoming link, delivers or passes it, and fills a free
  /// slot from its NI.
  void step() {
    final n = nis.length;
    final next = List<Packet?>.filled(n, null);
    for (var j = 0; j < n; j++) {
      var p = _links[(j - 1 + n) % n];
      if (p != null && p.dest == j) {
        nis[j]._deliver(p);
        p = null;
      }
      p ??= nis[j]._takeInjection();
      next[j] = p;
      if (p != null) hops++;
    }
    _links = next;
  }

  /// Whether nothing is in flight: no packet on a link, queued or owed.
  bool get idle =>
      _links.every((p) => p == null) &&
      nis.every((ni) => ni._queue.isEmpty && ni._owed.every((c) => c == 0));
}

class RingInterface implements NetworkPort {
  final int index;
  final ParticleCore core;

  /// Where each channel's writes go: (core, channel), or null.
  final List<(int, int)?> _routes = List.filled(4, null);

  /// Who sends to each of this core's channels: (core, their channel).
  final List<(int, int)?> _senders = List.filled(4, null);

  /// Credits for each output channel.
  final List<int> _credits = List.filled(4, RingNetwork.bufferWords);

  /// Credits this core owes the sender of each of its channels.
  final List<int> _owed = List.filled(4, 0);

  final Queue<Packet> _queue = Queue();

  RingInterface._(this.index, this.core);

  @override
  bool sends(int ch) => _routes[ch] != null;

  @override
  int push(int ch, int value) {
    final route = _routes[ch]!;
    if (_credits[ch] == 0) return NetworkPort.pushNoCredit;
    if (_queue.length >= RingNetwork.injectionQueue) return NetworkPort.pushQueueFull;
    _credits[ch]--;
    _queue.add(Packet(PacketType.data, route.$1, route.$2, value));
    return NetworkPort.pushAccepted;
  }

  /// Words held: 256 minus the credits (words in flight, in the receiver's
  /// buffer, or read but not yet credited). Full: a write now wouldn't be
  /// taken (no credit, or the injection queue is full); FIFO.TRYW returns 0
  /// then. Empty: every credit is back.
  @override
  int txStatus(int ch) {
    final held = RingNetwork.bufferWords - _credits[ch];
    final full = _credits[ch] == 0 || _queue.length >= RingNetwork.injectionQueue;
    return (held << 8) | (full ? 2 : 0) | (held == 0 ? 1 : 0);
  }

  @override
  void popped(int ch) {
    if (_senders[ch] != null) _owed[ch]++;
  }

  @override
  void flush(int ch) {
    final route = _routes[ch];
    if (route == null) return;
    // It follows the words already queued, in order
    _queue.add(Packet(PacketType.flush, route.$1, route.$2, 0));
  }

  /// The packet to put on the ring, if any: credits once a batch is owed,
  /// then the queue, then any credits owed.
  Packet? _takeInjection() {
    for (var ch = 0; ch < 4; ch++) {
      if (_owed[ch] >= RingNetwork.creditBatch) return _creditPacket(ch);
    }
    if (_queue.isNotEmpty) return _queue.removeFirst();
    for (var ch = 0; ch < 4; ch++) {
      if (_owed[ch] > 0) return _creditPacket(ch);
    }
    return null;
  }

  Packet _creditPacket(int ch) {
    final sender = _senders[ch]!;
    final p = Packet(PacketType.credit, sender.$1, sender.$2, _owed[ch]);
    _owed[ch] = 0;
    return p;
  }

  void _deliver(Packet p) {
    switch (p.type) {
      case PacketType.data:
        final q = core.fifos[p.channel];
        if (q.length >= RingNetwork.bufferWords) {
          throw StateError("ring: core $index's channel ${p.channel} overflowed (a credit was lost)");
        }
        q.add(p.payload);
      case PacketType.credit:
        _credits[p.channel] += p.payload;
        if (_credits[p.channel] > RingNetwork.bufferWords) {
          throw StateError("ring: core $index's channel ${p.channel} has more credits than buffer");
        }
      case PacketType.flush:
        final q = core.fifos[p.channel];
        _owed[p.channel] += q.length;
        q.clear();
    }
  }
}
