// =============================================================================
// File: hdl/parcore/lib/parcore_top.dart
// Architecture: Parcore Distributed RISC Pipeline & Conductor Supervisor
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
import 'package:parcore_rohd/spi_controller.dart';

class ParcoreTop extends Module {
  /// When set, the generated SystemVerilog loads each TCM from
  /// `<tcmInitDir>/<name>_tcm_bank0.hex` and `..._bank1.hex` ($readmemh)
  /// instead of from the binaries, so a test can change programs without
  /// rebuilding its Verilator model. Simulation always uses the binaries.
  final String? tcmInitDir;

  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // FTDI UART pins
  Logic get uartRx => input('uart_rx');
  Logic get uartTx => output('uart_tx');

  // Physical SPI Flash Pins (ULX3S)
  Logic get spiCsN => output('spi_cs_n');
  Logic get spiSck => output('spi_sck');
  Logic get spiMosi => output('spi_mosi');
  Logic get spiMiso => input('spi_miso');

  // Runtime guest .text end address (for FENCE.I store-mirror coherence)
  Logic get guestTextEnd => input('guest_text_end');

  // Diagnostic observability
  Logic get branchRedirectStrobe => output('branch_redirect_strobe');
  Logic get branchRedirectVector => output('branch_redirect_vector');

