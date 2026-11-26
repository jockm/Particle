// =============================================================================
// File: hdl/parcore/lib/parcore_top.dart
// Architecture: Parcore Distributed RISC Pipeline & Conductor Supervisor
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'dart:math';
import 'package:rohd/rohd.dart';
import 'package:particle_rohd/constants.dart';
import 'package:particle_rohd/cpu_core.dart';
import 'package:particle_rohd/network_interface.dart';
import 'package:particle_rohd/ring_interface.dart';
import 'package:particle_rohd/ring_router.dart';
import 'package:particle_rohd/uart.dart';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_tcm.dart';
import 'package:parcore_rohd/spi_controller.dart';

class ParcoreTop extends Module {
  /// When set, the generated SystemVerilog loads each TCM from
  /// `<tcmInitDir>/<name>_tcm_bank0.hex` and `..._bank1.hex` ($readmemh)
  /// instead of from the binaries, so a test can change programs without
  /// rebuilding its Verilator model. Simulation always uses the binaries.
  final String? tcmInitDir;

  /// FTDI UART divisor: clock cycles per bit (clkFreqMhz MHz / ftdiBaud).
  final int ftdiDivisor;

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

  // Board LEDs and buttons: the conductor shows boot progress and faults on
  // the LEDs, then hands them to the guest (core 3's I/O, 0x1000_0008).
  // Buttons, 1 = pressed: bit 0 FIRE1, 1 FIRE2, 2 UP, 3 DOWN, 4 LEFT, 5 RIGHT.
  Logic get leds => output('leds');
  Logic get buttons => input('buttons');

  // Diagnostic observability
  Logic get branchRedirectStrobe => output('branch_redirect_strobe');
  Logic get branchRedirectVector => output('branch_redirect_vector');

