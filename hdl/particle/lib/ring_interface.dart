// =============================================================================
// File: hdl/particle/lib/ring_interface.dart
// Architecture: Particle 32-bit RISC
// Description: A core's network interface on the one-way ring (step 2 of
//              Documentation/noc_design.md).
// =============================================================================
//
// Like ParticleNetworkInterface it sits on the core's FIFO port, with the
// same channel table, receive buffers, credits and local device, but its
// words travel as packets through a ParticleRingRouter:
//
//   * A FIFO.W on an output channel spends a credit and joins an injection
//     queue of 8 packets (LUT RAM); the router takes the queue's packets when
//     no packet is passing. Without a credit the word is dropped, as a
//     FIFO.W to a full FIFO is; with the queue full the core waits
//     (pushWait), and FIFO.TRYW returns 0 (FIFO.STAT reports full).
//   * Each word the core reads is a credit owed to that input's sender. They
//     go back in a CREDIT packet once 16 are owed, or sooner when there is
//     nothing else to send.
//   * A store to the FLUSH register (flushStrobe, with the channel in
//     flushChannel) queues a FLUSH packet behind the words already queued;
//     FIFO.W waits while it can't be queued. When a FLUSH arrives the
//     receive buffer is emptied, and a credit is owed for every word in it.
//   * DATA packets go into the receive buffer their channel reads; CREDIT
//     packets give the output channel they name its credits back.
//   * MBOX (step 3a of Documentation/mbox_design.md): an arriving MBOX joins
//     a queue of 4 and is answered ACK, or NACK when the queue is full; with
//     the answer queue (4) full it gets no answer, and its sender sends it
//     again after a timeout. The queue is handed to the core one MBOX at a
//     time, when the core is ready (mboxCoreReady). The core's own MBOX goes
//     to its target (or the default target) straight from a register, ahead
//     of the injection queue, and is kept until answered: sent again 8 cycles
//     after a NACK, or 64 after no answer; meanwhile the core's next MBOX
//     waits (mboxSendWait). An answer taking longer than 64 cycles would mean
//     a second copy (412); on Parcore's ring it takes under 10.
//   * Broadcast (step 3b): an MBOX to core 0xFF goes to every other core and
//     needs no answer. Each receiver keeps one slot for a broadcast, taken
//     after its queue; a broadcast that finds the slot full is dropped.
//   * CONFIG (step 3b): a CONFIG packet sets one entry of the tables, which
//     start as the HDL's txRoutes, rxSenders and mboxDefaultTarget: a
//     channel's route (with 256 new credits), the sender of a channel's
//     input, or the default MBOX target. An interface built with
//     configSender queues one for each store to the CONFIG register
//     (configStrobe, with configWord); a second store while one still waits
//     for room in the injection queue is dropped, as for FLUSH.
//   * ringCores, when given, lists the cores on the ring: an MBOX or CONFIG
//     for any other core is dropped (MBOX Rr, Imm4 with no default target
//     too).
//   * Options (411): without mboxReceive an arriving MBOX is answered ACK and
//     discarded; without mboxSend the core's MBOX is dropped; without
//     acceptConfig CONFIG packets are ignored, so the tables stay constant
//     and synthesis removes them.

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'fifo_subsystem.dart';
import 'lut_ram.dart';
import 'network_interface.dart';
import 'ring_router.dart';

/// The network interface's FLUSH register: storing a channel number sends a
/// FLUSH packet on it.
const int niFlushRegister = 0xFFFFFF00;

/// The CONFIG register: storing a CONFIG word sends a CONFIG packet
/// (Documentation/mbox_design.md, part 6).
const int niConfigRegister = 0xFFFFFF0C;

/// Where an output channel's packets go: a core and that core's channel.
typedef NocAddress = ({int core, int channel});

class ParticleRingInterface extends Module {
  final List<NiChannel> channels;
  final int coreId;

  /// For each output link: its destination.
  final List<NocAddress> txRoutes;

  /// For each receive buffer: its sender (core, and the sender's channel),
  /// to which its credits go back.
  final List<NocAddress> rxSenders;

  static const bufferWords = 256;
  static const queueDepth = 8;
  static const creditBatch = 16;
  static const mboxQueueDepth = 4;
  static const answerQueueDepth = 4;
  static const mboxRetryCycles = 8;
  static const mboxTimeoutCycles = 64;

