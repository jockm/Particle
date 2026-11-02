// ==============================================================================
// Parcore Architecture: Shared Architectural Register Fabric (SARF)
// Out-of-Band Multi-Port Register Block for Core 0 & Core 1 Co-execution
// ==============================================================================

import 'package:rohd/rohd.dart';

class SharedRegFabric extends Module {
  // Core 0 Ports
  Logic get c0Rs1Data => output('c0_rs1_data');
  Logic get c0Rs2Data => output('c0_rs2_data');
  Logic get c1Rs1Data => output('c1_rs1_data');
  Logic get c1Rs2Data => output('c1_rs2_data');
  Logic get collisionStrobe => output('collision_strobe');

  SharedRegFabric({
    required Logic clk,
    required Logic reset,
    // Core 0 Read Ports
    required Logic c0Rs1Addr,
    required Logic c0Rs2Addr,
    // Core 0 Write Port
    required Logic c0RdAddr,
    required Logic c0RdData,
    required Logic c0RdWe,
    // Core 1 Read Ports
    required Logic c1Rs1Addr,
    required Logic c1Rs2Addr,
    // Core 1 Write Port
    required Logic c1RdAddr,
    required Logic c1RdData,
    required Logic c1RdWe,
    super.name = 'shared_reg_fabric',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    c0Rs1Addr = addInput('c0_rs1_addr', c0Rs1Addr, width: 5);
    c0Rs2Addr = addInput('c0_rs2_addr', c0Rs2Addr, width: 5);
    c0RdAddr  = addInput('c0_rd_addr', c0RdAddr, width: 5);
    c0RdData  = addInput('c0_rd_data', c0RdData, width: 32);
    c0RdWe    = addInput('c0_rd_we', c0RdWe);

    c1Rs1Addr = addInput('c1_rs1_addr', c1Rs1Addr, width: 5);
    c1Rs2Addr = addInput('c1_rs2_addr', c1Rs2Addr, width: 5);
    c1RdAddr  = addInput('c1_rd_addr', c1RdAddr, width: 5);
    c1RdData  = addInput('c1_rd_data', c1RdData, width: 32);
    c1RdWe    = addInput('c1_rd_we', c1RdWe);

    addOutput('c0_rs1_data', width: 32);
    addOutput('c0_rs2_data', width: 32);
    addOutput('c1_rs1_data', width: 32);
    addOutput('c1_rs2_data', width: 32);
    addOutput('collision_strobe');

    // 32 physical 32-bit registers (phys 0 is hardwired zero)
    final regs = List<Logic>.generate(
      32,
      (i) => i == 0
          ? Const(0, width: 32)
          : Logic(name: 'reg_$i', width: 32),
    );

    // Collision detection: Both cores write same non-zero address concurrently
    final collision = c0RdWe & c1RdWe & (c0RdAddr.eq(c1RdAddr)) & (~c0RdAddr.eq(Const(0, width: 5)));
    collisionStrobe <= collision;

    // Sequential Write Logic with Core 0 priority arbitration
    final writeActions = <Conditional>[];
    for (var i = 1; i < 32; i++) {
      final idxConst = Const(i, width: 5);
      final c0Hit = c0RdWe & c0RdAddr.eq(idxConst);
      final c1Hit = c1RdWe & c1RdAddr.eq(idxConst);

      writeActions.add(
        If(
          c0Hit,
          then: [regs[i] < c0RdData],
          orElse: [
            If(c1Hit, then: [regs[i] < c1RdData]),
          ],
        ),
      );
    }

    Sequential(clk, reset: reset, writeActions);

    // Read Logic with Combinational Internal RAW Bypass (Core 0 priority)
    Logic buildReadPort(Logic raddr) {
      final out = Logic(width: 32);

      final bypassC0 = c0RdWe & raddr.eq(c0RdAddr) & (~raddr.eq(Const(0, width: 5)));
      final bypassC1 = c1RdWe & raddr.eq(c1RdAddr) & (~raddr.eq(Const(0, width: 5)));

      final regValCases = <CaseItem>[];
      for (var i = 1; i < 32; i++) {
        regValCases.add(CaseItem(Const(i, width: 5), [
          out < regs[i],
        ]));
      }

      Combinational([
        If(
          raddr.eq(Const(0, width: 5)),
          then: [
            out < Const(0, width: 32),
          ],
          orElse: [
            If(
              bypassC0,
              then: [
                out < c0RdData,
              ],
              orElse: [
                If(
                  bypassC1,
                  then: [
                    out < c1RdData,
                  ],
                  orElse: [
                    Case(raddr, regValCases, defaultItem: [
                      out < Const(0, width: 32),
                    ]),
                  ],
                ),
              ],
            ),
          ],
        ),
      ]);

      return out;
    }

    c0Rs1Data <= buildReadPort(c0Rs1Addr);
    c0Rs2Data <= buildReadPort(c0Rs2Addr);
    c1Rs1Data <= buildReadPort(c1Rs1Addr);
    c1Rs2Data <= buildReadPort(c1Rs2Addr);
  }
}
