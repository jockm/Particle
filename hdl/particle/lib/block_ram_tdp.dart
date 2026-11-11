// =============================================================================
// File: hdl/particle/lib/block_ram_tdp.dart
// Architecture: Particle 32-bit RISC
// Description: True Dual-Port Block RAM (TDP BRAM) parameterized for FPGA EBR.
// =============================================================================

import 'package:rohd/rohd.dart';

class ParticleBlockRamTdp extends Module {
  Logic get clk => input('clk');
  Logic get addrA => input('addrA');
  Logic get rDataA => output('rDataA');

  Logic get addrB => input('addrB');
  Logic get wDataB => input('wDataB');
  Logic get bEnB => input('bEnB');
  Logic get wEnB => input('wEnB');
  Logic get rEnB => input('rEnB');
  Logic get rDataB => output('rDataB');

  final int depthWords;

  ParticleBlockRamTdp({
    required Logic clk,
    required Logic addrA,
    required Logic addrB,
    required Logic wDataB,
    required Logic bEnB,
    required Logic wEnB,
    required Logic rEnB,
    this.depthWords = 16384,
    super.name = 'particle_block_ram_tdp',
  }) {
    addInput('clk', clk);
    addInput('addrA', addrA, width: addrA.width);
    addOutput('rDataA', width: 16);

    addInput('addrB', addrB, width: addrB.width);
    addInput('wDataB', wDataB, width: 32);
    addInput('bEnB', bEnB, width: 4);
    addInput('wEnB', wEnB);
    addInput('rEnB', rEnB);
    addOutput('rDataB', width: 32);
  }
}
