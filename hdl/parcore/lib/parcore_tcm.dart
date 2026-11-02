// =============================================================================
// File: hdl/parcore/lib/parcore_tcm.dart
// Architecture: Parcore Dual-Port Tightly-Coupled Memory with Preloading
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

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
  final List<int>? initialBytes;

  ParcoreTcm({
    required Logic clk,
    required Logic addrA,
    required Logic addrB,
    required Logic wDataB,
    required Logic bEnB,
    required Logic wEnB,
    required Logic rEnB,
    this.depthWords = 4096,
    this.initialBytes,
    super.name = 'parcore_tcm',
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

    _build();
  }

  void _build() {
    final totalBytes = depthWords * 4;
    final mem = List<int>.filled(totalBytes, 0);

    if (initialBytes != null) {
      final copyLen = initialBytes!.length > totalBytes ? totalBytes : initialBytes!.length;
      for (int i = 0; i < copyLen; i++) {
        mem[i] = initialBytes![i];
      }
    }

    final internalRDataA = Logic(name: 'internalRDataA', width: 16);
    final internalRDataB = Logic(name: 'internalRDataB', width: 32);

    rDataA <= internalRDataA;
    rDataB <= internalRDataB;

    clk.posedge.listen((_) {
      if (!addrA.value.isValid) {
        internalRDataA.put(0);
      } else {
        final byteAddrA = (addrA.value.toInt() << 1) % totalBytes;
        final b0 = mem[byteAddrA];
        final b1 = mem[(byteAddrA + 1) % totalBytes];
        internalRDataA.put(b0 | (b1 << 8));
      }

      if (addrB.value.isValid) {
        final wordAddr = addrB.value.toInt();
        final byteAddrB = (wordAddr << 2) % totalBytes;

        if (wEnB.value.isValid && wEnB.value.toInt() == 1) {
          final wdata = wDataB.value.isValid ? wDataB.value.toInt() : 0;
          final ben = bEnB.value.isValid ? bEnB.value.toInt() : 0xF;

          if ((ben & 0x1) != 0) mem[byteAddrB] = wdata & 0xFF;
          if ((ben & 0x2) != 0) mem[(byteAddrB + 1) % totalBytes] = (wdata >> 8) & 0xFF;
          if ((ben & 0x4) != 0) mem[(byteAddrB + 2) % totalBytes] = (wdata >> 16) & 0xFF;
          if ((ben & 0x8) != 0) mem[(byteAddrB + 3) % totalBytes] = (wdata >> 24) & 0xFF;
        }

        if (rEnB.value.isValid && rEnB.value.toInt() == 1) {
          final b0 = mem[byteAddrB];
          final b1 = mem[(byteAddrB + 1) % totalBytes];
          final b2 = mem[(byteAddrB + 2) % totalBytes];
          final b3 = mem[(byteAddrB + 3) % totalBytes];
          internalRDataB.put(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24));
        } else {
          internalRDataB.put(0);
        }
      } else {
        internalRDataB.put(0);
      }
    });
  }
}
