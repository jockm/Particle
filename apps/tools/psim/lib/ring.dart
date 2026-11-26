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
// Step 3 (Documentation/mbox_design.md):
//
//   * An MBOX is a packet. The receiver's core takes it into its queue (4
//     deep) and answers ACK, or NACK when the queue is full; the sender keeps
//     its MBOX until the answer, sends it again 8 cycles after a NACK, and
//     waits with its next MBOX until then (one in flight per core).
//   * A packet to core 0xFF is a broadcast: every router hands a copy to its
//     core and passes it on, and the sender's router takes it off. A
//     broadcast MBOX needs no answer; a core whose broadcast slot is full
//     drops it.
//   * A store to the CONFIG register (0xFFFF_FF0C) sends a CONFIG packet
//     setting one entry of a core's table: a channel's route, its input's
//     sender, or the default MBOX target. ACK, NACK and CREDIT packets go
//     before the injection queue.

import "dart:collection";

import "core.dart";

enum PacketType { data, credit, flush, mbox, ack, nack, config }

class Packet {
  final PacketType type;
  final int dest; // router index, or [broadcastDest]
  final int channel; // the destination's channel (an MBOX: its vector)
  final int payload; // the word, the number of credits, or a CONFIG word
  final int src; // the sending router

  const Packet(this.type, this.dest, this.channel, this.payload, [this.src = -1]);

  static const broadcastDest = 0xFF;
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
  static const mboxRetryCycles = 8;

  /// Cycles run, for MBOX retries.
  int cycle = 0;

  /// Core number -> router index, set by [connectMbox].
  Map<int, int> _byId = const {};

  RingNetwork(List<ParticleCore> cores) {
    for (var i = 0; i < cores.length; i++) {
      final ni = RingInterface._(i, cores[i]).._net = this;
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
      if (p != null && p.dest == Packet.broadcastDest) {
        // A broadcast: a copy for every core, and off at its sender
        if (p.src == j) {
          p = null;
        } else {
          nis[j]._deliver(p);
        }
      } else if (p != null && p.dest == j) {
        nis[j]._deliver(p);
        p = null;
      }
      p ??= nis[j]._takeInjection();
      next[j] = p;
      if (p != null) hops++;
    }
    _links = next;
    cycle++;
  }

  /// Sends core [i]'s MBOXes over the ring. [byId] maps core numbers to
  /// router indexes; [warn] reports a bad target once.
  void connectMbox(int i, Map<int, int> byId, void Function(String) warn) {
    _byId = byId;
    final ni = nis[i];
    ni.core.onMbox = (target, vector, value) {
      final tid = target ?? ni.core.mboxTarget;
      if (tid == null) {
        warn("MBOX with no target (set 'mbox_target' for clusters of more than two cores)");
        return true;
      }
      if (tid == mboxBroadcast) return ni._sendMbox(Packet.broadcastDest, vector, value);
      final t = byId[tid];
      if (t == null) {
        warn("MBOX to core $tid, which does not exist");
        return true;
      }
      return ni._sendMbox(t, vector, value);
    };
  }

  /// Whether nothing is in flight: no packet on a link, queued or owed.
  bool get idle =>
      _links.every((p) => p == null) &&
      nis.every((ni) =>
          ni._queue.isEmpty &&
          ni._control.isEmpty &&
          ni._mboxOut == null &&
          ni._owed.every((c) => c == 0));
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

  /// ACK and NACK answers to send, before anything else.
  final Queue<Packet> _control = Queue();

  /// The MBOX sent and not yet answered, and when to send it again after a
  /// NACK (null: wait for the answer).
  Packet? _mboxOut;
  int? _mboxRetryAt;

  /// Set by the cluster, for MBOX retries and core numbers.
  late final RingNetwork _net;

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

  /// An MBOX to router [dest] (or a broadcast): false while the last one is
  /// unanswered or the injection queue is full.
  bool _sendMbox(int dest, int vector, int value) {
    if (_mboxOut != null) return false;
    if (_queue.length >= RingNetwork.injectionQueue) return false;
    final p = Packet(PacketType.mbox, dest, vector & 0x0F, value & mask32, index);
    _queue.add(p);
    // A broadcast needs no answer
    if (dest != Packet.broadcastDest) _mboxOut = p;
    return true;
  }

  @override
  void config(int word) {
    final dest = (word >> 24) & 0xFF;
    final d = dest == Packet.broadcastDest ? dest : _net._byId[dest];
    if (d == null) return;
    _queue.add(Packet(PacketType.config, d, 0, word, index));
  }

  void _applyConfig(int word) {
    final kind = (word >> 20) & 0x0F;
    final ch = (word >> 16) & 0x03;
    final coreNum = (word >> 8) & 0xFF;
    final valueCh = word & 0x0F;
    final r = _net._byId[coreNum];
    switch (kind) {
      case 0: // the route of channel ch
        if (r != null) {
          _routes[ch] = (r, valueCh & 3);
          _credits[ch] = RingNetwork.bufferWords;
        }
      case 1: // the sender of channel ch's input
        if (r != null) _senders[ch] = (r, valueCh & 3);
      case 2: // the default MBOX target
        core.mboxTarget = coreNum;
    }
  }

  /// The packet to put on the ring, if any: answers first, then credits
  /// once a batch is owed, an MBOX due again, the queue, then any credits
  /// owed.
  Packet? _takeInjection() {
    if (_control.isNotEmpty) return _control.removeFirst();
    final retry = _mboxRetryAt;
    if (retry != null && _net.cycle >= retry && _mboxOut != null) {
      _mboxRetryAt = null;
      return _mboxOut;
    }
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
      case PacketType.mbox:
        final source = _net.nis[p.src].core.id;
        if (p.dest == Packet.broadcastDest) {
          if (!core.halted) core.acceptMbox(p.channel, p.payload, source, broadcast: true);
        } else {
          final ok = core.halted || core.acceptMbox(p.channel, p.payload, source);
          _control.add(Packet(ok ? PacketType.ack : PacketType.nack, p.src, 0, 0, index));
        }
      case PacketType.ack:
        _mboxOut = null;
        _mboxRetryAt = null;
      case PacketType.nack:
        _mboxRetryAt = _net.cycle + RingNetwork.mboxRetryCycles;
      case PacketType.config:
        _applyConfig(p.payload);
    }
  }
}
