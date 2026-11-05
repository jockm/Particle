// =============================================================================
// File: hdl/parcore/lib/parcore_interconnect.dart
// Architecture: Parcore Multi-Stage Streaming Interconnect
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:particle_rohd/fifo_subsystem.dart';

class ParcoreInterconnect extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get pipelineFlush => input('pipelineFlush');

  // Core 0 (IF) -> Core 1 (ID)
  Logic get ifToIdPush => input('ifToIdPush');
  Logic get ifToIdData => input('ifToIdData');
  Logic get ifToIdPop => input('ifToIdPop');
  Logic get ifToIdOut => output('ifToIdOut');
  Logic get ifToIdStatus => output('ifToIdStatus');

  // Core 1 (ID) -> Core 2 (EX)
  Logic get idToExPush => input('idToExPush');
  Logic get idToExData => input('idToExData');
  Logic get idToExPop => input('idToExPop');
  Logic get idToExOut => output('idToExOut');
  Logic get idToExStatus => output('idToExStatus');

  // Core 2 (EX) -> Core 3 (MEM)
  Logic get exToMemPush => input('exToMemPush');
  Logic get exToMemData => input('exToMemData');
  Logic get exToMemPop => input('exToMemPop');
  Logic get exToMemOut => output('exToMemOut');
  Logic get exToMemStatus => output('exToMemStatus');

  // Core 3 (MEM) -> Core 1 (ID) [Writeback Stream]
  Logic get memToWbPush => input('memToWbPush');
  Logic get memToWbData => input('memToWbData');
  Logic get memToWbPop => input('memToWbPop');
  Logic get memToWbOut => output('memToWbOut');
  Logic get memToWbStatus => output('memToWbStatus');

  ParcoreInterconnect({
    required Logic clk,
    required Logic reset,
    required Logic pipelineFlush,
    required Logic ifToIdPush,
    required Logic ifToIdData,
    required Logic ifToIdPop,
    required Logic idToExPush,
    required Logic idToExData,
    required Logic idToExPop,
    required Logic exToMemPush,
    required Logic exToMemData,
    required Logic exToMemPop,
    required Logic memToWbPush,
    required Logic memToWbData,
    required Logic memToWbPop,
    super.name = 'parcore_interconnect',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('pipelineFlush', pipelineFlush);

    addInput('ifToIdPush', ifToIdPush);
    addInput('ifToIdData', ifToIdData, width: 32);
    addInput('ifToIdPop', ifToIdPop);
    addOutput('ifToIdOut', width: 32);
    addOutput('ifToIdStatus', width: 32);

    addInput('idToExPush', idToExPush);
    addInput('idToExData', idToExData, width: 32);
    addInput('idToExPop', idToExPop);
    addOutput('idToExOut', width: 32);
    addOutput('idToExStatus', width: 32);

    addInput('exToMemPush', exToMemPush);
    addInput('exToMemData', exToMemData, width: 32);
    addInput('exToMemPop', exToMemPop);
    addOutput('exToMemOut', width: 32);
    addOutput('exToMemStatus', width: 32);

    addInput('memToWbPush', memToWbPush);
    addInput('memToWbData', memToWbData, width: 32);
    addInput('memToWbPop', memToWbPop);
    addOutput('memToWbOut', width: 32);
    addOutput('memToWbStatus', width: 32);

    _build();
  }

  void _build() {
    final ifIdReset = reset | pipelineFlush;
    final fifo0to1 = ParticleFifoSubsystem(
      clk: clk,
      reset: ifIdReset,
      chanSelect: Const(0, width: 2),
      pushData: ifToIdData,
      pushEn: ifToIdPush,
      popEn: ifToIdPop,
      channels: 1,
      name: 'parcore_fifo_if_to_id',
    );
    ifToIdOut <= fifo0to1.popData;
    ifToIdStatus <= fifo0to1.statusWord;

    final fifo1to2 = ParticleFifoSubsystem(
      clk: clk,
      reset: ifIdReset,
      chanSelect: Const(0, width: 2),
      pushData: idToExData,
      pushEn: idToExPush,
      popEn: idToExPop,
      channels: 1,
      name: 'parcore_fifo_id_to_ex',
    );
    idToExOut <= fifo1to2.popData;
    idToExStatus <= fifo1to2.statusWord;

    final fifo2to3 = ParticleFifoSubsystem(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: exToMemData,
      pushEn: exToMemPush,
      popEn: exToMemPop,
      channels: 1,
      name: 'parcore_fifo_ex_to_mem',
    );
    exToMemOut <= fifo2to3.popData;
    exToMemStatus <= fifo2to3.statusWord;

    final fifo3to1 = ParticleFifoSubsystem(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: memToWbData,
      pushEn: memToWbPush,
      popEn: memToWbPop,
      channels: 1,
      name: 'parcore_fifo_mem_to_wb',
    );
    memToWbOut <= fifo3to1.popData;
    memToWbStatus <= fifo3to1.statusWord;
  }
}
