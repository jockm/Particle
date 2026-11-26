// =============================================================================
// File: hdl/particle/test/ring_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================
//
// The one-way ring (step 2 of the network on chip): four routers, 0 -> 1 ->
// 2 -> 3 -> 0. Core 0's network interface (A) sends on its channel 1 to core
// 1's channel 0 (B). Router 2 has no interface; router 3 can jam the ring with
// packets for core 1 that pass router 0, so A's injection queue fills.

import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/network_interface.dart';
import '../lib/ring_interface.dart';
import '../lib/ring_router.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('Ring: delivery, credits, a full link, FLUSH and a full queue',
      () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    Logic l(String n, [int w = 1]) => Logic(name: n, width: w);
    const pw = NocPacket.width;

    // Ring links: out[i] leaves router i
    final out = [for (var i = 0; i < 4; i++) l('out$i', pw)];
    final outV = [for (var i = 0; i < 4; i++) l('outV$i')];
    final inject = [for (var i = 0; i < 4; i++) l('inject$i', pw)];
    final injectV = [for (var i = 0; i < 4; i++) l('injectV$i')];
    final routers = [
      for (var i = 0; i < 4; i++)
        ParticleRingRouter(
          clk: clk,
          reset: reset,
          ringIn: out[(i + 3) % 4],
          ringInValid: outV[(i + 3) % 4],
          inject: inject[i],
          injectValid: injectV[i],
          coreId: i,
          name: 'router$i',
        ),
    ];
    for (var i = 0; i < 4; i++) {
      out[i] <= routers[i].ringOut;
      outV[i] <= routers[i].ringOutValid;
    }

    final aChan = l('aChan', 2), aData = l('aData', ParticleWidths.word);
    final aPush = l('aPush'), flushStrobe = l('flushStrobe');
    final bPop = l('bPop');
    final a = ParticleRingInterface(
      clk: clk,
      reset: reset,
      chanSelect: aChan,
      pushData: aData,
      pushEn: aPush,
      popEn: Const(0),
      channels: const [
        NiChannel.unused,
        NiChannel(tx: 0, status: NiStatus.tx(0)),
        NiChannel.unused,
        NiChannel.unused,
      ],
      coreId: 0,
      txRoutes: const [(core: 1, channel: 0)],
      eject: routers[0].eject,
      ejectValid: routers[0].ejectValid,
      injectTaken: routers[0].injectTaken,
      flushStrobe: flushStrobe,
      flushChannel: Const(1, width: 2),
      name: 'ni_a',
    );
    final b = ParticleRingInterface(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: Const(0, width: 32),
      pushEn: Const(0),
      popEn: bPop,
      channels: const [
        NiChannel(rx: 0, status: NiStatus.rx(0)),
        NiChannel.unused,
        NiChannel.unused,
        NiChannel.unused,
      ],
      coreId: 1,
      rxSenders: const [(core: 0, channel: 1)],
      eject: routers[1].eject,
      ejectValid: routers[1].ejectValid,
      injectTaken: routers[1].injectTaken,
      name: 'ni_b',
    );
    inject[0] <= a.inject;
    injectV[0] <= a.injectValid;
    inject[1] <= b.inject;
    injectV[1] <= b.injectValid;
    // Router 2: nothing to send. Router 3: the jammer, a CREDIT for core 1's
    // channel 15 (which names nothing, so it changes nothing)
    final jam = l('jam');
    inject[2] <= Const(0, width: pw);
    injectV[2] <= Const(0);
    inject[3] <= NocPacket.make(
        type: NocPacket.credit,
        dest: Const(1, width: 8),
        channel: Const(15, width: 4),
        src: 3,
        payload: Const(0, width: 32));
    injectV[3] <= jam;

    for (final r in routers) {
      await r.build();
    }
    await a.build();
    await b.build();
    unawaited(Simulator.run());

    for (final x in [aPush, bPop, flushStrobe, jam]) {
      x.put(0);
    }
    aChan.put(1);
    aData.put(0);
    reset.put(1);
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.put(0);
    await clk.nextPosedge;

    int count(Logic st) => (st.value.toInt() >> 8) & 0xFF;
    bool full(Logic st) => (st.value.toInt() & 2) != 0;
    bool empty(Logic st) => (st.value.toInt() & 1) != 0;
    Future<void> cycles(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    // Three words arrive at B; A counts them until their credits are back
    for (var i = 1; i <= 3; i++) {
      aData.put(0x100 + i);
      aPush.put(1);
      await clk.nextPosedge;
    }
    aPush.put(0);
    await cycles(6);
    await clk.nextNegedge;
    expect(count(b.statusWord), equals(3));
    expect(count(a.statusWord), equals(3));
    expect(b.popData.value.toInt(), equals(0x101));

    // B reads all three: their credits go back round the ring
    bPop.put(1);
    await cycles(3);
    bPop.put(0);
    await cycles(8);
    await clk.nextNegedge;
    expect(empty(b.statusWord), isTrue);
    expect(a.credits(0), equals(256));
    expect(empty(a.statusWord), isTrue);

    // Fill the link: 300 words, of which 256 fit; A then reports full
    for (var i = 0; i < 300; i++) {
      aData.put(i);
      aPush.put(1);
      await clk.nextPosedge;
    }
    aPush.put(0);
    await cycles(12);
    await clk.nextNegedge;
    expect(a.credits(0), equals(0));
    expect(full(a.statusWord), isTrue);
    expect(full(b.statusWord), isTrue);
    expect(b.popData.value.toInt(), equals(0), reason: 'the first of them');

    // FLUSH: B empties its buffer and gives A all 256 credits back
    flushStrobe.put(1);
    await clk.nextPosedge;
    flushStrobe.put(0);
    await cycles(12);
    await clk.nextNegedge;
    expect(empty(b.statusWord), isTrue);
    expect(b.owed(0), equals(0));
    expect(a.credits(0), equals(256));

    // Jam the ring past router 0: A's queue fills after 8 words, and then a
    // FIFO.W waits (pushWait) instead of being dropped
    jam.put(1);
    await cycles(4);
    for (var i = 0; i < 8; i++) {
      aData.put(0x200 + i);
      aPush.put(1);
      await clk.nextPosedge;
    }
    aData.put(0x208);
    await clk.nextNegedge;
    expect(a.pushWait.value.toInt(), equals(1));
    expect(full(a.statusWord), isTrue, reason: 'FIFO.TRYW would return 0');
    expect(a.credits(0), equals(256 - 8));
    // Unjam: the queue drains, the ninth word goes in, all nine arrive
    jam.put(0);
    await clk.nextPosedge;
    while (a.pushWait.value.toInt() == 1) {
      await clk.nextPosedge;
    }
    await clk.nextPosedge;
    aPush.put(0);
    await cycles(16);
    await clk.nextNegedge;
    expect(count(b.statusWord), equals(9));
    expect(b.popData.value.toInt(), equals(0x200));
  });

  test('Ring: MBOX, ACK, NACK and retry, the default target', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    Logic l(String n, [int w = 1]) => Logic(name: n, width: w);
    const pw = NocPacket.width;

    final out = [for (var i = 0; i < 4; i++) l('out$i', pw)];
    final outV = [for (var i = 0; i < 4; i++) l('outV$i')];
    final inject = [for (var i = 0; i < 4; i++) l('inject$i', pw)];
    final injectV = [for (var i = 0; i < 4; i++) l('injectV$i')];
    final routers = [
      for (var i = 0; i < 4; i++)
        ParticleRingRouter(
          clk: clk,
          reset: reset,
          ringIn: out[(i + 3) % 4],
          ringInValid: outV[(i + 3) % 4],
          inject: inject[i],
          injectValid: injectV[i],
          coreId: i,
          name: 'router$i',
        ),
    ];
    for (var i = 0; i < 4; i++) {
      out[i] <= routers[i].ringOut;
      outV[i] <= routers[i].ringOutValid;
    }

    // A (core 0) sends; B (core 1) receives
    final send = l('send'), vec = l('vec', 4), data = l('data', 32);
    final target = l('target', 8), targetValid = l('targetValid');
    final bReady = l('bReady');
    ParticleRingInterface ni(int id, {required bool sender}) =>
        ParticleRingInterface(
          clk: clk,
          reset: reset,
          chanSelect: Const(0, width: 2),
          pushData: Const(0, width: 32),
          pushEn: Const(0),
          popEn: Const(0),
          channels: const [
            NiChannel.unused,
            NiChannel.unused,
            NiChannel.unused,
            NiChannel.unused,
          ],
          coreId: id,
          eject: routers[id].eject,
          ejectValid: routers[id].ejectValid,
          injectTaken: routers[id].injectTaken,
          mboxSendStrobe: sender ? send : null,
          mboxSendVector: sender ? vec : null,
          mboxSendData: sender ? data : null,
          mboxSendTarget: sender ? target : null,
          mboxSendTargetValid: sender ? targetValid : null,
          mboxCoreReady: sender ? null : bReady,
          mboxDefaultTarget: sender ? 1 : null,
          name: 'ni_$id',
        );
    final a = ni(0, sender: true);
    final b = ni(1, sender: false);
    inject[0] <= a.inject;
    injectV[0] <= a.injectValid;
    inject[1] <= b.inject;
    injectV[1] <= b.injectValid;
    for (final i in [2, 3]) {
      inject[i] <= Const(0, width: pw);
      injectV[i] <= Const(0);
    }
    for (final r in routers) {
      await r.build();
    }
    await a.build();
    await b.build();
    unawaited(Simulator.run());

    for (final x in [send, targetValid, bReady]) {
      x.put(0);
    }
    vec.put(0);
    data.put(0);
    target.put(0);
    reset.put(1);
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.put(0);
    await clk.nextPosedge;

    Future<void> cycles(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    int wait() => a.mboxSendWait.value.toInt();

    // MBOX R, Rl to core 1: sent, ACKed; A's next MBOX may go
    Future<void> mbox(int v, int value, {int? to}) async {
      await clk.nextNegedge;
      vec.put(v);
      data.put(value);
      targetValid.put(to == null ? 0 : 1);
      target.put(to ?? 0);
      send.put(1);
      await clk.nextPosedge;
      send.put(0);
    }

    Future<void> waitAnswered([int limit = 200]) async {
      for (var i = 0; i < limit && wait() == 1; i++) {
        await clk.nextPosedge;
      }
      await clk.nextNegedge;
      expect(wait(), equals(0), reason: 'answered with an ACK');
    }

    await mbox(3, 0x1234, to: 1);
    await clk.nextNegedge;
    expect(wait(), equals(1), reason: 'in flight');
    await waitAnswered();
    expect(b.mboxStrobe.value.toInt(), equals(0), reason: 'B is not ready');

    // B takes it: vector, value and source (the strobe follows ready at
    // once; the queue pops on the clock)
    bReady.put(1);
    expect(b.mboxStrobe.value.toInt(), equals(1));
    expect(b.mboxVector.value.toInt(), equals(3));
    expect(b.mboxData.value.toInt(), equals(0x1234));
    expect(b.mboxSource.value.toInt(), equals(0));
    await clk.nextPosedge;
    bReady.put(0);
    await clk.nextNegedge;
    expect(b.mboxStrobe.value.toInt(), equals(0), reason: 'one at a time');

    // Four fill B's queue (the default target, MBOX R, Imm4)
    for (var i = 0; i < 4; i++) {
      await mbox(i, 0x100 + i);
      await waitAnswered();
    }
    // The fifth is NACKed and sent again every 8 cycles: still waiting
    await mbox(9, 0x999);
    await cycles(60);
    await clk.nextNegedge;
    expect(wait(), equals(1), reason: 'NACKed, sent again');
    // B takes one: the fifth gets in on a retry
    await clk.nextNegedge;
    bReady.put(1);
    expect(b.mboxData.value.toInt(), equals(0x100));
    await clk.nextPosedge;
    bReady.put(0);
    await waitAnswered(40);
    // The queue now holds the rest, in order, then the fifth
    final got = <(int, int)>[];
    bReady.put(1);
    for (var i = 0; i < 4; i++) {
      expect(b.mboxStrobe.value.toInt(), equals(1));
      got.add((b.mboxVector.value.toInt(), b.mboxData.value.toInt()));
      await clk.nextPosedge;
      await clk.nextNegedge;
    }
    bReady.put(0);
    expect(got, equals([(1, 0x101), (2, 0x102), (3, 0x103), (9, 0x999)]));
    expect(b.mboxStrobe.value.toInt(), equals(0));

    // A broadcast: no answer, done once it has left; B takes it from its
    // broadcast slot
    await mbox(5, 0x55, to: 0xFF);
    for (var i = 0; i < 4 && wait() == 1; i++) {
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
    expect(wait(), equals(0), reason: 'a broadcast needs no answer');
    await cycles(8);
    await clk.nextNegedge;
    bReady.put(1);
    expect(b.mboxStrobe.value.toInt(), equals(1));
    expect(b.mboxVector.value.toInt(), equals(5));
    expect(b.mboxData.value.toInt(), equals(0x55));
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(b.mboxStrobe.value.toInt(), equals(0));
    bReady.put(0);
  });

  test('Ring: broadcast, CONFIG, cores not on the ring', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    Logic l(String n, [int w = 1]) => Logic(name: n, width: w);
    const pw = NocPacket.width;
    const ring = [0, 1, 2, 3, 4];

    final out = [for (var i = 0; i < 5; i++) l('out$i', pw)];
    final outV = [for (var i = 0; i < 5; i++) l('outV$i')];
    final inject = [for (var i = 0; i < 5; i++) l('inject$i', pw)];
    final injectV = [for (var i = 0; i < 5; i++) l('injectV$i')];
    final routers = [
      for (var i = 0; i < 5; i++)
        ParticleRingRouter(
          clk: clk,
          reset: reset,
          ringIn: out[(i + 4) % 5],
          ringInValid: outV[(i + 4) % 5],
          inject: inject[i],
          injectValid: injectV[i],
          coreId: i,
          name: 'router$i',
        ),
    ];
    for (var i = 0; i < 5; i++) {
      out[i] <= routers[i].ringOut;
      outV[i] <= routers[i].ringOutValid;
    }

    // C (core 0): sends CONFIG and MBOX. A (core 1): sends on its channel 1,
    // first to B (core 2), and MBOX with no default target. B and D (core 3):
    // receive A's words on channel 0 and take MBOX. Router 4 has no
    // interface: a test drives it.
    final ready = [for (var i = 0; i < 4; i++) l('ready$i')];
    final send = [for (var i = 0; i < 2; i++) l('send$i')];
    final vec = [for (var i = 0; i < 2; i++) l('vec$i', 4)];
    final data = [for (var i = 0; i < 2; i++) l('data$i', 32)];
    final target = [for (var i = 0; i < 2; i++) l('target$i', 8)];
    final targetValid = [for (var i = 0; i < 2; i++) l('targetValid$i')];
    final cfgStrobe = l('cfgStrobe'), cfgWord = l('cfgWord', 32);
    final aPush = l('aPush'), aData = l('aData', 32);
    final pop = [l('popB'), l('popD')];
    const unused = NiChannel.unused;
    ParticleRingInterface ni(int id) => ParticleRingInterface(
          clk: clk,
          reset: reset,
          chanSelect: Const(id == 1 ? 1 : 0, width: 2),
          pushData: id == 1 ? aData : Const(0, width: 32),
          pushEn: id == 1 ? aPush : Const(0),
          popEn: id == 2 ? pop[0] : (id == 3 ? pop[1] : Const(0)),
          channels: switch (id) {
            1 => const [unused, NiChannel(tx: 0, status: NiStatus.tx(0)),
                unused, unused],
            2 || 3 => const [NiChannel(rx: 0, status: NiStatus.rx(0)),
                unused, unused, unused],
            _ => const [unused, unused, unused, unused],
          },
          coreId: id,
          txRoutes: id == 1 ? const [(core: 2, channel: 0)] : const [],
          rxSenders:
              id >= 2 ? const [(core: 1, channel: 1)] : const [],
          eject: routers[id].eject,
          ejectValid: routers[id].ejectValid,
          injectTaken: routers[id].injectTaken,
          mboxSendStrobe: id < 2 ? send[id] : null,
          mboxSendVector: id < 2 ? vec[id] : null,
          mboxSendData: id < 2 ? data[id] : null,
          mboxSendTarget: id < 2 ? target[id] : null,
          mboxSendTargetValid: id < 2 ? targetValid[id] : null,
          mboxCoreReady: ready[id],
          ringCores: ring,
          configSender: id == 0,
          configStrobe: id == 0 ? cfgStrobe : null,
          configWord: id == 0 ? cfgWord : null,
          name: 'ni_$id',
        );
    final nis = [for (var i = 0; i < 4; i++) ni(i)];
    for (var i = 0; i < 4; i++) {
      inject[i] <= nis[i].inject;
      injectV[i] <= nis[i].injectValid;
    }
    final raw = l('raw', pw), rawV = l('rawV');
    inject[4] <= raw;
    injectV[4] <= rawV;
    for (final r in routers) {
      await r.build();
    }
    for (final n in nis) {
      await n.build();
    }
    unawaited(Simulator.run());

    for (final x in [...ready, ...send, ...targetValid, cfgStrobe, aPush,
        ...pop, rawV]) {
      x.put(0);
    }
    for (final x in [...vec, ...data, ...target, cfgWord, aData, raw]) {
      x.put(0);
    }
    reset.put(1);
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.put(0);
    await clk.nextPosedge;

    Future<void> cycles(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    Future<void> mbox(int from, int v, int value, {int? to}) async {
      await clk.nextNegedge;
      vec[from].put(v);
      data[from].put(value);
      targetValid[from].put(to == null ? 0 : 1);
      target[from].put(to ?? 0);
      send[from].put(1);
      await clk.nextPosedge;
      send[from].put(0);
    }

    Future<void> config(int word) async {
      await clk.nextNegedge;
      cfgWord.put(word);
      cfgStrobe.put(1);
      await clk.nextPosedge;
      cfgStrobe.put(0);
    }

    int wait(int i) => nis[i].mboxSendWait.value.toInt();
    // What core i takes now (ready for one cycle), or null
    Future<(int, int, int)?> take(int i) async {
      await clk.nextNegedge;
      ready[i].put(1);
      final n = nis[i];
      final got = n.mboxStrobe.value.toInt() == 1
          ? (
              n.mboxVector.value.toInt(),
              n.mboxData.value.toInt(),
              n.mboxSource.value.toInt()
            )
          : null;
      await clk.nextPosedge;
      ready[i].put(0);
      return got;
    }

    int count(Logic st) => (st.value.toInt() >> 8) & 0xFF;

    // A broadcast from C reaches A, B and D, from their broadcast slots, and
    // not C. A second one, while the slots are full, is dropped.
    await mbox(0, 4, 0xB0, to: 0xFF);
    await cycles(10);
    await mbox(0, 5, 0xB1, to: 0xFF);
    await cycles(10);
    for (final i in [1, 2, 3]) {
      expect(await take(i), equals((4, 0xB0, 0)), reason: 'core $i');
      expect(await take(i), isNull, reason: 'core $i: the second dropped');
    }
    expect(await take(0), isNull, reason: 'not its sender');

    // A's word goes to B; CONFIG gives A's channel 1 a new route, to D's
    // channel 0, with all its credits again
    await clk.nextNegedge;
    aData.put(0x11);
    aPush.put(1);
    await clk.nextPosedge;
    aPush.put(0);
    await cycles(8);
    await clk.nextNegedge;
    expect(count(nis[2].statusWord), equals(1));
    expect(nis[1].credits(0), equals(255));
    await config(0x01010300); // core 1: entry 0, channel 1 -> core 3, ch 0
    await cycles(10);
    await clk.nextNegedge;
    expect(nis[1].credits(0), equals(256), reason: 'a new route');
    aData.put(0x22);
    aPush.put(1);
    await clk.nextPosedge;
    aPush.put(0);
    await cycles(8);
    await clk.nextNegedge;
    expect(count(nis[3].statusWord), equals(1));
    expect(nis[3].popData.value.toInt(), equals(0x22));
    expect(count(nis[2].statusWord), equals(1), reason: 'B: still one');

    // A has no default target: MBOX R, Imm4 is dropped. A broadcast CONFIG
    // gives every core B as its default target; then it goes to B's queue.
    await mbox(1, 6, 0x66);
    await clk.nextNegedge;
    expect(wait(1), equals(0), reason: 'dropped: no target');
    await config(0xFF200200); // every core: entry 2 -> core 2
    await cycles(10);
    await mbox(1, 6, 0x66);
    await cycles(20);
    await clk.nextNegedge;
    expect(wait(1), equals(0), reason: 'ACKed');
    expect(await take(2), equals((6, 0x66, 1)));

    // Cores not on the ring: MBOX and CONFIG to core 9 are dropped
    await mbox(1, 7, 0x77, to: 9);
    await clk.nextNegedge;
    expect(wait(1), equals(0));
    await config(0x09010300);
    await cycles(10);

    // A packet back at its sender's router leaves the ring there
    await clk.nextNegedge;
    raw.put(NocPacket.make(
            type: NocPacket.data,
            dest: Const(9, width: 8),
            channel: Const(0, width: 4),
            src: 4,
            payload: Const(0, width: 32))
        .value);
    rawV.put(1);
    await clk.nextPosedge;
    rawV.put(0);
    await cycles(7);
    await clk.nextNegedge;
    for (var i = 0; i < 5; i++) {
      expect(outV[i].value.toInt(), equals(0), reason: 'link $i is empty');
    }
  });
}