  ParcoreTop({
    required Logic clk,
    required Logic reset,
    required Logic uartRx,
    Logic? spiMiso,
    Logic? buttons,
    int clkFreqMhz = 25,
    int ftdiBaud = 1000000,
    List<int>? conductorBinary,
    List<int>? core0Binary,
    List<int>? core1Binary,
    List<int>? core2Binary,
    List<int>? core3Binary,
    this.tcmInitDir,
    super.name = 'parcore_top',
  }) : ftdiDivisor = (clkFreqMhz * 1000000 / ftdiBaud).round() {
    if (ftdiDivisor < 2 || ftdiDivisor > 0xFFFF) {
      throw ArgumentError('ftdiBaud $ftdiBaud gives divisor $ftdiDivisor '
          'at $clkFreqMhz MHz; it must be 2 to 65535');
    }
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('uart_rx', uartRx);
    addInput('spi_miso', spiMiso ?? Const(0));
    addInput('buttons', buttons ?? Const(0, width: 6), width: 6);

    addOutput('uart_tx');
    addOutput('spi_cs_n');
    addOutput('spi_sck');
    addOutput('spi_mosi');
    addOutput('leds', width: 8);
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

    // The conductor's MBOX goes through its network interface (built below)
    final condMboxSendWait = Logic(name: 'cond_mbox_send_wait');
    final conductor = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: condMemARData,
      memPortBRData: condMemBRData,
      mboxStrobeIn: Const(0),
      mboxVectorIn: Const(0, width: 4),
      mboxSendWait: condMboxSendWait,
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

    // Buttons, through two flip-flops (they're asynchronous to the clock)
    final buttonsMeta = Logic(name: 'buttons_meta', width: 6);
    final buttonsSync = Logic(name: 'buttons_sync', width: 6);
    Sequential(clk, [buttonsMeta < buttons, buttonsSync < buttonsMeta]);

    // STATUS (0xF000_0020): bits [7:0] the LEDs while the conductor has them,
    // bit 8 gives them to the guest. Without a conductor the guest has them
    // from reset. BUTTONS (0xF000_0024, read only).
    final regStatus = Logic(name: 'reg_status', width: 9);
    final isStatusSel = condMemAddr.eq(Const(0xF0000020, width: 32));
    final isButtonsSel = condMemAddr.eq(Const(0xF0000024, width: 32));
    // CORE_STATE (0xF000_0028, read only): 2 bits per stage core, core n at
    // bits 2n+1:2n: 0 running, 1 asleep in a WAIT, 2 halted (HALT), 3 held
    // in reset (RST_CTRL). The cores' outputs are driven once they exist.
    final isCoreStateSel = condMemAddr.eq(Const(0xF0000028, width: 32));
    final coreWaiting = [for (var n = 0; n < 4; n++) Logic(name: 'core${n}_waiting')];
    final coreHalted = [for (var n = 0; n < 4; n++) Logic(name: 'core${n}_halted')];
    final coreState = [
      for (var n = 0; n < 4; n++)
        mux(condCoreReset[n], Const(3, width: 2),
            mux(coreHalted[n], Const(2, width: 2),
                mux(coreWaiting[n], Const(1, width: 2), Const(0, width: 2)))),
    ].rswizzle();
    Sequential(clk, reset: reset, resetValues: {
      regStatus: Const(conductorBinary != null ? 0 : 0x100, width: 9),
    }, [
      If(condMemWEn & isStatusSel, then: [
        regStatus < condMemWData.slice(8, 0),
      ]),
    ]);

    // Conductor Port B Readback Multiplexer. Memory is synchronous: a load's
    // data is used in the cycle after its address, so the source selection
    // and the register values are captured at the clock edge, like the TCM.
    final readSelRst = Logic(name: 'cond_read_sel_rst');
    final readSelSpi = Logic(name: 'cond_read_sel_spi');
    final readSelIo = Logic(name: 'cond_read_sel_io');
    final readRstVal = Logic(name: 'cond_read_rst_val', width: 32);
    final readSpiVal = Logic(name: 'cond_read_spi_val', width: 32);
    final readIoVal = Logic(name: 'cond_read_io_val', width: 32);
    Sequential(clk, [
      readSelRst < isRstCtrlSel,
      readSelSpi < isSpiSel,
      readSelIo < isStatusSel | isButtonsSel | isCoreStateSel,
      readRstVal < regRstCtrl,
      readSpiVal < spiCtrl.rData,
      readIoVal <
          mux(isStatusSel, regStatus.zeroExtend(32),
              mux(isCoreStateSel, coreState.zeroExtend(32),
                  buttonsSync.zeroExtend(32))),
    ]);
    condMemBRData <= mux(
      readSelRst,
      readRstVal,
      mux(readSelSpi, readSpiVal,
          mux(readSelIo, readIoVal, condTcm.rDataB)),
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

    // -------------------------------------------------------------------------
    // The network (step 2 of Documentation/noc_design.md): a one-way ring of
    // routers, conductor -> core 0 -> core 1 -> core 2 -> core 3 ->
    // conductor. Each stage core has a network interface holding its receive
    // buffers, the credits of its output links, an injection queue and its
    // channel table (which CONFIG can change); the conductor's interface
    // only sends CONFIG packets (step 3b). A store of a channel number to
    // 0xFFFF_FF00 sends a FLUSH on it (core 0 flushes ifToId on a redirect);
    // a core's network interface resets with the core.
    // -------------------------------------------------------------------------
    const pw = NocPacket.width;
    const ringOrder = [7, 0, 1, 2, 3]; // router ids: the conductor is 7
    final ringOut = [
      for (final id in ringOrder) Logic(name: 'ring_out_$id', width: pw),
    ];
    final ringOutValid = [
      for (final id in ringOrder) Logic(name: 'ring_out_valid_$id'),
    ];
    final ringInject = [
      for (final id in ringOrder) Logic(name: 'ring_inject_$id', width: pw),
    ];
    final ringInjectValid = [
      for (final id in ringOrder) Logic(name: 'ring_inject_valid_$id'),
    ];
    final routers = [
      for (var r = 0; r < ringOrder.length; r++)
        ParticleRingRouter(
          clk: clk,
          reset: reset,
          ringIn: ringOut[(r + ringOrder.length - 1) % ringOrder.length],
          ringInValid:
              ringOutValid[(r + ringOrder.length - 1) % ringOrder.length],
          inject: ringInject[r],
          injectValid: ringInjectValid[r],
          coreId: ringOrder[r],
          name: 'ring_router_${ringOrder[r]}',
        ),
    ];
    for (var r = 0; r < ringOrder.length; r++) {
      ringOut[r] <= routers[r].ringOut;
      ringOutValid[r] <= routers[r].ringOutValid;
    }
    // The conductor's network interface only sends CONFIG: a store to its
    // CONFIG register (0xFFFF_FF0C) sets one table entry of a core, or of
    // every core (Documentation/mbox_design.md, part 6). With
    // ParcoreConfig.writableNocTables off it sends nothing.
    final condNi = ParticleRingInterface(
      clk: clk,
      reset: reset,
      chanSelect: Const(0, width: 2),
      pushData: Const(0, width: ParticleWidths.word),
      pushEn: Const(0),
      popEn: Const(0),
      channels: const [
        NiChannel.unused,
        NiChannel.unused,
        NiChannel.unused,
        NiChannel.unused,
      ],
      coreId: ringOrder[0],
      eject: routers[0].eject,
      ejectValid: routers[0].ejectValid,
      injectTaken: routers[0].injectTaken,
      ringCores: ringOrder,
      // The conductor's MBOX Rr, Rl reaches any core (to wake one from a
      // WAIT, say); MBOX Rr, Imm4 has no default target and is dropped
      mboxSend: true,
      mboxSendStrobe: conductor.mboxStrobeOut,
      mboxSendVector: conductor.mboxVectorOut,
      mboxSendData: conductor.mboxDataOut,
      mboxSendTarget: conductor.mboxTargetOut,
      mboxSendTargetValid: conductor.mboxTargetValid,
      mboxReceive: false,
      acceptConfig: false,
      configSender: ParcoreConfig.writableNocTables,
      configStrobe:
          condMemWEn & condMemAddr.eq(Const(niConfigRegister, width: 32)),
      configWord: condMemWData,
      name: 'conductor_ni',
    );
    ringInject[0] <= condNi.inject;
    ringInjectValid[0] <= condNi.injectValid;
    condMboxSendWait <= condNi.mboxSendWait;

    // Each core's FIFO port, and its stores to the FLUSH register, driven
    // once the core exists
    (Logic, Logic, Logic, Logic, Logic, Logic) fifoPort(String n) => (
          Logic(name: '${n}_fifo_chan', width: 2),
          Logic(name: '${n}_fifo_push_data', width: ParticleWidths.word),
          Logic(name: '${n}_fifo_push_en'),
          Logic(name: '${n}_fifo_pop_en'),
          Logic(name: '${n}_ni_flush'),
          Logic(name: '${n}_ni_flush_chan', width: 2),
        );
    // Each core's MBOX outputs, driven once the core exists
    (Logic, Logic, Logic, Logic, Logic, Logic) mboxPort(String n) => (
          Logic(name: '${n}_mbox_send'),
          Logic(name: '${n}_mbox_send_vector', width: 4),
          Logic(name: '${n}_mbox_send_data', width: ParticleWidths.word),
          Logic(name: '${n}_mbox_send_target', width: 8),
          Logic(name: '${n}_mbox_send_target_valid'),
          Logic(name: '${n}_mbox_ready'),
        );
    final c0Mbox = mboxPort('c0');
    final c1Mbox = mboxPort('c1');
    final c2Mbox = mboxPort('c2');
    final c3Mbox = mboxPort('c3');
    final c0Port = fifoPort('c0');
    final c1Port = fifoPort('c1');
    final c2Port = fifoPort('c2');
    final c3Port = fifoPort('c3');

    ParticleRingInterface ni(
      int core,
      (Logic, Logic, Logic, Logic, Logic, Logic) port,
      List<NiChannel> channels, {
      List<NocAddress> txRoutes = const [],
      List<NocAddress> rxSenders = const [],
      List<String> bufferNames = const [],
      Logic? devPopData,
      Logic? devStatus,
      required (Logic, Logic, Logic, Logic, Logic, Logic) mbox,
      int? mboxDefaultTarget,
      bool mboxSend = false,
      required bool mboxReceive,
    }) {
      final r = ringOrder.indexOf(core);
      final iface = ParticleRingInterface(
        clk: clk,
        reset: reset | condCoreReset.slice(core, core),
        chanSelect: port.$1,
        pushData: port.$2,
        pushEn: port.$3,
        popEn: port.$4,
        flushStrobe: port.$5,
        flushChannel: port.$6,
        channels: channels,
        coreId: core,
        txRoutes: txRoutes,
        rxSenders: rxSenders,
        eject: routers[r].eject,
        ejectValid: routers[r].ejectValid,
        injectTaken: routers[r].injectTaken,
        devPopData: devPopData,
        devStatus: devStatus,
        bufferNames: bufferNames,
        mboxSendStrobe: mbox.$1,
        mboxSendVector: mbox.$2,
        mboxSendData: mbox.$3,
        mboxSendTarget: mbox.$4,
        mboxSendTargetValid: mbox.$5,
        mboxCoreReady: mbox.$6,
        mboxDefaultTarget: mboxDefaultTarget,
        // Only what each core uses is built (411)
        mboxSend: mboxSend,
        mboxReceive: mboxReceive,
        ringCores: ringOrder,
        acceptConfig: ParcoreConfig.writableNocTables,
        name: 'core${core}_ni',
      );
      ringInject[r] <= iface.inject;
      ringInjectValid[r] <= iface.injectValid;
      return iface;
    }

    // Core 0: channel 1 sends to core 1 (FIFO.STAT: its room, checked before
    // each packet); channel 2 receives core 3's mirrored stores
    final ni0 = ni(0, c0Port, const [
      NiChannel.unused,
      NiChannel(tx: 0, status: NiStatus.tx(0)),
      NiChannel(rx: 0, status: NiStatus.rx(0)),
      NiChannel.unused,
    ], txRoutes: const [(core: 1, channel: 0)],
        rxSenders: const [(core: 3, channel: 2)],
        bufferNames: ['parcore_fifo_mem_to_if'],
        mbox: c0Mbox,
        mboxReceive: ParcoreConfig.core0If.enableMboxReceive);

    // Core 1: channel 0 receives from core 0, channel 1 sends to core 2
    // (FIFO.STAT: its room, checked before decoding), channel 2 receives the
    // writebacks from core 3; channel 3 reports channel 0's status
    final ni1 = ni(1, c1Port, const [
      NiChannel(rx: 0, status: NiStatus.rx(0)),
      NiChannel(tx: 0, status: NiStatus.tx(0)),
      NiChannel(rx: 1, status: NiStatus.rx(1)),
      NiChannel(status: NiStatus.rx(0)),
    ], txRoutes: const [(core: 2, channel: 0)],
        rxSenders: const [(core: 0, channel: 1), (core: 3, channel: 1)],
        bufferNames: ['parcore_fifo_if_to_id', 'parcore_fifo_mem_to_wb'],
        mbox: c1Mbox,
        mboxReceive: ParcoreConfig.core1Id.enableMboxReceive);

    // Core 2: every channel receives from core 1 and reports that input's
    // status; channel 1 also sends to core 3
    const c2In = NiChannel(rx: 0, status: NiStatus.rx(0));
    final ni2 = ni(2, c2Port, const [
      c2In,
      NiChannel(rx: 0, tx: 0, status: NiStatus.rx(0)),
      c2In,
      c2In,
    ], txRoutes: const [(core: 3, channel: 0)],
        rxSenders: const [(core: 1, channel: 1)],
        bufferNames: ['parcore_fifo_id_to_ex'],
        // Its MBOXes (redirects and FENCE.I) go to core 0
        mbox: c2Mbox, mboxDefaultTarget: 0, mboxSend: true,
        mboxReceive: ParcoreConfig.core2Ex.enableMboxReceive);

    // Core 3: channels 0-2 receive from core 2; channel 1 sends the
    // writebacks to core 1, channel 2 mirrors stores to core 0 (FIFO.STAT:
    // its room); channel 3 is the FTDI UART
    final c3DevPopData = Logic(name: 'c3_dev_pop_data', width: ParticleWidths.word);
    final c3DevStatus = Logic(name: 'c3_dev_status', width: ParticleWidths.word);
    final ni3 = ni(3, c3Port, const [
      NiChannel(rx: 0, status: NiStatus.rx(0)),
      NiChannel(rx: 0, tx: 0, status: NiStatus.rx(0)),
      NiChannel(rx: 0, tx: 1, status: NiStatus.tx(1)),
      NiChannel(device: true, status: NiStatus.device()),
    ], txRoutes: const [(core: 1, channel: 2), (core: 0, channel: 2)],
        rxSenders: const [(core: 2, channel: 1)],
        bufferNames: ['parcore_fifo_ex_to_mem'],
        devPopData: c3DevPopData, devStatus: c3DevStatus, mbox: c3Mbox,
        mboxReceive: ParcoreConfig.core3Mem.enableMboxReceive);

    void driveMbox((Logic, Logic, Logic, Logic, Logic, Logic) m,
        ParticleCpuCore core) {
      final n = [c0Mbox, c1Mbox, c2Mbox, c3Mbox].indexOf(m);
      coreWaiting[n] <= core.waiting;
      coreHalted[n] <= core.halted;
      m.$1 <= core.mboxStrobeOut;
      m.$2 <= core.mboxVectorOut;
      m.$3 <= core.mboxDataOut;
      m.$4 <= core.mboxTargetOut;
      m.$5 <= core.mboxTargetValid;
      m.$6 <= core.mboxReady;
    }

    void drivePort((Logic, Logic, Logic, Logic, Logic, Logic) port,
        ParticleCpuCore core) {
      port.$1 <= core.fifoChanSelect;
      port.$2 <= core.fifoPushData;
      port.$3 <= core.fifoPushEn;
      port.$4 <= core.fifoPopEn;
      // The FLUSH register: a store of a channel number to 0xFFFF_FF00
      port.$5 <=
          core.memPortBWEn &
              core.memPortBAddr.eq(Const(niFlushRegister, width: 32));
      port.$6 <= core.memPortBWData.slice(1, 0);
    }

    // -------------------------------------------------------------------------
    // Core 0: IF & UART
    // -------------------------------------------------------------------------
    final c0MemARData = Logic(name: 'c0_mem_a_rdata', width: ParticleWidths.halfWord);
    final c0MemBRData = Logic(name: 'c0_mem_b_rdata', width: ParticleWidths.word);

    final c0FifoPopData = Logic(name: 'c0_fifo_pop_data', width: ParticleWidths.word);
    final c0FifoStatus  = Logic(name: 'c0_fifo_status', width: ParticleWidths.word);

    final core0 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(0, 0),
      memPortARData: c0MemARData,
      memPortBRData: c0MemBRData,
      mboxStrobeIn: ni0.mboxStrobe,
      mboxVectorIn: ni0.mboxVector,
      mboxDataIn: ni0.mboxData,
      mboxSourceIn: ni0.mboxSource,
      mboxSendWait: ni0.mboxSendWait,
      fifoPopData: c0FifoPopData,
      fifoStatus: c0FifoStatus,
      fifoPushWait: ni0.pushWait,
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

    drivePort(c0Port, core0);
    driveMbox(c0Mbox, core0);
    c0FifoStatus <= ni0.statusWord;
    c0FifoPopData <= ni0.popData;

    // -------------------------------------------------------------------------
    // Core 1: ID & Register Scoreboard
    // -------------------------------------------------------------------------
    final c1MemARData = Logic(name: 'c1_mem_a_rdata', width: ParticleWidths.halfWord);
    final c1MemBRData = Logic(name: 'c1_mem_b_rdata', width: ParticleWidths.word);

    final c1PopData = Logic(name: 'c1PopData', width: 32);
    final c1FifoStatus = Logic(name: 'c1FifoStatus', width: 32);

    c1PopData <= ni1.popData;
    c1FifoStatus <= ni1.statusWord;

    final core1 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(1, 1),
      memPortARData: c1MemARData,
      memPortBRData: c1MemBRData,
      mboxStrobeIn: ni1.mboxStrobe,
      mboxVectorIn: ni1.mboxVector,
      mboxDataIn: ni1.mboxData,
      mboxSourceIn: ni1.mboxSource,
      mboxSendWait: ni1.mboxSendWait,
      fifoPopData: c1PopData,
      fifoStatus: c1FifoStatus,
      fifoPushWait: ni1.pushWait,
      config: ParcoreConfig.core1Id,
      name: 'core1_id',
    );

    drivePort(c1Port, core1);
    driveMbox(c1Mbox, core1);

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
      mboxStrobeIn: ni2.mboxStrobe,
      mboxVectorIn: ni2.mboxVector,
      mboxDataIn: ni2.mboxData,
      mboxSourceIn: ni2.mboxSource,
      mboxSendWait: ni2.mboxSendWait,
      fifoPopData: ni2.popData,
      fifoStatus: ni2.statusWord,
      fifoPushWait: ni2.pushWait,
      config: ParcoreConfig.core2Ex,
      name: 'core2_ex',
    );