  /// The core MBOX Rr, Imm4 goes to at reset, or null (it is dropped).
  final int? mboxDefaultTarget;

  /// The cores on the ring, or null for any.
  final List<int>? ringCores;

  final bool mboxSend;
  final bool mboxReceive;
  final bool acceptConfig;
  final bool configSender;

  Logic get popData => output('popData');
  Logic get statusWord => output('statusWord');
  Logic get pushWait => output('pushWait');
  Logic get inject => output('inject');
  Logic get injectValid => output('injectValid');
  Logic get devPushEn => output('devPushEn');
  Logic get devPushData => output('devPushData');
  Logic get devPopEn => output('devPopEn');

  // MBOX: to the core (an MBOX from the queue), and from it
  Logic get mboxStrobe => output('mboxStrobe');
  Logic get mboxVector => output('mboxVector');
  Logic get mboxData => output('mboxData');
  Logic get mboxSource => output('mboxSource');
  Logic get mboxSendWait => output('mboxSendWait');

  late final List<Logic> _credits;
  late final List<Logic> _owed;

  /// Output link [j]'s credits, and the credits owed for input [i], for
  /// tests.
  int credits(int j) => _credits[j].value.toInt();
  int owed(int i) => _owed[i].value.toInt();

  ParticleRingInterface({
    required Logic clk,
    required Logic reset,
    required Logic chanSelect,
    required Logic pushData,
    required Logic pushEn,
    required Logic popEn,
    required this.channels,
    required this.coreId,
    this.txRoutes = const [],
    this.rxSenders = const [],
    required Logic eject,
    required Logic ejectValid,
    required Logic injectTaken,
    Logic? flushStrobe,
    Logic? flushChannel,
    Logic? devPopData,
    Logic? devStatus,
    List<String>? bufferNames,
    Logic? mboxSendStrobe,
    Logic? mboxSendVector,
    Logic? mboxSendData,
    Logic? mboxSendTarget,
    Logic? mboxSendTargetValid,
    Logic? mboxCoreReady,
    this.mboxDefaultTarget,
    this.ringCores,
    this.mboxSend = true,
    this.mboxReceive = true,
    this.acceptConfig = true,
    this.configSender = false,
    Logic? configStrobe,
    Logic? configWord,
    super.name = 'ring_interface',
  }) {
    final inputCount = rxSenders.length;
    final outputCount = txRoutes.length;
    if (channels.length != 4) {
      throw ArgumentError('The channel table needs 4 entries');
    }
    for (final ch in channels) {
      if ((ch.rx != null && ch.rx! >= inputCount) ||
          (ch.tx != null && ch.tx! >= outputCount) ||
          (ch.status.input != null && ch.status.input! >= inputCount) ||
          (ch.status.output != null && ch.status.output! >= outputCount)) {
        throw ArgumentError('A channel names an input or output that '
            'does not exist');
      }
    }
    const w = ParticleWidths.word;
    const pw = NocPacket.width;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    chanSelect = addInput('chanSelect', chanSelect, width: 2);
    pushData = addInput('pushData', pushData, width: w);
    pushEn = addInput('pushEn', pushEn);
    popEn = addInput('popEn', popEn);
    eject = addInput('eject', eject, width: pw);
    ejectValid = addInput('ejectValid', ejectValid);
    injectTaken = addInput('injectTaken', injectTaken);
    final fStrobe = addInput('flushStrobe', flushStrobe ?? Const(0));
    final fChannel =
        addInput('flushChannel', flushChannel ?? Const(0, width: 2), width: 2);
    final dData =
        addInput('devPopData', devPopData ?? Const(0, width: w), width: w);
    final dStatus =
        addInput('devStatus', devStatus ?? Const(0, width: w), width: w);
    addOutput('popData', width: w);
    addOutput('statusWord', width: w);
    addOutput('pushWait');
    addOutput('inject', width: pw);
    addOutput('injectValid');
    addOutput('devPushEn');
    addOutput('devPushData', width: w);
    addOutput('devPopEn');
    final mSend = addInput('mboxSendStrobe', mboxSendStrobe ?? Const(0));
    final mVec =
        addInput('mboxSendVector', mboxSendVector ?? Const(0, width: 4), width: 4);
    final mData =
        addInput('mboxSendData', mboxSendData ?? Const(0, width: w), width: w);
    final mTarget =
        addInput('mboxSendTarget', mboxSendTarget ?? Const(0, width: 8), width: 8);
    final mTargetValid =
        addInput('mboxSendTargetValid', mboxSendTargetValid ?? Const(0));
    final mReady = addInput('mboxCoreReady', mboxCoreReady ?? Const(0));
    addOutput('mboxStrobe');
    addOutput('mboxVector', width: 4);
    addOutput('mboxData', width: w);
    addOutput('mboxSource', width: 8);
    addOutput('mboxSendWait');
    final cStrobe = addInput('configStrobe', configStrobe ?? Const(0));
    final cWord =
        addInput('configWord', configWord ?? Const(0, width: w), width: w);

    Logic on(int c) => chanSelect.eq(Const(c, width: 2));
    Logic anyOf(Iterable<int> cs) =>
        cs.map(on).fold<Logic>(Const(0), (a, b) => a | b);
    List<int> where(bool Function(NiChannel) f) =>
        [for (var c = 0; c < 4; c++) if (f(channels[c])) c];

    // ---- The tables (CONFIG writes them) ----
    final routeCore = [
      for (var j = 0; j < outputCount; j++)
        Logic(name: 'routeCore$j', width: 8),
    ];
    final routeCh = [
      for (var j = 0; j < outputCount; j++) Logic(name: 'routeCh$j', width: 2),
    ];
    final senderCore = [
      for (var i = 0; i < inputCount; i++)
        Logic(name: 'senderCore$i', width: 8),
    ];
    final senderCh = [
      for (var i = 0; i < inputCount; i++) Logic(name: 'senderCh$i', width: 2),
    ];
    final defTarget = Logic(name: 'mboxDefTarget', width: 8);
    final defValid = Logic(name: 'mboxDefValid');
    // Whether a core is on the ring
    Logic exists(Logic core) => ringCores == null
        ? Const(1)
        : ringCores!
            .map((c) => core.eq(Const(c, width: 8)))
            .fold<Logic>(Const(0), (a, b) => a | b);
    final toAll = Const(NocPacket.broadcast, width: 8);

    // ---- Arriving packets ----
    final pType = NocPacket.type(eject);
    final pChan = NocPacket.channel(eject);
    Logic arrives(int type) =>
        ejectValid & pType.eq(Const(type, width: 3));
    // The receive buffer a DATA or FLUSH packet's channel reads, and the
    // output channel a CREDIT names
    Logic forInput(int i) => [
          for (var c = 0; c < 4; c++)
            if (channels[c].rx == i && !channels[c].device) c
        ].map((c) => pChan.eq(Const(c, width: 4))).fold<Logic>(
            Const(0), (a, b) => a | b);
    Logic forOutput(int j) => [
          for (var c = 0; c < 4; c++)
            if (channels[c].tx == j && !channels[c].device) c
        ].map((c) => pChan.eq(Const(c, width: 4))).fold<Logic>(
            Const(0), (a, b) => a | b);

    // ---- Receive buffers ----
    final popOf = [
      for (var i = 0; i < inputCount; i++)
        popEn & anyOf(where((ch) => ch.rx == i && !ch.device)),
    ];
    final flushIn = [
      for (var i = 0; i < inputCount; i++)
        arrives(NocPacket.flush) & forInput(i),
    ];
    final buffers = [
      for (var i = 0; i < inputCount; i++)
        ParticleFifoSubsystem(
          clk: clk,
          reset: reset | flushIn[i],
          chanSelect: Const(0, width: 2),
          pushData: NocPacket.payload(eject),
          pushEn: arrives(NocPacket.data) & forInput(i),
          popEn: popOf[i],
          channels: 1,
          name: bufferNames?[i] ?? 'rx_buffer_$i',
        ),
    ];
    // Words a buffer holds (its status gives 8 bits and full for 256)
    Logic held(ParticleFifoSubsystem b) => mux(
        b.full,
        Const(bufferWords, width: 9),
        b.statusWord.getRange(8, 16).zeroExtend(9));

    // ---- Credits owed for each input ----
    _owed = [
      for (var i = 0; i < inputCount; i++) Logic(name: 'owed$i', width: 9),
    ];
    final readNow = [
      for (var i = 0; i < inputCount; i++) popOf[i] & ~buffers[i].empty,
    ];

    // ---- Output credits and the injection queue ----
    _credits = [
      for (var j = 0; j < outputCount; j++) Logic(name: 'credits$j', width: 9),
    ];
    final qWr = Logic(name: 'qWr', width: 3);
    final qRd = Logic(name: 'qRd', width: 3);
    final qCount = Logic(name: 'qCount', width: 4);
    final qFull = qCount.eq(Const(queueDepth, width: 4));
    final qEmpty = qCount.eq(0);
    final flushPending = Logic(name: 'flushPending');
    final flushPendingCh = Logic(name: 'flushPendingCh', width: 2);

    // A FLUSH to queue: a new store, or one waiting for room
    final flushCh = mux(flushPending, flushPendingCh, fChannel);
    final flushWanted = flushPending | fStrobe;
    Logic txOf(Logic ch, int j) => [
          for (var c = 0; c < 4; c++)
            if (channels[c].tx == j && !channels[c].device) c
        ].map((c) => ch.eq(Const(c, width: 2))).fold<Logic>(
            Const(0), (a, b) => a | b);
    final flushHasRoute = [
      for (var j = 0; j < outputCount; j++) txOf(flushCh, j),
    ].fold<Logic>(Const(0), (a, b) => a | b);

    // A word from the core: its output link, and whether it has a credit
    final pushOn = [
      for (var j = 0; j < outputCount; j++)
        pushEn & anyOf(where((ch) => ch.tx == j && !ch.device)),
    ];
    final hasCredit = [
      for (var j = 0; j < outputCount; j++) ~_credits[j].eq(0),
    ];
    final pushTx = pushOn.fold<Logic>(Const(0), (a, b) => a | b);
    final pushCredit = [
      for (var j = 0; j < outputCount; j++) pushOn[j] & hasCredit[j],
    ].fold<Logic>(Const(0), (a, b) => a | b);
    // A CONFIG to queue (configSender): a new store, or one waiting for room
    final configPending = Logic(name: 'configPending');
    final configPendingWord = Logic(name: 'configPendingWord', width: w);
    final configWanted = configSender ? configPending | cStrobe : Const(0);
    final cfgWord = mux(configPending, configPendingWord, cWord);
    final cfgDest = cfgWord.getRange(24, 32);
    final cfgOk = cfgDest.eq(toAll) | exists(cfgDest);
    // The core waits while the queue is full or a FLUSH or CONFIG waits to be
    // queued
    final blocked = qFull | flushPending | configPending;
    pushWait <= pushTx & pushCredit & blocked;
    final enqueueData = [
      for (var j = 0; j < outputCount; j++) pushOn[j] & hasCredit[j] & ~blocked,
    ];
    final enqueueFlush = flushWanted & flushHasRoute & ~qFull;
    // A FLUSH goes first if both are waiting
    final enqueueConfig = configWanted & cfgOk & ~qFull & ~enqueueFlush;
    final configWaits = configWanted & cfgOk & ~enqueueConfig;

    // The queued packet: the word to its route, or a FLUSH to the route of
    // its channel
    Logic routeDest(Logic Function(int) sel) => [
          for (var j = 0; j < outputCount; j++)
            mux(sel(j), routeCore[j], Const(0, width: 8)),
        ].fold<Logic>(Const(0, width: 8), (a, b) => a | b);
    Logic routeChan(Logic Function(int) sel) => [
          for (var j = 0; j < outputCount; j++)
            mux(sel(j), routeCh[j].zeroExtend(4), Const(0, width: 4)),
        ].fold<Logic>(Const(0, width: 4), (a, b) => a | b);
    final dataPacket = NocPacket.make(
      type: NocPacket.data,
      dest: routeDest((j) => pushOn[j]),
      channel: routeChan((j) => pushOn[j]),
      src: coreId,
      payload: pushData,
    );
    final configPacket = NocPacket.make(
      type: NocPacket.config,
      dest: cfgDest,
      channel: Const(0, width: 4),
      src: coreId,
      payload: cfgWord,
    );
    final flushPacket = NocPacket.make(
      type: NocPacket.flush,
      dest: routeDest((j) => txOf(flushCh, j)),
      channel: routeChan((j) => txOf(flushCh, j)),
      src: coreId,
      payload: Const(0, width: w),
    );
    final anyEnqueueData =
        enqueueData.fold<Logic>(Const(0), (a, b) => a | b);
    final enqueue = anyEnqueueData | enqueueFlush | enqueueConfig;
    final queue = ParticleLutRam(
      clk: clk,
      wAddr: qWr,
      wData: mux(enqueueConfig, configPacket,
          mux(enqueueFlush, flushPacket, dataPacket)),
      wEn: enqueue,
      rAddrA: qRd,
      rAddrB: qRd,
      depth: queueDepth,
      width: pw,
      name: 'inject_queue',
    );

    // ---- What goes on the ring: a batch of credits, the queue, then any
    // credits owed ----
    Logic creditPacket(int i) => NocPacket.make(
          type: NocPacket.credit,
          dest: senderCore[i],
          channel: senderCh[i].zeroExtend(4),
          src: coreId,
          payload: _owed[i].zeroExtend(w),
        );
    final batch = [
      for (var i = 0; i < inputCount; i++)
        _owed[i].gte(Const(creditBatch, width: 9)),
    ];
    final some = [
      for (var i = 0; i < inputCount; i++) ~_owed[i].eq(0),
    ];
    // Choose: the first input with a batch; else the queue; else the first
    // input owed anything
    Logic chosen = Const(0, width: pw);
    Logic chosenValid = Const(0);
    final sendCredit = List<Logic>.filled(inputCount, Const(0));
    Logic takeQueue = Const(0);
    {
      // Built from the lowest priority up
      for (var i = inputCount - 1; i >= 0; i--) {
        chosen = mux(some[i], creditPacket(i), chosen);
        chosenValid = some[i] | chosenValid;
      }
      final lowCredit = [for (var i = 0; i < inputCount; i++) some[i]];
      chosen = mux(~qEmpty, queue.rDataA, chosen);
      chosenValid = ~qEmpty | chosenValid;
      final anyBatch = batch.fold<Logic>(Const(0), (a, b) => a | b);
      Logic batchPacket = Const(0, width: pw);
      for (var i = inputCount - 1; i >= 0; i--) {
        batchPacket = mux(batch[i], creditPacket(i), batchPacket);
      }
      chosen = mux(anyBatch, batchPacket, chosen);
      chosenValid = anyBatch | chosenValid;
      takeQueue = ~anyBatch & ~qEmpty;
      // Which input's credits go: the first with a batch, else (queue empty)
      // the first owed anything
      Logic earlierBatch = Const(0);
      Logic earlierSome = Const(0);
      for (var i = 0; i < inputCount; i++) {
        final viaBatch = batch[i] & ~earlierBatch;
        final viaSome =
            ~anyBatch & qEmpty & lowCredit[i] & ~earlierSome;
        sendCredit[i] = viaBatch | viaSome;
        earlierBatch = earlierBatch | batch[i];
        earlierSome = earlierSome | lowCredit[i];
      }
    }
    // ---- MBOX ----
    final pSrc = NocPacket.src(eject);
    final pDest = NocPacket.dest(eject);
    final mboxArrives = arrives(NocPacket.mbox);
    final mboxIn = mboxArrives & pDest.eq(Const(coreId, width: 8));
    final arrivedEntry =
        [NocPacket.channel(eject), NocPacket.payload(eject), pSrc].swizzle();
    const entryWidth = 4 + 32 + 8; // vector, value, source

    // The receive queue (mboxReceive) and the broadcast slot
    final rqWr = Logic(name: 'rqWr', width: 2);
    final rqRd = Logic(name: 'rqRd', width: 2);
    final rqCount = Logic(name: 'rqCount', width: 3);
    final bcValid = Logic(name: 'mboxBcValid');
    final bcEntry = Logic(name: 'mboxBcEntry', width: entryWidth);
    final Logic rqFull;
    final Logic rqEmpty;
    final Logic takeIn;
    final Logic toCore;
    final Logic fromQueue;
    final Logic bcIn;
    final Logic bcTake;
    // The answer queue: destination, and 1 for a NACK
    final aqWr = Logic(name: 'aqWr', width: 2);
    final aqRd = Logic(name: 'aqRd', width: 2);
    final aqCount = Logic(name: 'aqCount', width: 3);
    final aqFull = aqCount.eq(Const(answerQueueDepth, width: 3));
    final aqEmpty = aqCount.eq(0);
    final answer = mboxIn & ~aqFull; // with the answer queue full: none
    if (mboxReceive) {
      rqFull = rqCount.eq(Const(mboxQueueDepth, width: 3));
      rqEmpty = rqCount.eq(0);
      takeIn = answer & ~rqFull;
      final rxQueue = ParticleLutRam(
        clk: clk,
        wAddr: rqWr,
        wData: arrivedEntry,
        wEn: takeIn,
        rAddrA: rqRd,
        rAddrB: rqRd,
        depth: mboxQueueDepth,
        width: entryWidth,
        name: 'mbox_queue',
      );
      // A broadcast fills the slot if it is free, else it is dropped
      bcIn = mboxArrives & pDest.eq(toAll) & ~bcValid;
      // To the core, one at a time: the queue first, then the slot
      fromQueue = ~rqEmpty;
      toCore = mReady & (fromQueue | bcValid);
      bcTake = toCore & ~fromQueue;
      final head = mux(fromQueue, rxQueue.rDataA, bcEntry);
      mboxStrobe <= toCore;
      mboxVector <= head.getRange(40, 44);
      mboxData <= head.getRange(8, 40);
      mboxSource <= head.getRange(0, 8);
    } else {
      // Answered ACK and discarded
      rqFull = Const(0);
      rqEmpty = Const(1);
      takeIn = Const(0);
      fromQueue = Const(0);
      toCore = Const(0);
      bcIn = Const(0);
      bcTake = Const(0);
      mboxStrobe <= Const(0);
      mboxVector <= Const(0, width: 4);
      mboxData <= Const(0, width: w);
      mboxSource <= Const(0, width: 8);
    }
    final ansQueue = ParticleLutRam(
      clk: clk,
      wAddr: aqWr,
      wData: [pSrc, rqFull].swizzle(),
      wEn: answer,
      rAddrA: aqRd,
      rAddrB: aqRd,
      depth: answerQueueDepth,
      width: 9,
      name: 'answer_queue',
    );
    final answerPacket = NocPacket.make(
      type: NocPacket.ack,
      dest: ansQueue.rDataA.getRange(1, 9),
      channel: Const(0, width: 4),
      src: coreId,
      payload: Const(0, width: w),
    );
    // A NACK: the same packet with type 6
    final nackPacket = [
      Const(NocPacket.nack, width: 3),
      answerPacket.getRange(0, NocPacket.typeLsb),
    ].swizzle();
    final answerOut = mux(ansQueue.rDataA[0], nackPacket, answerPacket);

    // Sending (mboxSend): one MBOX in flight
    final outstanding = Logic(name: 'mboxOutstanding');
    final outBroadcast = Logic(name: 'mboxOutBroadcast');
    final outPacket = Logic(name: 'mboxOutPacket', width: pw);
    final retryTimer = Logic(name: 'mboxRetryTimer', width: 7);
    final retryDue = outstanding & retryTimer.eq(0);
    mboxSendWait <= outstanding;
    final sendDest = mux(mTargetValid, mTarget, defTarget);
    final sendToAll = sendDest.eq(toAll);
    // No target, or a core not on the ring: dropped
    final sendOk = (mTargetValid | defValid) & (sendToAll | exists(sendDest));
    final mboxPacket = NocPacket.make(
      type: NocPacket.mbox,
      dest: sendDest,
      channel: mVec,
      src: coreId,
      payload: mData,
    );
    // It doesn't go through the injection queue: it is sent from
    // mboxOutPacket the next cycle the ring has room (the timer starts at 0),
    // ahead of queued data, so the timeout counts from when it left. A
    // broadcast is done once it has left.
    final startSend = mboxSend ? mSend & ~outstanding & sendOk : Const(0);
    final ackIn = arrives(NocPacket.ack);
    final nackIn = arrives(NocPacket.nack);

    // What goes on the ring: an answer, then an MBOX due (new or again), then
    // the rest
    final answerFirst = ~aqEmpty;
    final retryNext = ~answerFirst & retryDue;
    final rest = ~answerFirst & ~retryDue;
    inject <= mux(answerFirst, answerOut, mux(retryDue, outPacket, chosen));
    injectValid <= answerFirst | retryDue | chosenValid;
    final dequeue = injectTaken & rest & takeQueue;
    for (var i = 0; i < inputCount; i++) {
      sendCredit[i] = sendCredit[i] & rest;
    }
    final answerSent = injectTaken & answerFirst;
    final retrySent = injectTaken & retryNext;

    // ---- CONFIG arriving ----
    final cfgIn = acceptConfig ? arrives(NocPacket.config) : Const(0);
    final inWord = NocPacket.payload(eject);
    final inKind = inWord.getRange(20, 24);
    final inCh = inWord.getRange(16, 18);
    final inCore = inWord.getRange(8, 16);
    final inValueCh = inWord.getRange(0, 2);
    Logic rxOf(Logic ch, int i) => [
          for (var c = 0; c < 4; c++)
            if (channels[c].rx == i && !channels[c].device) c
        ].map((c) => ch.eq(Const(c, width: 2))).fold<Logic>(
            Const(0), (a, b) => a | b);
    // Entry 0, a channel's route, and 1, its input's sender, name a core on
    // the ring; entry 2 is the default MBOX target
    final setRoute = [
      for (var j = 0; j < outputCount; j++)
        cfgIn & inKind.eq(0) & txOf(inCh, j) & exists(inCore),
    ];
    final setSender = [
      for (var i = 0; i < inputCount; i++)
        cfgIn & inKind.eq(1) & rxOf(inCh, i) & exists(inCore),
    ];
    final setTarget = cfgIn & inKind.eq(2);

    // ---- State ----
    Sequential(clk, reset: reset, resetValues: {
      for (final c in _credits) c: Const(bufferWords, width: 9),
      for (final o in _owed) o: Const(0, width: 9),
      qWr: Const(0, width: 3),
      qRd: Const(0, width: 3),
      qCount: Const(0, width: 4),
      flushPending: Const(0),
      flushPendingCh: Const(0, width: 2),
      rqWr: Const(0, width: 2),
      rqRd: Const(0, width: 2),
      rqCount: Const(0, width: 3),
      aqWr: Const(0, width: 2),
      aqRd: Const(0, width: 2),
      aqCount: Const(0, width: 3),
      outstanding: Const(0),
      outBroadcast: Const(0),
      outPacket: Const(0, width: pw),
      retryTimer: Const(0, width: 7),
      bcValid: Const(0),
      bcEntry: Const(0, width: entryWidth),
      configPending: Const(0),
      configPendingWord: Const(0, width: w),
      for (var j = 0; j < outputCount; j++) ...{
        routeCore[j]: Const(txRoutes[j].core, width: 8),
        routeCh[j]: Const(txRoutes[j].channel, width: 2),
      },
      for (var i = 0; i < inputCount; i++) ...{
        senderCore[i]: Const(rxSenders[i].core, width: 8),
        senderCh[i]: Const(rxSenders[i].channel, width: 2),
      },
      defTarget: Const(mboxDefaultTarget ?? 0, width: 8),
      defValid: Const(mboxDefaultTarget == null ? 0 : 1),
    }, [
      // The tables
      for (var j = 0; j < outputCount; j++)
        If(setRoute[j], then: [
          routeCore[j] < inCore,
          routeCh[j] < inValueCh,
        ]),
      for (var i = 0; i < inputCount; i++)
        If(setSender[i], then: [
          senderCore[i] < inCore,
          senderCh[i] < inValueCh,
        ]),
      If(setTarget, then: [defTarget < inCore, defValid < Const(1)]),
      // The broadcast slot
      If(bcIn, then: [bcValid < Const(1), bcEntry < arrivedEntry]),
      If(bcTake, then: [bcValid < Const(0)]),
      // A CONFIG that can't be queued yet waits (a store can't stall)
      If(configWaits, then: [
        configPending < Const(1),
        configPendingWord < cfgWord,
      ], orElse: [
        If(enqueueConfig, then: [configPending < Const(0)]),
      ]),
      // The MBOX receive queue and the answers
      If(takeIn, then: [rqWr < rqWr + 1]),
      If(toCore & fromQueue, then: [rqRd < rqRd + 1]),
      rqCount < rqCount + takeIn.zeroExtend(3) -
          (toCore & fromQueue).zeroExtend(3),
      If(answer, then: [aqWr < aqWr + 1]),
      If(answerSent, then: [aqRd < aqRd + 1]),
      aqCount < aqCount + answer.zeroExtend(3) - answerSent.zeroExtend(3),
      // The MBOX in flight: kept until an ACK; sent again 8 cycles after a
      // NACK, or 64 after no answer
      If(startSend, then: [
        outstanding < Const(1),
        outBroadcast < sendToAll,
        outPacket < mboxPacket,
        retryTimer < Const(0, width: 7),
      ], orElse: [
        If(ackIn, then: [
          outstanding < Const(0),
        ], orElse: [
          If(nackIn, then: [
            retryTimer < Const(mboxRetryCycles, width: 7),
          ], orElse: [
            If(retrySent, then: [
              If(outBroadcast, then: [
                outstanding < Const(0), // no answer comes
              ], orElse: [
                retryTimer < Const(mboxTimeoutCycles, width: 7),
              ]),
            ], orElse: [
              If(outstanding & ~retryTimer.eq(0), then: [
                retryTimer < retryTimer - 1,
              ]),
            ]),
          ]),
        ]),
      ]),
      for (var j = 0; j < outputCount; j++)
        If(setRoute[j], then: [
          // A new route starts with all its credits (a word queued in this
          // cycle goes to the old route)
          _credits[j] < Const(bufferWords, width: 9),
        ], orElse: [
          _credits[j] <
              _credits[j] -
                  enqueueData[j].zeroExtend(9) +
                  mux(arrives(NocPacket.credit) & forOutput(j),
                      NocPacket.payload(eject).getRange(0, 9),
                      Const(0, width: 9)),
        ]),
      for (var i = 0; i < inputCount; i++)
        If(flushIn[i], then: [
          // Every word in the buffer is discarded, and owed (a word read in
          // this cycle is one of them)
          _owed[i] <
              mux(injectTaken & sendCredit[i], Const(0, width: 9), _owed[i]) +
                  held(buffers[i]),
        ], orElse: [
          _owed[i] <
              mux(injectTaken & sendCredit[i], Const(0, width: 9), _owed[i]) +
                  readNow[i].zeroExtend(9),
        ]),
      If(enqueue, then: [qWr < qWr + 1]),
      If(dequeue, then: [qRd < qRd + 1]),
      qCount < qCount + enqueue.zeroExtend(4) - dequeue.zeroExtend(4),
      // A FLUSH that can't be queued yet waits (a store can't stall)
      If(flushWanted & flushHasRoute & qFull, then: [
        flushPending < Const(1),
        flushPendingCh < flushCh,
      ], orElse: [
        If(enqueueFlush, then: [flushPending < Const(0)]),
      ]),
    ]);

    // ---- The local device ----
    final devChannels = where((ch) => ch.device);
    devPushEn <= pushEn & anyOf(devChannels);
    devPushData <= pushData;
    devPopEn <= popEn & anyOf(devChannels);

    // ---- Status and data, in the FIFO subsystem's format ----
    Logic txStatus(int j) {
      final heldTx = Const(bufferWords, width: 9) - _credits[j];
      return [
        Const(0, width: 16),
        heldTx.slice(7, 0),
        Const(0, width: 6),
        _credits[j].eq(0) | blocked,
        heldTx.eq(0),
      ].swizzle();
    }

    Logic statusOf(NiChannel ch) {
      final st = ch.status;
      if (st.device) return dStatus;
      if (st.input != null) return buffers[st.input!].statusWord;
      if (st.output != null) return txStatus(st.output!);
      return Const(0, width: w);
    }

    Logic dataOf(NiChannel ch) {
      if (ch.device) return dData;
      if (ch.rx != null) return buffers[ch.rx!].popData;
      return Const(0, width: w);
    }

    final curStatus = Logic(name: 'curStatus', width: w);
    final curData = Logic(name: 'curData', width: w);
    Combinational([
      Case(chanSelect, [
        for (var c = 0; c < 4; c++)
          CaseItem(Const(c, width: 2), [
            curStatus < statusOf(channels[c]),
            curData < dataOf(channels[c]),
          ]),
      ]),
    ]);
    statusWord <= curStatus;
    popData <= curData;
  }
}
