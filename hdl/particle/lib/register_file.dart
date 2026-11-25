// =============================================================================
// File: hdl/particle/lib/register_file.dart
// Architecture: Particle 32-bit RISC Core
// Description: 16x32 Register File with hardwired R0, dual read ports, two
//              write ports, and a single-cycle shadow bank, in LUT RAM.
// =============================================================================
//
// Registers R0..R15 are addressed by their 4-bit index. R0 reads as zero and
// can't be written. Each register Rn has a shadow Sn (S0 is also always zero).
//
// Write ports: port 1 (wAddr/wData/wEn) and port 2 (wAddr2/wData2/wEn2).
// When both write the same register in the same cycle, port 2 wins.
//
// Storage:
//   * R14 and S14 are flip-flops. Every second write the core makes in one
//     cycle (TRYR's status, trap and MBOX entry, the odd-target trap) goes to
//     R14, so R14 has a write port of its own.
//   * The other registers and their shadows are in two LUT RAMs, bank 0 and
//     bank 1, each with one write port. A bank bit per register says which
//     bank holds its active value; XCHG, XCHGALL and XCHGMOST flip bank bits
//     (and swap R14 with S14), so they stay single-cycle. A read reads both
//     banks and picks one with the register's bank bit.
//   * Entry 0 of bank 0 is R0: it is never written except by the clear, so it
//     stays zero.
//   * The LUT RAMs have one write port, so at most one write per cycle may go
//     to them. The core never makes two (a pointer update, the only port-2
//     write outside R14, never comes in the same cycle as a port-1 write);
//     simulation stops with an error if it happens.
//   * LUT RAM can't be reset. After reset, [clearing] is high for 16 cycles
//     while both banks are written with zeros; the core is held in reset
//     until it falls.
//   * As before, a swap and a write to the same register in one cycle keep
//     the swap.
//   * Without the shadow bank ([shadowBank] false) there is one LUT RAM,
//     no bank bits and no S14; the swap inputs are ignored.

import 'package:rohd/rohd.dart';

import 'constants.dart';
import 'lut_ram.dart';

