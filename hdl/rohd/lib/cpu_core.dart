// =============================================================================
// File: hdl/rohd/lib/cpu_core.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'alu.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'divider.dart';
import 'register_file.dart';
import 'multiplier.dart';

class ParticleCpuCore extends Module {
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

  // Cross-Core Outbound Mailbox Strobe and Vector
  Logic get mboxStrobeOut => output('mboxStrobeOut');
  Logic get mboxVectorOut => output('mboxVectorOut');

  // Streaming FIFO Subsystem Interface
  Logic get fifoChanSelect => output('fifoChanSelect');
  Logic get fifoPushData => output('fifoPushData');
  Logic get fifoPushEn => output('fifoPushEn');
  Logic get fifoPopEn => output('fifoPopEn');
  Logic get fifoPopData => input('fifoPopData');
  Logic get fifoStatus => input('fifoStatus');

  // Out-of-Band Shared Architectural Register Fabric (SARF)
  Logic get sarfRs1Addr => output('sarfRs1Addr');
  Logic get sarfRs2Addr => output('sarfRs2Addr');
  Logic get sarfRs1Data => input('sarfRs1Data');
  Logic get sarfRs2Data => input('sarfRs2Data');
  Logic get sarfRdAddr => output('sarfRdAddr');
  Logic get sarfRdData => output('sarfRdData');
  Logic get sarfRdWe => output('sarfRdWe');

