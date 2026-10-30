import 'package:rohd/rohd.dart';
import 'cpu_config.dart';

class ParticleCpuCore extends Module {
  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    CpuConfig config = const CpuConfig(),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: 16);
    addInput('memPortBRData', memPortBRData, width: 32);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: 4);
  }
}
