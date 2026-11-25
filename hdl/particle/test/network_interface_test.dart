// =============================================================================
// File: hdl/particle/test/network_interface_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================
//
// Two network interfaces joined by a direct link (step 1 of the network): A's
// channel 1 sends to B's channel 0. The sender's FIFO.STAT must report what a
// shared FIFO would: the words held, full after 256, and empty again once the
// receiver has read them all.

import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/network_interface.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('A link: credits, status, a full link, flush and a device', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final flush = Logic(name: 'flush');
    Logic l(String n, [int w = 1]) => Logic(name: n, width: w);
    final aChan = l('aChan', 2), aData = l('aData', ParticleWidths.word);
    final aPush = l('aPush'), aPop = l('aPop');
    final bChan = l('bChan', 2), bPop = l('bPop');
    final linkValid = l('linkValid'), linkData = l('linkData', 32);
    final linkCredit = l('linkCredit');
    final devData = Const(0xA5, width: 32), devStatus = Const(0x2, width: 32);

    final a = ParticleNetworkInterface(
      clk: clk,
      reset: reset,
      chanSelect: aChan,
      pushData: aData,
      pushEn: aPush,
      popEn: aPop,
      channels: const [
        NiChannel.unused,
        NiChannel(tx: 0, status: NiStatus.tx(0)),
        NiChannel.unused,
        NiChannel(device: true, status: NiStatus.device()),
      ],
      txCredit: [linkCredit],
      txReset: [flush],
      devPopData: devData,
      devStatus: devStatus,
      name: 'ni_a',
    );
    final b = ParticleNetworkInterface(
      clk: clk,
      reset: reset,
      chanSelect: bChan,
      pushData: Const(0, width: 32),
      pushEn: Const(0),
      popEn: bPop,
      channels: const [
        NiChannel(rx: 0, status: NiStatus.rx(0)),
        NiChannel.unused,
        NiChannel.unused,
        NiChannel.unused,
      ],
      rxValid: [linkValid],
      rxData: [linkData],
      rxFlush: [flush],
      name: 'ni_b',
    );
    linkValid <= a.txValid(0);
    linkData <= a.txData(0);
    linkCredit <= b.rxTaken(0);
    await a.build();
    await b.build();

    unawaited(Simulator.run());
    for (final x in [aPush, aPop, bPop, flush]) {
      x.put(0);
    }
    aChan.put(1);
    bChan.put(0);
    aData.put(0);
    reset.put(1);
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.put(0);
    await clk.nextPosedge;

    int count(Logic status) => (status.value.toInt() >> 8) & 0xFF;
    bool full(Logic status) => (status.value.toInt() & 2) != 0;
    bool empty(Logic status) => (status.value.toInt() & 1) != 0;

    expect(empty(a.statusWord), isTrue);
    expect(a.credits(0), equals(256));

    // Three words: A's status counts them, B holds them
    for (var i = 1; i <= 3; i++) {
      aData.put(0x100 + i);
      aPush.put(1);
      await clk.nextPosedge;
    }
    aPush.put(0);
    await clk.nextNegedge;
    expect(count(a.statusWord), equals(3));
    expect(count(b.statusWord), equals(3));

    // B reads one: A gets the credit back in the same cycle
    expect(b.popData.value.toInt(), equals(0x101));
    bPop.put(1);
    await clk.nextPosedge;
    bPop.put(0);
    await clk.nextNegedge;
    expect(count(a.statusWord), equals(2));
    expect(b.popData.value.toInt(), equals(0x102));

    // Fill the link: after 256 words A reports full and a 257th is dropped
    for (var i = 0; i < 254; i++) {
      aData.put(i);
      aPush.put(1);
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
    expect(full(a.statusWord), isTrue);
    expect(a.credits(0), equals(0));
    expect(a.txValid(0).value.toInt(), equals(0));
    await clk.nextPosedge;
    aPush.put(0);
    await clk.nextNegedge;
    expect(full(b.statusWord), isTrue);

    // A flush empties B and gives A its credits back
    flush.put(1);
    await clk.nextPosedge;
    flush.put(0);
    await clk.nextNegedge;
    expect(empty(b.statusWord), isTrue);
    expect(empty(a.statusWord), isTrue);
    expect(a.credits(0), equals(256));

    // The device channel: its data and status, and its strobes
    aChan.put(3);
    aPush.put(1);
    await clk.nextNegedge;
    expect(a.statusWord.value.toInt(), equals(0x2));
    expect(a.popData.value.toInt(), equals(0xA5));
    expect(a.devPushEn.value.toInt(), equals(1));
    expect(a.txValid(0).value.toInt(), equals(0));
    aPush.put(0);
  });
}
