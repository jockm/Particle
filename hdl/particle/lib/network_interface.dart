// =============================================================================
// File: hdl/particle/lib/network_interface.dart
// Architecture: Particle 32-bit RISC
// Description: A core's network interface: its receive buffers, the credits
//              of its output links, its channel table and a local device.
// =============================================================================
//
// The network interface sits on a core's FIFO port, where a FIFO subsystem
// would, so the core and the ISA don't change (see Documentation/
// noc_design.md). It holds:
//
//   * a receive buffer per input (a 256-word FIFO in block RAM). The word on
//     input i arrives with rxValid[i] and is written into buffer i; each word
//     the core reads is a credit, returned on rxTaken[i]. rxFlush[i] empties
//     the buffer.
//   * a credit count per output link, 256 at reset: the room left in the
//     receiver's buffer. The core's word goes out on txValid[j]/txData[j]
//     only with a credit (a FIFO.W without one is dropped, as a FIFO.W to a
//     full FIFO is); a credit comes back on txCredit[j], and txReset[j] sets
//     the count back to 256 (the receiver's buffer was flushed).
//   * a channel table: for each of the core's channels 0-3, the input it
//     reads, the output it writes, or the local device, and where FIFO.STAT
//     reads its status.
//
// Step 1 of the network (noc_design.md): the links are direct wires and a
// credit comes back in the cycle its word is read. A sender's credits are
// then always 256 minus what the receiver holds, so FIFO.STAT reports what a
// shared FIFO reports, cycle for cycle. Step 2 puts routers on the links.

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'fifo_subsystem.dart';

/// Where FIFO.STAT on a channel reads its status.
class NiStatus {
  /// The status of receive buffer [input].
  const NiStatus.rx(int this.input)
      : output = null,
        device = false;

  /// The status of output link [output]: its words in flight and buffered.
  const NiStatus.tx(int this.output)
      : input = null,
        device = false;

  /// The local device's status.
  const NiStatus.device()
      : input = null,
        output = null,
        device = true;

  /// Zero.
  const NiStatus.none()
      : input = null,
        output = null,
        device = false;

  final int? input;
  final int? output;
  final bool device;
}

/// One entry of the channel table.
class NiChannel {
  /// The receive buffer FIFO.R and FIFO.TRYR read on this channel, if any.
  final int? rx;

  /// The output link FIFO.W and FIFO.TRYW write on this channel, if any.
  final int? tx;

  /// Whether this channel is the local device (it reads, writes and reports
  /// the device instead).
  final bool device;

  /// Where FIFO.STAT reads this channel's status.
  final NiStatus status;

  const NiChannel({
    this.rx,
    this.tx,
    this.device = false,
    this.status = const NiStatus.none(),
  });

  /// A channel that does nothing and reports zero.
  static const unused = NiChannel();
}

class ParticleNetworkInterface extends Module {
  /// The channel table, for channels 0-3.
  final List<NiChannel> channels;

  /// The number of receive buffers and of output links.
  final int inputCount;
  final int outputCount;

  /// The words a receive buffer holds (and an output link's credits).
  static const bufferWords = 256;

  // Core side
  Logic get popData => output('popData');
  Logic get statusWord => output('statusWord');

  /// Output link [j]'s word and its valid strobe.
  Logic txValid(int j) => output('txValid$j');
  Logic txData(int j) => output('txData$j');

  /// Receive buffer [i]'s credit return: high when the core reads a word.
  Logic rxTaken(int i) => output('rxTaken$i');

  /// The local device's port.
  Logic get devPushEn => output('devPushEn');
  Logic get devPushData => output('devPushData');
  Logic get devPopEn => output('devPopEn');

  late final List<ParticleFifoSubsystem> _buffers;
  late final List<Logic> _credits;

  /// Output link [j]'s credits, for tests.
  int credits(int j) => _credits[j].value.toInt();

