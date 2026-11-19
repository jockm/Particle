// =============================================================================
// File: hdl/parcore/lib/parcore_tcm.dart
// Architecture: Parcore Dual-Port Tightly-Coupled Memory with Preloading
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================
//
// A core's tightly-coupled memory: ParticleBlockRamTdp (synchronous, two
// 16-bit banks) with its contents placed at [loadOffset] (0x100, the reset
// vector). Port A reads 16-bit halfwords (halfword address); port B reads and
// writes 32-bit words (word address) with byte enables. Read data appears the
// cycle after the address, as the Particle core expects.
//
// Contents at start-up: [initialBytes] in simulation; in the generated
// SystemVerilog, [initFileBank0]/[initFileBank1] ($readmemh, written with
// ParticleBlockRamTdp.bankFiles) when given, otherwise [initialBytes].

import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:rohd/rohd.dart';

class ParcoreTcm extends Module {
  Logic get clk => input('clk');

  // Port A: 16-bit half-word fetch interface
  Logic get addrA => input('addrA');
  Logic get rDataA => output('rDataA');

  // Port B: 32-bit word data interface with byte enables
  Logic get addrB => input('addrB');
  Logic get wDataB => input('wDataB');
  Logic get bEnB => input('bEnB');
  Logic get wEnB => input('wEnB');
  Logic get rEnB => input('rEnB');
  Logic get rDataB => output('rDataB');

  final int depthWords;
  final int loadOffset;
  final List<int>? initialBytes;
  late final ParticleBlockRamTdp _ram;

  ParcoreTcm({
    required Logic clk,
    required Logic addrA,
    required Logic addrB,
    required Logic wDataB,
    required Logic bEnB,
    required Logic wEnB,
    required Logic rEnB,
    this.depthWords = 4096,
    this.loadOffset = 0x00000100,
    this.initialBytes,
    String? initFileBank0,
    String? initFileBank1,
    super.name = 'parcore_tcm',
  }) {
    clk = addInput('clk', clk);
    addrA = addInput('addrA', addrA, width: addrA.width);
    addOutput('rDataA', width: 16);
    addrB = addInput('addrB', addrB, width: addrB.width);
    wDataB = addInput('wDataB', wDataB, width: 32);
    bEnB = addInput('bEnB', bEnB, width: 4);
    wEnB = addInput('wEnB', wEnB);
    rEnB = addInput('rEnB', rEnB);
    addOutput('rDataB', width: 32);

    _ram = ParticleBlockRamTdp(
      clk: clk,
      addrA: addrA,
      addrB: addrB,
      wDataB: wDataB,
      bEnB: bEnB,
      wEnB: wEnB,
      rEnB: rEnB,
      depthWords: depthWords,
      initialBytes: initialBytes,
      loadOffset: loadOffset,
      initFileBank0: initFileBank0,
      initFileBank1: initFileBank1,
      name: 'ram',
    );
    rDataA <= _ram.rDataA;
    rDataB <= _ram.rDataB;
  }

  /// Reads a 32-bit word from the simulation model (for tests).
  int readWord(int byteAddr) => _ram.peekWord(byteAddr & ~3);
}
