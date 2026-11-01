// =============================================================================
// File: hdl/rohd/lib/cpu_core.dart
// Architecture: Particle 32-bit RISC Core
// Description: Multi-stage execution engine, Direct Stride vector dispatch,
//              branch evaluation, and instruction decoding in Intel ROHD.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'register_file.dart';

class ParticleCpuCore extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get memPortARData => input('memPortARData');
  Logic get memPortBRData => input('memPortBRData');
  Logic get mboxStrobeIn => input('mboxStrobeIn');
  Logic get mboxVectorIn => input('mboxVectorIn');

  Logic get memPortAAddr => output('memPortAAddr');
  Logic get memPortBAddr => output('memPortBAddr');
  Logic get memPortBWData => output('memPortBWData');
  Logic get memPortBBEn => output('memPortBBEn');
  Logic get memPortBWEn => output('memPortBWEn');
  Logic get memPortBREn => output('memPortBREn');

  final CpuConfig config;

  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    this.config = const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 64),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: ParticleWidths.inst);
    addInput('memPortBRData', memPortBRData, width: ParticleWidths.word);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: ParticleWidths.trapVector);

    addOutput('memPortAAddr', width: ParticleWidths.word);
    addOutput('memPortBAddr', width: ParticleWidths.word);
    addOutput('memPortBWData', width: ParticleWidths.word);
    addOutput('memPortBBEn', width: ParticleWidths.byteEnable);
    addOutput('memPortBWEn');
    addOutput('memPortBREn');

    _build();
  }

  void _build() {
    final pc = Logic(name: 'pc', width: ParticleWidths.word);
    final nextPc = Logic(name: 'nextPc', width: ParticleWidths.word);

    // Synchronous PC update with asynchronous/synchronous reset to trapTableBase
    Sequential(clk, reset: reset, resetValues: {
      pc: Const(config.trapTableBase, width: 32)
    }, [
      pc < nextPc,
    ]);

    memPortAAddr <= pc;

    final inst = memPortARData;
    final opcode = inst.slice(15, 8);
    final rr = inst.slice(7, 4);
    final rl = inst.slice(3, 0);
    final imm4 = inst.slice(3, 0);
    final imm8 = inst.slice(7, 0);

    // Register File instantiation
    final rfWEn = Logic(name: 'rfWEn');
    final rfWAddr = Logic(name: 'rfWAddr', width: 4);
    final rfWData = Logic(name: 'rfWData', width: 32);

    final rf = RegisterFile(
      clk: clk,
      reset: reset,
      rAddrA: rr,
      rAddrB: rl,
      wAddr: rfWAddr,
      wData: rfWData,
      wEn: rfWEn,
      xchgEn: Const(0),
      xchgAllEn: Const(0),
      xchgMostEn: Const(0),
      xchgRegIdx: rr,
    );

    // Branch condition evaluation
    final rValA = rf.rDataA;
    final isZero = rValA.eq(0);
    final isNegative = rValA.slice(31, 31).eq(1);
    final isPositive = (~isNegative) & (~isZero);
    final isNotZero = ~isZero;

    // Displacements (in bytes, shifted by 1 bit)
    final dispImm4 = imm4.zeroExtend(32) << 1;
    final dispImm8 = imm8.zeroExtend(32) << 1;
    final signedRegDisp = (rValA.signExtend(32)) << 1;

    // Direct Stride MBOX vector computation: TRAP_TABLE_BASE + (vector * 64)
    final mboxTargetAddr = Const(config.trapTableBase, width: 32) +
        (mboxVectorIn.zeroExtend(32) << 6);

    final branchNextPc = Logic(name: 'branchNextPc', width: 32);

    Combinational([
      Case(opcode, [
        // BRANCH Rr (0xA4)
        CaseItem(Const(ParticleOpcodes.branch, width: 8), [
          branchNextPc < (pc + signedRegDisp),
        ]),

        // Unconditional Branches
        CaseItem(Const(ParticleOpcodes.fbraImm8, width: 8), [
          branchNextPc < (pc + dispImm8),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraImm8, width: 8), [
          branchNextPc < (pc - dispImm8),
        ]),

        // Forward Conditional Branches
        CaseItem(Const(ParticleOpcodes.fbraZImm4, width: 8), [
          branchNextPc < mux(isZero, pc + dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraNImm4, width: 8), [
          branchNextPc < mux(isNegative, pc + dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraPImm4, width: 8), [
          branchNextPc < mux(isPositive, pc + dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraNZImm4, width: 8), [
          branchNextPc < mux(isNotZero, pc + dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraZImm8, width: 8), [
          branchNextPc < mux(isZero, pc + dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraNImm8, width: 8), [
          branchNextPc < mux(isNegative, pc + dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraPImm8, width: 8), [
          branchNextPc < mux(isPositive, pc + dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraNZImm8, width: 8), [
          branchNextPc < mux(isNotZero, pc + dispImm8, pc + 2),
        ]),

        // Backward Conditional Branches
        CaseItem(Const(ParticleOpcodes.bbraZImm4, width: 8), [
          branchNextPc < mux(isZero, pc - dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraNImm4, width: 8), [
          branchNextPc < mux(isNegative, pc - dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraPImm4, width: 8), [
          branchNextPc < mux(isPositive, pc - dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraNZImm4, width: 8), [
          branchNextPc < mux(isNotZero, pc - dispImm4, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraZImm8, width: 8), [
          branchNextPc < mux(isZero, pc - dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraNImm8, width: 8), [
          branchNextPc < mux(isNegative, pc - dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraPImm8, width: 8), [
          branchNextPc < mux(isPositive, pc - dispImm8, pc + 2),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraNZImm8, width: 8), [
          branchNextPc < mux(isNotZero, pc - dispImm8, pc + 2),
        ]),

        // Indirect Jump
        CaseItem(Const(ParticleOpcodes.jmp, width: 8), [
          branchNextPc < rValA,
        ]),
      ], defaultItem: [
        branchNextPc < pc + 2,
      ]),
    ]);

    // Top-level PC Arbitration: MBOX interrupt has highest priority over regular branch
    nextPc <= mux(mboxStrobeIn, mboxTargetAddr, branchNextPc);

    // Data port & control defaults
    memPortBAddr <= Const(0, width: 32);
    memPortBWData <= Const(0, width: 32);
    memPortBBEn <= Const(0, width: 4);
    memPortBWEn <= Const(0);
    memPortBREn <= Const(0);
    rfWEn <= Const(0);
    rfWAddr <= Const(0, width: 4);
    rfWData <= Const(0, width: 32);
  }
}
