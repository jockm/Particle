// =============================================================================
// File: hdl/rohd/lib/divider.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleDivider extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get start => input('start');
  Logic get isSigned => input('isSigned');
  Logic get dividend => input('dividend');
  Logic get divisor => input('divisor');

  Logic get quotient => output('quotient');
  Logic get remainder => output('remainder');
  Logic get done => output('done');
  Logic get ready => output('done');

  ParticleDivider({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic isSigned,
    required Logic dividend,
    required Logic divisor,
    super.name = 'particle_divider',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('start', start);
    addInput('isSigned', isSigned);
    addInput('dividend', dividend, width: ParticleWidths.word);
    addInput('divisor', divisor, width: ParticleWidths.word);

    addOutput('quotient', width: ParticleWidths.word);
    addOutput('remainder', width: ParticleWidths.word);
    addOutput('done');

    _build();
  }

  void _build() {
    final busy = Logic(name: 'busy');
    final count = Logic(name: 'count', width: 6);
    final regRem = Logic(name: 'regRem', width: 33);
    final regQuot = Logic(name: 'regQuot', width: ParticleWidths.word);
    final regDivisor = Logic(name: 'regDivisor', width: ParticleWidths.word);
    final signResQuot = Logic(name: 'signResQuot');
    final signResRem = Logic(name: 'signResRem');
    final divByZero = Logic(name: 'divByZero');
    final overflow = Logic(name: 'overflow');

    final diff = regRem.slice(31, 0) - regDivisor;

    Sequential(clk, reset: reset, resetValues: {
      busy: Const(0),
      count: Const(0, width: 6),
      done: Const(0),
      quotient: Const(0, width: ParticleWidths.word),
      remainder: Const(0, width: ParticleWidths.word),
    }, [
      If(start & ~busy, then: [
        busy < Const(1),
        done < Const(0),
        count < Const(32, width: 6),
        divByZero < divisor.eq(0),
        overflow < isSigned & dividend.eq(0x80000000) & divisor.eq(0xFFFFFFFF),
        signResQuot <
            isSigned & (dividend.slice(31, 31) ^ divisor.slice(31, 31)),
        signResRem < isSigned & dividend.slice(31, 31),
        regDivisor <
            mux(isSigned & divisor.slice(31, 31).eq(1),
                Const(0, width: ParticleWidths.word) - divisor, divisor),
        regQuot <
            mux(isSigned & dividend.slice(31, 31).eq(1),
                Const(0, width: ParticleWidths.word) - dividend, dividend),
        regRem < Const(0, width: 33),
      ], orElse: [
        If(busy, then: [
          If(divByZero, then: [
            busy < Const(0),
            done < Const(1),
            quotient < Const(0xFFFFFFFF, width: ParticleWidths.word),
            remainder < dividend,
          ], orElse: [
            If(overflow, then: [
              busy < Const(0),
              done < Const(1),
              quotient < Const(0x80000000, width: ParticleWidths.word),
              remainder < Const(0, width: ParticleWidths.word),
            ], orElse: [
              If(count.eq(0), then: [
                busy < Const(0),
                done < Const(1),
                quotient <
                    mux(
                        signResQuot,
                        Const(0, width: ParticleWidths.word) - regQuot,
                        regQuot),
                remainder <
                    mux(
                        signResRem,
                        Const(0, width: ParticleWidths.word) -
                            regRem.slice(31, 0),
                        regRem.slice(31, 0)),
              ], orElse: [
                count < count - Const(1, width: 6),
                If(diff.slice(31, 31).eq(0), then: [
                  regRem <
                      [
                        Const(0, width: 1),
                        diff.slice(30, 0),
                        regQuot.slice(31, 31)
                      ].swizzle(),
                  regQuot <
                      [regQuot.slice(30, 0), Const(1, width: 1)].swizzle(),
                ], orElse: [
                  regRem <
                      [
                        Const(0, width: 1),
                        regRem.slice(30, 0),
                        regQuot.slice(31, 31)
                      ].swizzle(),
                  regQuot <
                      [regQuot.slice(30, 0), Const(0, width: 1)].swizzle(),
                ]),
              ]),
            ]),
          ]),
        ], orElse: [
          done < Const(0),
        ]),
      ]),
    ]);
  }
}
