// =============================================================================
// File: hdl/parcore/lib/parcore_top.dart
// Architecture: Parcore Distributed 4-Stage RISC Pipeline & Cache Subsystem
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'dart:math';
import 'package:rohd/rohd.dart';
import 'package:particle_rohd/constants.dart';
import 'package:particle_rohd/cpu_core.dart';
import 'package:particle_rohd/uart.dart';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_interconnect.dart';
import 'package:parcore_rohd/parcore_tcm.dart';

class ParcoreTop extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // FTDI UART pins
  Logic get uartRx => input('uart_rx');
  Logic get uartTx => output('uart_tx');

  // Diagnostic observability
  Logic get branchRedirectStrobe => output('branch_redirect_strobe');
  Logic get branchRedirectVector => output('branch_redirect_vector');

  ParcoreTop({
    required Logic clk,
    required Logic reset,
    required Logic uartRx,
    int clkFreqMhz = 25,
    List<int>? core0Binary,
    List<int>? core1Binary,
    List<int>? core2Binary,
    List<int>? core3Binary,
    super.name = 'parcore_top',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('uart_rx', uartRx);

    addOutput('uart_tx');
    addOutput('branch_redirect_strobe');
    addOutput('branch_redirect_vector', width: 4);

    _build(
      clkFreqMhz,
      core0Binary: core0Binary,
      core1Binary: core1Binary,
      core2Binary: core2Binary,
      core3Binary: core3Binary,
    );
  }

  void _build(
    int clkFreqMhz, {
    List<int>? core0Binary,
    List<int>? core1Binary,
    List<int>? core2Binary,
    List<int>? core3Binary,
  }) {
    void buildTcm({
      required String name,
      required int sizeBytes,
      required Logic portAAddr,
      required Logic portARData,
      required Logic portBAddr,
      required Logic portBWData,
      required Logic portBBEn,
      required Logic portBWEn,
      required Logic portBREn,
      required Logic portBRData,
      List<int>? initialBytes,
    }) {
      final addrBits = (log(sizeBytes) / ln2).round();
      final halfAddrBits = addrBits - 1;

      final tcm = ParcoreTcm(
        clk: clk,
        addrA: portAAddr.slice(halfAddrBits, 1),
        addrB: portBAddr.slice(addrBits - 1, 2),
        wDataB: portBWData,
        bEnB: portBBEn,
        wEnB: portBWEn,
        rEnB: portBREn,
        depthWords: sizeBytes ~/ 4,
        initialBytes: initialBytes,
        name: '${name}_tcm',
      );

      portARData <= tcm.rDataA;
      portBRData <= tcm.rDataB;
    }

    // Interconnect wires
    final ifToIdPush = Logic(name: 'ifToIdPush');
    final ifToIdData = Logic(name: 'ifToIdData', width: 32);
    final ifToIdPop = Logic(name: 'ifToIdPop');

    final idToExPush = Logic(name: 'idToExPush');
    final idToExData = Logic(name: 'idToExData', width: 32);
    final idToExPop = Logic(name: 'idToExPop');

    final exToMemPush = Logic(name: 'exToMemPush');
    final exToMemData = Logic(name: 'exToMemData', width: 32);
    final exToMemPop = Logic(name: 'exToMemPop');

    final memToWbPush = Logic(name: 'memToWbPush');
    final memToWbData = Logic(name: 'memToWbData', width: 32);
    final memToWbPop = Logic(name: 'memToWbPop');
    final pipelineFlush = Logic(name: 'pipelineFlush');

    final interconnect = ParcoreInterconnect(
      clk: clk,
      reset: reset,
      pipelineFlush: pipelineFlush,
      ifToIdPush: ifToIdPush,
      ifToIdData: ifToIdData,
      ifToIdPop: ifToIdPop,
      idToExPush: idToExPush,
      idToExData: idToExData,
      idToExPop: idToExPop,
      exToMemPush: exToMemPush,
      exToMemData: exToMemData,
      exToMemPop: exToMemPop,
      memToWbPush: memToWbPush,
      memToWbData: memToWbData,
      memToWbPop: memToWbPop,
    );

    // -------------------------------------------------------------------------
    // Core 0: IF & UART
    // -------------------------------------------------------------------------
    final c0MemARData =
        Logic(name: 'c0_mem_a_rdata', width: ParticleWidths.halfWord);
    final c0MemBRData =
        Logic(name: 'c0_mem_b_rdata', width: ParticleWidths.word);
    final c0TcmPortBRData =
        Logic(name: 'c0_tcm_port_b_rdata', width: ParticleWidths.word);
    final branchRedirectTarget =
        Logic(name: 'branch_redirect_target', width: ParticleWidths.word);
    final c0MboxStrobe = Logic(name: 'c0_mbox_strobe');
    final c0MboxVector = Logic(name: 'c0_mbox_vector', width: 4);
    final c1MboxStrobe = Logic(name: 'c1_mbox_strobe');
    final c1MboxVector = Logic(name: 'c1_mbox_vector', width: 4);

    final c0FifoPopData =
        Logic(name: 'c0_fifo_pop_data', width: ParticleWidths.word);
    final c0FifoStatus =
        Logic(name: 'c0_fifo_status', width: ParticleWidths.word);
    final c0FifoPopEn = Logic(name: 'c0_fifo_pop_en');

    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c0MemARData,
      memPortBRData: c0MemBRData,
      mboxStrobeIn: c0MboxStrobe,
      mboxVectorIn: c0MboxVector,
      fifoPopData: c0FifoPopData,
      fifoStatus: c0FifoStatus,
      config: ParcoreConfig.core0If,
      name: 'core0_if',
    );

    buildTcm(
      name: 'core0',
      sizeBytes: ParcoreConfig.core0If.tcmSizeBytes,
      portAAddr: core0.memPortAAddr,
      portARData: c0MemARData,
      portBAddr: core0.memPortBAddr,
      portBWData: core0.memPortBWData,
      portBBEn: core0.memPortBBEn,
      portBWEn: core0.memPortBWEn,
      portBREn: core0.memPortBREn,
      portBRData: c0TcmPortBRData,
      initialBytes: core0Binary,
    );

    ifToIdPush <=
        core0.fifoPushEn & core0.fifoChanSelect.eq(Const(1, width: 2));
    ifToIdData <= core0.fifoPushData;

    final uartTxValid =
        core0.fifoPushEn & core0.fifoChanSelect.eq(Const(0, width: 2));
    c0FifoPopEn <=
        core0.fifoPopEn & core0.fifoChanSelect.eq(Const(0, width: 2));

    final ftdiUart = ParticleUartTransceiver(
      clk: clk,
      reset: reset,
      rxPin: uartRx,
      txData: core0.fifoPushData.slice(7, 0),
      txValid: uartTxValid,
      rxReady: c0FifoPopEn,
      baudDivisor: Const(8, width: 16),
      name: 'parcore_ftdi_uart',
    );
    uartTx <= ftdiUart.output('txPin');

    // Core 0 Channel 0 status: bit 0 = empty (~rxValid)
    c0FifoStatus <=
        mux(
          core0.fifoChanSelect.eq(Const(0, width: 2)),
          [Const(0, width: 31), ~ftdiUart.output('rxValid')].swizzle(),
          Const(0, width: ParticleWidths.word),
        );

    // Channel 0 pop data: zero-extend 8-bit UART RX data to 32 bits
    c0FifoPopData <=
        [
          Const(0, width: 24),
          ftdiUart.output('rxData'),
        ].swizzle();

    // -------------------------------------------------------------------------
    // Core 1: ID & Register Scoreboard
    // -------------------------------------------------------------------------
    final c1MemARData =
        Logic(name: 'c1_mem_a_rdata', width: ParticleWidths.halfWord);
    final c1MemBRData =
        Logic(name: 'c1_mem_b_rdata', width: ParticleWidths.word);

    final c1ChanSelect = Logic(name: 'c1ChanSelect', width: 2);
    final c1PopData = Logic(name: 'c1PopData', width: 32);
    final c1FifoStatus = Logic(name: 'c1FifoStatus', width: 32);
    final c1PopEn = Logic(name: 'c1PopEn');

    ifToIdPop <= c1PopEn & c1ChanSelect.eq(Const(0, width: 2));
    memToWbPop <= c1PopEn & c1ChanSelect.eq(Const(2, width: 2));

    c1PopData <=
        mux(
          c1ChanSelect.eq(Const(2, width: 2)),
          interconnect.memToWbOut,
          interconnect.ifToIdOut,
        );
    c1FifoStatus <=
        mux(
          c1ChanSelect.eq(Const(2, width: 2)),
          interconnect.memToWbStatus,
          interconnect.ifToIdStatus,
        );

    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c1MemARData,
      memPortBRData: c1MemBRData,
      mboxStrobeIn: c1MboxStrobe,
      mboxVectorIn: c1MboxVector,
      fifoPopData: c1PopData,
      fifoStatus: c1FifoStatus,
      config: ParcoreConfig.core1Id,
      name: 'core1_id',
    );

    c1ChanSelect <= core1.fifoChanSelect;
    c1PopEn <= core1.fifoPopEn;

    buildTcm(
      name: 'core1',
      sizeBytes: ParcoreConfig.core1Id.tcmSizeBytes,
      portAAddr: core1.memPortAAddr,
      portARData: c1MemARData,
      portBAddr: core1.memPortBAddr,
      portBWData: core1.memPortBWData,
      portBBEn: core1.memPortBBEn,
      portBWEn: core1.memPortBWEn,
      portBREn: core1.memPortBREn,
      portBRData: c1MemBRData,
      initialBytes: core1Binary,
    );

    idToExPush <=
        core1.fifoPushEn & core1.fifoChanSelect.eq(Const(1, width: 2));
    idToExData <= core1.fifoPushData;

    // -------------------------------------------------------------------------
    // Core 2: EX & Branch Resolution
    // -------------------------------------------------------------------------
    final c2MemARData =
        Logic(name: 'c2_mem_a_rdata', width: ParticleWidths.halfWord);
    final c2MemBRData =
        Logic(name: 'c2_mem_b_rdata', width: ParticleWidths.word);

    final core2 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c2MemARData,
      memPortBRData: c2MemBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      fifoPopData: interconnect.idToExOut,
      fifoStatus: interconnect.idToExStatus,
      config: ParcoreConfig.core2Ex,
      name: 'core2_ex',
    );

    idToExPop <= core2.fifoPopEn;

    buildTcm(
      name: 'core2',
      sizeBytes: ParcoreConfig.core2Ex.tcmSizeBytes,
      portAAddr: core2.memPortAAddr,
      portARData: c2MemARData,
      portBAddr: core2.memPortBAddr,
      portBWData: core2.memPortBWData,
      portBBEn: core2.memPortBBEn,
      portBWEn: core2.memPortBWEn,
      portBREn: core2.memPortBREn,
      portBRData: c2MemBRData,
      initialBytes: core2Binary,
    );

    exToMemPush <=
        core2.fifoPushEn & core2.fifoChanSelect.eq(Const(1, width: 2));
    exToMemData <= core2.fifoPushData;

    pipelineFlush <= core2.mboxStrobeOut;
    c0MboxStrobe <= core2.mboxStrobeOut;
    c0MboxVector <= core2.mboxVectorOut;
    c1MboxStrobe <= core2.mboxStrobeOut;
    c1MboxVector <= core2.mboxVectorOut;

    // Latch 32-bit redirect target from Core 2 (rf.rDataA = fifoPushData) on MBOX strobe
    Sequential(clk, reset: reset, [
      If(core2.mboxStrobeOut, then: [
        branchRedirectTarget < core2.fifoPushData,
      ]),
    ]);

    // Memory-mapped redirect target at 0x0000013C for Core 0 Trap 1 handler
    final c0ReadRedirectMmio = core0.memPortBAddr.eq(Const(0x0000013C, width: 32));
    c0MemBRData <= mux(c0ReadRedirectMmio, branchRedirectTarget, c0TcmPortBRData);

    branchRedirectStrobe <= core2.mboxStrobeOut;
    branchRedirectVector <= core2.mboxVectorOut;

    // -------------------------------------------------------------------------
    // Core 3: MEM & Alignment
    // -------------------------------------------------------------------------
    final c3MemARData =
        Logic(name: 'c3_mem_a_rdata', width: ParticleWidths.halfWord);
    final c3MemBRData =
        Logic(name: 'c3_mem_b_rdata', width: ParticleWidths.word);

    final core3 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c3MemARData,
      memPortBRData: c3MemBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      fifoPopData: interconnect.exToMemOut,
      fifoStatus: interconnect.exToMemStatus,
      config: ParcoreConfig.core3Mem,
      name: 'core3_mem',
    );

    exToMemPop <= core3.fifoPopEn;

    buildTcm(
      name: 'core3',
      sizeBytes: ParcoreConfig.core3Mem.tcmSizeBytes,
      portAAddr: core3.memPortAAddr,
      portARData: c3MemARData,
      portBAddr: core3.memPortBAddr,
      portBWData: core3.memPortBWData,
      portBBEn: core3.memPortBBEn,
      portBWEn: core3.memPortBWEn,
      portBREn: core3.memPortBREn,
      portBRData: c3MemBRData,
      initialBytes: core3Binary,
    );

    memToWbPush <=
        core3.fifoPushEn & core3.fifoChanSelect.eq(Const(1, width: 2));
    memToWbData <= core3.fifoPushData;
  }
}