class RegisterFile extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  Logic get rAddrA => input('rAddrA');
  Logic get rAddrB => input('rAddrB');

  Logic get wAddr => input('wAddr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');

  Logic get wAddr2 => input('wAddr2');
  Logic get wData2 => input('wData2');
  Logic get wEn2 => input('wEn2');

  // Shadow Bank Exchange Strobes
  Logic get xchgEn => input('xchgEn');
  Logic get xchgAllEn => input('xchgAllEn');
  Logic get xchgMostEn => input('xchgMostEn');
  Logic get xchgRegIdx => input('xchgRegIdx');

  // Outputs
  Logic get rDataA => output('rDataA');
  Logic get rDataB => output('rDataB');

  /// Cycles the register file takes to clear itself after reset.
  static const clearCycles = 16;

  /// High while the register file clears itself after reset ([clearCycles]).
  Logic get clearing => output('clearing');

  /// Whether the shadow bank exists. Without it there is one LUT RAM bank,
  /// the swap inputs are ignored and the shadows read as zero.
  final bool shadowBank;

  late final List<ParticleLutRam> _banks;
  late final Logic _bank;
  late final Logic _r14;
  late final Logic _s14;

  RegisterFile({
    required Logic clk,
    required Logic reset,
    required Logic rAddrA,
    required Logic rAddrB,
    required Logic wAddr,
    required Logic wData,
    required Logic wEn,
    required Logic xchgEn,
    required Logic xchgAllEn,
    required Logic xchgMostEn,
    required Logic xchgRegIdx,
    Logic? wAddr2,
    Logic? wData2,
    Logic? wEn2,
    this.shadowBank = true,
    super.name = 'register_file',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('rAddrA', rAddrA, width: ParticleWidths.regAddr);
    addInput('rAddrB', rAddrB, width: ParticleWidths.regAddr);
    addInput('wAddr', wAddr, width: ParticleWidths.regAddr);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('wEn', wEn);
    addInput(
      'wAddr2',
      wAddr2 ?? Const(0, width: ParticleWidths.regAddr),
      width: ParticleWidths.regAddr,
    );
    addInput(
      'wData2',
      wData2 ?? Const(0, width: ParticleWidths.word),
      width: ParticleWidths.word,
    );
    addInput('wEn2', wEn2 ?? Const(0));
    addInput('xchgEn', xchgEn);
    addInput('xchgAllEn', xchgAllEn);
    addInput('xchgMostEn', xchgMostEn);
    addInput('xchgRegIdx', xchgRegIdx, width: ParticleWidths.regAddr);
    addOutput('rDataA', width: ParticleWidths.word);
    addOutput('rDataB', width: ParticleWidths.word);
    addOutput('clearing');
    _build();
  }

  /// Register [index]'s value (R0..R15), for tests and debugging; -1 if not
  /// valid.
  int regValue(int index) => _value(index, active: true);

  /// Shadow register [index]'s value (S0..S15); -1 if not valid.
  int shadowValue(int index) => _value(index, active: false);

  int _value(int index, {required bool active}) {
    if (index == 0 || (!active && !shadowBank)) return 0;
    final Logic flop = active ? _r14 : _s14;
    if (index == 14) {
      return flop.value.isValid ? flop.value.toInt() : -1;
    }
    final b = _bank.value;
    if (!b.isValid) return -1;
    if (!shadowBank) return _banks[0].word(index);
    final activeBank = b[index].toBool() ? 1 : 0;
    return _banks[active ? activeBank : 1 - activeBank].word(index);
  }

  void _build() {
    const w = ParticleWidths.regAddr;
    Logic idx(int i) => Const(i, width: w);

    _bank = Logic(name: 'bank', width: 16);
    _r14 = Logic(name: 'r14', width: ParticleWidths.word);
    _s14 = Logic(name: 's14', width: ParticleWidths.word);
    final clearCount = Logic(name: 'clearCount', width: 4);
    final clear = Logic(name: 'clear');
    clearing <= clear;

    // Whether register [addr] is swapped this cycle
    Logic swapped(Logic addr) => shadowBank
        ? xchgAllEn |
            (xchgMostEn & ~addr.eq(idx(15))) |
            (xchgEn & xchgRegIdx.eq(addr))
        : Const(0);
    // The bank bit of register [addr]
    Logic bankOf(Logic addr) => shadowBank
        ? [for (var i = 0; i < 16; i++) _bank[i]]._select(addr)
        : Const(0);

    bool inRam(int i) => i != 0 && i != 14;
    Logic ramReg(Logic addr) => ~addr.eq(idx(0)) & ~addr.eq(idx(14));

    // The one LUT RAM write: port 2's, else port 1's
    final p2Ram = wEn2 & ramReg(wAddr2);
    final p1Ram = wEn & ramReg(wAddr) & ~(wEn2 & wAddr2.eq(wAddr));
    final ramWAddr = mux(p2Ram, wAddr2, wAddr);
    final ramWData = mux(p2Ram, wData2, wData);
    final ramWEn = (p2Ram | p1Ram) & ~swapped(ramWAddr);
    final ramBank = bankOf(ramWAddr);

    final wAddrBanks = mux(clear, clearCount, ramWAddr);
    final wDataBanks = mux(
      clear,
      Const(0, width: ParticleWidths.word),
      ramWData,
    );
    _banks = [
      for (var b = 0; b < (shadowBank ? 2 : 1); b++)
        ParticleLutRam(
          clk: clk,
          wAddr: wAddrBanks,
          wData: wDataBanks,
          wEn: clear | (ramWEn & (b == 0 ? ~ramBank : ramBank)),
          rAddrA: rAddrA,
          rAddrB: rAddrB,
          width: ParticleWidths.word,
          name: 'bank$b',
        ),
    ];

    Logic read(Logic addr, Logic bank0, Logic bank1) =>
        mux(addr.eq(idx(14)), _r14, mux(bankOf(addr), bank1, bank0));
    final last = _banks.length - 1;
    rDataA <= read(rAddrA, _banks[0].rDataA, _banks[last].rDataA);
    rDataB <= read(rAddrB, _banks[0].rDataB, _banks[last].rDataB);

    // The bank bits, R14 and S14, and the clear
    final nextBank = [
      for (var i = 0; i < 16; i++)
        inRam(i) ? _bank[i] ^ swapped(idx(i)) : Const(0),
    ].rswizzle();
    final swap14 = swapped(idx(14));
    Sequential(
      clk,
      reset: reset,
      resetValues: {
        _bank: Const(0, width: 16),
        _r14: Const(0, width: ParticleWidths.word),
        _s14: Const(0, width: ParticleWidths.word),
        clearCount: Const(0, width: 4),
        clear: Const(1),
      },
      [
        If(
          clear,
          then: [
            clearCount < clearCount + 1,
            If(clearCount.eq(Const(15, width: 4)), then: [clear < Const(0)]),
          ],
          orElse: [
            _bank < nextBank,
            If(
              swap14,
              then: [_r14 < _s14, _s14 < _r14],
              orElse: [
                If(
                  wEn2 & wAddr2.eq(idx(14)),
                  then: [_r14 < wData2],
                  orElse: [
                    If(wEn & wAddr.eq(idx(14)), then: [_r14 < wData]),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    // The LUT RAMs take one write a cycle: stop if two are asked for
    clk.negedge.listen((_) {
      bool on(Logic l) => l.value.isValid && l.value.toInt() == 1;
      int? val(Logic l) => l.value.isValid ? l.value.toInt() : null;
      if (on(clear) || !on(wEn) || !on(wEn2)) return;
      final a1 = val(wAddr);
      final a2 = val(wAddr2);
      if (a1 == null || a2 == null) return;
      if (a1 != a2 && a1 != 0 && a1 != 14 && a2 != 0 && a2 != 14) {
        Simulator.throwException(
          Exception(
            'RegisterFile: two LUT RAM writes in one cycle '
            '(R$a1 on port 1, R$a2 on port 2)',
          ),
          StackTrace.current,
        );
      }
    });
  }
}

extension on List<Logic> {
  /// The one-bit element selected by [index].
  Logic _select(Logic index) {
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