  ParticleNetworkInterface({
    required Logic clk,
    required Logic reset,
    required Logic chanSelect,
    required Logic pushData,
    required Logic pushEn,
    required Logic popEn,
    required this.channels,
    List<Logic> rxValid = const [],
    List<Logic> rxData = const [],
    List<Logic>? rxFlush,
    List<Logic> txCredit = const [],
    List<Logic>? txReset,
    Logic? devPopData,
    Logic? devStatus,
    List<String>? bufferNames,
    super.name = 'network_interface',
  })  : inputCount = rxValid.length,
        outputCount = txCredit.length {
    if (channels.length != 4) {
      throw ArgumentError('The channel table needs 4 entries');
    }
    if (rxData.length != inputCount ||
        (rxFlush != null && rxFlush.length != inputCount) ||
        (txReset != null && txReset.length != outputCount) ||
        (bufferNames != null && bufferNames.length != inputCount)) {
      throw ArgumentError('One entry per input and per output');
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
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    chanSelect = addInput('chanSelect', chanSelect, width: 2);
    pushData = addInput('pushData', pushData, width: w);
    pushEn = addInput('pushEn', pushEn);
    popEn = addInput('popEn', popEn);
    final inValid = [
      for (var i = 0; i < inputCount; i++) addInput('rxValid$i', rxValid[i]),
    ];
    final inData = [
      for (var i = 0; i < inputCount; i++)
        addInput('rxData$i', rxData[i], width: w),
    ];
    final inFlush = [
      for (var i = 0; i < inputCount; i++)
        addInput('rxFlush$i', rxFlush?[i] ?? Const(0)),
    ];
    final credIn = [
      for (var j = 0; j < outputCount; j++) addInput('txCredit$j', txCredit[j]),
    ];
    final credReset = [
      for (var j = 0; j < outputCount; j++)
        addInput('txReset$j', txReset?[j] ?? Const(0)),
    ];
    final dData = addInput('devPopData', devPopData ?? Const(0, width: w),
        width: w);
    final dStatus =
        addInput('devStatus', devStatus ?? Const(0, width: w), width: w);
    addOutput('popData', width: w);
    addOutput('statusWord', width: w);
    for (var j = 0; j < outputCount; j++) {
      addOutput('txValid$j');
      addOutput('txData$j', width: w);
    }
    for (var i = 0; i < inputCount; i++) {
      addOutput('rxTaken$i');
    }
    addOutput('devPushEn');
    addOutput('devPushData', width: w);
    addOutput('devPopEn');

    Logic on(int c) => chanSelect.eq(Const(c, width: 2));
    Logic anyOf(Iterable<int> cs) =>
        cs.map(on).fold<Logic>(Const(0), (a, b) => a | b);
    List<int> where(bool Function(NiChannel) f) =>
        [for (var c = 0; c < 4; c++) if (f(channels[c])) c];

    // Receive buffers: the core pops buffer i on the channels that read it
    _buffers = [
      for (var i = 0; i < inputCount; i++)
        ParticleFifoSubsystem(
          clk: clk,
          reset: reset | inFlush[i],
          chanSelect: Const(0, width: 2),
          pushData: inData[i],
          pushEn: inValid[i],
          popEn: popEn & anyOf(where((ch) => ch.rx == i && !ch.device)),
          channels: 1,
          name: bufferNames?[i] ?? 'rx_buffer_$i',
        ),
    ];
    for (var i = 0; i < inputCount; i++) {
      rxTaken(i) <=
          popEn &
              anyOf(where((ch) => ch.rx == i && !ch.device)) &
              ~_buffers[i].empty;
    }

    // Output links: a word goes out only with a credit
    _credits = [
      for (var j = 0; j < outputCount; j++) Logic(name: 'credits$j', width: 9),
    ];
    for (var j = 0; j < outputCount; j++) {
      final hasCredit = ~_credits[j].eq(0);
      final send = pushEn & anyOf(where((ch) => ch.tx == j && !ch.device)) &
          hasCredit;
      txValid(j) <= send;
      txData(j) <= pushData;
      Sequential(clk, reset: reset, resetValues: {
        _credits[j]: Const(bufferWords, width: 9),
      }, [
        If(credReset[j], then: [
          _credits[j] < Const(bufferWords, width: 9),
        ], orElse: [
          _credits[j] <
              _credits[j] -
                  send.zeroExtend(9) +
                  credIn[j].zeroExtend(9),
        ]),
      ]);
    }

    // The local device
    final devChannels = where((ch) => ch.device);
    devPushEn <= pushEn & anyOf(devChannels);
    devPushData <= pushData;
    devPopEn <= popEn & anyOf(devChannels);

    // Status words, in the FIFO subsystem's format
    Logic txStatus(int j) {
      final held = Const(bufferWords, width: 9) - _credits[j];
      return [
        Const(0, width: 16),
        held.slice(7, 0),
        Const(0, width: 6),
        _credits[j].eq(0),
        held.eq(0),
      ].swizzle();
    }

    Logic statusOf(NiChannel ch) {
      final st = ch.status;
      if (st.device) return dStatus;
      if (st.input != null) return _buffers[st.input!].statusWord;
      if (st.output != null) return txStatus(st.output!);
      return Const(0, width: w);
    }

    Logic dataOf(NiChannel ch) {
      if (ch.device) return dData;
      if (ch.rx != null) return _buffers[ch.rx!].popData;
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