  final CpuConfig config;

  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    Logic? fifoPopData,
    Logic? fifoStatus,
    Logic? sarfRs1Data,
    Logic? sarfRs2Data,
    this.config = const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 64),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: ParticleWidths.inst);
    addInput('memPortBRData', memPortBRData, width: ParticleWidths.word);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: ParticleWidths.trapVector);

    addInput('fifoPopData', fifoPopData ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);
    addInput('fifoStatus', fifoStatus ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);
    addInput('sarfRs1Data', sarfRs1Data ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);
    addInput('sarfRs2Data', sarfRs2Data ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);

    addOutput('memPortAAddr', width: ParticleWidths.word);
    addOutput('memPortBAddr', width: ParticleWidths.word);
    addOutput('memPortBWData', width: ParticleWidths.word);
    addOutput('memPortBBEn', width: ParticleWidths.byteEnable);
    addOutput('memPortBWEn');
    addOutput('memPortBREn');

    addOutput('mboxStrobeOut');
    addOutput('mboxVectorOut', width: ParticleWidths.trapVector);

    addOutput('fifoChanSelect', width: 2);
    addOutput('fifoPushData', width: ParticleWidths.word);
    addOutput('fifoPushEn');
    addOutput('fifoPopEn');

    addOutput('sarfRs1Addr', width: 5);
    addOutput('sarfRs2Addr', width: 5);
    addOutput('sarfRdAddr', width: 5);
    addOutput('sarfRdData', width: ParticleWidths.word);
    addOutput('sarfRdWe');

    _build();
  }

  void _build() {
    const int stateFetch = 0;
    const int stateExec = 1;
    const int stateWait = 2;

    final pc = Logic(name: 'pc', width: ParticleWidths.word);
    final nextPc = Logic(name: 'nextPc', width: ParticleWidths.word);
    final state = Logic(name: 'state', width: 2);

    final outMemBREn = Logic(name: 'outMemBREn');
    final outMemBWEn = Logic(name: 'outMemBWEn');
    final outMemBAddr = Logic(name: 'outMemBAddr', width: ParticleWidths.word);
    final outMemBWData = Logic(name: 'outMemBWData', width: ParticleWidths.word);
    final outMemBBEn = Logic(name: 'outMemBBEn', width: ParticleWidths.byteEnable);

    memPortAAddr <= pc;

    final inst = memPortARData;
    final opcode = inst.slice(15, 8);
    final rr = inst.slice(7, 4);
    final rl = inst.slice(3, 0);
    final imm4 = inst.slice(3, 0);
    final imm8 = inst.slice(7, 0);

    final imm4Val = imm4.zeroExtend(32);
    final negImm4Val = Const(0, width: 32) - imm4Val;
    final imm8Val = imm8.zeroExtend(32);
    final negImm8Val = Const(0, width: 32) - imm8Val;

    final rfWEn = Logic(name: 'rfWEn');
    final rfWAddr = Logic(name: 'rfWAddr', width: 4);
    final rfWData = Logic(name: 'rfWData', width: 32);
    final rfXchgEn = Logic(name: 'rfXchgEn');
    final rfXchgAllEn = Logic(name: 'rfXchgAllEn');
    final rfXchgMostEn = Logic(name: 'rfXchgMostEn');
    final rfXchgRegIdx = Logic(name: 'rfXchgRegIdx', width: 4);
    final rfRbaseEn = Logic(name: 'rfRbaseEn');
    final rfRbaseIn = Logic(name: 'rfRbaseIn', width: 5);

    final isPushAccum = opcode.eq(Const(ParticleOpcodes.push4, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.push8, width: 8));
    final effRAddrA = mux(isPushAccum, Const(14, width: 4), rr);

    final rf = RegisterFile(
      clk: clk,
      reset: reset,
      rAddrA: effRAddrA,
      rAddrB: rl,
      wAddr: rfWAddr,
      wData: rfWData,
      wEn: rfWEn,
      xchgEn: rfXchgEn,
      xchgAllEn: rfXchgAllEn,
      xchgMostEn: rfXchgMostEn,
      xchgRegIdx: rfXchgRegIdx,
      rbaseEn: rfRbaseEn,
      rbaseIn: rfRbaseIn,
    );

    final aluOp = Logic(name: 'aluOp', width: 5);
    final aluOperandB = Logic(name: 'aluOperandB', width: 32);

    Combinational([
      aluOp < Const(AluOps.add, width: 5),
      aluOperandB < rf.rDataB,
      Case(opcode, [
        // Arithmetic
        CaseItem(Const(ParticleOpcodes.add, width: 8),
            [aluOp < Const(AluOps.add, width: 5)]),
        CaseItem(Const(ParticleOpcodes.sub, width: 8),
            [aluOp < Const(AluOps.sub, width: 5)]),
        CaseItem(Const(ParticleOpcodes.addImm4, width: 8),
            [aluOp < Const(AluOps.add, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.subImm4, width: 8),
            [aluOp < Const(AluOps.sub, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.saddImm4, width: 8), [
          aluOp < Const(AluOps.add, width: 5),
          aluOperandB < imm4.signExtend(32)
        ]),
        CaseItem(Const(ParticleOpcodes.ssubImm4, width: 8), [
          aluOp < Const(AluOps.sub, width: 5),
          aluOperandB < imm4.signExtend(32)
        ]),

        // Logic & Inversions
        CaseItem(Const(ParticleOpcodes.notOp, width: 8),
            [aluOp < Const(AluOps.not, width: 5)]),
        CaseItem(Const(ParticleOpcodes.nezOp, width: 8),
            [aluOp < Const(AluOps.nez, width: 5)]),
        CaseItem(Const(ParticleOpcodes.andOp, width: 8),
            [aluOp < Const(AluOps.and, width: 5)]),
        CaseItem(Const(ParticleOpcodes.orOp, width: 8),
            [aluOp < Const(AluOps.or, width: 5)]),
        CaseItem(Const(ParticleOpcodes.xorOp, width: 8),
            [aluOp < Const(AluOps.xor, width: 5)]),
        CaseItem(Const(ParticleOpcodes.andImm4, width: 8),
            [aluOp < Const(AluOps.and, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.orImm4, width: 8),
            [aluOp < Const(AluOps.or, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.xorImm4, width: 8),
            [aluOp < Const(AluOps.xor, width: 5), aluOperandB < imm4Val]),

        // Shifts & Rotates
        CaseItem(Const(ParticleOpcodes.shiftL, width: 8),
            [aluOp < Const(AluOps.shiftl, width: 5)]),
        CaseItem(Const(ParticleOpcodes.shiftR, width: 8),
            [aluOp < Const(AluOps.shiftr, width: 5)]),
        CaseItem(Const(ParticleOpcodes.ashiftR, width: 8),
            [aluOp < Const(AluOps.ashiftr, width: 5)]),
        CaseItem(Const(ParticleOpcodes.rotL, width: 8),
            [aluOp < Const(AluOps.rotl, width: 5)]),
        CaseItem(Const(ParticleOpcodes.rotR, width: 8),
            [aluOp < Const(AluOps.rotr, width: 5)]),
        CaseItem(Const(ParticleOpcodes.shiftLImm4, width: 8),
            [aluOp < Const(AluOps.shiftl, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.shiftRImm4, width: 8),
            [aluOp < Const(AluOps.shiftr, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.ashiftRImm4, width: 8),
            [aluOp < Const(AluOps.ashiftr, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.rotLImm4, width: 8),
            [aluOp < Const(AluOps.rotl, width: 5), aluOperandB < imm4Val]),        // Shifts & Rotates Immediate
        CaseItem(Const(ParticleOpcodes.rotRImm4, width: 8),
            [aluOp < Const(AluOps.rotr, width: 5), aluOperandB < imm4Val]),

        // 4.6 Bit Manipulation & System Operations (0x80 - 0x8C)
        CaseItem(Const(ParticleOpcodes.bextr, width: 8),
            [aluOp < Const(AluOps.bextr, width: 5)]),
        CaseItem(Const(ParticleOpcodes.clz, width: 8),
            [aluOp < Const(AluOps.clz, width: 5)]),
        CaseItem(Const(ParticleOpcodes.bset, width: 8),
            [aluOp < Const(AluOps.bset, width: 5)]),
        CaseItem(Const(ParticleOpcodes.bsetImm4, width: 8),
            [aluOp < Const(AluOps.bset, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.bclr, width: 8),
            [aluOp < Const(AluOps.bclr, width: 5)]),
        CaseItem(Const(ParticleOpcodes.bclrImm4, width: 8),
            [aluOp < Const(AluOps.bclr, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.binv, width: 8),
            [aluOp < Const(AluOps.binv, width: 5)]),
        CaseItem(Const(ParticleOpcodes.binvImm4, width: 8),
            [aluOp < Const(AluOps.binv, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.bget, width: 8),
            [aluOp < Const(AluOps.bget, width: 5)]),
        CaseItem(Const(ParticleOpcodes.bgetImm4, width: 8),
            [aluOp < Const(AluOps.bget, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.rev32, width: 8),
            [aluOp < Const(AluOps.rev32, width: 5)]),

        // Relational Comparisons
        CaseItem(Const(ParticleOpcodes.slt, width: 8),
            [aluOp < Const(AluOps.slt, width: 5)]),
        CaseItem(Const(ParticleOpcodes.sltImm4, width: 8),
            [aluOp < Const(AluOps.slt, width: 5), aluOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.sltNegImm4, width: 8),
            [aluOp < Const(AluOps.slt, width: 5), aluOperandB < negImm4Val]),
        CaseItem(Const(ParticleOpcodes.sltR14Imm8, width: 8),
            [aluOp < Const(AluOps.slt, width: 5), aluOperandB < imm8Val]),
        CaseItem(Const(ParticleOpcodes.sltR14NegImm8, width: 8),
            [aluOp < Const(AluOps.slt, width: 5), aluOperandB < negImm8Val]),
        CaseItem(Const(ParticleOpcodes.sslt, width: 8),
            [aluOp < Const(AluOps.sslt, width: 5)]),
        CaseItem(Const(ParticleOpcodes.ssltImm4, width: 8), [
          aluOp < Const(AluOps.sslt, width: 5),
          aluOperandB < imm4.signExtend(32)
        ]),
        CaseItem(Const(ParticleOpcodes.ssltNegImm4, width: 8),
            [aluOp < Const(AluOps.sslt, width: 5), aluOperandB < negImm4Val]),
        CaseItem(Const(ParticleOpcodes.ssltR14Imm8, width: 8), [
          aluOp < Const(AluOps.sslt, width: 5),
          aluOperandB < imm8.signExtend(32)
        ]),
        CaseItem(Const(ParticleOpcodes.ssltR14NegImm8, width: 8),
            [aluOp < Const(AluOps.sslt, width: 5), aluOperandB < negImm8Val]),
      ]),
    ]);

    final alu = ParticleAlu(
      operandA: rf.rDataA,
      operandB: aluOperandB,
      aluOp: aluOp,
    );

    final mulMode = Logic(name: 'mulMode', width: 2);
    final mulOperandB = Logic(name: 'mulOperandB', width: 32);

    Combinational([
      mulMode < Const(0, width: 2),
      mulOperandB < rf.rDataB,
      Case(opcode, [
        CaseItem(Const(ParticleOpcodes.mull, width: 8),
            [mulMode < Const(0, width: 2)]),
        CaseItem(Const(ParticleOpcodes.mulh, width: 8),
            [mulMode < Const(1, width: 2)]),
        CaseItem(Const(ParticleOpcodes.smulh, width: 8),
            [mulMode < Const(2, width: 2)]),
        CaseItem(Const(ParticleOpcodes.mulhsu, width: 8),
            [mulMode < Const(3, width: 2)]),
        CaseItem(Const(ParticleOpcodes.mullImm4, width: 8),
            [mulMode < Const(0, width: 2), mulOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.mulhImm4, width: 8),
            [mulMode < Const(1, width: 2), mulOperandB < imm4Val]),
        CaseItem(Const(ParticleOpcodes.smulhImm4, width: 8),
            [mulMode < Const(2, width: 2), mulOperandB < imm4.signExtend(32)]),
        CaseItem(Const(ParticleOpcodes.mulhsuImm4, width: 8),
            [mulMode < Const(3, width: 2), mulOperandB < imm4Val]),
      ]),
    ]);

    final mul = ParticleMultiplier(
      operandA: rf.rDataA,
      operandB: mulOperandB,
      mulMode: mulMode,
    );

    memPortBAddr <= outMemBAddr;
    memPortBWData <= outMemBWData;
    memPortBBEn <= outMemBBEn;
    memPortBWEn <= outMemBWEn;
    memPortBREn <= outMemBREn;

    final isR14Dest = opcode.eq(Const(ParticleOpcodes.ldImm8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.ldNegImm8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.push4, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.push8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.sltR14Imm8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.sltR14NegImm8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.ssltR14Imm8, width: 8)) |
        opcode.eq(Const(ParticleOpcodes.ssltR14NegImm8, width: 8));

    rfWAddr <=
        mux(
          isR14Dest,
          Const(14, width: 4),
          mux(opcode.eq(Const(ParticleOpcodes.tas, width: 8)), rl, rr),
        );
    rfXchgRegIdx <= rr;

    // Out-of-Band SARF default port connections
    sarfRs1Addr <= rr.zeroExtend(5);
    sarfRs2Addr <= rl.zeroExtend(5);
    sarfRdAddr <= rr.zeroExtend(5);
    sarfRdData <= rf.rDataA;

    // Streaming FIFO default port connections
    fifoChanSelect <= rf.rDataB.slice(1, 0);
    fifoPushData <= rf.rDataA;
    mboxVectorOut <= rl.slice(3, 0);

    final inExec = state.eq(stateExec);

    final outMboxStrobe = Logic(name: 'outMboxStrobe');
    final outFifoPushEn = Logic(name: 'outFifoPushEn');
    final outFifoPopEn = Logic(name: 'outFifoPopEn');
    final outSarfRdWe = Logic(name: 'outSarfRdWe');

    final fifoEmpty = fifoStatus.slice(0, 0);
    final isFifoRead = opcode.eq(Const(ParticleOpcodes.fifoR, width: 8));
    final fifoReadStall = inExec & isFifoRead & fifoEmpty;

    mboxStrobeOut <= outMboxStrobe;
    fifoPushEn <= outFifoPushEn;
    fifoPopEn <= outFifoPopEn;
    sarfRdWe <= outSarfRdWe;

    Combinational([
      // Defaults
      rfWData < alu.result,
      rfWEn < Const(0),
      rfXchgEn < Const(0),
      rfXchgAllEn < Const(0),
      rfXchgMostEn < Const(0),
      rfRbaseEn < Const(0),
      rfRbaseIn < Const(0, width: 5),
      outMboxStrobe < Const(0),
      outFifoPushEn < Const(0),
      outFifoPopEn < Const(0),
      outSarfRdWe < Const(0),
      outMemBREn < Const(0),
      outMemBWEn < Const(0),
      outMemBAddr < rf.rDataB,
      outMemBWData < rf.rDataA,
      outMemBBEn < Const(0xF, width: 4),

      Case(opcode, [
        // Arithmetic
        CaseItem(Const(ParticleOpcodes.add, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.sub, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.addImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.subImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.saddImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.ssubImm4, width: 8), [rfWEn < inExec]),

        // Logic & Inversions
        CaseItem(Const(ParticleOpcodes.notOp, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.nezOp, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.andOp, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.orOp, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.xorOp, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.andImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.orImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.xorImm4, width: 8), [rfWEn < inExec]),

        // Shifts & Rotates
        CaseItem(Const(ParticleOpcodes.shiftL, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.shiftR, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.ashiftR, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rotL, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rotR, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.shiftLImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.shiftRImm4, width: 8), [rfWEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.ashiftRImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rotLImm4, width: 8), [rfWEn < inExec]),        CaseItem(Const(ParticleOpcodes.rotRImm4, width: 8), [rfWEn < inExec]),

        // 4.6 Bit Manipulation Writeback (0x80 - 0x8C)
        CaseItem(Const(ParticleOpcodes.bextr, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.clz, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bset, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bsetImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bclr, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bclrImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.binv, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.binvImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bget, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.bgetImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rev32, width: 8), [rfWEn < inExec]),

        // Multiplications
        CaseItem(Const(ParticleOpcodes.mull, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.mulh, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.smulh, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.mulhsu, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.mullImm4, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.mulhImm4, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.smulhImm4, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.mulhsuImm4, width: 8),
            [rfWData < mul.result, rfWEn < inExec]),

        // Relational Comparisons
        CaseItem(Const(ParticleOpcodes.slt, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.sltImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.sltNegImm4, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.sltR14Imm8, width: 8), [rfWEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.sltR14NegImm8, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.sslt, width: 8), [rfWEn < inExec]),
        CaseItem(Const(ParticleOpcodes.ssltImm4, width: 8), [rfWEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.ssltNegImm4, width: 8), [rfWEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.ssltR14Imm8, width: 8), [rfWEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.ssltR14NegImm8, width: 8), [rfWEn < inExec]),

        // Context Exchange & RBASE
        CaseItem(Const(ParticleOpcodes.xchg, width: 8), [rfXchgEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.xchgAll, width: 8), [rfXchgAllEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rbaseImm4, width: 8),
            [rfRbaseIn < imm8.slice(4, 0), rfRbaseEn < inExec]),
        CaseItem(Const(ParticleOpcodes.rbaseR, width: 8),
            [rfRbaseIn < rf.rDataA.slice(4, 0), rfRbaseEn < inExec]),
        CaseItem(
            Const(ParticleOpcodes.xchgMost, width: 8), [rfXchgMostEn < inExec]),

        // 4.1 Loads & Immediates (0x00 - 0x06)
        CaseItem(Const(ParticleOpcodes.ld, width: 8), [
          rfWData < rf.rDataB,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ldImm4, width: 8), [
          rfWData < imm4Val,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ldImm8, width: 8), [
          rfWData < imm8Val,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ldNegImm4, width: 8), [
          rfWData < negImm4Val,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ldNegImm8, width: 8), [
          rfWData < negImm8Val,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.push4, width: 8), [
          rfWData < ((rf.rDataA << 4) | imm4Val),
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.push8, width: 8), [
          rfWData < ((rf.rDataA << 8) | imm8Val),
          rfWEn < inExec,
        ]),

        // Memory Loads (Port B: Address in Rl/rDataB, Target in Rr/rfWData)
        CaseItem(Const(ParticleOpcodes.ld8, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData.slice(7, 0).zeroExtend(32),
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ld8PostInc, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData.slice(7, 0).zeroExtend(32),
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ld16, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData.slice(15, 0).zeroExtend(32),
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ld16PostInc, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData.slice(15, 0).zeroExtend(32),
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ld32, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.ld32PostInc, width: 8), [
          outMemBREn < inExec,
          rfWData < memPortBRData,
          rfWEn < inExec,
        ]),

        // Memory Stores (Port B: Address in Rr/rDataA, Data in Rl/rDataB matching pasm/psim)
        CaseItem(Const(ParticleOpcodes.st8, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0x1, width: 4),
        ]),
        CaseItem(Const(ParticleOpcodes.st8PostInc, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0x1, width: 4),
        ]),
        CaseItem(Const(ParticleOpcodes.st16, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0x3, width: 4),
        ]),
        CaseItem(Const(ParticleOpcodes.st16PostInc, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0x3, width: 4),
        ]),
        CaseItem(Const(ParticleOpcodes.st32, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0xF, width: 4),
        ]),
        // Atomic Test-And-Set / Swap: Old <- Mem32[Rr]; Mem32[Rr] <- Rl; Rl <- Old
        CaseItem(Const(ParticleOpcodes.tas, width: 8), [
          outMemBREn < inExec,
          outMemBWEn < inExec,
          outMemBBEn < Const(0xF, width: 4),
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          rfWData < memPortBRData,
          rfWEn < inExec,
        ]),

        CaseItem(Const(ParticleOpcodes.st32PostInc, width: 8), [
          outMemBWEn < inExec,
          outMemBAddr < rf.rDataA,
          outMemBWData < rf.rDataB,
          outMemBBEn < Const(0xF, width: 4),
        ]),

        // Hardware Streaming FIFOs & Mailbox
        CaseItem(Const(ParticleOpcodes.fifoR, width: 8), [
          rfWData < fifoPopData,
          rfWEn < inExec & ~fifoEmpty,
          outFifoPopEn < inExec & ~fifoEmpty,
        ]),
        CaseItem(Const(ParticleOpcodes.fifoTryR, width: 8), [
          rfWData <
              mux(fifoEmpty, Const(0, width: ParticleWidths.word), fifoPopData),
          rfWEn < inExec,
          outFifoPopEn < inExec & ~fifoEmpty,
        ]),
        CaseItem(Const(ParticleOpcodes.fifoW, width: 8), [
          outFifoPushEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.fifoStat, width: 8), [
          rfWData < fifoStatus,
          rfWEn < inExec,
        ]),
        CaseItem(Const(ParticleOpcodes.mbox, width: 8), [
          outMboxStrobe < inExec,
        ]),
      ]),
    ]);

    // Next PC & Branch / Table Jump Calculation
    final rValA = rf.rDataA;
    final isZero = rValA.eq(0);
    final isNegative = rValA.slice(31, 31).eq(1);
    final isPositive = (~isNegative) & (~isZero);
    final isNotZero = ~isZero;

    final dispImm4 = imm4.zeroExtend(32) << 1;
    final dispImm8 = imm8.zeroExtend(32) << 1;
    final signedRegDisp = (rValA.signExtend(32)) << 1;

    final branchNextPc = Logic(name: 'branchNextPc', width: 32);

    Combinational([
      Case(opcode, [
        CaseItem(Const(ParticleOpcodes.jtbl, width: 8), [
          branchNextPc < (pc + Const(2, width: 32) + (rValA << 1)),
        ]),
        CaseItem(Const(ParticleOpcodes.branch, width: 8), [
          branchNextPc < (pc + signedRegDisp),
        ]),
        CaseItem(Const(ParticleOpcodes.fbraImm8, width: 8), [
          branchNextPc < (pc + dispImm8),
        ]),
        CaseItem(Const(ParticleOpcodes.bbraImm8, width: 8), [
          branchNextPc < (pc - dispImm8),
        ]),
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
        CaseItem(Const(ParticleOpcodes.jmp, width: 8), [
          branchNextPc < rValA,
        ]),
        CaseItem(Const(ParticleOpcodes.rjump, width: 8), [
          branchNextPc < (pc + signedRegDisp),
        ]),
      ], defaultItem: [
        branchNextPc < pc + 2,
      ]),
    ]);

    final mboxTargetAddr = Const(config.trapTableBase, width: 32) +
        (mboxVectorIn.zeroExtend(32) << 6);

    nextPc <= mux(mboxStrobeIn, mboxTargetAddr, branchNextPc);

    Sequential(clk, reset: reset, resetValues: {
      pc: Const(config.trapTableBase, width: 32),
      state: Const(stateFetch, width: 2),
    }, [
      If(mboxStrobeIn, then: [
        pc < mboxTargetAddr,
        state < Const(stateFetch, width: 2),
      ], orElse: [
        Case(state, [
          CaseItem(Const(stateFetch, width: 2), [
            state < Const(stateExec, width: 2),
          ]),
          CaseItem(Const(stateExec, width: 2), [
            If(fifoReadStall, then: [
              pc < pc,
              state < Const(stateExec, width: 2),
            ], orElse: [
              pc < nextPc,
              state < Const(stateFetch, width: 2),
            ]),
          ]),
          CaseItem(Const(stateWait, width: 2), []),
        ]),
      ]),
    ]);
  }
}