  ParcoreTop({
    required Logic clk,
    required Logic reset,
    required Logic uartRx,
    Logic? spiMiso,
    Logic? guestTextEnd,
    int clkFreqMhz = 25,
    List<int>? conductorBinary,
    List<int>? core0Binary,
    List<int>? core1Binary,
    List<int>? core2Binary,
    List<int>? core3Binary,
    this.tcmInitDir,
    super.name = 'parcore_top',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('uart_rx', uartRx);
    addInput('spi_miso', spiMiso ?? Const(0));
    addInput('guest_text_end', guestTextEnd ?? Const(0, width: 32), width: 32);

    addOutput('uart_tx');
    addOutput('spi_cs_n');
    addOutput('spi_sck');
    addOutput('spi_mosi');
    addOutput('branch_redirect_strobe');
    addOutput('branch_redirect_vector', width: 4);

    _build(
      clkFreqMhz,
      conductorBinary: conductorBinary,
      core0Binary: core0Binary,
      core1Binary: core1Binary,
      core2Binary: core2Binary,
      core3Binary: core3Binary,
    );
  }

  void _build(
    int clkFreqMhz, {
    List<int>? conductorBinary,
    List<int>? core0Binary,
    List<int>? core1Binary,
    List<int>? core2Binary,
    List<int>? core3Binary,
  }) {
    // -------------------------------------------------------------------------
    // Conductor Supervisor Core & Control Registers
    // -------------------------------------------------------------------------
    final condMemARData = Logic(name: 'cond_mem_a_rdata', width: ParticleWidths.halfWord);
    final condMemBRData = Logic(name: 'cond_mem_b_rdata', width: ParticleWidths.word);

    final conductor = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: condMemARData,
      memPortBRData: condMemBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      config: ParcoreConfig.conductorConfig,
      name: 'parcore_conductor',
    );

    final condMemAddr  = conductor.memPortBAddr;
    final condMemWData = conductor.memPortBWData;
    final condMemBEn   = conductor.memPortBBEn;
    final condMemWEn   = conductor.memPortBWEn;
    final condMemREn   = conductor.memPortBREn;

    // Conductor local 2 KB TCM
    final condAddrBits = (log(ParcoreConfig.conductorConfig.tcmSizeBytes) / ln2).round();
    final condLocalSelect = condMemAddr.slice(31, 28).eq(Const(0x0, width: 4));
    final condTcm = ParcoreTcm(
      clk: clk,
      addrA: conductor.memPortAAddr.slice(condAddrBits - 1, 1),
      addrB: condMemAddr.slice(condAddrBits - 1, 2),
      wDataB: condMemWData,
      bEnB: condMemBEn,
      wEnB: condMemWEn & condLocalSelect,
      rEnB: condMemREn & condLocalSelect,
      depthWords: ParcoreConfig.conductorConfig.tcmSizeBytes ~/ 4,
      initialBytes: conductorBinary,
      initFileBank0: tcmInitDir == null ? null : '$tcmInitDir/conductor_tcm_bank0.hex',
      initFileBank1: tcmInitDir == null ? null : '$tcmInitDir/conductor_tcm_bank1.hex',
      name: 'conductor_tcm',
    );
    condMemARData <= condTcm.rDataA;

    // RST_CTRL Register (0xF000_0000):
    //   Bits [5:0]: Per-core reset/hold lines (default 0x3F when conductorBinary != null, else 0x00)
    //   Bit  [6]:   Interconnect FIFO flush strobe
    //   Bit  [31]:  Boot complete flag
    final regRstCtrl = Logic(name: 'reg_rst_ctrl', width: 32);
    final defaultRst = conductorBinary != null ? 0x0000003F : 0x00000000;
    final isRstCtrlSel = condMemAddr.eq(Const(0xF0000000, width: 32));

    Sequential(clk, reset: reset, resetValues: {
      regRstCtrl: Const(defaultRst, width: 32),
    }, [
      If(condMemWEn & isRstCtrlSel, then: [
        regRstCtrl < condMemWData,
      ]),
    ]);

    final condCoreReset = regRstCtrl.slice(5, 0);
    final condFifoFlush = regRstCtrl.slice(6, 6);
    final condTargetCore = condMemAddr.slice(18, 16);
    final isCoreWindow = condMemAddr.slice(31, 28).eq(Const(0x1, width: 4));

    // SPI Master Controller (0xF000_0010 - 0xF000_0018)
    final spiCtrl = SpiController(
      clk: clk,
      reset: reset,
      addr: condMemAddr,
      wData: condMemWData,
      wEn: condMemWEn,
      rEn: condMemREn,
      spiMiso: spiMiso,
    );
    spiCsN <= spiCtrl.spiCsN;
    spiSck <= spiCtrl.spiSck;
    spiMosi <= spiCtrl.spiMosi;

    final isSpiSel = condMemAddr.slice(31, 4).eq(Const(0xF000001, width: 28));

    // Conductor Port B Readback Multiplexer. Memory is synchronous: a load's
    // data is used in the cycle after its address, so the source selection
    // and the register values are captured at the clock edge, like the TCM.
    final readSelRst = Logic(name: 'cond_read_sel_rst');
    final readSelSpi = Logic(name: 'cond_read_sel_spi');
    final readRstVal = Logic(name: 'cond_read_rst_val', width: 32);
    final readSpiVal = Logic(name: 'cond_read_spi_val', width: 32);
    Sequential(clk, [
      readSelRst < isRstCtrlSel,
      readSelSpi < isSpiSel,
      readRstVal < regRstCtrl,
      readSpiVal < spiCtrl.rData,
    ]);
    condMemBRData <= mux(
      readSelRst,
      readRstVal,
      mux(readSelSpi, readSpiVal, condTcm.rDataB),
    );

    // -------------------------------------------------------------------------
    // Helper: Build Core TCM with Port B Conductor Staging Multiplexer
    // -------------------------------------------------------------------------
    void buildTcm({
      required int coreIndex,
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

      final coreHeldInReset = condCoreReset.slice(coreIndex, coreIndex);
      final isConductorActive = coreHeldInReset &
          isCoreWindow &
          condTargetCore.eq(Const(coreIndex, width: 3));

      final muxedAddrB  = mux(isConductorActive, condMemAddr.slice(addrBits - 1, 2), portBAddr.slice(addrBits - 1, 2));
      final muxedWDataB = mux(isConductorActive, condMemWData, portBWData);
      final muxedBEnB   = mux(isConductorActive, condMemBEn, portBBEn);
      final muxedWEnB   = mux(
        isConductorActive,
        condMemWEn,
        portBWEn & portBAddr.slice(31, 28).neq(Const(0xF, width: 4)),
      );
      final muxedREnB   = mux(isConductorActive, condMemREn, portBREn);

      final tcm = ParcoreTcm(
        clk: clk,
        addrA: portAAddr.slice(halfAddrBits, 1),
        addrB: muxedAddrB,
        wDataB: muxedWDataB,
        bEnB: muxedBEnB,
        wEnB: muxedWEnB,
        rEnB: muxedREnB,
        depthWords: sizeBytes ~/ 4,
        initialBytes: initialBytes,
        initFileBank0: tcmInitDir == null ? null : '$tcmInitDir/${name}_tcm_bank0.hex',
        initFileBank1: tcmInitDir == null ? null : '$tcmInitDir/${name}_tcm_bank1.hex',
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

    final pipelineFlush = Logic(name: 'pipeline_flush');
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
    final c0MemARData = Logic(name: 'c0_mem_a_rdata', width: ParticleWidths.halfWord);
    final c0MemBRData = Logic(name: 'c0_mem_b_rdata', width: ParticleWidths.word);
    final c0MboxStrobe = Logic(name: 'c0_mbox_strobe');
    final c0MboxVector = Logic(name: 'c0_mbox_vector', width: 4);
    final c0MboxData = Logic(name: 'c0_mbox_data', width: 32);

    final c0FifoPopData = Logic(name: 'c0_fifo_pop_data', width: ParticleWidths.word);
    final c0FifoStatus  = Logic(name: 'c0_fifo_status', width: ParticleWidths.word);
    final c0FifoPopEn   = Logic(name: 'c0_fifo_pop_en');

    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(0, 0),
      memPortARData: c0MemARData,
      memPortBRData: c0MemBRData,
      mboxStrobeIn: c0MboxStrobe,
      mboxVectorIn: c0MboxVector,
      mboxDataIn: c0MboxData,
      fifoPopData: c0FifoPopData,
      fifoStatus: c0FifoStatus,
      config: ParcoreConfig.core0If,
      name: 'core0_if',
    );

    buildTcm(
      coreIndex: 0,
      name: 'core0',
      sizeBytes: ParcoreConfig.core0If.tcmSizeBytes,
      portAAddr: core0.memPortAAddr,
      portARData: c0MemARData,
      portBAddr: core0.memPortBAddr,
      portBWData: core0.memPortBWData,
      portBBEn: core0.memPortBBEn,
      portBWEn: core0.memPortBWEn,
      portBREn: core0.memPortBREn,
      portBRData: c0MemBRData,
      initialBytes: core0Binary,
    );

    ifToIdPush <= core0.fifoPushEn & core0.fifoChanSelect.eq(Const(1, width: 2));
    ifToIdData <= core0.fifoPushData;

    final uartTxValid = core0.fifoPushEn & core0.fifoChanSelect.eq(Const(0, width: 2));
    c0FifoPopEn <= core0.fifoPopEn & core0.fifoChanSelect.eq(Const(0, width: 2));

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

    c0FifoStatus <= mux(
      core0.fifoChanSelect.eq(Const(0, width: 2)),
      [Const(0, width: 31), ~ftdiUart.output('rxValid')].swizzle(),
      Const(0, width: ParticleWidths.word),
    );

    c0FifoPopData <= [
      Const(0, width: 24),
      ftdiUart.output('rxData'),
    ].swizzle();

    // -------------------------------------------------------------------------
    // Core 1: ID & Register Scoreboard
    // -------------------------------------------------------------------------
    final c1MemARData = Logic(name: 'c1_mem_a_rdata', width: ParticleWidths.halfWord);
    final c1MemBRData = Logic(name: 'c1_mem_b_rdata', width: ParticleWidths.word);

    final c1ChanSelect = Logic(name: 'c1ChanSelect', width: 2);
    final c1PopData = Logic(name: 'c1PopData', width: 32);
    final c1FifoStatus = Logic(name: 'c1FifoStatus', width: 32);
    final c1PopEn = Logic(name: 'c1PopEn');

    ifToIdPop <= c1PopEn & c1ChanSelect.eq(Const(0, width: 2));
    memToWbPop <= c1PopEn & c1ChanSelect.eq(Const(2, width: 2));

    c1PopData <= mux(
      c1ChanSelect.eq(Const(2, width: 2)),
      interconnect.memToWbOut,
      interconnect.ifToIdOut,
    );
    c1FifoStatus <= mux(
      c1ChanSelect.eq(Const(2, width: 2)),
      interconnect.memToWbStatus,
      interconnect.ifToIdStatus,
    );

    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(1, 1),
      memPortARData: c1MemARData,
      memPortBRData: c1MemBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      fifoPopData: c1PopData,
      fifoStatus: c1FifoStatus,
      config: ParcoreConfig.core1Id,
      name: 'core1_id',
    );

    c1ChanSelect <= core1.fifoChanSelect;
    c1PopEn <= core1.fifoPopEn;

    buildTcm(
      coreIndex: 1,
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

    idToExPush <= core1.fifoPushEn & core1.fifoChanSelect.eq(Const(1, width: 2));
    idToExData <= core1.fifoPushData;

    // -------------------------------------------------------------------------
    // Core 2: EX & Branch Resolution
    // -------------------------------------------------------------------------
    final c2MemARData = Logic(name: 'c2_mem_a_rdata', width: ParticleWidths.halfWord);
    final c2MemBRData = Logic(name: 'c2_mem_b_rdata', width: ParticleWidths.word);

    final core2 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(2, 2),
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
      coreIndex: 2,
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

    exToMemPush <= core2.fifoPushEn & core2.fifoChanSelect.eq(Const(1, width: 2));
    exToMemData <= core2.fifoPushData;

    pipelineFlush <= core2.mboxStrobeOut | condFifoFlush;
    c0MboxStrobe <= core2.mboxStrobeOut;
    c0MboxVector <= core2.mboxVectorOut;
    c0MboxData <= core2.mboxDataOut;

    branchRedirectStrobe <= core2.mboxStrobeOut;
    branchRedirectVector <= core2.mboxVectorOut;

    // -------------------------------------------------------------------------
    // Core 3: MEM & Alignment
    // -------------------------------------------------------------------------
    final c3MemARData = Logic(name: 'c3_mem_a_rdata', width: ParticleWidths.halfWord);
    final c3MemBRData = Logic(name: 'c3_mem_b_rdata', width: ParticleWidths.word);

    final core3 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(3, 3),
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
      coreIndex: 3,
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

    memToWbPush <= core3.fifoPushEn & core3.fifoChanSelect.eq(Const(1, width: 2));
    memToWbData <= core3.fifoPushData;
  }
}
