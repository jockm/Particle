// =============================================================================
// File: hdl/parcore/lib/parcore_interconnect.dart
// Architecture: Parcore 5-Stage Interconnect Matrix
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// Description: Synchronous streaming FIFO channels linking the 5 pipeline stages:
//              IF -> ID -> EX -> MEM -> WB, plus WB -> ID writeback feedback.
// =============================================================================

import 'package:rohd/rohd.dart';

class ParcoreInterconnect extends Module {
  // Clock and reset inputs
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Core 0 (IF) -> Core 1 (ID)
  Logic get ifToIdPush => input('ifToIdPush');
  Logic get ifToIdData => input('ifToIdData');
  Logic get ifToIdPop => input('ifToIdPop');
  Logic get ifToIdOut => output('ifToIdOut');
  Logic get ifToIdEmpty => output('ifToIdEmpty');
  Logic get ifToIdFull => output('ifToIdFull');

  // Core 1 (ID) -> Core 2 (EX)
  Logic get idToExPush => input('idToExPush');
  Logic get idToExData => input('idToExData');
  Logic get idToExPop => input('idToExPop');
  Logic get idToExOut => output('idToExOut');
  Logic get idToExEmpty => output('idToExEmpty');
  Logic get idToExFull => output('idToExFull');

  // Core 2 (EX) -> Core 3 (MEM)
  Logic get exToMemPush => input('exToMemPush');
  Logic get exToMemData => input('exToMemData');
  Logic get exToMemPop => input('exToMemPop');
  Logic get exToMemOut => output('exToMemOut');
  Logic get exToMemEmpty => output('exToMemEmpty');
  Logic get exToMemFull => output('exToMemFull');

  // Core 3 (MEM) -> Core 4 (WB)
  Logic get memToWbPush => input('memToWbPush');
  Logic get memToWbData => input('memToWbData');
  Logic get memToWbPop => input('memToWbPop');
  Logic get memToWbOut => output('memToWbOut');
  Logic get memToWbEmpty => output('memToWbEmpty');
  Logic get memToWbFull => output('memToWbFull');

  // Core 4 (WB) -> Core 1 (ID) [Writeback feedback]
  Logic get wbToIdPush => input('wbToIdPush');
  Logic get wbToIdData => input('wbToIdData');
  Logic get wbToIdPop => input('wbToIdPop');
  Logic get wbToIdOut => output('wbToIdOut');
  Logic get wbToIdEmpty => output('wbToIdEmpty');
  Logic get wbToIdFull => output('wbToIdFull');

  ParcoreInterconnect({
    required Logic clk,
    required Logic reset,
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
    required Logic wbToIdPush,
    required Logic wbToIdData,
    required Logic wbToIdPop,
    super.name = 'parcore_interconnect',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);

    addInput('ifToIdPush', ifToIdPush);
    addInput('ifToIdData', ifToIdData, width: 32);
    addInput('ifToIdPop', ifToIdPop);
    addOutput('ifToIdOut', width: 32);
    addOutput('ifToIdEmpty');
    addOutput('ifToIdFull');

    addInput('idToExPush', idToExPush);
    addInput('idToExData', idToExData, width: 32);
    addInput('idToExPop', idToExPop);
    addOutput('idToExOut', width: 32);
    addOutput('idToExEmpty');
    addOutput('idToExFull');

    addInput('exToMemPush', exToMemPush);
    addInput('exToMemData', exToMemData, width: 32);
    addInput('exToMemPop', exToMemPop);
    addOutput('exToMemOut', width: 32);
    addOutput('exToMemEmpty');
    addOutput('exToMemFull');

    addInput('memToWbPush', memToWbPush);
    addInput('memToWbData', memToWbData, width: 32);
    addInput('memToWbPop', memToWbPop);
    addOutput('memToWbOut', width: 32);
    addOutput('memToWbEmpty');
    addOutput('memToWbFull');

    addInput('wbToIdPush', wbToIdPush);
    addInput('wbToIdData', wbToIdData, width: 32);
    addInput('wbToIdPop', wbToIdPop);
    addOutput('wbToIdOut', width: 32);
    addOutput('wbToIdEmpty');
    addOutput('wbToIdFull');

    _build();
  }

  void _build() {
    _buildChannel('if_to_id', clk, reset, ifToIdPush, ifToIdData, ifToIdPop,
        ifToIdOut, ifToIdEmpty, ifToIdFull);
    _buildChannel('id_to_ex', clk, reset, idToExPush, idToExData, idToExPop,
        idToExOut, idToExEmpty, idToExFull);
    _buildChannel('ex_to_mem', clk, reset, exToMemPush, exToMemData, exToMemPop,
        exToMemOut, exToMemEmpty, exToMemFull);
    _buildChannel('mem_to_wb', clk, reset, memToWbPush, memToWbData, memToWbPop,
        memToWbOut, memToWbEmpty, memToWbFull);
    _buildChannel('wb_to_id', clk, reset, wbToIdPush, wbToIdData, wbToIdPop,
        wbToIdOut, wbToIdEmpty, wbToIdFull);
  }

  void _buildChannel(
    String name,
    Logic clockSignal,
    Logic resetSignal,
    Logic push,
    Logic dataIn,
    Logic pop,
    Logic dataOut,
    Logic empty,
    Logic full,
  ) {
    final fifoReg = Logic(name: '${name}_reg', width: 32);
    final validReg = Logic(name: '${name}_valid');

    Sequential(clockSignal, reset: resetSignal, resetValues: {
      fifoReg: Const(0, width: 32),
      validReg: Const(0),
    }, [
      If(push & (~validReg | pop), then: [
        fifoReg < dataIn,
        validReg < Const(1),
      ], orElse: [
        If(pop, then: [
          validReg < Const(0),
        ]),
      ]),
    ]);

    dataOut <= fifoReg;
    empty <= ~validReg;
    full <= validReg;
  }
}
