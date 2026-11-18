// =============================================================================
// File: hdl/particle/lib/block_ram_tdp.dart
// Architecture: Particle 32-bit RISC
// Description: True Dual-Port Block RAM (TDP BRAM) parameterized for FPGA EBR.
// =============================================================================
//
// Port A reads 16-bit halfwords (instruction fetch); port B reads and writes
// 32-bit words with byte enables (data). Both ports are registered on the
// FALLING edge of clk: the core sets its addresses after the rising edge, the
// RAM latches them half a cycle later, and the data is ready before the next
// rising edge. This is how the core, which expects memory to answer in the
// same cycle, can use synchronous block RAM.
//
// The memory is two 16-bit banks, each with one port A read and one port B
// read/write port, as ECP5 DP16KD block RAM provides:
//   bank 0: halfwords at byte addresses 0x0, 0x4, 0x8, ... (word bits 15:0)
//   bank 1: halfwords at byte addresses 0x2, 0x6, 0xA, ... (word bits 31:16)
//
// In simulation the contents come from [initialBytes]. In the generated
// SystemVerilog they come from [initFileBank0] and [initFileBank1], loaded
// with $readmemh (one 16-bit hex word per line; `@index` lines allowed).
// Both should describe the same image; bin/generate_ulx3s.dart writes both.

import 'package:rohd/rohd.dart';

class ParticleBlockRamTdp extends Module with SystemVerilog {
  Logic get clk => input('clk');

  // Port A: halfword address, 16-bit read
  Logic get addrA => input('addrA');
  Logic get rDataA => output('rDataA');

  // Port B: word address, 32-bit read/write with byte enables
  Logic get addrB => input('addrB');
  Logic get wDataB => input('wDataB');
  Logic get bEnB => input('bEnB');
  Logic get wEnB => input('wEnB');
  Logic get rEnB => input('rEnB');
  Logic get rDataB => output('rDataB');

  /// Number of 32-bit words (16384 = 64 KiB).
  final int depthWords;

  /// Initial contents for simulation, placed at byte [loadOffset].
  final List<int>? initialBytes;
  final int loadOffset;

  /// $readmemh files for the generated SystemVerilog (null: no initial load).
  final String? initFileBank0;
  final String? initFileBank1;

  /// Simulation storage: one entry per halfword (bank = index & 1).
  late final List<int> _halfwords;

  ParticleBlockRamTdp({
    required Logic clk,
    required Logic addrA,
    required Logic addrB,
    required Logic wDataB,
    required Logic bEnB,
    required Logic wEnB,
    required Logic rEnB,
    this.depthWords = 16384,
    this.initialBytes,
    this.loadOffset = 0,
    this.initFileBank0,
    this.initFileBank1,
    super.name = 'particle_block_ram_tdp',
  }) {
    final idxBits = (depthWords - 1).bitLength;
    if (depthWords != 1 << idxBits) {
      throw ArgumentError('depthWords must be a power of two: $depthWords');
    }
    if (addrA.width != idxBits + 1 || addrB.width != idxBits) {
      throw ArgumentError('For $depthWords words addrA must be '
          '${idxBits + 1} bits and addrB $idxBits bits '
          '(got ${addrA.width} and ${addrB.width})');
    }
    addInput('clk', clk);
    addInput('addrA', addrA, width: addrA.width);
    addOutput('rDataA', width: 16);
    addInput('addrB', addrB, width: addrB.width);
    addInput('wDataB', wDataB, width: 32);
    addInput('bEnB', bEnB, width: 4);
    addInput('wEnB', wEnB);
    addInput('rEnB', rEnB);
    addOutput('rDataB', width: 32);
    _buildModel();
  }

  /// Reads a 32-bit word from the simulation model (for tests).
  int peekWord(int byteAddr) {
    final h = (byteAddr >> 1) % _halfwords.length;
    return _halfwords[h] | (_halfwords[(h + 1) % _halfwords.length] << 16);
  }

