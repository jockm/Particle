// =============================================================================
// Particle Processor Core Module (cpu_core.dart)
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'register_file.dart';
import 'alu.dart';

class ParticleCpuCore extends Module {
  // Clock and Reset
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // Memory Port A: Instruction Fetch (16-bit)
  Logic get memPortARData => input('memPortARData');
  Logic get memPortAAddr => output('memPortAAddr');

  // Memory Port B: Data Load/Store (32-bit)
  Logic get memPortBRData => input('memPortBRData');
  Logic get memPortBAddr => output('memPortBAddr');
  Logic get memPortBWData => output('memPortBWData');
  Logic get memPortBBEn => output('memPortBBEn');
  Logic get memPortBWEn => output('memPortBWEn');
  Logic get memPortBREn => output('memPortBREn');

  // Cross-Core Inbound Mailbox Strobe and Vector
  Logic get mboxStrobeIn => input('mboxStrobeIn');
  Logic get mboxVectorIn => input('mboxVectorIn');

  final CpuConfig config;

  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    this.config = const CpuConfig(),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: ParticleWidths.inst);
    addInput('memPortBRData', memPortBRData, width: ParticleWidths.word);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: 4);

    addOutput('memPortAAddr', width: ParticleWidths.word);
    addOutput('memPortBAddr', width: ParticleWidths.word);
    addOutput('memPortBWData', width: ParticleWidths.word);
    addOutput('memPortBBEn', width: 4);
    addOutput('memPortBWEn');
    addOutput('memPortBREn');

    _build();
  }

  void _build() {
    // -------------------------------------------------------------------------
    // Execution State Definitions
    // -------------------------------------------------------------------------
    const int stateFetch = 0;
    const int stateExec = 1;
    const int stateWait = 2;

    final pc = Logic(name: 'pc', width: ParticleWidths.word);
    final state = Logic(name: 'state', width: 2);

    // -------------------------------------------------------------------------
    // Instruction Slicing
    // -------------------------------------------------------------------------
    final opcode = memPortARData.slice(15, 8);
    final rr = memPortARData.slice(7, 4);
    final rl = memPortARData.slice(3, 0);

    // -------------------------------------------------------------------------
    // Register File Control Signals & Instantiation
    // -------------------------------------------------------------------------
    final rfWAddr = Logic(name: 'rfWAddr', width: 4);
    final rfWData = Logic(name: 'rfWData', width: ParticleWidths.word);
    final rfWEn = Logic(name: 'rfWEn');
    final rfXchgEn = Logic(name: 'rfXchgEn');
    final rfXchgAllEn = Logic(name: 'rfXchgAllEn');
    final rfXchgMostEn = Logic(name: 'rfXchgMostEn');
    final rfXchgRegIdx = Logic(name: 'rfXchgRegIdx', width: 4);

    // Register File: Read addresses are driven directly by instruction fields
    final rf = RegisterFile(
      clk: clk,
      reset: reset,
      rAddrA: rr,
      rAddrB: rl,
      wAddr: rfWAddr,
      wData: rfWData,
      wEn: rfWEn,
      xchgEn: rfXchgEn,
      xchgAllEn: rfXchgAllEn,
      xchgMostEn: rfXchgMostEn,
      xchgRegIdx: rfXchgRegIdx,
    );

    // -------------------------------------------------------------------------
    // ALU Instantiation
    // -------------------------------------------------------------------------
    final aluOp = Logic(name: 'aluOp', width: 5);

    // ALU inputs are directly driven from the register file read outputs
    final alu = ParticleAlu(
      aluOp: aluOp,
      operandA: rf.rDataA,
      operandB: rf.rDataB,
    );

    // -------------------------------------------------------------------------
    // Static Port Routing via Continuous Assignment
    // -------------------------------------------------------------------------
    memPortAAddr <= pc;
    memPortBAddr <= rf.rDataA;
    memPortBWData <= rf.rDataB;
    memPortBBEn <= Const(0xF, width: 4);
    memPortBWEn <= Const(0);
    memPortBREn <= Const(0);

    rfWAddr <= rr;
    rfXchgRegIdx <= rr;
    rfWData <= alu.result;

    // -------------------------------------------------------------------------
    // Instruction Decode & Control Routing
    // -------------------------------------------------------------------------
    final inExec = state.eq(stateExec);

    Combinational([
      Case(opcode, [
        // Arithmetic: ADD Rr, Rl
        CaseItem(Const(ParticleOpcodes.add, width: 8), [
          aluOp < Const(AluOps.add, width: 5),
          rfWEn < inExec,
          rfXchgEn < Const(0),
          rfXchgAllEn < Const(0),
          rfXchgMostEn < Const(0),
        ]),
        // Arithmetic: SUB Rr, Rl
        CaseItem(Const(ParticleOpcodes.sub, width: 8), [
          aluOp < Const(AluOps.sub, width: 5),
          rfWEn < inExec,
          rfXchgEn < Const(0),
          rfXchgAllEn < Const(0),
          rfXchgMostEn < Const(0),
        ]),
        // Logic: NOT Rr (0x72)
        CaseItem(Const(ParticleOpcodes.not, width: 8), [
          aluOp < Const(AluOps.not, width: 5),
          rfWEn < inExec,
          rfXchgEn < Const(0),
          rfXchgAllEn < Const(0),
          rfXchgMostEn < Const(0),
        ]),
        // Condition: NEZ Rr (0x73)
        CaseItem(Const(ParticleOpcodes.nez, width: 8), [
          aluOp < Const(AluOps.nez, width: 5),
          rfWEn < inExec,
          rfXchgEn < Const(0),
          rfXchgAllEn < Const(0),
          rfXchgMostEn < Const(0),
        ]),
        // Context Switch: XCHGMOST (0xD2)
        CaseItem(Const(ParticleOpcodes.xchgmost, width: 8), [
          aluOp < Const(AluOps.add, width: 5),
          rfWEn < Const(0),
          rfXchgEn < Const(0),
          rfXchgAllEn < Const(0),
          rfXchgMostEn < inExec,
        ]),
      ], defaultItem: [
        aluOp < Const(AluOps.add, width: 5),
        rfWEn < Const(0),
        rfXchgEn < Const(0),
        rfXchgAllEn < Const(0),
        rfXchgMostEn < Const(0),
      ]),
    ]);

    // -------------------------------------------------------------------------
    // Pipeline & Program Counter Sequential FSM
    // -------------------------------------------------------------------------
    // Trap computation: Target = TRAP_BASE + (vector * 64)[cite: 1]
    final mboxTarget = Const(config.trapTableBase, width: ParticleWidths.word) +
        (mboxVectorIn.zeroExtend(ParticleWidths.word) << 6);

    Sequential(clk, reset: reset, resetValues: {
      pc: Const(config.trapTableBase, width: ParticleWidths.word),
      state: Const(stateFetch, width: 2),
    }, [
      // Priority 1: Inbound MBOX Strobe Interruption
      If(mboxStrobeIn, then: [
        pc < mboxTarget,
        state < Const(stateFetch, width: 2),
      ], orElse: [
        Case(state, [
          // State 0: Fetch -> Transition to Execute
          CaseItem(Const(stateFetch, width: 2), [
            state < Const(stateExec, width: 2),
          ]),
          // State 1: Execute
          CaseItem(Const(stateExec, width: 2), [
            If(opcode.eq(Const(ParticleOpcodes.wait, width: 8)), then: [
              // WAIT instruction halts pipeline advancement until strobe
              state < Const(stateWait, width: 2),
            ], orElse: [
              pc < pc + Const(2, width: ParticleWidths.word),
              state < Const(stateFetch, width: 2),
            ]),
          ]),
          // State 2: Stalled / Waiting for MBOX Strobe
          CaseItem(Const(stateWait, width: 2), [
            // Remains parked here until mboxStrobeIn asserts
          ]),
        ]),
      ]),
    ]);
  }
}