    drivePort(c2Port, core2);
    driveMbox(c2Mbox, core2);

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



    branchRedirectStrobe <= core2.mboxStrobeOut;
    branchRedirectVector <= core2.mboxVectorOut;

    // -------------------------------------------------------------------------
    // Core 3: MEM & Alignment
    // -------------------------------------------------------------------------
    final c3MemARData = Logic(name: 'c3_mem_a_rdata', width: ParticleWidths.halfWord);
    final c3MemBRData = Logic(name: 'c3_mem_b_rdata', width: ParticleWidths.word);
    final c3TcmBRData = Logic(name: 'c3_tcm_b_rdata', width: ParticleWidths.word);

    // FIFO.STAT: channel 2 memToIf (core 3 waits for room before mirroring
    // a store), channel 3 the FTDI UART, any other channel exToMem
    final c3FifoStatus = Logic(name: 'c3_fifo_status', width: ParticleWidths.word);
    final c3FifoPopData = Logic(name: 'c3_fifo_pop_data', width: ParticleWidths.word);
    final core3 = ParticleCpuCore(
      clk: clk,
      reset: reset | condCoreReset.slice(3, 3),
      memPortARData: c3MemARData,
      memPortBRData: c3MemBRData,
      mboxStrobeIn: ni3.mboxStrobe,
      mboxVectorIn: ni3.mboxVector,
      mboxDataIn: ni3.mboxData,
      mboxSourceIn: ni3.mboxSource,
      mboxSendWait: ni3.mboxSendWait,
      fifoPopData: c3FifoPopData,
      fifoStatus: c3FifoStatus,
      fifoPushWait: ni3.pushWait,
      config: ParcoreConfig.core3Mem,
      name: 'core3_mem',
    );