  void _buildModel() {
    final count = depthWords * 2;
    _halfwords = List<int>.filled(count, 0);
    final bytes = initialBytes;
    if (bytes != null) {
      for (var i = 0; i < bytes.length; i++) {
        final addr = loadOffset + i;
        final h = addr >> 1;
        if (h >= count) break;
        if (addr.isEven) {
          _halfwords[h] = (_halfwords[h] & 0xFF00) | (bytes[i] & 0xFF);
        } else {
          _halfwords[h] = (_halfwords[h] & 0x00FF) | ((bytes[i] & 0xFF) << 8);
        }
      }
    }

    rDataA.put(0);
    rDataB.put(0);

    clk.negedge.listen((_) {
      // Port A read
      final a = addrA.value;
      final nextA = a.isValid ? _halfwords[a.toInt() % count] : 0;

      // Port B read (old contents: read before write)
      final b = addrB.value;
      int nextB = 0;
      if (b.isValid) {
        final h = (b.toInt() * 2) % count;
        nextB = _halfwords[h] | (_halfwords[h + 1] << 16);

        final we = wEnB.value;
        final be = bEnB.value;
        final wd = wDataB.value;
        if (we.isValid && we.toInt() == 1 && be.isValid && wd.isValid) {
          final enables = be.toInt();
          final data = wd.toInt();
          var word = nextB;
          for (var lane = 0; lane < 4; lane++) {
            if ((enables >> lane) & 1 == 1) {
              final mask = 0xFF << (lane * 8);
              word = (word & ~mask) | (data & mask);
            }
          }
          _halfwords[h] = word & 0xFFFF;
          _halfwords[h + 1] = (word >> 16) & 0xFFFF;
        }
      }

      rDataA.put(nextA);
      rDataB.put(nextB);
    });
  }

  @override
  String instantiationVerilog(
      String instanceType, String instanceName, Map<String, String> ports) {
    final inputs = ports;
    final outputs = ports;
    final p = instanceName;
    final aW = addrA.width;
    final bW = addrB.width;
    final idxBits = (depthWords - 1).bitLength;
    final raS = outputs['rDataA']!;
    final rbS = outputs['rDataB']!;

    final init = StringBuffer();
    if (initFileBank0 != null && initFileBank1 != null) {
      init
        ..writeln('initial begin')
        ..writeln('  \$readmemh("$initFileBank0", ${p}_bank0);')
        ..writeln('  \$readmemh("$initFileBank1", ${p}_bank1);')
        ..writeln('end');
    }

    return '''
// ---- $p: ParticleBlockRamTdp, ${depthWords * 4} bytes, two 16-bit banks, falling edge ----
logic [15:0] ${p}_bank0 [0:${depthWords - 1}];
logic [15:0] ${p}_bank1 [0:${depthWords - 1}];
$init
// Inputs copied to local wires, so they can be indexed
wire ${p}_clk = ${inputs['clk']};
wire [${aW - 1}:0] ${p}_addrA = ${inputs['addrA']};
wire [${bW - 1}:0] ${p}_addrB = ${inputs['addrB']};
wire [31:0] ${p}_wData = ${inputs['wDataB']};
wire [3:0] ${p}_bEn = ${inputs['bEnB']};
wire ${p}_wEn = ${inputs['wEnB']};
wire [${idxBits - 1}:0] ${p}_aIdx = ${p}_addrA[${aW - 1}:1];
logic [15:0] ${p}_a0;
logic [15:0] ${p}_a1;
logic ${p}_aSel;
logic [15:0] ${p}_b0;
logic [15:0] ${p}_b1;
always_ff @(negedge ${p}_clk) begin
  ${p}_a0 <= ${p}_bank0[${p}_aIdx];
  ${p}_a1 <= ${p}_bank1[${p}_aIdx];
  ${p}_aSel <= ${p}_addrA[0];
end
always_ff @(negedge ${p}_clk) begin
  ${p}_b0 <= ${p}_bank0[${p}_addrB];
  if (${p}_wEn) begin
    if (${p}_bEn[0]) ${p}_bank0[${p}_addrB][7:0] <= ${p}_wData[7:0];
    if (${p}_bEn[1]) ${p}_bank0[${p}_addrB][15:8] <= ${p}_wData[15:8];
  end
end
always_ff @(negedge ${p}_clk) begin
  ${p}_b1 <= ${p}_bank1[${p}_addrB];
  if (${p}_wEn) begin
    if (${p}_bEn[2]) ${p}_bank1[${p}_addrB][7:0] <= ${p}_wData[23:16];
    if (${p}_bEn[3]) ${p}_bank1[${p}_addrB][15:8] <= ${p}_wData[31:24];
  end
end
assign $raS = ${p}_aSel ? ${p}_a1 : ${p}_a0;
assign $rbS = {${p}_b1, ${p}_b0};
// ---- end $p ----''';
  }
}
