import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleAlu extends Module {
  Logic get aluOp => input('aluOp');
  Logic get operandA => input('operandA');
  Logic get operandB => input('operandB');
  Logic get result => output('result');
  Logic get isZero => output('isZero');
  Logic get isNegative => output('isNegative');

  ParticleAlu({
    required Logic aluOp,
    required Logic operandA,
    required Logic operandB,
    super.name = 'particle_alu',
  }) {
    addInput('aluOp', aluOp, width: 5);
    addInput('operandA', operandA, width: ParticleWidths.word);
    addInput('operandB', operandB, width: ParticleWidths.word);
    addOutput('result', width: ParticleWidths.word);
    addOutput('isZero');
    addOutput('isNegative');
  }
}
