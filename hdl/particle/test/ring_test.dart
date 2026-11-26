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
}
