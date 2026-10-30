// =============================================================================
// File: hdl/rohd/lib/cache_subsystem_top.dart
// Architecture: Particle 32-bit RISC Dual-Core Cache & SDRAM Subsystem Top
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// Description: Instantiates Core 0 (Client) and Core 1 (Cache/SDRAM Worker),
//              cross-core MBOX strobe routing, and MMIO bridge to the SDRAM PHY.
// =============================================================================

import 'package:rohd/rohd.dart';

import 'constants.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'sdram_controller.dart';

class CacheSubsystemTop extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get sdramDqIn => input('sdram_dq_in');

  // External SDRAM Controller Interface Pins
  Logic get sdramClk => output('sdram_clk');
  Logic get sdramCke => output('sdram_cke');
  Logic get sdramCsN => output('sdram_cs_n');
  Logic get sdramRasN => output('sdram_ras_n');
  Logic get sdramCasN => output('sdram_cas_n');
  Logic get sdramWeN => output('sdram_we_n');
  Logic get sdramDqm => output('sdram_dqm');
  Logic get sdramAddr => output('sdram_addr');
  Logic get sdramBa => output('sdram_ba');
  Logic get sdramDqOut => output('sdram_dq_out');
  Logic get sdramDqOe => output('sdram_dq_oe');

  CacheSubsystemTop({
    required Logic clk,
    required Logic reset,
    required Logic sdramDqIn,
    int clkFreqMhz = 25,
    int casLatency = 2,
    super.name = 'particle_cache_subsystem_top',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('sdram_dq_in', sdramDqIn, width: 16);

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
    // Cross-Core Hardware MBOX Strobes & Vectors
    // -------------------------------------------------------------------------
    final c0ToC1Strobe = Logic(name: 'c0_to_c1_strobe');
    final c0ToC1Vector = Logic(name: 'c0_to_c1_vector', width: 4);

    final c1ToC0Strobe = Logic(name: 'c1_to_c0_strobe');
    final c1ToC0Vector = Logic(name: 'c1_to_c0_vector', width: 4);

    // Mock/Bypass Read Data lines for local core instruction & data caches
    final c0MemARData = Logic(
      name: 'c0_mem_a_rdata',
      width: ParticleWidths.halfWord,
    );
    final c0MemBRData = Logic(
      name: 'c0_mem_b_rdata',
      width: ParticleWidths.word,
    );

    final c1MemARData = Logic(
      name: 'c1_mem_a_rdata',
      width: ParticleWidths.halfWord,
    );
    final c1MemBRData = Logic(
      name: 'c1_mem_b_rdata',
      width: ParticleWidths.word,
    );

    // -------------------------------------------------------------------------
    // Core 0 Instantiation (Application / Client Core)
    // -------------------------------------------------------------------------
    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c0MemARData,
      memPortBRData: c0MemBRData,
      mboxStrobeIn: c1ToC0Strobe,
      mboxVectorIn: c1ToC0Vector,
      config: const CpuConfig(
        coreId: 0,
        tcmSizeBytes: 65536,
        trapTableBase: 0x00000100,
        enableMultiplier: true,
        enableDivider: true,
      ),
    );

    // -------------------------------------------------------------------------
    // Core 1 Instantiation (Cache & SDRAM Worker Core)
    // -------------------------------------------------------------------------
    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: c1MemARData,
      memPortBRData: c1MemBRData,
      mboxStrobeIn: c0ToC1Strobe,
      mboxVectorIn: c0ToC1Vector,
      config: const CpuConfig(
        coreId: 1,
        tcmSizeBytes: 8192,
        trapTableBase: 0x00000100,
        enableMultiplier: false,
        enableDivider: false,
      ),
    );

    // Default TCM memory read tie-offs (if BRAM blocks are external)
    c0MemARData <= Const(0, width: ParticleWidths.halfWord);
    c0MemBRData <= Const(0, width: ParticleWidths.word);
    c1MemARData <= Const(0, width: ParticleWidths.halfWord);
    c1MemBRData <= Const(0, width: ParticleWidths.word);

    // -------------------------------------------------------------------------
    // Cross-Core Mailbox Interconnect Logic (MMIO: 0xF0000020)
    // Bits [7:4] = Target Core ID, Bits [3:0] = Trap Vector Number
    // -------------------------------------------------------------------------
    const mmioMailboxAddr = 0xF0000020;

    final c0MbWrite =
        core0.memPortBWEn &
        core0.memPortBAddr.eq(
          Const(mmioMailboxAddr, width: ParticleWidths.word),
        );

    c0ToC1Strobe <=
        c0MbWrite & core0.memPortBWData.slice(7, 4).eq(Const(1, width: 4));
    c0ToC1Vector <= core0.memPortBWData.slice(3, 0);

    final c1MbWrite =
        core1.memPortBWEn &
        core1.memPortBAddr.eq(
          Const(mmioMailboxAddr, width: ParticleWidths.word),
        );

    c1ToC0Strobe <=
        c1MbWrite & core1.memPortBWData.slice(7, 4).eq(Const(0, width: 4));
    c1ToC0Vector <= core1.memPortBWData.slice(3, 0);

    // -------------------------------------------------------------------------
    // SDRAM Physical & Command MMIO Registers (Managed by Core 1)
    // 0xF0000030: SDRAM Physical Target Address (32-bit)
    // 0xF0000034: SDRAM Command (1: Read Burst, 2: Write Burst)
    // 0xF0000038: SDRAM Write Data FIFO Register
    // -------------------------------------------------------------------------
    const mmioSdramAddr = 0xF0000030;
    const mmioSdramCmd = 0xF0000034;
    const mmioSdramWData = 0xF0000038;

    final regSdramAddr = Logic(name: 'reg_sdram_addr', width: 24);
    final sdramCmdReq = Logic(name: 'sdram_cmd_req');
    final sdramCmdRw = Logic(name: 'sdram_cmd_rw');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        regSdramAddr: Const(0, width: 24),
        sdramCmdReq: Const(0),
        sdramCmdRw: Const(0),
      },
      [
        sdramCmdReq < 0,
        If(
          core1.memPortBWEn,
          then: [
            If(
              core1.memPortBAddr.eq(
                Const(mmioSdramAddr, width: ParticleWidths.word),
              ),
              then: [regSdramAddr < core1.memPortBWData.slice(23, 0)],
            ),
            If(
              core1.memPortBAddr.eq(
                Const(mmioSdramCmd, width: ParticleWidths.word),
              ),
              then: [
                sdramCmdReq < 1,
                sdramCmdRw <
                    core1.memPortBWData.slice(1, 0).eq(Const(2, width: 2)),
              ],
            ),
          ],
        ),
      ],
    );

    // -------------------------------------------------------------------------
    // SDRAM Controller Instantiation
    // -------------------------------------------------------------------------
    final sdram = SdramController(
      clk: clk,
      rstN: ~reset,
      cmdReq: sdramCmdReq,
      cmdRw: sdramCmdRw,
      cmdAddr: regSdramAddr,
      cmdBurstLen: Const(8, width: 8),
      wdata: core1.memPortBWData.slice(15, 0),
      wdataValid:
          core1.memPortBWEn &
          core1.memPortBAddr.eq(
            Const(mmioSdramWData, width: ParticleWidths.word),
          ),
      sdramDqIn: sdramDqIn,
      clkFreqMhz: clkFreqMhz,
      casLatency: casLatency,
    );

    // Route SDRAM controller outputs to module top-level ports
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
