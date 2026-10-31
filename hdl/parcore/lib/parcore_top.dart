// =============================================================================
// File: hdl/parcore/lib/parcore_top.dart
// Architecture: Parcore Distributed 5-Stage RISC Pipeline & Cache Subsystem
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// Description: Instantiates the 5-stage pipeline cores (IF, ID, EX, MEM, WB)
//              and dedicated L1 Cache Controller core, cross-core streaming
//              FIFOs, MBOX branch redirect feedback, FTDI UART transceiver,
//              physical 16-bit SDRAM PHY bus, and right-sized local TCM BRAMs.
// =============================================================================

import 'dart:math';
import 'package:rohd/rohd.dart';
import 'package:particle_rohd/constants.dart';
import 'package:particle_rohd/cpu_core.dart';
import 'package:particle_rohd/uart.dart';
import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:particle_rohd/sdram_controller.dart';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_interconnect.dart';

class ParcoreTop extends Module {
  // Clock and synchronous reset
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Physical FTDI Console UART pins (ULX3S 3 Mbps)
  Logic get uartRx => input('uart_rx');
  Logic get uartTx => output('uart_tx');

  // Physical 16-bit SDRAM Interface Pins (ULX3S ECP5)
  Logic get sdramClk => output('sdram_clk');
  Logic get sdramCke => output('sdram_cke');
  Logic get sdramCsN => output('sdram_cs_n');
  Logic get sdramRasN => output('sdram_ras_n');
  Logic get sdramCasN => output('sdram_cas_n');
  Logic get sdramWeN => output('sdram_we_n');
  Logic get sdramDqm => output('sdram_dqm');
  Logic get sdramAddr => output('sdram_addr');
  Logic get sdramBa => output('sdram_ba');

  // Split bi-directional SDRAM data bus
  Logic get sdramDqIn => input('sdram_dq_in');
  Logic get sdramDqOut => output('sdram_dq_out');
  Logic get sdramDqOe => output('sdram_dq_oe');

  ParcoreTop({
    required Logic clk,
    required Logic reset,
    required Logic uartRx,
    required Logic sdramDqIn,
    int clkFreqMhz = 25,
    int casLatency = 2,
    super.name = 'parcore_top',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('uart_rx', uartRx);
    addInput('sdram_dq_in', sdramDqIn, width: 16);

    addOutput('uart_tx');

    addOutput('sdram_clk');
    addOutput('sdram_cke');
    addOutput('sdram_cs_n');
    addOutput('sdram_ras_n');
    addOutput('sdram_cas_n');
    addOutput('sdram_we_n');
    addOutput('sdram_dqm', width: 2);
    addOutput('sdram_addr', width: 13);
    addOutput('sdram_ba', width: 2);
    addOutput('sdram_dq_out', width: 16);
    addOutput('sdram_dq_oe');

    _build(clkFreqMhz, casLatency);
  }

  void _build(int clkFreqMhz, int casLatency) {
    // -------------------------------------------------------------------------
    // Helper: Instantiate Right-Sized Local True Dual-Port Block RAM for a Core
    // -------------------------------------------------------------------------
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
      Logic? mmioReadData,
      Logic? mmioSelect,
    }) {
      final addrBits = (log(sizeBytes) / ln2).round();
      final halfAddrBits = addrBits - 1; // 16-bit instruction halfwords

      final bramRDataB =
          Logic(name: '${name}_bram_rdata_b', width: ParticleWidths.word);

      final tcm = ParticleBlockRamTdp(
        clk: clk,
        // Port A: 16-bit Instruction Fetch
        addrA: portAAddr.slice(halfAddrBits, 1),
        // Port B: 32-bit Data Access
        addrB: portBAddr.slice(addrBits - 1, 2),
        wDataB: portBWData,
        bEnB: portBBEn,
        wEnB: portBWEn & (portBAddr.slice(31, 28).neq(Const(0xF, width: 4))),
        rEnB: portBREn,
        depthWords: sizeBytes ~/ 4,
        name: '${name}_tcm',
      );

      portARData <= tcm.rDataA;
      bramRDataB <= tcm.rDataB;

      if (mmioReadData != null && mmioSelect != null) {
        portBRData <= mux(mmioSelect, mmioReadData, bramRDataB);
      } else {
        portBRData <= bramRDataB;
      }
    }

