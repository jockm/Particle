// =============================================================================
// File: hdl/particle/lib/divider.dart
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
    final regDivisor = Logic(name: 'regDivisor', width: 32);
    final acc = Logic(name: 'acc', width: 64);
    final signResQuot = Logic(name: 'signResQuot');
    final signResRem = Logic(name: 'signResRem');
    final divByZero = Logic(name: 'divByZero');
    final overflow = Logic(name: 'overflow');

    final absDividend = mux(
      isSigned & dividend.slice(31, 31).eq(1),
      Const(0, width: 32) - dividend,
      dividend,
    );
    final absDivisor = mux(
      isSigned & divisor.slice(31, 31).eq(1),
      Const(0, width: 32) - divisor,
      divisor,
    );

    // One bit shift left of the 64-bit working register
    final accShifted = [acc.slice(62, 0), Const(0, width: 1)].swizzle();
    final remPart = accShifted.slice(63, 32);
    final quotPart = accShifted.slice(31, 0);

    final subDiff = remPart - regDivisor;
    final subOk = remPart >= regDivisor;

    final nextAcc = mux(
      subOk,
      [subDiff, quotPart.slice(31, 1), Const(1, width: 1)].swizzle(),
      [remPart, quotPart.slice(31, 1), Const(0, width: 1)].swizzle(),
    );

    final finalQuot = mux(
      signResQuot,
      Const(0, width: 32) - nextAcc.slice(31, 0),
      nextAcc.slice(31, 0),
    );
    final finalRem = mux(
      signResRem,
      Const(0, width: 32) - nextAcc.slice(63, 32),
      nextAcc.slice(63, 32),
    );

    Sequential(clk, reset: reset, resetValues: {
      busy: Const(0),
      count: Const(0, width: 6),
      done: Const(0),
      quotient: Const(0, width: 32),
      remainder: Const(0, width: 32),
      acc: Const(0, width: 64),
      regDivisor: Const(0, width: 32),
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
        regDivisor < absDivisor,
        acc < [Const(0, width: 32), absDividend].swizzle(),
      ], orElse: [
        If(busy, then: [
          If(divByZero, then: [
            busy < Const(0),
            done < Const(1),
            quotient < Const(0xFFFFFFFF, width: 32),
            remainder < dividend,
          ], orElse: [
            If(overflow, then: [
              busy < Const(0),
              done < Const(1),
              quotient < Const(0x80000000, width: 32),
              remainder < Const(0, width: 32),
            ], orElse: [
              acc < nextAcc,
              count < count - Const(1, width: 6),
              If(count.eq(1), then: [
                busy < Const(0),
                done < Const(1),
                quotient < finalQuot,
                remainder < finalRem,
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
