// =============================================================================
// File: hdl/particle/lib/cpu_core.dart
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
  Logic get mboxDataIn => input('mboxDataIn');

  // Cross-Core Outbound Mailbox Strobe and Vector
  Logic get mboxStrobeOut => output('mboxStrobeOut');
  Logic get mboxVectorOut => output('mboxVectorOut');
  Logic get mboxDataOut => output('mboxDataOut');

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

  /// The register file, and the PC of the instruction in the execute stage
  /// (valid when [execValid] is high), for tests and debugging.
  late final RegisterFile registerFile;
  late final Logic pcReg;
  late final Logic execValid;

  ParticleCpuCore({
    required Logic clk,
    required Logic reset,
    required Logic memPortARData,
    required Logic memPortBRData,
    required Logic mboxStrobeIn,
    required Logic mboxVectorIn,
    Logic? mboxDataIn,
    Logic? fifoPopData,
    Logic? fifoStatus,
    Logic? sarfRs1Data,
    Logic? sarfRs2Data,
    this.config = const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 16),
    super.name = 'particle_cpu_core',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('memPortARData', memPortARData, width: ParticleWidths.inst);
    addInput('memPortBRData', memPortBRData, width: ParticleWidths.word);
    addInput('mboxStrobeIn', mboxStrobeIn);
    addInput('mboxVectorIn', mboxVectorIn, width: ParticleWidths.trapVector);
    addInput('mboxDataIn', mboxDataIn ?? Const(0, width: ParticleWidths.word),
        width: ParticleWidths.word);

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
    addOutput('mboxDataOut', width: ParticleWidths.word);

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
    // -------------------------------------------------------------------------
    // Pipeline. Memory is synchronous: an address presented in one cycle gives
    // its data in the next.
    //   F  presents the fetch address (memPortAAddr)
    //   I  the instruction arrives (memPortARData) and is latched into D
    //   D  decode and register read; PC-relative branches that can be decided
    //      here (no register still being written) redirect the fetch
    //   E  execute, with the operands forwarded from the last cycle's writes;
    //      register writes; traps, MBOX, jumps and the other branches redirect
    //   W  a load's (or TAS's) data arrives and is written (E is empty then)
    // -------------------------------------------------------------------------
    final trapBase = config.trapTableBase;
    final strideShift = (config.trapStrideBytes - 1).bitLength;
    if (config.trapStrideBytes != 1 << strideShift) {
      throw ArgumentError('trapStrideBytes must be a power of two');
    }
    Logic vectorAddr(Logic vec) =>
        Const(trapBase, width: 32) + (vec.zeroExtend(32) << strideShift);

    // F / I: the address presented last cycle, whose data arrives now
    final fPc = Logic(name: 'fPc', width: 32);
    final fValid = Logic(name: 'fValid');
    // D
    final dValid = Logic(name: 'dValid');
    final dPc = Logic(name: 'dPc', width: 32);
    final dInst = Logic(name: 'dInst', width: 16);
    // E
    final eValid = Logic(name: 'eValid');
    final ePc = Logic(name: 'ePc', width: 32);
    final eInst = Logic(name: 'eInst', width: 16);
    final eA = Logic(name: 'eA', width: 32); // operand A as read in D
    final eB = Logic(name: 'eB', width: 32); // operand B as read in D
    final eAsrc = Logic(name: 'eAsrc', width: 4); // their registers
    final eBsrc = Logic(name: 'eBsrc', width: 4);
    final eImm16 = Logic(name: 'eImm16', width: 16); // LDI/LDIS immediate
    final eResolved = Logic(name: 'eResolved'); // a branch D already decided
    final eDivStarted = Logic(name: 'eDivStarted');
    // The last cycle's register writes, for forwarding (port 2 wins). Whether
    // E's operands are one of them is worked out a cycle early, when the
    // writes are made, so E only selects.
    final fw1D = Logic(name: 'fw1D', width: 32);
    final fw2D = Logic(name: 'fw2D', width: 32);
    final eFa1 = Logic(name: 'eFa1'); // operand A is fw1D
    final eFa2 = Logic(name: 'eFa2'); // operand A is fw2D
    final eFb1 = Logic(name: 'eFb1');
    final eFb2 = Logic(name: 'eFb2');
    // W
    final lValid = Logic(name: 'lValid');
    final lIsMul = Logic(name: 'lIsMul'); // W writes a MUL's result

    pcReg = ePc;
    execValid = eValid;

    // -------------------------------------------------------------------------
    // D: decode, register read
    // -------------------------------------------------------------------------
    final dOpcode = dInst.slice(15, 8);
    final dRr = dInst.slice(7, 4);
    final dRl = dInst.slice(3, 0);
    Logic dOp(int code) => dOpcode.eq(Const(code, width: 8));
    Logic dAnyOp(List<int> codes) => codes.map(dOp).reduce((a, b) => a | b);

    final dReadsR14 = dAnyOp([
      ParticleOpcodes.push8,
      ParticleOpcodes.sltR14Imm8,
      ParticleOpcodes.sltR14NegImm8,
      ParticleOpcodes.ssltR14Imm8,
      ParticleOpcodes.ssltR14NegImm8,
      ParticleOpcodes.fbraZImm8,
      ParticleOpcodes.fbraNImm8,
      ParticleOpcodes.fbraPImm8,
      ParticleOpcodes.fbraNZImm8,
      ParticleOpcodes.bbraZImm8,
      ParticleOpcodes.bbraNImm8,
      ParticleOpcodes.bbraPImm8,
      ParticleOpcodes.bbraNZImm8,
    ]);
    final rAddrA = mux(dReadsR14, Const(14, width: 4), dRr);

    final rfWEn = Logic(name: 'rfWEn');
    final rfWAddr = Logic(name: 'rfWAddr', width: 4);
    final rfWData = Logic(name: 'rfWData', width: 32);
    final rfWEn2 = Logic(name: 'rfWEn2');
    final rfWAddr2 = Logic(name: 'rfWAddr2', width: 4);
    final rfWData2 = Logic(name: 'rfWData2', width: 32);
    final rfXchgEn = Logic(name: 'rfXchgEn');
    final rfXchgAllEn = Logic(name: 'rfXchgAllEn');
    final rfXchgMostEn = Logic(name: 'rfXchgMostEn');

    final inst = eInst;
    final pc = ePc;
    final opcode = inst.slice(15, 8);
    final rr = inst.slice(7, 4);
    final rl = inst.slice(3, 0);
    final imm4 = inst.slice(3, 0);
    final imm8 = inst.slice(7, 0);
    final imm4Val = imm4.zeroExtend(32);
    final imm4SVal = imm4.signExtend(32);
    final negImm4Val = Const(0, width: 32) - imm4Val;
    final imm8Val = imm8.zeroExtend(32);
    final negImm8Val = Const(0, width: 32) - imm8Val;

    Logic op(int code) => opcode.eq(Const(code, width: 8));
    Logic anyOp(List<int> codes) =>
        codes.map(op).reduce((a, b) => a | b);

    final rf = RegisterFile(
      clk: clk,
      reset: reset,
      rAddrA: rAddrA,
      rAddrB: dRl,
      wAddr: rfWAddr,
      wData: rfWData,
      wEn: rfWEn,
      wAddr2: rfWAddr2,
      wData2: rfWData2,
      wEn2: rfWEn2,
      xchgEn: rfXchgEn,
      xchgAllEn: rfXchgAllEn,
      xchgMostEn: rfXchgMostEn,
      xchgRegIdx: rr,
    );
    registerFile = rf;
    // The core stays in reset while the register file clears its LUT RAM
    final coreReset = reset | rf.clearing;
    final dValA = rf.rDataA;
    final dValB = rf.rDataB;

    // -------------------------------------------------------------------------
    // E: operands, forwarded from the writes D's read didn't see (the last
    // cycle's; R0 is never forwarded)
    // -------------------------------------------------------------------------
    final valA = mux(eFa2, fw2D, mux(eFa1, fw1D, eA));
    final valB = mux(eFb2, fw2D, mux(eFb1, fw1D, eB));

    // -------------------------------------------------------------------------
    // ALU
    // -------------------------------------------------------------------------
    final aluOp = Logic(name: 'aluOp', width: 5);
    final aluOperandA = mux(op(ParticleOpcodes.clz), valB, valA);
    final aluOperandB = Logic(name: 'aluOperandB', width: 32);

    CaseItem alu(int code, int aluCode, [Logic? operandB]) =>
        CaseItem(Const(code, width: 8), [
          aluOp < Const(aluCode, width: 5),
          if (operandB != null) aluOperandB < operandB,
        ]);

    Combinational([
      aluOp < Const(AluOps.add, width: 5),
      aluOperandB < valB,
      Case(opcode, [
        alu(ParticleOpcodes.add, AluOps.add),
        alu(ParticleOpcodes.sub, AluOps.sub),
        alu(ParticleOpcodes.addImm4, AluOps.add, imm4Val),
        alu(ParticleOpcodes.subImm4, AluOps.sub, imm4Val),
        alu(ParticleOpcodes.neg, AluOps.neg),
        alu(ParticleOpcodes.sadd, AluOps.add),
        alu(ParticleOpcodes.ssub, AluOps.sub),
        alu(ParticleOpcodes.saddImm4, AluOps.add, imm4SVal),
        alu(ParticleOpcodes.ssubImm4, AluOps.sub, imm4SVal),
        alu(ParticleOpcodes.notOp, AluOps.not),
        alu(ParticleOpcodes.nezOp, AluOps.nez),
        alu(ParticleOpcodes.andOp, AluOps.and),
        alu(ParticleOpcodes.orOp, AluOps.or),
        alu(ParticleOpcodes.xorOp, AluOps.xor),
        alu(ParticleOpcodes.andImm4, AluOps.and, imm4Val),
        alu(ParticleOpcodes.orImm4, AluOps.or, imm4Val),
        alu(ParticleOpcodes.xorImm4, AluOps.xor, imm4Val),
        alu(ParticleOpcodes.shiftL, AluOps.shiftl),
        alu(ParticleOpcodes.shiftR, AluOps.shiftr),
        alu(ParticleOpcodes.ashiftR, AluOps.ashiftr),
        alu(ParticleOpcodes.rotL, AluOps.rotl),
        alu(ParticleOpcodes.rotR, AluOps.rotr),
        alu(ParticleOpcodes.shiftLImm4, AluOps.shiftl, imm4Val),
        alu(ParticleOpcodes.shiftRImm4, AluOps.shiftr, imm4Val),
        alu(ParticleOpcodes.ashiftRImm4, AluOps.ashiftr, imm4Val),
        alu(ParticleOpcodes.rotLImm4, AluOps.rotl, imm4Val),
        alu(ParticleOpcodes.rotRImm4, AluOps.rotr, imm4Val),
        alu(ParticleOpcodes.sext8, AluOps.sext8),
        alu(ParticleOpcodes.sext16, AluOps.sext16),
        alu(ParticleOpcodes.bextr, AluOps.bextr),
        alu(ParticleOpcodes.clz, AluOps.clz),
        alu(ParticleOpcodes.bset, AluOps.bset),
        alu(ParticleOpcodes.bsetImm4, AluOps.bset, imm4Val),
        alu(ParticleOpcodes.bclr, AluOps.bclr),
        alu(ParticleOpcodes.bclrImm4, AluOps.bclr, imm4Val),
        alu(ParticleOpcodes.binv, AluOps.binv),
        alu(ParticleOpcodes.binvImm4, AluOps.binv, imm4Val),
        alu(ParticleOpcodes.bget, AluOps.bget),
        alu(ParticleOpcodes.bgetImm4, AluOps.bget, imm4Val),
        alu(ParticleOpcodes.rev32, AluOps.rev32),
        alu(ParticleOpcodes.slt, AluOps.slt),
        alu(ParticleOpcodes.sltImm4, AluOps.slt, imm4Val),
        alu(ParticleOpcodes.sltNegImm4, AluOps.slt, negImm4Val),
        alu(ParticleOpcodes.sltR14Imm8, AluOps.slt, imm8Val),
        alu(ParticleOpcodes.sltR14NegImm8, AluOps.slt, negImm8Val),
        alu(ParticleOpcodes.sslt, AluOps.sslt),
        alu(ParticleOpcodes.ssltImm4, AluOps.sslt, imm4SVal),
        alu(ParticleOpcodes.ssltNegImm4, AluOps.sslt, negImm4Val),
        alu(ParticleOpcodes.ssltR14Imm8, AluOps.sslt, imm8.signExtend(32)),
        alu(ParticleOpcodes.ssltR14NegImm8, AluOps.sslt, negImm8Val),
        alu(ParticleOpcodes.seq, AluOps.seq),
        alu(ParticleOpcodes.sne, AluOps.sne),
        alu(ParticleOpcodes.sle, AluOps.sle),
        alu(ParticleOpcodes.ssle, AluOps.ssle),
      ]),
    ]);

    final aluUnit = ParticleAlu(
      operandA: aluOperandA,
      operandB: aluOperandB,
      aluOp: aluOp,
    );

    // Ops whose result is the ALU result, written to Rr (or R14)
    final aluWritesRr = anyOp([
      ParticleOpcodes.add, ParticleOpcodes.sub, ParticleOpcodes.addImm4,
      ParticleOpcodes.subImm4, ParticleOpcodes.neg, ParticleOpcodes.sadd,
      ParticleOpcodes.ssub, ParticleOpcodes.saddImm4, ParticleOpcodes.ssubImm4,
      ParticleOpcodes.notOp, ParticleOpcodes.nezOp, ParticleOpcodes.andOp,
      ParticleOpcodes.orOp, ParticleOpcodes.xorOp, ParticleOpcodes.andImm4,
      ParticleOpcodes.orImm4, ParticleOpcodes.xorImm4, ParticleOpcodes.shiftL,
      ParticleOpcodes.shiftR, ParticleOpcodes.ashiftR, ParticleOpcodes.rotL,
      ParticleOpcodes.rotR, ParticleOpcodes.shiftLImm4,
      ParticleOpcodes.shiftRImm4, ParticleOpcodes.ashiftRImm4,
      ParticleOpcodes.rotLImm4, ParticleOpcodes.rotRImm4, ParticleOpcodes.sext8,
      ParticleOpcodes.sext16, ParticleOpcodes.bextr, ParticleOpcodes.clz,
      ParticleOpcodes.bset, ParticleOpcodes.bsetImm4, ParticleOpcodes.bclr,
      ParticleOpcodes.bclrImm4, ParticleOpcodes.binv, ParticleOpcodes.binvImm4,
      ParticleOpcodes.bget, ParticleOpcodes.bgetImm4, ParticleOpcodes.rev32,
      ParticleOpcodes.slt, ParticleOpcodes.sltImm4, ParticleOpcodes.sltNegImm4,
      ParticleOpcodes.sslt, ParticleOpcodes.ssltImm4,
      ParticleOpcodes.ssltNegImm4, ParticleOpcodes.seq, ParticleOpcodes.sne,
      ParticleOpcodes.sle, ParticleOpcodes.ssle,
    ]);
    final aluWritesR14 = anyOp([
      ParticleOpcodes.sltR14Imm8, ParticleOpcodes.sltR14NegImm8,
      ParticleOpcodes.ssltR14Imm8, ParticleOpcodes.ssltR14NegImm8,
    ]);

    // -------------------------------------------------------------------------
    // Multiplier (when enabled)
    // -------------------------------------------------------------------------
    const mulOps = [
      ParticleOpcodes.mull, ParticleOpcodes.mulh, ParticleOpcodes.smulh,
      ParticleOpcodes.mulhsu, ParticleOpcodes.mullImm4,
      ParticleOpcodes.mulhImm4, ParticleOpcodes.smulhImm4,
      ParticleOpcodes.mulhsuImm4,
    ];
    final isMulOp = anyOp(mulOps);
    Logic mulResult = Const(0, width: 32);
    if (config.enableMultiplier) {
      final mulMode = Logic(name: 'mulMode', width: 2);
      final mulOperandB = Logic(name: 'mulOperandB', width: 32);
      Combinational([
        mulMode < Const(0, width: 2),
        mulOperandB < valB,
        Case(opcode, [
          CaseItem(Const(ParticleOpcodes.mulh, width: 8),
              [mulMode < Const(1, width: 2)]),
          CaseItem(Const(ParticleOpcodes.smulh, width: 8),
              [mulMode < Const(2, width: 2)]),
          CaseItem(Const(ParticleOpcodes.mulhsu, width: 8),
              [mulMode < Const(3, width: 2)]),
          CaseItem(Const(ParticleOpcodes.mullImm4, width: 8),
              [mulOperandB < imm4Val]),
          CaseItem(Const(ParticleOpcodes.mulhImm4, width: 8),
              [mulMode < Const(1, width: 2), mulOperandB < imm4Val]),
          CaseItem(Const(ParticleOpcodes.smulhImm4, width: 8),
              [mulMode < Const(2, width: 2), mulOperandB < imm4SVal]),
          CaseItem(Const(ParticleOpcodes.mulhsuImm4, width: 8),
              [mulMode < Const(3, width: 2), mulOperandB < imm4Val]),
        ]),
      ]);
      // MUL takes two cycles: E latches the operands, and the next cycle (W,
      // with E empty) multiplies and writes
      final mulA = Logic(name: 'mulA', width: 32);
      final mulB = Logic(name: 'mulB', width: 32);
      final mulModeReg = Logic(name: 'mulModeReg', width: 2);
      Sequential(clk, reset: coreReset, resetValues: {
        mulA: Const(0, width: 32),
        mulB: Const(0, width: 32),
        mulModeReg: Const(0, width: 2),
      }, [
        If(isMulOp, then: [
          mulA < valA,
          mulB < mulOperandB,
          mulModeReg < mulMode,
        ]),
      ]);
      mulResult = ParticleMultiplier(
        operandA: mulA,
        operandB: mulB,
        mulMode: mulModeReg,
      ).result;
    }

    // -------------------------------------------------------------------------
    // Divider (when enabled)
    // -------------------------------------------------------------------------
    const divOps = [
      ParticleOpcodes.div, ParticleOpcodes.mod, ParticleOpcodes.divImm4,
      ParticleOpcodes.modImm4, ParticleOpcodes.sdiv, ParticleOpcodes.smod,
      ParticleOpcodes.sdivImm4, ParticleOpcodes.smodImm4,
    ];
    final isDivOp = anyOp(divOps);
    final isRemOp = anyOp([
      ParticleOpcodes.mod, ParticleOpcodes.modImm4,
      ParticleOpcodes.smod, ParticleOpcodes.smodImm4,
    ]);
    final divStart = Logic(name: 'divStart');
    final divAbort = Logic(name: 'divAbort');
    Logic divDone = Const(0);
    Logic divResult = Const(0, width: 32);
    if (config.enableDivider) {
      final isSignedDiv = anyOp([
        ParticleOpcodes.sdiv, ParticleOpcodes.smod,
        ParticleOpcodes.sdivImm4, ParticleOpcodes.smodImm4,
      ]);
      final divisor = mux(
        anyOp([ParticleOpcodes.divImm4, ParticleOpcodes.modImm4]),
        imm4Val,
        mux(anyOp([ParticleOpcodes.sdivImm4, ParticleOpcodes.smodImm4]),
            imm4SVal, valB),
      );
      final divider = ParticleDivider(
        clk: clk,
        reset: coreReset,
        start: divStart,
        abort: divAbort,
        isSigned: isSignedDiv,
        dividend: valA,
        divisor: divisor,
      );
      divDone = divider.done;
      divResult = mux(isRemOp, divider.remainder, divider.quotient);
    }

    // -------------------------------------------------------------------------
    // Loads and stores
    // -------------------------------------------------------------------------
    final group = opcode.slice(7, 4);
    final mode = opcode.slice(3, 0);
    final isMemGroup = group.eq(Const(1, width: 4)) |
        group.eq(Const(2, width: 4)) |
        group.eq(Const(3, width: 4));
    final isLoadOp = isMemGroup & mode.lte(Const(4, width: 4));
    final isStoreOp = isMemGroup &
        mode.gte(Const(5, width: 4)) &
        mode.lte(Const(9, width: 4));
    final isTas = op(ParticleOpcodes.tas);
    // Size in bytes: 1, 2 or 4
    final size = mux(group.eq(Const(1, width: 4)), Const(1, width: 32),
        mux(group.eq(Const(2, width: 4)), Const(2, width: 32), Const(4, width: 32)));
    // Load modes 1..4 and store modes 6..9 change the pointer register
    final modeOfs = mux(isStoreOp, mode - Const(5, width: 4), mode);
    final ptrMode = (isLoadOp | isStoreOp) & ~modeOfs.eq(Const(0, width: 4));
    final preMode = modeOfs.eq(Const(1, width: 4)) | modeOfs.eq(Const(3, width: 4));
    final incMode = modeOfs.eq(Const(1, width: 4)) | modeOfs.eq(Const(2, width: 4));
    final ptrVal = mux(isStoreOp, valA, valB); // loads: (Rl); stores: (Rr)
    final ptrReg = mux(isStoreOp, rr, rl);
    // One adder for both directions
    final newPtr = ptrVal + mux(incMode, size, Const(0, width: 32) - size);
    final effAddr = mux(isTas, valA, mux(preMode, newPtr, ptrVal));
    // A store through its own pointer (Rr == Rl) stores the updated pointer
    final storeVal = mux(ptrMode & rr.eq(rl), newPtr, valB);
    final isSize2 = group.eq(Const(2, width: 4));
    final isSize4 = group.eq(Const(3, width: 4)) | isTas;
    final memAccess = isLoadOp | isStoreOp | isTas;
    final misaligned = memAccess &
        ((isSize2 & effAddr.slice(0, 0).eq(1)) |
            (isSize4 & ~effAddr.slice(1, 0).eq(Const(0, width: 2))));

    final storeBEn = Logic(name: 'storeBEn', width: 4);
    final storeWData = Logic(name: 'storeWData', width: 32);
    Combinational([
      If(isSize4, then: [
        storeBEn < Const(0xF, width: 4),
        storeWData < mux(isTas, valB, storeVal),
      ], orElse: [
        If(isSize2, then: [
          storeBEn < mux(effAddr.slice(1, 1).eq(1), Const(0xC, width: 4),
              Const(0x3, width: 4)),
          storeWData <
              [storeVal.slice(15, 0), storeVal.slice(15, 0)].swizzle(),
        ], orElse: [
          storeBEn < (Const(1, width: 4) << effAddr.slice(1, 0)),
          storeWData < [
            storeVal.slice(7, 0),
            storeVal.slice(7, 0),
            storeVal.slice(7, 0),
            storeVal.slice(7, 0),
          ].swizzle(),
        ]),
      ]),
    ]);

    // W: latched for the cycle the load data arrives (the cycle after E)
    final ldDest = Logic(name: 'ldDest', width: 4);
    final ldSizeCode = Logic(name: 'ldSizeCode', width: 2); // 0: 8, 1: 16, 2: 32
    final ldLow = Logic(name: 'ldLow', width: 2);
    final ldData = Logic(name: 'ldData', width: 32);
    Combinational([
      If(ldSizeCode.eq(Const(2, width: 2)), then: [
        ldData < memPortBRData,
      ], orElse: [
        If(ldSizeCode.eq(Const(1, width: 2)), then: [
          ldData < mux(ldLow.slice(1, 1).eq(1), memPortBRData.slice(31, 16),
                  memPortBRData.slice(15, 0))
              .zeroExtend(32),
        ], orElse: [
          Case(ldLow, [
            CaseItem(Const(0, width: 2),
                [ldData < memPortBRData.slice(7, 0).zeroExtend(32)]),
            CaseItem(Const(1, width: 2),
                [ldData < memPortBRData.slice(15, 8).zeroExtend(32)]),
            CaseItem(Const(2, width: 2),
                [ldData < memPortBRData.slice(23, 16).zeroExtend(32)]),
            CaseItem(Const(3, width: 2),
                [ldData < memPortBRData.slice(31, 24).zeroExtend(32)]),
          ]),
        ]),
      ]),
    ]);

    // -------------------------------------------------------------------------
    // Branches, jumps and the next PC
    // -------------------------------------------------------------------------
    final isZero = valA.eq(0);
    final isNegative = valA.slice(31, 31).eq(1);
    final isPositive = ~isNegative & ~isZero;
    final isNotZero = ~isZero;
    final pcPlus2 = pc + Const(2, width: 32);

    final branchNextPc = Logic(name: 'branchNextPc', width: 32);
    final branchTaken = Logic(name: 'branchTaken');
    // One adder for every PC-relative target, on halfwords:
    // pc/2 + offset (+1 for JTBL), or pc/2 - offset for the backward forms
    final brOffset = Logic(name: 'brOffset', width: 31);
    final brBack = Logic(name: 'brBack');
    final brCarry = Logic(name: 'brCarry');
    final brAbs = Logic(name: 'brAbs'); // JMP: the target is Ra
    final brCond = Logic(name: 'brCond');
    CaseItem br(int code, Logic offset,
            {bool back = false, Logic? cond, bool carry = false}) =>
        CaseItem(Const(code, width: 8), [
          brOffset < offset.getRange(0, 31),
          brBack < Const(back ? 1 : 0),
          brCarry < Const(back || carry ? 1 : 0),
          brCond < (cond ?? Const(1)),
          brAbs < Const(0),
        ]);
    final o4 = imm4Val, o8 = imm8Val;
    Combinational([
      brOffset < Const(0, width: 31),
      brBack < Const(0),
      brCarry < Const(0),
      brCond < Const(0),
      brAbs < Const(0),
      Case(opcode, [
        br(ParticleOpcodes.jtbl, valA, carry: true),
        br(ParticleOpcodes.branch, valA),
        CaseItem(Const(ParticleOpcodes.jmp, width: 8),
            [brCond < Const(1), brAbs < Const(1)]),
        br(ParticleOpcodes.rjump, valA),
        br(ParticleOpcodes.fbraImm8, o8),
        br(ParticleOpcodes.bbraImm8, o8, back: true),
        br(ParticleOpcodes.fbraZR, valB, cond: isZero),
        br(ParticleOpcodes.fbraNR, valB, cond: isNegative),
        br(ParticleOpcodes.fbraPR, valB, cond: isPositive),
        br(ParticleOpcodes.bbraZR, valB, back: true, cond: isZero),
        br(ParticleOpcodes.bbraNR, valB, back: true, cond: isNegative),
        br(ParticleOpcodes.bbraPR, valB, back: true, cond: isPositive),
        br(ParticleOpcodes.fbraZImm4, o4, cond: isZero),
        br(ParticleOpcodes.fbraNImm4, o4, cond: isNegative),
        br(ParticleOpcodes.fbraPImm4, o4, cond: isPositive),
        br(ParticleOpcodes.fbraNZImm4, o4, cond: isNotZero),
        br(ParticleOpcodes.fbraZImm8, o8, cond: isZero),
        br(ParticleOpcodes.fbraNImm8, o8, cond: isNegative),
        br(ParticleOpcodes.fbraPImm8, o8, cond: isPositive),
        br(ParticleOpcodes.fbraNZImm8, o8, cond: isNotZero),
        br(ParticleOpcodes.bbraZImm4, o4, back: true, cond: isZero),
        br(ParticleOpcodes.bbraNImm4, o4, back: true, cond: isNegative),
        br(ParticleOpcodes.bbraPImm4, o4, back: true, cond: isPositive),
        br(ParticleOpcodes.bbraNZImm4, o4, back: true, cond: isNotZero),
        br(ParticleOpcodes.bbraZImm8, o8, back: true, cond: isZero),
        br(ParticleOpcodes.bbraNImm8, o8, back: true, cond: isNegative),
        br(ParticleOpcodes.bbraPImm8, o8, back: true, cond: isPositive),
        br(ParticleOpcodes.bbraNZImm8, o8, back: true, cond: isNotZero),
      ]),
    ]);
    // {0, pc/2, 1} + {0, offset ^ back, carry}: the low bit carries the 1
    final brSum = Logic(name: 'brSum', width: 33);
    brSum <=
        [Const(0), pc.getRange(1, 32), Const(1)].swizzle() +
            [Const(0), brOffset ^ brBack.replicate(31), brCarry].swizzle();
    final relTarget = [brSum.getRange(1, 32), pc[0]].swizzle();
    branchTaken <= brCond;
    branchNextPc <= mux(brCond, mux(brAbs, valA, relTarget), pcPlus2);

    // -------------------------------------------------------------------------
    // Traps and interrupts
    // -------------------------------------------------------------------------
    final validOpcode = anyOp([
      for (final code in ParticleOpcodes.all)
        if ((config.enableMultiplier || !mulOps.contains(code)) &&
            (config.enableDivider || !divOps.contains(code)))
          code,
    ]);
    final illegal = ~validOpcode;
    final isTrapInstr =
        anyOp([ParticleOpcodes.trapR, ParticleOpcodes.trapImm4]);
    final trapVec =
        mux(op(ParticleOpcodes.trapR), valA.slice(3, 0), imm4);
    final isLdi = anyOp([ParticleOpcodes.ldi, ParticleOpcodes.ldis]);

    // An MBOX strobe is held until the core can take it: when an instruction
    // is in E and hasn't run yet (it runs again after the handler returns),
    // or while a divide is in progress
    final mboxPending = Logic(name: 'mboxPending');
    final mboxPendingVec = Logic(name: 'mboxPendingVec', width: 4);
    // The sender's Rr: stored at MBOX_VALUE (the word below the trap table)
    // in the trap-entry cycle, which makes no other memory access
    final mboxPendingData =
        Logic(name: 'mboxPendingData', width: ParticleWidths.word);
    final mboxValueAddr = Const(config.trapTableBase - 4, width: 32);
    final divWaiting = eValid & eDivStarted;
    final mboxTake = mboxPending & eValid;
    final mboxTarget = vectorAddr(mboxPendingVec);

    final fifoEmpty = fifoStatus.slice(0, 0);
    final fifoFull = fifoStatus.slice(1, 1);
    final fifoReadStall = op(ParticleOpcodes.fifoR) & fifoEmpty;

    // In E: nothing happens if the MBOX is taken, the opcode is illegal, the
    // access is misaligned or the instruction is a TRAP
    final execRuns = eValid & ~eDivStarted & ~mboxTake;
    final faultIllegal = execRuns & illegal;
    final faultAlign = execRuns & ~illegal & misaligned;
    final trapInstr = execRuns & ~illegal & isTrapInstr;
    final doExec = execRuns & ~illegal & ~misaligned & ~isTrapInstr;
    // A branch or jump E decides (D decided the others)
    final ctlTaken = doExec & ~eResolved & branchTaken;
    // A branch or jump to an odd address runs (a JMP still links) and then
    // takes vector 14, with R14 = the odd target
    final oddTarget = ctlTaken & branchNextPc.slice(0, 0).eq(1);
    // These swap register values behind the operands D has already read:
    // what follows is fetched again
    final isSerialize = anyOp([
      ParticleOpcodes.xchg, ParticleOpcodes.xchgAll, ParticleOpcodes.xchgMost,
    ]);

    final vec14 = Const(trapBase + 14 * config.trapStrideBytes, width: 32);
    final vec15 = Const(trapBase + 15 * config.trapStrideBytes, width: 32);

    // -------------------------------------------------------------------------
    // Register file write ports
    // -------------------------------------------------------------------------
    final imm16Extended = mux(op(ParticleOpcodes.ldis),
        eImm16.signExtend(32), eImm16.zeroExtend(32));

    Combinational([
      // Port 1: an instruction's result, or a load's data in W
      rfWEn < Const(0),
      rfWAddr < rr,
      rfWData < aluUnit.result,
      If(lValid, then: [
        rfWEn < Const(1),
        rfWAddr < ldDest,
        rfWData < mux(lIsMul, mulResult, ldData),
      ]),
      If(divWaiting & divDone & ~mboxTake, then: [
        rfWEn < Const(1),
        rfWAddr < rr,
        rfWData < divResult,
      ]),
      If(doExec, then: [
        If(aluWritesRr, then: [rfWEn < Const(1)]),
        If(aluWritesR14, then: [rfWEn < Const(1), rfWAddr < Const(14, width: 4)]),
        If(isLdi, then: [
          rfWEn < Const(1),
          rfWAddr < rl,
          rfWData < imm16Extended,
        ]),
        Case(opcode, [
          CaseItem(Const(ParticleOpcodes.ld, width: 8),
              [rfWEn < Const(1), rfWData < valB]),
          CaseItem(Const(ParticleOpcodes.ldImm4, width: 8),
              [rfWEn < Const(1), rfWData < imm4Val]),
          CaseItem(Const(ParticleOpcodes.ldNegImm4, width: 8),
              [rfWEn < Const(1), rfWData < negImm4Val]),
          CaseItem(Const(ParticleOpcodes.ldImm8, width: 8), [
            rfWEn < Const(1),
            rfWAddr < Const(14, width: 4),
            rfWData < imm8Val,
          ]),
          CaseItem(Const(ParticleOpcodes.ldNegImm8, width: 8), [
            rfWEn < Const(1),
            rfWAddr < Const(14, width: 4),
            rfWData < negImm8Val,
          ]),
          CaseItem(Const(ParticleOpcodes.push4, width: 8), [
            rfWEn < Const(1),
            rfWData < ((valA << 4) | imm4Val),
          ]),
          CaseItem(Const(ParticleOpcodes.push8, width: 8), [
            rfWEn < Const(1),
            rfWAddr < Const(14, width: 4),
            rfWData < ((valA << 8) | imm8Val),
          ]),
          // Jump and link: Rl <- PC + 2 (Rr was read first)
          CaseItem(Const(ParticleOpcodes.jmp, width: 8),
              [rfWEn < Const(1), rfWAddr < rl, rfWData < pcPlus2]),
          CaseItem(Const(ParticleOpcodes.rjump, width: 8),
              [rfWEn < Const(1), rfWAddr < rl, rfWData < pcPlus2]),
          CaseItem(Const(ParticleOpcodes.fifoR, width: 8),
              [rfWEn < ~fifoEmpty, rfWData < fifoPopData]),
          CaseItem(Const(ParticleOpcodes.fifoTryR, width: 8),
              [rfWEn < ~fifoEmpty, rfWData < fifoPopData]),
          CaseItem(Const(ParticleOpcodes.fifoTryW, width: 8), [
            rfWEn < Const(1),
            rfWAddr < Const(14, width: 4),
            rfWData < mux(fifoFull, Const(0, width: 32), Const(1, width: 32)),
          ]),
          CaseItem(Const(ParticleOpcodes.fifoStat, width: 8),
              [rfWEn < Const(1), rfWData < fifoStatus]),
        ]),
      ]),

      // Port 2: pointer updates, TRYR's status, and R14 on trap entry. Port 2
      // wins when both write the same register.
      rfWEn2 < Const(0),
      rfWAddr2 < Const(14, width: 4),
      rfWData2 < pc,
      If(doExec & ptrMode, then: [
        rfWEn2 < Const(1),
        rfWAddr2 < ptrReg,
        rfWData2 < newPtr,
      ]),
      If(doExec & op(ParticleOpcodes.fifoTryR), then: [
        rfWEn2 < Const(1),
        rfWAddr2 < Const(14, width: 4),
        rfWData2 < mux(fifoEmpty, Const(0, width: 32), Const(1, width: 32)),
      ]),
      If(oddTarget, then: [
        rfWEn2 < Const(1),
        rfWAddr2 < Const(14, width: 4),
        rfWData2 < branchNextPc,
      ]),
      If(trapInstr, then: [
        rfWEn2 < Const(1),
        rfWAddr2 < Const(14, width: 4),
        rfWData2 < pcPlus2,
      ]),
      If(faultIllegal | faultAlign | mboxTake, then: [
        rfWEn2 < Const(1),
        rfWAddr2 < Const(14, width: 4),
        rfWData2 < pc,
      ]),
    ]);

    Combinational([
      rfXchgEn < doExec & op(ParticleOpcodes.xchg),
      rfXchgAllEn < doExec & op(ParticleOpcodes.xchgAll),
      rfXchgMostEn < doExec & op(ParticleOpcodes.xchgMost),
    ]);

    // -------------------------------------------------------------------------
    // Memory port B, FIFOs, MBOX and SARF outputs
    // -------------------------------------------------------------------------
    memPortBAddr <= mux(mboxTake, mboxValueAddr, effAddr);
    memPortBWData <= mux(mboxTake, mboxPendingData, storeWData);
    memPortBBEn <= mux(mboxTake, Const(0xF, width: 4), storeBEn);
    memPortBWEn <= mboxTake | (doExec & (isStoreOp | isTas));
    memPortBREn <= doExec & (isLoadOp | isTas);

    fifoChanSelect <= valB.slice(1, 0);
    fifoPushData <= valA;
    fifoPushEn <= doExec &
        (op(ParticleOpcodes.fifoW) |
            (op(ParticleOpcodes.fifoTryW) & ~fifoFull));
    fifoPopEn <= doExec &
        (op(ParticleOpcodes.fifoR) | op(ParticleOpcodes.fifoTryR)) &
        ~fifoEmpty;

    mboxStrobeOut <= doExec & op(ParticleOpcodes.mbox);
    mboxVectorOut <= rl;
    mboxDataOut <= valA;

    sarfRs1Addr <= rr.zeroExtend(5);
    sarfRs2Addr <= rl.zeroExtend(5);
    sarfRdAddr <= rr.zeroExtend(5);
    sarfRdData <= valA;
    sarfRdWe <= Const(0);

    divStart <= doExec & isDivOp;
    divAbort <= divWaiting & mboxTake;

    // -------------------------------------------------------------------------
    // E: stall, completion and redirect
    // -------------------------------------------------------------------------
    // E keeps its instruction while a FIFO.R waits for data or a divide runs
    final eStall = (doExec & fifoReadStall) |
        (doExec & isDivOp) |
        (divWaiting & ~divDone & ~mboxTake);
    final eDone = eValid & ~eStall;
    // A load, TAS or MUL writes in W, the next cycle, when E must be empty
    final wNext = doExec & (isLoadOp | isTas | isMulOp);

    final eRedirect = Logic(name: 'eRedirect');
    final eTarget = Logic(name: 'eTarget', width: 32);
    Combinational([
      eRedirect < Const(0),
      eTarget < pcPlus2,
      If(mboxTake, then: [
        eRedirect < Const(1),
        eTarget < mboxTarget,
      ], orElse: [
        If(faultIllegal, then: [
          eRedirect < Const(1),
          eTarget < vec15,
        ], orElse: [
          If(faultAlign, then: [
            eRedirect < Const(1),
            eTarget < vec14,
          ], orElse: [
            If(trapInstr, then: [
              eRedirect < Const(1),
              eTarget < vectorAddr(trapVec),
            ], orElse: [
              If(oddTarget, then: [
                eRedirect < Const(1),
                eTarget < vec14,
              ], orElse: [
                If(ctlTaken, then: [
                  eRedirect < Const(1),
                  eTarget < branchNextPc,
                ], orElse: [
                  If(doExec & isSerialize, then: [
                    eRedirect < Const(1),
                    eTarget < pcPlus2,
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]),
    ]);

    // -------------------------------------------------------------------------
    // D: advance into E, and the unconditional branches D can decide
    // -------------------------------------------------------------------------
    final dIsLdi = dAnyOp([ParticleOpcodes.ldi, ParticleOpcodes.ldis]);
    // LDI's immediate is the halfword arriving now
    final dImmReady = fValid & fPc.eq(dPc + Const(2, width: 32));
    final eFree = ~eValid | eDone;
    final dAdvance = dValid &
        ~eRedirect &
        eFree &
        ~wNext &
        (~dIsLdi | dImmReady);

    // D decides the unconditional FBRA/BBRA imm8 forms: they need no
    // register, so the redirect costs one cycle. Conditional branches test a
    // register and are decided in E, where the operand is forwarded; testing
    // it here put the register-file read on the path to the fetch address
    // (about 35.5 MHz against 39.5 MHz on the ULX3S).
    final dIsFbra = dOpcode.eq(Const(ParticleOpcodes.fbraImm8, width: 8));
    final dIsBbra = dOpcode.eq(Const(ParticleOpcodes.bbraImm8, width: 8));
    final dResolves = dAdvance & (dIsFbra | dIsBbra);
    final dTaken = Const(1);
    final dImm8Disp = dInst.slice(7, 0).zeroExtend(32) << 1;
    // One adder for both: dPc + disp, or dPc + ~disp + 1
    final dSum = Logic(name: 'dSum', width: 34);
    dSum <=
        [Const(0), dPc, Const(1)].swizzle() +
            [Const(0), dImm8Disp ^ dIsBbra.replicate(32), dIsBbra].swizzle();
    final dTarget = dSum.getRange(1, 33);
    final dRedirect = dResolves & dTaken;

    // -------------------------------------------------------------------------
    // Fetch. The halfword arriving now is dropped on a redirect, and when it
    // is the immediate of the LDI going to E; it is fetched again when D can't
    // take it.
    // -------------------------------------------------------------------------
    final dropArriving = eRedirect | dRedirect | (dAdvance & dIsLdi);
    final dCapture = fValid & ~dropArriving & (~dValid | dAdvance);
    final fetchAddr = Logic(name: 'fetchAddr', width: 32);
    Combinational([
      fetchAddr < fPc + Const(2, width: 32),
      If(eRedirect, then: [
        fetchAddr < eTarget,
      ], orElse: [
        If(dRedirect, then: [
          fetchAddr < dTarget,
        ], orElse: [
          If(fValid & ~dropArriving & ~dCapture, then: [fetchAddr < fPc]),
        ]),
      ]),
    ]);
    memPortAAddr <= fetchAddr;

    // E's source registers next cycle, and whether this cycle's writes hit
    // them (R0 is never forwarded)
    final nextSrcA = mux(dAdvance, rAddrA, eAsrc);
    final nextSrcB = mux(dAdvance, dRl, eBsrc);
    Logic fwdHit(Logic wEn, Logic wAddr, Logic src) =>
        wEn & wAddr.eq(src) & ~src.eq(0);

    Sequential(clk, reset: coreReset, resetValues: {
      fPc: Const(trapBase - 2, width: 32),
      fValid: Const(0),
      dValid: Const(0),
      dPc: Const(0, width: 32),
      dInst: Const(0, width: 16),
      eValid: Const(0),
      ePc: Const(trapBase, width: 32),
      eInst: Const(0, width: 16),
      eA: Const(0, width: 32),
      eB: Const(0, width: 32),
      eAsrc: Const(0, width: 4),
      eBsrc: Const(0, width: 4),
      eImm16: Const(0, width: 16),
      eResolved: Const(0),
      eDivStarted: Const(0),
      fw1D: Const(0, width: 32),
      fw2D: Const(0, width: 32),
      eFa1: Const(0),
      eFa2: Const(0),
      eFb1: Const(0),
      eFb2: Const(0),
      lValid: Const(0),
      lIsMul: Const(0),
      ldDest: Const(0, width: 4),
      ldSizeCode: Const(0, width: 2),
      ldLow: Const(0, width: 2),
      mboxPending: Const(0),
      mboxPendingVec: Const(0, width: 4),
      mboxPendingData: Const(0, width: ParticleWidths.word),
    }, [
      // MBOX: a new strobe is remembered (a newer one replaces an older
      // one); a taken one is cleared
      If(mboxStrobeIn, then: [
        mboxPending < Const(1),
        mboxPendingVec < mboxVectorIn,
        mboxPendingData < mboxDataIn,
      ], orElse: [
        If(mboxTake, then: [mboxPending < Const(0)]),
      ]),

      fPc < fetchAddr,
      fValid < Const(1),

      If(dCapture, then: [
        dValid < Const(1),
        dPc < fPc,
        dInst < memPortARData,
      ], orElse: [
        If(dAdvance | eRedirect, then: [dValid < Const(0)]),
      ]),

      If(dAdvance, then: [
        eValid < Const(1),
        ePc < dPc,
        eInst < dInst,
        eA < dValA,
        eB < dValB,
        eAsrc < rAddrA,
        eBsrc < dRl,
        eImm16 < memPortARData,
        eResolved < dResolves,
        eDivStarted < Const(0),
      ], orElse: [
        If(eStall, then: [
          eA < valA,
          eB < valB,
          If(doExec & isDivOp, then: [eDivStarted < Const(1)]),
        ], orElse: [
          eValid < Const(0),
          eDivStarted < Const(0),
        ]),
      ]),

      lValid < wNext,
      lIsMul < wNext & isMulOp,
      If(wNext, then: [
        ldDest < mux(isTas, rl, rr),
        ldSizeCode < mux(isSize4, Const(2, width: 2),
            mux(isSize2, Const(1, width: 2), Const(0, width: 2))),
        ldLow < effAddr.slice(1, 0),
      ]),

      fw1D < rfWData,
      fw2D < rfWData2,
      eFa1 < fwdHit(rfWEn, rfWAddr, nextSrcA),
      eFa2 < fwdHit(rfWEn2, rfWAddr2, nextSrcA),
      eFb1 < fwdHit(rfWEn, rfWAddr, nextSrcB),
      eFb2 < fwdHit(rfWEn2, rfWAddr2, nextSrcB),
    ]);
  }
}
