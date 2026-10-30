import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleDivider extends Module {
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
  }
}
