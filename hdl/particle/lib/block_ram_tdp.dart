// =============================================================================
// File: hdl/particle/lib/block_ram_tdp.dart
// Architecture: Particle 32-bit RISC
// Description: True Dual-Port Block RAM (TDP BRAM) parameterized for FPGA EBR.
// =============================================================================
//
// Port A reads 16-bit halfwords (instruction fetch); port B reads and writes
// 32-bit words with byte enables (data). Both ports are synchronous, like FPGA
// block RAM: the address (and write data) present before a rising edge of clk
// is taken at that edge, and the read data appears after it, for the whole of
// the next cycle. A port B read in the same cycle as a write to the same word
// returns the old contents (read-first).
//
// The memory is two 16-bit banks, each with one port A read and one port B
// read/write port, as ECP5 DP16KD block RAM provides:
//   bank 0: halfwords at byte addresses 0x0, 0x4, 0x8, ... (word bits 15:0)
//   bank 1: halfwords at byte addresses 0x2, 0x6, 0xA, ... (word bits 31:16)
//
// Contents at start-up:
//   * simulation: [initialBytes], placed at byte [loadOffset];
//   * generated SystemVerilog: [initFileBank0] / [initFileBank1] loaded with
//     $readmemh (one 16-bit hex word per line; `@index` lines allowed) when
//     given, otherwise [initialBytes] written out as initial values.
// bin/generate_ulx3s.dart writes matching bank files for a program.

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

  /// Initial contents, placed at byte [loadOffset].
  final List<int>? initialBytes;
  final int loadOffset;

  /// $readmemh files for the generated SystemVerilog.
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

  /// The two $readmemh files (bank 0, bank 1) for [bytes] placed at byte
  /// [loadOffset]: one 16-bit hex word per line, each file starting with an
  /// `@index` line. Bytes beyond [depthWords] words (when given) are dropped.
  static (String, String) bankFiles(List<int> bytes,
      {int loadOffset = 0, int? depthWords}) {
    final banks = [<int, int>{}, <int, int>{}];
    for (var i = 0; i < bytes.length; i++) {
      final addr = loadOffset + i;
      if (depthWords != null && addr >= depthWords * 4) break;
      final h = addr >> 1;
      final bank = banks[h & 1];
      final v = bank[h >> 1] ?? 0;
      bank[h >> 1] = addr.isEven
          ? (v & 0xFF00) | (bytes[i] & 0xFF)
          : (v & 0x00FF) | ((bytes[i] & 0xFF) << 8);
    }
    String file(Map<int, int> entries) {
      if (entries.isEmpty) return '';
      final keys = entries.keys.toList()..sort();
      final buf = StringBuffer('@${keys.first.toRadixString(16)}\n');
      for (var i = keys.first; i <= keys.last; i++) {
        buf.writeln((entries[i] ?? 0).toRadixString(16).padLeft(4, '0'));
      }
      return buf.toString();
    }

    return (file(banks[0]), file(banks[1]));
  }

  /// Reads a 32-bit word from the simulation model (for tests).
  int peekWord(int byteAddr) {
    final h = (byteAddr >> 1) % _halfwords.length;
    return _halfwords[h] | (_halfwords[(h + 1) % _halfwords.length] << 16);
  }

  /// Reads a byte from the simulation model (for tests).
  int peekByte(int byteAddr) {
    final h = (byteAddr >> 1) % _halfwords.length;
    return byteAddr.isEven ? _halfwords[h] & 0xFF : _halfwords[h] >> 8;
  }

  /// Writes a byte in the simulation model (for tests, before simulating).
  void pokeByte(int byteAddr, int value) {
    final h = (byteAddr >> 1) % _halfwords.length;
    _halfwords[h] = byteAddr.isEven
        ? (_halfwords[h] & 0xFF00) | (value & 0xFF)
        : (_halfwords[h] & 0x00FF) | ((value & 0xFF) << 8);
  }

  void _buildModel() {
    final count = depthWords * 2;
    _halfwords = List<int>.filled(count, 0);
    final bytes = initialBytes;
    if (bytes != null) {
      for (var i = 0; i < bytes.length; i++) {
        if (((loadOffset + i) >> 1) >= count) break;
        pokeByte(loadOffset + i, bytes[i]);
      }
    }

    // The port inputs as they were at the last rising edge. ROHD runs
    // Sequential blocks with the values from before the edge, while edge
    // listeners run afterwards, when the core's registers may already have
    // changed; so the memory acts on these captured copies.
    final capAddrA = Logic(name: 'capAddrA', width: addrA.width);
    final capAddrB = Logic(name: 'capAddrB', width: addrB.width);
    final capWData = Logic(name: 'capWData', width: 32);
    final capBEn = Logic(name: 'capBEn', width: 4);
    final capWEn = Logic(name: 'capWEn');
    Sequential(clk, [
      capAddrA < addrA,
      capAddrB < addrB,
      capWData < wDataB,
      capBEn < bEnB,
      capWEn < wEnB,
    ]);

    rDataA.put(0);
    rDataB.put(0);

    clk.posedge.listen((_) {
      // Port A read
      final a = capAddrA.value;
      final nextA = a.isValid ? _halfwords[a.toInt() % count] : 0;

      // Port B read (old contents: read before write), then write
      final b = capAddrB.value;
      int nextB = 0;
      if (b.isValid) {
        final h = (b.toInt() * 2) % count;
        nextB = _halfwords[h] | (_halfwords[h + 1] << 16);

        final we = capWEn.value;
        final be = capBEn.value;
        final wd = capWData.value;
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

  /// `initial` assignments for [initialBytes] (non-zero halfwords only).
  String _literalInit(String p) {
    final bytes = initialBytes;
    if (bytes == null || bytes.isEmpty) return '';
    final count = depthWords * 2;
    final halfwords = <int, int>{};
    for (var i = 0; i < bytes.length; i++) {
      final addr = loadOffset + i;
      final h = addr >> 1;
      if (h >= count) break;
      final v = halfwords[h] ?? 0;
      halfwords[h] = addr.isEven
          ? (v & 0xFF00) | (bytes[i] & 0xFF)
          : (v & 0x00FF) | ((bytes[i] & 0xFF) << 8);
    }
    final buf = StringBuffer('initial begin\n');
    for (final e in halfwords.entries) {
      if (e.value == 0) continue;
      final bank = e.key & 1;
      final idx = e.key >> 1;
      buf.writeln("  ${p}_bank$bank[$idx] = 16'h"
          "${e.value.toRadixString(16).padLeft(4, '0')};");
    }
    buf.write('end');
    return buf.toString();
  }

  @override
  String instantiationVerilog(
      String instanceType, String instanceName, Map<String, String> ports) {
    final p = instanceName;
    final aW = addrA.width;
    final bW = addrB.width;
    final idxBits = (depthWords - 1).bitLength;
    final raS = ports['rDataA']!;
    final rbS = ports['rDataB']!;

    final String init;
    if (initFileBank0 != null && initFileBank1 != null) {
      init = 'initial begin\n'
          '  \$readmemh("$initFileBank0", ${p}_bank0);\n'
          '  \$readmemh("$initFileBank1", ${p}_bank1);\n'
          'end';
    } else {
      init = _literalInit(p);
    }

    return '''
// ---- $p: ParticleBlockRamTdp, ${depthWords * 4} bytes, two 16-bit banks, synchronous ----
logic [15:0] ${p}_bank0 [0:${depthWords - 1}];
logic [15:0] ${p}_bank1 [0:${depthWords - 1}];
$init
// Inputs copied to local wires, so they can be indexed
wire ${p}_clk = ${ports['clk']};
wire [${aW - 1}:0] ${p}_addrA = ${ports['addrA']};
wire [${bW - 1}:0] ${p}_addrB = ${ports['addrB']};
wire [31:0] ${p}_wData = ${ports['wDataB']};
wire [3:0] ${p}_bEn = ${ports['bEnB']};
wire ${p}_wEn = ${ports['wEnB']};
wire [${idxBits - 1}:0] ${p}_aIdx = ${p}_addrA[${aW - 1}:1];
logic [15:0] ${p}_a0;
logic [15:0] ${p}_a1;
logic ${p}_aSel;
logic [15:0] ${p}_b0;
logic [15:0] ${p}_b1;
always_ff @(posedge ${p}_clk) begin
  ${p}_a0 <= ${p}_bank0[${p}_aIdx];
  ${p}_a1 <= ${p}_bank1[${p}_aIdx];
  ${p}_aSel <= ${p}_addrA[0];
end
// Each byte's write has its own flat condition: with a shared outer
// if (wEn), Xilinx XST makes wEn the whole port's enable, so the read
// register then changes only on writes
always_ff @(posedge ${p}_clk) begin
  ${p}_b0 <= ${p}_bank0[${p}_addrB];
  if (${p}_wEn && ${p}_bEn[0]) ${p}_bank0[${p}_addrB][7:0] <= ${p}_wData[7:0];
  if (${p}_wEn && ${p}_bEn[1]) ${p}_bank0[${p}_addrB][15:8] <= ${p}_wData[15:8];
end
always_ff @(posedge ${p}_clk) begin
  ${p}_b1 <= ${p}_bank1[${p}_addrB];
  if (${p}_wEn && ${p}_bEn[2]) ${p}_bank1[${p}_addrB][7:0] <= ${p}_wData[23:16];
  if (${p}_wEn && ${p}_bEn[3]) ${p}_bank1[${p}_addrB][15:8] <= ${p}_wData[31:24];
end
assign $raS = ${p}_aSel ? ${p}_a1 : ${p}_a0;
assign $rbS = {${p}_b1, ${p}_b0};
// ---- end $p ----''';
  }
}
