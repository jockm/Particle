// =============================================================================
// File: hdl/parcore/test/parcore_ulx3s_boot_test.dart
// Description: The whole Parcore ULX3S design, from reset: the conductor
//              loads the image from the SPI-style ROM, releases the cores,
//              and the guest prints on the FTDI UART. Runs in Verilator
//              (a boot is about a million cycles).
// =============================================================================

import 'dart:io';

import 'package:particle_rohd/particle_rohd.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../lib/parcore_config.dart';
import '../lib/parcore_image.dart';
import '../lib/parcore_ulx3s_top.dart';
import '../lib/spi_flash_rom.dart';
import 'guest_echo.dart';

const _dir = '/tmp/parcore_ulx3s_boot';
const _clockHz = 25000000;

// Drives the board's inputs and decodes ftdi_tx_pin at the UART's divisor
// (DIVISOR clocks per bit). Prints each byte received as RX=<hex>, the cycle
// the first byte started, and the LEDs at the end; stops after STOP_AFTER
// bytes or MAX_CYCLES.
const _simMain = r'''
#include "VParcoreUlx3sTop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreUlx3sTop* top = new VParcoreUlx3sTop;
    const long maxCycles = std::atol(std::getenv("MAX_CYCLES"));
    const int divisor = std::atoi(std::getenv("DIVISOR"));
    const int stopAfter = std::atoi(std::getenv("STOP_AFTER"));

    top->clk = 0;
    top->reset_n = 0;
    top->ftdi_rx_pin = 1;
    top->gpio_rx_pin = 1;
    top->buttons = 0;
    top->eval();

    long cycle = 0;
    long firstByte = -1;
    int received = 0;
    int bitNo = -1;      // -1: waiting for a start bit
    long nextSample = 0;
    int byte = 0;
    for (; cycle < maxCycles && received < stopAfter; cycle++) {
        if (cycle == 10) top->reset_n = 1;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
        const int tx = top->ftdi_tx_pin;
        if (bitNo < 0) {
            if (tx == 0 && cycle > 20) {
                bitNo = 0;
                byte = 0;
                nextSample = cycle + divisor + divisor / 2;
                if (firstByte < 0) firstByte = cycle;
            }
        } else if (cycle == nextSample) {
            if (bitNo < 8) {
                byte |= tx << bitNo;
                bitNo++;
                nextSample += divisor;
            } else {
                printf("RX=%02x\n", byte);
                received++;
                bitNo = -1;   // in the stop bit; wait for the next start
            }
        }
    }
    printf("CYCLES=%ld FIRST_BYTE=%ld LEDS=%02x\n", cycle, firstByte, top->leds);
    delete top;
    return 0;
}
''';

void main() {
  final fastSim = Platform.environment['PARCORE_FAST_SIM'] != '0';

  group('Parcore ULX3S design boots from its ROM',
      skip: fastSim ? false : 'needs Verilator (PARCORE_FAST_SIM=1)', () {
    test(
        'The conductor loads the image, releases the cores, and the guest prints "Hi!\\n"',
        () async {
      List<int> bin(String path) => File(path).readAsBytesSync();
      const b = '../../build/parcore';
      final guest = <int>[
        for (final w in guestHelloProgram)
          for (var i = 0; i < 4; i++) (w >> (8 * i)) & 0xFF,
      ];
      final image = buildParcoreStageImage(
        core0: bin('$b/riscv/core0_if.bin'),
        core1: bin('$b/riscv/core1_id.bin'),
        core2: bin('$b/riscv/core2_ex.bin'),
        core3: bin('$b/riscv/core3_mem.bin'),
        guest: guest,
      );
      final conductor = bin('$b/conductor/conductor.bin');

      final dir = Directory(_dir)..createSync(recursive: true);
      for (final (name, bytes, size) in [
        (
          'conductor_tcm',
          conductor,
          ParcoreConfig.conductorConfig.tcmSizeBytes
        ),
        ('core0_tcm', const <int>[], ParcoreConfig.core0If.tcmSizeBytes),
        ('core1_tcm', const <int>[], ParcoreConfig.core1Id.tcmSizeBytes),
        ('core2_tcm', const <int>[], ParcoreConfig.core2Ex.tcmSizeBytes),
        ('core3_tcm', const <int>[], ParcoreConfig.core3Mem.tcmSizeBytes),
      ]) {
        final (bank0, bank1) = ParticleBlockRamTdp.bankFiles(bytes,
            loadOffset: 0x100, depthWords: size ~/ 4);
        File('$_dir/${name}_bank0.hex').writeAsStringSync(bank0);
        File('$_dir/${name}_bank1.hex').writeAsStringSync(bank1);
      }

      final top = ParcoreUlx3sTop(
        clk: Logic(name: 'clk'),
        resetN: Logic(name: 'reset_n'),
        ftdiRxPin: Logic(name: 'ftdi_rx_pin'),
        gpioRxPin: Logic(name: 'gpio_rx_pin'),
        buttons: Logic(name: 'buttons', width: 6),
        conductorBinary: conductor,
        image: image,
        clockHz: _clockHz,
        tcmInitDir: _dir,
        romInitFile: '$_dir/parcore_image_rom.hex',
      );
      await top.build();
      final rom = top.subModules.whereType<SpiFlashRom>().single;
      File('$_dir/parcore_image_rom.hex')
          .writeAsStringSync(SpiFlashRom.hexFile(rom.contents));
      File('$_dir/parcore_ulx3s_top.sv').writeAsStringSync(top.dumpSystemVerilog());
      File('$_dir/sim_main.cpp').writeAsStringSync(_simMain);

      final objDir = Directory('$_dir/obj_dir');
      if (objDir.existsSync()) objDir.deleteSync(recursive: true);
      final verilator = Platform.environment['VERILATOR'] ?? 'verilator';
      final build = Process.runSync(
        verilator,
        [
          '--cc',
          '--exe',
          '--build',
          '-O3',
          '-Wno-fatal',
          '--top-module',
          'ParcoreUlx3sTop',
          'parcore_ulx3s_top.sv',
          'sim_main.cpp',
          '-o',
          'VParcoreUlx3sTop',
        ],
        workingDirectory: dir.path,
      );
      expect(build.exitCode, equals(0),
          reason: 'Verilator build failed:\n${build.stderr}');

      final run = Process.runSync(
        '$_dir/obj_dir/VParcoreUlx3sTop',
        const [],
        environment: {
          'MAX_CYCLES': '6000000',
          'DIVISOR': '${top.parcore.ftdiDivisor}',
          'STOP_AFTER': '4',
        },
      );
      expect(run.exitCode, equals(0), reason: '${run.stderr}');
      final out = '${run.stdout}';
      print(out.split('\n').where((l) => l.startsWith('CYCLES')).join());
      final bytes = [
        for (final m
            in RegExp(r'^RX=([0-9a-f]{2})', multiLine: true).allMatches(out))
          int.parse(m.group(1)!, radix: 16),
      ];
      expect(String.fromCharCodes(bytes), equals('Hi!\n'),
          reason: 'the guest should print after the conductor boots it');
      final leds = int.parse(
          RegExp(r'LEDS=([0-9a-f]{2})').firstMatch(out)!.group(1)!,
          radix: 16);
      expect(leds, equals(0),
          reason: 'the guest has the LEDs (and hasn\'t lit any)');
    }, timeout: const Timeout(Duration(minutes: 30)));
  });
}