    drivePort(c3Port, core3);
    driveMbox(c3Mbox, core3);

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
      portBRData: c3TcmBRData,
      initialBytes: core3Binary,
    );

    // Core 3's own I/O, at 0xF000_0000 in its address space (writes there
    // never reach its TCM): 0xF000_0000 the guest's LEDs (bits 7:0, written),
    // 0xF000_0004 the buttons (read). Its firmware maps them to the guest
    // addresses 0x1000_0008 and 0x1000_000C. Reads answer like memory: the
    // selection and value are captured at the clock edge.
    final c3IoSel = core3.memPortBAddr.slice(31, 28).eq(Const(0xF, width: 4));
    final guestLeds = Logic(name: 'guest_leds', width: 8);
    Sequential(clk, reset: reset, resetValues: {
      guestLeds: Const(0, width: 8),
    }, [
      If(core3.memPortBWEn &
          core3.memPortBAddr.eq(Const(0xF0000000, width: 32)), then: [
        guestLeds < core3.memPortBWData.slice(7, 0),
      ]),
    ]);
    final c3ReadIo = Logic(name: 'c3_read_io');
    final c3ReadIoVal = Logic(name: 'c3_read_io_val', width: 32);
    Sequential(clk, [
      c3ReadIo < c3IoSel,
      c3ReadIoVal <
          mux(core3.memPortBAddr.slice(2, 2), buttonsSync.zeroExtend(32),
              guestLeds.zeroExtend(32)),
    ]);
    c3MemBRData <= mux(c3ReadIo, c3ReadIoVal, c3TcmBRData);

    leds <= mux(regStatus[8], guestLeds, regStatus.slice(7, 0));


    // Core 3's channel 3 is the FTDI UART: the guest's memory-mapped UART
    // (core 3 does every guest load and store). FIFO.W/FIFO.TRYW send the
    // low byte, FIFO.TRYR receives one; FIFO.STAT gives bit 0 = nothing
    // received and bit 1 = the transmitter is busy, so FIFO.TRYW only sends
    // when it can.
    final ftdiUart = ParticleUartTransceiver(
      clk: clk,
      reset: reset,
      rxPin: uartRx,
      txData: ni3.devPushData.slice(7, 0),
      txValid: ni3.devPushEn,
      rxReady: ni3.devPopEn,
      baudDivisor: Const(ftdiDivisor, width: 16),
      name: 'parcore_ftdi_uart',
    );
    uartTx <= ftdiUart.output('txPin');

    c3DevStatus <= [Const(0, width: 30), ~ftdiUart.output('txReady'), ~ftdiUart.output('rxValid')].swizzle();
    c3DevPopData <= [Const(0, width: 24), ftdiUart.output('rxData')].swizzle();
    c3FifoStatus <= ni3.statusWord;
    c3FifoPopData <= ni3.popData;
  }
}
