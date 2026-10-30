import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleFifoSubsystem extends Module {
  Logic get popData => output('popData');
  Logic get empty => output('empty');
  Logic get full => output('full');
  Logic get statusWord => output('statusWord');

  ParticleFifoSubsystem({
    required Logic clk,
    required Logic reset,
    required Logic chanSelect,
    required Logic pushData,
    required Logic pushEn,
    required Logic popEn,
    int channels = 4,
    super.name = 'fifo_subsystem',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('chanSelect', chanSelect, width: 2);
    addInput('pushData', pushData, width: ParticleWidths.word);
    addInput('pushEn', pushEn);
    addInput('popEn', popEn);
    addOutput('popData', width: ParticleWidths.word);
    addOutput('empty');
    addOutput('full');
    addOutput('statusWord', width: ParticleWidths.word);
  }
}
