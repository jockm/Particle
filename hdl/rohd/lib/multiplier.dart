import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleMultiplier extends Module {
  ParticleMultiplier({
    required Logic operandA,
    required Logic operandB,
    required Logic mulMode,
    super.name = 'particle_multiplier',
  }) {
    addInput('operandA', operandA, width: ParticleWidths.word);
    addInput('operandB', operandB, width: ParticleWidths.word);
    addInput('mulMode', mulMode, width: 2);
    addOutput('result', width: ParticleWidths.word);
  }
}
