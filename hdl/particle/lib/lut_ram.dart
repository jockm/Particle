// =============================================================================
// File: hdl/particle/lib/lut_ram.dart
// Architecture: Particle 32-bit RISC
// Description: Small RAM with one synchronous write port and two asynchronous
//              read ports, for FPGA LUT RAM (distributed RAM).
// =============================================================================
//
// A write presented before a rising edge of clk is made at that edge. The read
// ports are combinational: rDataA and rDataB follow rAddrA and rAddrB, and
// show a write from the edge it is made. There is no reset; the contents start
// at zero, as LUT RAM does when the FPGA is configured.
//
// The generated SystemVerilog is a plain memory array with asynchronous reads,
// which Yosys maps to ECP5 TRELLIS_DPR16X4 cells (one copy per read port).
// Simulation uses ROHD registers with the same behaviour.

import 'package:rohd/rohd.dart';

class ParticleLutRam extends Module with SystemVerilog {
  Logic get clk => input('clk');
  Logic get wAddr => input('wAddr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');
  Logic get rAddrA => input('rAddrA');
  Logic get rAddrB => input('rAddrB');
  Logic get rDataA => output('rDataA');
  Logic get rDataB => output('rDataB');

  /// Number of words (a power of two).
  final int depth;

  /// Bits per word.
  final int width;

  late final List<Logic> _words;

  ParticleLutRam({
    required Logic clk,
    required Logic wAddr,
    required Logic wData,
    required Logic wEn,
    required Logic rAddrA,
    required Logic rAddrB,
    this.depth = 16,
    required this.width,
    super.name = 'particle_lut_ram',
  }) {
    final idxBits = (depth - 1).bitLength;
    if (depth != 1 << idxBits) {
      throw ArgumentError('depth must be a power of two: $depth');
    }
    for (final a in [wAddr, rAddrA, rAddrB]) {
      if (a.width != idxBits) {
        throw ArgumentError(
          'For $depth words the addresses must be $idxBits '
          'bits (got ${a.width})',
        );
      }
    }
    addInput('clk', clk);
    addInput('wAddr', wAddr, width: idxBits);
    addInput('wData', wData, width: width);
    addInput('wEn', wEn);
    addInput('rAddrA', rAddrA, width: idxBits);
    addInput('rAddrB', rAddrB, width: idxBits);
    addOutput('rDataA', width: width);
    addOutput('rDataB', width: width);
    _buildModel();
  }

  /// The word at [index], for tests and debugging (-1 if not valid).
  int word(int index) {
    final v = _words[index].value;
    return v.isValid ? v.toInt() : -1;
  }

  void _buildModel() {
    final idxBits = wAddr.width;
    _words = List.generate(depth, (i) => Logic(name: 'word$i', width: width));
    Sequential(clk, [
      for (var i = 0; i < depth; i++)
        If(wEn & wAddr.eq(Const(i, width: idxBits)), then: [_words[i] < wData]),
    ]);
    // The contents at configuration
    for (final w in _words) {
      w.put(0);
    }
    Logic read(Logic addr) =>
        [for (var i = 0; i < depth; i++) _words[i]].reduceIndexed(addr, width);
    rDataA <= read(rAddrA);
    rDataB <= read(rAddrB);
  }

  @override
  String instantiationVerilog(
    String instanceType,
    String instanceName,
    Map<String, String> ports,
  ) {
    final p = instanceName;
    final aW = wAddr.width;
    return '''
// ---- $p: ParticleLutRam, $depth x $width, asynchronous reads ----
logic [${width - 1}:0] ${p}_mem [0:${depth - 1}];
initial for (int ${p}_i = 0; ${p}_i < $depth; ${p}_i++) ${p}_mem[${p}_i] = '0;
wire ${p}_clk = ${ports['clk']};
wire [${aW - 1}:0] ${p}_wAddr = ${ports['wAddr']};
wire [${width - 1}:0] ${p}_wData = ${ports['wData']};
wire ${p}_wEn = ${ports['wEn']};
always_ff @(posedge ${p}_clk) begin
  if (${p}_wEn) ${p}_mem[${p}_wAddr] <= ${p}_wData;
end
assign ${ports['rDataA']} = ${p}_mem[${ports['rAddrA']}];
assign ${ports['rDataB']} = ${p}_mem[${ports['rAddrB']}];
// ---- end $p ----''';
  }
}

extension on List<Logic> {
  /// The element selected by [index], as a multiplexer tree.
  Logic reduceIndexed(Logic index, int width) {
    var level = this;
    for (var bit = 0; level.length > 1; bit++) {
      final sel = index[bit];
      level = [
        for (var i = 0; i < level.length; i += 2)
          mux(sel, level[i + 1], level[i]),
      ];
    }
    return level.first;
  }
}
