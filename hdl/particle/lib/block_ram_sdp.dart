// =============================================================================
// File: hdl/particle/lib/block_ram_sdp.dart
// Architecture: Particle 32-bit RISC
// Description: Simple dual-port block RAM: one write port, one read port.
// =============================================================================
//
// Both ports are synchronous, like FPGA block RAM: the addresses (and write
// data) present before a rising edge of clk are taken at that edge, and the
// read data appears after it, for the whole of the next cycle. A read of the
// word being written at the same edge returns the old contents in simulation;
// the hardware may differ, so users must not depend on it (the FIFO bypasses
// that case).
//
// The generated SystemVerilog is a plain memory array with registered reads
// and no reset, which Yosys maps to ECP5 DP16KD block RAM. Simulation uses a
// Dart model of the same behaviour.

import 'package:rohd/rohd.dart';

class ParticleBlockRamSdp extends Module with SystemVerilog {
  Logic get clk => input('clk');
  Logic get wAddr => input('wAddr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');
  Logic get rAddr => input('rAddr');
  Logic get rData => output('rData');

  /// Number of words (a power of two).
  final int depth;

  /// Bits per word.
  final int width;

  late final List<int> _words;

  ParticleBlockRamSdp({
    required Logic clk,
    required Logic wAddr,
    required Logic wData,
    required Logic wEn,
    required Logic rAddr,
    required this.depth,
    required this.width,
    super.name = 'particle_block_ram_sdp',
  }) {
    final idxBits = (depth - 1).bitLength;
    if (depth != 1 << idxBits) {
      throw ArgumentError('depth must be a power of two: $depth');
    }
    if (wAddr.width != idxBits || rAddr.width != idxBits) {
      throw ArgumentError('For $depth words the addresses must be $idxBits '
          'bits (got ${wAddr.width} and ${rAddr.width})');
    }
    addInput('clk', clk);
    addInput('wAddr', wAddr, width: idxBits);
    addInput('wData', wData, width: width);
    addInput('wEn', wEn);
    addInput('rAddr', rAddr, width: idxBits);
    addOutput('rData', width: width);
    _buildModel();
  }

  void _buildModel() {
    _words = List<int>.filled(depth, 0);

    // The inputs as they were at the last rising edge. ROHD runs Sequential
    // blocks with the values from before the edge, while edge listeners run
    // afterwards, when the driving registers may already have changed; so the
    // memory acts on these captured copies (as ParticleBlockRamTdp does).
    final capWAddr = Logic(name: 'capWAddr', width: wAddr.width);
    final capWData = Logic(name: 'capWData', width: width);
    final capWEn = Logic(name: 'capWEn');
    final capRAddr = Logic(name: 'capRAddr', width: rAddr.width);
    Sequential(clk, [
      capWAddr < wAddr,
      capWData < wData,
      capWEn < wEn,
      capRAddr < rAddr,
    ]);

    rData.put(0);

    clk.posedge.listen((_) {
      // Read the old contents, then write
      final r = capRAddr.value;
      final next = r.isValid ? _words[r.toInt()] : 0;
      final we = capWEn.value;
      final wa = capWAddr.value;
      final wd = capWData.value;
      if (we.isValid && we.toInt() == 1 && wa.isValid && wd.isValid) {
        _words[wa.toInt()] = wd.toInt();
      }
      rData.put(next);
    });
  }

  @override
  String instantiationVerilog(
      String instanceType, String instanceName, Map<String, String> ports) {
    final p = instanceName;
    final aW = wAddr.width;
    return '''
// ---- $p: ParticleBlockRamSdp, $depth x $width, synchronous ----
logic [${width - 1}:0] ${p}_mem [0:${depth - 1}];
wire ${p}_clk = ${ports['clk']};
wire [${aW - 1}:0] ${p}_wAddr = ${ports['wAddr']};
wire [${width - 1}:0] ${p}_wData = ${ports['wData']};
wire ${p}_wEn = ${ports['wEn']};
wire [${aW - 1}:0] ${p}_rAddr = ${ports['rAddr']};
logic [${width - 1}:0] ${p}_q;
always_ff @(posedge ${p}_clk) begin
  if (${p}_wEn) ${p}_mem[${p}_wAddr] <= ${p}_wData;
end
always_ff @(posedge ${p}_clk) begin
  ${p}_q <= ${p}_mem[${p}_rAddr];
end
assign ${ports['rData']} = ${p}_q;
// ---- end $p ----''';
  }
}
