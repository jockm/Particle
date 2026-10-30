import 'package:rohd/rohd.dart';
import 'constants.dart';

class ParticleMemoryBus extends Module {
  ParticleMemoryBus({
    required Logic addr,
    required Logic wData,
    required Logic size,
    required Logic wEn,
    required Logic rEn,
    required Logic rDataRaw,
    super.name = 'memory_bus',
  }) {
    addInput('addr', addr, width: ParticleWidths.word);
    addInput('wData', wData, width: ParticleWidths.word);
    addInput('size', size, width: 2);
    addInput('wEn', wEn);
    addInput('rEn', rEn);
    addInput('rDataRaw', rDataRaw, width: ParticleWidths.word);
    addOutput('bEn', width: 4);
    addOutput('wDataAligned', width: ParticleWidths.word);
    addOutput('rDataFormatted', width: ParticleWidths.word);
    addOutput('alignFault');
  }
}
