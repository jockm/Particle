// =============================================================================
// File: hdl/particle/lib/ring_router.dart
// Architecture: Particle 32-bit RISC
// Description: A router of the one-way ring network on chip, and the packet
//              format (Documentation/noc_design.md, step 2).
// =============================================================================
//
// Each router has one input from the previous router, one output to the next
// (a register, so a packet moves one router a cycle) and a port to its core's
// network interface:
//
//   * A packet for this router's core (its destination is [coreId]) leaves
//     the ring: eject/ejectValid, which the network interface always takes.
//   * Any other packet goes on to the next router.
//   * The network interface's packet (inject/injectValid) goes on only when
//     no packet is passing: injectTaken says when.
//
// Nothing ever waits inside the ring: every packet has room at its
// destination (the credits), so routers need no buffers and the ring can't
// deadlock.

import 'package:rohd/rohd.dart';
import 'keep.dart';

/// The fields of a packet: one flit of [NocPacket.width] bits.
class NocPacket {
  static const width = 55;

  // Bit positions
  static const payloadLsb = 0; // 32 bits: the word, or a credit count
  static const srcLsb = 32; // 8 bits: the sending core
  static const channelLsb = 40; // 4 bits: the destination's channel
  static const destLsb = 44; // 8 bits: the destination core
  static const typeLsb = 52; // 3 bits

  // Types
  static const data = 0;
  static const credit = 1;
  static const flush = 2;
  // 3 MBOX and 4 CONFIG come in step 3

  /// A packet from its fields.
  static Logic make({
    required int type,
    required Logic dest,
    required Logic channel,
    required int src,
    required Logic payload,
  }) =>
      [
        Const(type, width: 3),
        dest.zeroExtend(8),
        channel.zeroExtend(4),
        Const(src, width: 8),
        payload.zeroExtend(32),
      ].swizzle();

  static Logic type(Logic p) => p.getRange(typeLsb, typeLsb + 3);
  static Logic dest(Logic p) => p.getRange(destLsb, destLsb + 8);
  static Logic channel(Logic p) => p.getRange(channelLsb, channelLsb + 4);
  static Logic src(Logic p) => p.getRange(srcLsb, srcLsb + 8);
  static Logic payload(Logic p) => p.getRange(payloadLsb, payloadLsb + 32);
}

class ParticleRingRouter extends Module {
  /// The core this router serves: packets with this destination leave here.
  final int coreId;

  Logic get ringOut => output('ringOut');
  Logic get ringOutValid => output('ringOutValid');
  Logic get eject => output('eject');
  Logic get ejectValid => output('ejectValid');
  Logic get injectTaken => output('injectTaken');

  ParticleRingRouter({
    required Logic clk,
    required Logic reset,
    required Logic ringIn,
    required Logic ringInValid,
    required Logic inject,
    required Logic injectValid,
    required this.coreId,
    super.name = 'ring_router',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ringIn = addInput('ringIn', ringIn, width: NocPacket.width);
    ringInValid = addInput('ringInValid', ringInValid);
    inject = addInput('inject', inject, width: NocPacket.width);
    injectValid = addInput('injectValid', injectValid);
    addOutput('ringOut', width: NocPacket.width);
    addOutput('ringOutValid');
    addOutput('eject', width: NocPacket.width);
    addOutput('ejectValid');
    addOutput('injectTaken');

    final mine = ringInValid &
        NocPacket.dest(ringIn).eq(Const(coreId, width: 8));
    // One net for the 55-bit multiplexer's select (see keep.dart)
    final passing = ParticleKeep(ringInValid & ~mine, name: 'passing_keep').y;
    final take = injectValid & ~passing;
    eject <= ringIn;
    ejectValid <= mine;
    injectTaken <= take;

    final outReg = Logic(name: 'outReg', width: NocPacket.width);
    final outValidReg = Logic(name: 'outValidReg');
    Sequential(clk, reset: reset, resetValues: {
      outReg: Const(0, width: NocPacket.width),
      outValidReg: Const(0),
    }, [
      outValidReg < passing | take,
      outReg < mux(passing, ringIn, inject),
    ]);
    ringOut <= outReg;
    ringOutValid <= outValidReg;
  }
}