    // -------------------------------------------------------------------------
    // Core 0: Stage 1 - Instruction Fetch & FTDI Console Gateway (8 KB TCM)
    // -------------------------------------------------------------------------
    final c0MemARData =
        Logic(name: 'c0_mem_a_rdata', width: ParticleWidths.halfWord);
    final c0MemBRData =
        Logic(name: 'c0_mem_b_rdata', width: ParticleWidths.word);
    final c0MboxStrobe = Logic(name: 'c0_mbox_strobe');
    final c0MboxVector = Logic(name: 'c0_mbox_vector', width: 4);

    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c0MemARData,
      memPortBRData: c0MemBRData,
      mboxStrobeIn: c0MboxStrobe,
      mboxVectorIn: c0MboxVector,
      config: ParcoreConfig.core0If,
      name: 'parcore_stage_if',
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
      portBRData: c0MemBRData,
    );

    // -------------------------------------------------------------------------
    // Core 1: Stage 2 - Instruction Decode & Register Scoreboard (4 KB TCM)
    // -------------------------------------------------------------------------
    final c1MemARData =
        Logic(name: 'c1_mem_a_rdata', width: ParticleWidths.halfWord);
    final c1MemBRData =
        Logic(name: 'c1_mem_b_rdata', width: ParticleWidths.word);
    final c1MboxStrobe = Logic(name: 'c1_mbox_strobe');
    final c1MboxVector = Logic(name: 'c1_mbox_vector', width: 4);

    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c1MemARData,
      memPortBRData: c1MemBRData,
      mboxStrobeIn: c1MboxStrobe,
      mboxVectorIn: c1MboxVector,
      config: ParcoreConfig.core1Id,
      name: 'parcore_stage_id',
    );

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
    );

    // -------------------------------------------------------------------------
    // Core 2: Stage 3 - Execution, ALU & Branch Resolution (4 KB TCM)
    // -------------------------------------------------------------------------
    final c2MemARData =
        Logic(name: 'c2_mem_a_rdata', width: ParticleWidths.halfWord);
    final c2MemBRData =
        Logic(name: 'c2_mem_b_rdata', width: ParticleWidths.word);
    final c2MboxStrobe = Logic(name: 'c2_mbox_strobe');
    final c2MboxVector = Logic(name: 'c2_mbox_vector', width: 4);

    final core2 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c2MemARData,
      memPortBRData: c2MemBRData,
      mboxStrobeIn: c2MboxStrobe,
      mboxVectorIn: c2MboxVector,
      config: ParcoreConfig.core2Ex,
      name: 'parcore_stage_ex',
    );

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
    );

    // -------------------------------------------------------------------------
    // Core 3: Stage 4 - Memory Access & Alignment Engine (4 KB TCM)
    // -------------------------------------------------------------------------
    final c3MemARData =
        Logic(name: 'c3_mem_a_rdata', width: ParticleWidths.halfWord);
    final c3MemBRData =
        Logic(name: 'c3_mem_b_rdata', width: ParticleWidths.word);
    final c3MboxStrobe = Logic(name: 'c3_mbox_strobe');
    final c3MboxVector = Logic(name: 'c3_mbox_vector', width: 4);

    final core3 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c3MemARData,
      memPortBRData: c3MemBRData,
      mboxStrobeIn: c3MboxStrobe,
      mboxVectorIn: c3MboxVector,
      config: ParcoreConfig.core3Mem,
      name: 'parcore_stage_mem',
    );

    // -------------------------------------------------------------------------
    // Core 4: Stage 5 - Writeback & Architectural Commitment (4 KB TCM)
    // -------------------------------------------------------------------------
    final c4MemARData =
        Logic(name: 'c4_mem_a_rdata', width: ParticleWidths.halfWord);
    final c4MemBRData =
        Logic(name: 'c4_mem_b_rdata', width: ParticleWidths.word);
    final c4MboxStrobe = Logic(name: 'c4_mbox_strobe');
    final c4MboxVector = Logic(name: 'c4_mbox_vector', width: 4);

    final core4 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c4MemARData,
      memPortBRData: c4MemBRData,
      mboxStrobeIn: c4MboxStrobe,
      mboxVectorIn: c4MboxVector,
      config: ParcoreConfig.core4Wb,
      name: 'parcore_stage_wb',
    );

    buildTcm(
      name: 'core4',
      sizeBytes: ParcoreConfig.core4Wb.tcmSizeBytes,
      portAAddr: core4.memPortAAddr,
      portARData: c4MemARData,
      portBAddr: core4.memPortBAddr,
      portBWData: core4.memPortBWData,
      portBBEn: core4.memPortBBEn,
      portBWEn: core4.memPortBWEn,
      portBREn: core4.memPortBREn,
      portBRData: c4MemBRData,
    );

    // -------------------------------------------------------------------------
    // Core 5: L1 Cache Controller (CC) & SDRAM Burster (32 KB TCM)
    // -------------------------------------------------------------------------
    final c5MemARData =
        Logic(name: 'c5_mem_a_rdata', width: ParticleWidths.halfWord);
    final c5MemBRData =
        Logic(name: 'c5_mem_b_rdata', width: ParticleWidths.word);
    final c5MboxStrobe = Logic(name: 'c5_mbox_strobe');
    final c5MboxVector = Logic(name: 'c5_mbox_vector', width: 4);

    final core5 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c5MemARData,
      memPortBRData: c5MemBRData,
      mboxStrobeIn: c5MboxStrobe,
      mboxVectorIn: c5MboxVector,
      config: ParcoreConfig.core5Cache,
      name: 'parcore_cache_ctrl',
    );

    buildTcm(
      name: 'core5',
      sizeBytes: ParcoreConfig.core5Cache.tcmSizeBytes,
      portAAddr: core5.memPortAAddr,
      portARData: c5MemARData,
      portBAddr: core5.memPortBAddr,
      portBWData: core5.memPortBWData,
      portBBEn: core5.memPortBBEn,
      portBWEn: core5.memPortBWEn,
      portBREn: core5.memPortBREn,
      portBRData: c5MemBRData,
    );

    // Unused Mailbox strobe tie-offs
    c1MboxStrobe <= Const(0);
    c1MboxVector <= Const(0, width: 4);
    c2MboxStrobe <= Const(0);
    c2MboxVector <= Const(0, width: 4);
    c4MboxStrobe <= Const(0);
    c4MboxVector <= Const(0, width: 4);
    c5MboxStrobe <= Const(0);
    c5MboxVector <= Const(0, width: 4);

    // -------------------------------------------------------------------------
    // 5-Stage Interconnect Pipeline (FIFO Handshakes)
    // -------------------------------------------------------------------------
    final ifToIdPush = core0.memPortBWEn &
        core0.memPortBAddr.eq(Const(0xF0000004, width: ParticleWidths.word));
    final ifToIdData = core0.memPortBWData;
    final ifToIdPop = core1.memPortBREn &
        core1.memPortBAddr.eq(Const(0xF0000000, width: ParticleWidths.word));

    final idToExPush = core1.memPortBWEn &
        core1.memPortBAddr.eq(Const(0xF0000004, width: ParticleWidths.word));
    final idToExData = core1.memPortBWData;
    final idToExPop = core2.memPortBREn &
        core2.memPortBAddr.eq(Const(0xF0000000, width: ParticleWidths.word));

    final exToMemPush = core2.memPortBWEn &
        core2.memPortBAddr.eq(Const(0xF0000004, width: ParticleWidths.word));
    final exToMemData = core2.memPortBWData;
    final exToMemPop = core3.memPortBREn &
        core3.memPortBAddr.eq(Const(0xF0000000, width: ParticleWidths.word));

    final memToWbPush = core3.memPortBWEn &
        core3.memPortBAddr.eq(Const(0xF0000004, width: ParticleWidths.word));
    final memToWbData = core3.memPortBWData;
    final memToWbPop = core4.memPortBREn &
        core4.memPortBAddr.eq(Const(0xF0000000, width: ParticleWidths.word));

    final wbToIdPush = core4.memPortBWEn &
        core4.memPortBAddr.eq(Const(0xF0000004, width: ParticleWidths.word));
    final wbToIdData = core4.memPortBWData;
    final wbToIdPop = core1.memPortBREn &
        core1.memPortBAddr.eq(Const(0xF0000008, width: ParticleWidths.word));

    ParcoreInterconnect(
      clk: clk,
      reset: reset,
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
      wbToIdPush: wbToIdPush,
      wbToIdData: wbToIdData,
      wbToIdPop: wbToIdPop,
    );

    // -------------------------------------------------------------------------
    // Branch Redirect & Flush Control (Core 2 EX -> Core 0 IF)
    // MMIO: 0xF0000020 (Bits [7:4] = Target Core ID, Bits [3:0] = Trap Vector)
    // -------------------------------------------------------------------------
    const mmioMailboxAddr = 0xF0000020;

    final c2BranchStrobe = core2.memPortBWEn &
        core2.memPortBAddr
            .eq(Const(mmioMailboxAddr, width: ParticleWidths.word));

    c0MboxStrobe <=
        c2BranchStrobe & core2.memPortBWData.slice(7, 4).eq(Const(0, width: 4));
    c0MboxVector <= core2.memPortBWData.slice(3, 0);

    // -------------------------------------------------------------------------
    // Core 3 (MEM) <-> Core 5 (Cache Controller) MMIO Interface
    // -------------------------------------------------------------------------
    const mmioMemRespAddr = 0xF0000044;

    final c5MemRespWrite = core5.memPortBWEn &
        core5.memPortBAddr
            .eq(Const(mmioMemRespAddr, width: ParticleWidths.word));

    c3MboxStrobe <=
        c5MemRespWrite & core5.memPortBWData.slice(7, 4).eq(Const(3, width: 4));
    c3MboxVector <= core5.memPortBWData.slice(3, 0);

    final regMemRespData =
        Logic(name: 'reg_mem_resp_data', width: ParticleWidths.word);
    Sequential(clk, reset: reset, resetValues: {
      regMemRespData: Const(0, width: ParticleWidths.word),
    }, [
      If(c5MemRespWrite, then: [
        regMemRespData < core5.memPortBWData,
      ]),
    ]);

    // Core 3 TCM with MMIO multiplexing on read response
    final isCore3Mmio =
        core3.memPortBAddr.slice(31, 28).eq(Const(0xF, width: 4));
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
      mmioReadData: regMemRespData,
      mmioSelect: isCore3Mmio,
    );

    // -------------------------------------------------------------------------
    // Primary FTDI Console UART (Core 0 FIFO Channel 0)
    // 3 Mbps Transceiver: Clock Divisor = 8 at 25MHz
    // -------------------------------------------------------------------------
    final uartTxData = core0.memPortBWData.slice(7, 0);
    final uartTxValid = core0.memPortBWEn &
        core0.memPortBAddr.eq(Const(0xF0000000, width: ParticleWidths.word));

    final ftdiUart = ParticleUartTransceiver(
      clk: clk,
      reset: reset,
      rxPin: uartRx,
      txData: uartTxData,
      txValid: uartTxValid,
      rxReady: Const(1),
      baudDivisor: Const(8, width: 16),
      name: 'parcore_ftdi_uart',
    );
    uartTx <= ftdiUart.output('txPin');

    // -------------------------------------------------------------------------
    // SDRAM Physical & Command MMIO Registers (Managed by Core 5)
    // 0xF0000030: SDRAM Physical Target Address (24-bit)
    // 0xF0000034: SDRAM Command (1: Read Burst, 2: Write Burst)
    // 0xF0000038: SDRAM Write Data Port (16-bit)
    // -------------------------------------------------------------------------
    const mmioSdramAddr = 0xF0000030;
    const mmioSdramCmd = 0xF0000034;
    const mmioSdramWData = 0xF0000038;

    final regSdramAddr = Logic(name: 'reg_sdram_addr', width: 24);
    final sdramCmdReq = Logic(name: 'sdram_cmd_req');
    final sdramCmdRw = Logic(name: 'sdram_cmd_rw');

    Sequential(clk, reset: reset, resetValues: {
      regSdramAddr: Const(0, width: 24),
      sdramCmdReq: Const(0),
      sdramCmdRw: Const(0),
    }, [
      sdramCmdReq < 0,
      If(core5.memPortBWEn, then: [
        If(
            core5.memPortBAddr
                .eq(Const(mmioSdramAddr, width: ParticleWidths.word)),
            then: [
              regSdramAddr < core5.memPortBWData.slice(23, 0),
            ]),
        If(
            core5.memPortBAddr
                .eq(Const(mmioSdramCmd, width: ParticleWidths.word)),
            then: [
              sdramCmdReq < 1,
              sdramCmdRw <
                  core5.memPortBWData.slice(1, 0).eq(Const(2, width: 2)),
            ]),
      ]),
    ]);

    // -------------------------------------------------------------------------
    // SDRAM Physical Controller Instantiation
    // -------------------------------------------------------------------------
    final sdram = SdramController(
      clk: clk,
      rstN: ~reset,
      cmdReq: sdramCmdReq,
      cmdRw: sdramCmdRw,
      cmdAddr: regSdramAddr,
      cmdBurstLen: Const(8, width: 8),
      wdata: core5.memPortBWData.slice(15, 0),
      wdataValid: core5.memPortBWEn &
          core5.memPortBAddr
              .eq(Const(mmioSdramWData, width: ParticleWidths.word)),
      sdramDqIn: sdramDqIn,
      clkFreqMhz: clkFreqMhz,
      casLatency: casLatency,
    );

    // Connect SDRAM controller interface to module top outputs
    sdramClk <= sdram.sdramClk;
    sdramCke <= sdram.sdramCke;
    sdramCsN <= sdram.sdramCsN;
    sdramRasN <= sdram.sdramRasN;
    sdramCasN <= sdram.sdramCasN;
    sdramWeN <= sdram.sdramWeN;
    sdramDqm <= sdram.sdramDqm;
    sdramAddr <= sdram.sdramAddr;
    sdramBa <= sdram.sdramBa;
    sdramDqOut <= sdram.sdramDqOut;
    sdramDqOe <= sdram.sdramDqOe;
  }
}
