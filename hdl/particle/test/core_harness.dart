// =============================================================================
// File: hdl/particle/test/core_harness.dart
// Description: A Particle core with 64 KiB of synchronous block RAM and a
//              four-channel FIFO subsystem whose channels loop back to the
//              core (as psim's channels do for a single core). Used by the
//              differential ISA test and the core unit tests.
// =============================================================================

import 'dart:async';

import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:particle_rohd/cpu_config.dart';
import 'package:particle_rohd/cpu_core.dart';
import 'package:particle_rohd/fifo_subsystem.dart';
import 'package:rohd/rohd.dart';

class CoreState {
  final int pc;
  final int rbase;
  final List<int> physical; // P0..P31
  final List<int> shadow; // S0..S31
  final int cycles;
  CoreState(this.pc, this.rbase, this.physical, this.shadow, this.cycles);

  /// Virtual register Rn through the RBASE window.
  int reg(int n) => n == 0 ? 0 : physical[(n + rbase) % 32];
}

class _HarnessTop extends Module {
  late final ParticleCpuCore core;
  late final ParticleBlockRamTdp ram;
  late final ParticleFifoSubsystem fifos;

  _HarnessTop(Logic clk, Logic reset, Logic mboxStrobe, Logic mboxVector,
      List<int> program, int base, CpuConfig config)
      : super(name: 'core_harness') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    mboxStrobe = addInput('mboxStrobe', mboxStrobe);
    mboxVector = addInput('mboxVector', mboxVector, width: 4);
    addOutput('pcOut', width: 32);

    final memARData = Logic(name: 'memARData', width: 16);
    final memBRData = Logic(name: 'memBRData', width: 32);
    final fifoPopData = Logic(name: 'fifoPopData', width: 32);
    final fifoStatus = Logic(name: 'fifoStatus', width: 32);
    core = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: memARData,
      memPortBRData: memBRData,
      mboxStrobeIn: mboxStrobe,
      mboxVectorIn: mboxVector,
      fifoPopData: fifoPopData,
      fifoStatus: fifoStatus,
      config: config,
    );
    ram = ParticleBlockRamTdp(
      clk: clk,
      addrA: core.memPortAAddr.slice(15, 1),
      addrB: core.memPortBAddr.slice(15, 2),
      wDataB: core.memPortBWData,
      bEnB: core.memPortBBEn,
      wEnB: core.memPortBWEn,
      rEnB: core.memPortBREn,
      initialBytes: program,
      loadOffset: base,
    );
    memARData <= ram.rDataA;
    memBRData <= ram.rDataB;
    fifos = ParticleFifoSubsystem(
      clk: clk,
      reset: reset,
      chanSelect: core.fifoChanSelect,
      pushData: core.fifoPushData,
      pushEn: core.fifoPushEn,
      popEn: core.fifoPopEn,
    );
    fifoPopData <= fifos.popData;
    fifoStatus <= fifos.statusWord;
    output('pcOut') <= core.memPortAAddr;
  }
}

class CoreHarness {
  final Logic clk = SimpleClockGenerator(10).clk;
  final Logic reset = Logic(name: 'reset');
  final Logic mboxStrobe = Logic(name: 'mboxStrobe');
  final Logic mboxVector = Logic(name: 'mboxVector', width: 4);
  late final _HarnessTop _top;
  ParticleCpuCore get core => _top.core;
  ParticleBlockRamTdp get ram => _top.ram;
  ParticleFifoSubsystem get fifos => _top.fifos;
  int cycles = 0;

  /// The harness whose simulation is running, if any.
  static CoreHarness? _active;

  /// Stops the running harness (if a failed test left one running) and resets
  /// the simulator. For tearDown.
  static Future<void> stopActive() async {
    await _active?.stop();
    await Simulator.reset();
  }

  CoreHarness(List<int> program,
      {int base = 0x100, CpuConfig config = const CpuConfig()}) {
    _top = _HarnessTop(
        clk, reset, mboxStrobe, mboxVector, program, base, config);
  }

  Future<void> start() async {
    await _top.build();
    reset.inject(1);
    mboxStrobe.inject(0);
    mboxVector.inject(0);
    Simulator.setMaxSimTime(1 << 40);
    _active = this;
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
  }

  Future<void> step([int n = 1]) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
      cycles++;
    }
  }

  int get pc => core.pcReg.value.toInt();

  /// True when the instruction at [pc] is in the execute stage this cycle.
  bool get inExec =>
      core.execValid.value.isValid && core.execValid.value.toInt() == 1;

  /// Runs until the execute stage has seen only the instruction at one PC
  /// [stableCycles] times in a row (the program's final jump-to-self), or
  /// [maxCycles]. Cycles with nothing in execute (pipeline bubbles) don't
  /// count either way. A divide holds its PC too, so it has to finish: the
  /// count only starts again when a new instruction enters execute.
  Future<void> runToHalt({int maxCycles = 20000, int stableCycles = 8}) async {
    var last = -1;
    var same = 0;
    var wasExec = false;
    while (cycles < maxCycles) {
      await step();
      if (!inExec) {
        wasExec = false;
        continue;
      }
      final v = core.pcReg.value;
      final now = v.isValid ? v.toInt() : -1;
      // Only a new entry into execute counts (a stall at one PC doesn't)
      final entered = !wasExec || _entered();
      wasExec = true;
      if (!entered) continue;
      same = (now == last) ? same + 1 : 0;
      last = now;
      if (same >= stableCycles) return;
    }
  }

  late final Logic _eDivStarted =
      core.internalSignals.firstWhere((s) => s.name == 'eDivStarted');
  // An instruction is new in execute unless a divide is under way there
  bool _entered() =>
      !(_eDivStarted.value.isValid && _eDivStarted.value.toInt() == 1);

  CoreState snapshot() {
    final rf = core.registerFile;
    int val(Logic l) => l.value.isValid ? l.value.toInt() : -1;
    return CoreState(
      pc,
      val(rf.rbaseOut),
      [for (final r in rf.physical) val(r)],
      [for (final r in rf.shadow) val(r)],
      cycles,
    );
  }

  Future<void> stop() async {
    if (_active != this) return;
    _active = null;
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    await Simulator.reset();
  }
}
