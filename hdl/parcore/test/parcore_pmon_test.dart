// =============================================================================
// File: hdl/parcore/test/parcore_pmon_test.dart
// Description: pmon, the conductor's console (Road to GHz item 16), in the
//              whole Parcore ULX3S design: the real conductor boots the
//              image, then answers on gpio_rx_pin / gpio_tx_pin at 115200
//              baud. A script of text commands and frames is sent, each once
//              the console has gone quiet after the last. Runs in Verilator.
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

const _dir = '/tmp/parcore_pmon';
const _clockHz = 25000000;

// Drives gpio_rx_pin from SCRIPT and decodes gpio_tx_pin (DIVISOR clocks a
// bit). SCRIPT has a line a step: "R hex..." sends the bytes, then waits for
// an answer and for the console to be quiet for IDLE cycles; "Q n hex..."
// sends the bytes and waits n cycles. The first step waits for the banner.
// Prints STEP=<n> as each step starts, RX=<hex> for each byte received, and
// CYCLES= at the end.
const _simMain = r'''
#include "VParcoreUlx3sTop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

struct Step { bool quiet; long wait; std::vector<int> bytes; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreUlx3sTop* top = new VParcoreUlx3sTop;
    const long maxCycles = std::atol(std::getenv("MAX_CYCLES"));
    const int divisor = std::atoi(std::getenv("DIVISOR"));
    const long idle = std::atol(std::getenv("IDLE"));

    std::vector<Step> steps;
    std::ifstream script(std::getenv("SCRIPT"));
    std::string line;
    while (std::getline(script, line)) {
        std::istringstream in(line);
        std::string mode;
        if (!(in >> mode)) continue;
        Step s{mode == "Q", 0, {}};
        if (s.quiet) in >> s.wait;
        std::string hex;
        while (in >> hex) s.bytes.push_back(std::stoi(hex, nullptr, 16));
        steps.push_back(s);
    }

    top->clk = 0;
    top->reset_n = 0;
    top->ftdi_rx_pin = 1;
    top->gpio_rx_pin = 1;
    top->buttons = 0;
    top->eval();

    // The receiver
    int bitNo = -1;
    long nextSample = 0;
    int byte = 0;
    long lastActive = 0;     // the last cycle tx was busy
    long received = 0;
    // The sender: the levels to drive, a bit at a time
    std::vector<int> bits;
    size_t bitAt = 0;
    long bitEnd = 0;
    // The script
    size_t step = 0;
    bool sending = false;
    long sentAt = 0;          // when the last step's bytes were all sent
    long receivedAtSent = 0;  // received, then
    bool lastQuiet = false;
    long lastWait = 0;

    long cycle = 0;
    for (; cycle < maxCycles; cycle++) {
        if (cycle == 10) top->reset_n = 1;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        const int tx = top->gpio_tx_pin;
        if (bitNo >= 0 || tx == 0) lastActive = cycle;
        if (bitNo < 0) {
            if (tx == 0 && cycle > 20) {
                bitNo = 0;
                byte = 0;
                nextSample = cycle + divisor + divisor / 2;
            }
        } else if (cycle == nextSample) {
            if (bitNo < 8) {
                byte |= tx << bitNo;
                bitNo++;
                nextSample += divisor;
            } else {
                printf("RX=%02x\n", byte);
                received++;
                bitNo = -1;
            }
        }

        if (sending) {
            if (cycle >= bitEnd) {
                if (bitAt == bits.size()) {
                    sending = false;
                    sentAt = cycle;
                    receivedAtSent = received;
                    top->gpio_rx_pin = 1;
                } else {
                    top->gpio_rx_pin = bits[bitAt++];
                    bitEnd = cycle + divisor;
                }
            }
            continue;
        }
        if (step == steps.size()) {
            // Done once the last step's wait is over
            if (lastQuiet ? cycle - sentAt >= lastWait
                          : received > receivedAtSent && cycle - lastActive >= idle)
                break;
            continue;
        }
        bool ready;
        if (step == 0) {
            ready = received > 0 && cycle - lastActive >= idle;
        } else if (lastQuiet) {
            ready = cycle - sentAt >= lastWait;
        } else {
            ready = received > receivedAtSent && cycle - lastActive >= idle;
        }
        if (!ready) continue;
        printf("STEP=%zu\n", step);
        bits.clear();
        for (int b : steps[step].bytes) {
            bits.push_back(0);
            for (int i = 0; i < 8; i++) bits.push_back((b >> i) & 1);
            bits.push_back(1);  // back to back, as a host sends them
        }
        bitAt = 0;
        bitEnd = cycle;
        sending = true;
        lastQuiet = steps[step].quiet;
        lastWait = steps[step].wait;
        step++;
    }
    printf("CYCLES=%ld STEPS=%zu LEDS=%02x\n", cycle, step, top->leds);
    delete top;
    return 0;
}
''';

/// The CRC-16 pmon uses (CRC-16/CCITT-FALSE).
int crc16(List<int> bytes, [int crc = 0xFFFF]) {
  for (final b in bytes) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// A frame: SOH, [cmd], [addr] and the length (little-endian), [data], the
/// CRC (high byte first); the length is data.length unless given.
List<int> frame(String cmd, int addr,
    {List<int> data = const [], int? length}) {
  final len = length ?? data.length;
  final body = [
    cmd.codeUnitAt(0),
    ...le32(addr),
    len & 0xFF, len >> 8,
    ...data,
  ];
  final crc = crc16(body);
  return [0x01, ...body, crc >> 8, crc & 0xFF];
}

List<int> le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

int word(List<int> b, int at) =>
    b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

const _ack = 0x06;
const _nak = 0x15;

void main() {
  final fastSim = Platform.environment['PARCORE_FAST_SIM'] != '0';

  group('pmon on the Parcore ULX3S design',
      skip: fastSim ? false : 'needs Verilator (PARCORE_FAST_SIM=1)', () {
    test('The banner, text commands, frames, and a frame cut short',
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
      File('$_dir/parcore_ulx3s_top.sv').writeAsStringSync(top.generateSynth());
      File('$_dir/sim_main.cpp').writeAsStringSync(_simMain);

      // The script: each step, and a check of what came back
      const at = 0x10010F00; // core 1's TCM
      final words = [0x11223344, 0x55667788, 0xDEADBEEF, 0x00C0FFEE];
      final data = [for (final w in words) ...le32(w)];
      final badCrc = frame('W', at, data: data)..[9] ^= 0x40;
      final steps = <(String, List<int>, void Function(List<int>))>[];
      void text(String line, void Function(String) check) => steps.add(
          ('R', line.codeUnits, (r) => check(String.fromCharCodes(r))));
      void reply(List<int> bytes, void Function(List<int>) check) =>
          steps.add(('R', bytes, check));

      text('s\r', (r) {
        expect(r, contains('state '));
        expect(r, contains('rst 80000000'), reason: 'booted, cores running');
        expect(r.endsWith('pmon> '), isTrue, reason: r);
      });
      reply(frame('H', 0x02), (r) => expect(r, equals([_ack])));
      text('w 10010f00 cafef00d\r', (r) => expect(r.endsWith('pmon> '), isTrue, reason: r));
      text('r 10010F00\r',
          (r) => expect(r, contains('10010F00: CAFEF00D')));
      text('x\r', (r) => expect(r, contains('?\r\n')));
      reply(frame('W', at, data: data), (r) => expect(r, equals([_ack])));
      reply(frame('R', at, length: 16), (r) {
        expect(r.length, equals(19), reason: '$r');
        expect(r[0], equals(_ack));
        expect(r.sublist(1, 17), equals(data));
        final crc = crc16(data);
        expect(r.sublist(17), equals([crc >> 8, crc & 0xFF]));
      });
      reply(badCrc, (r) => expect(r, equals([_nak, 1])));
      reply(frame('R', at + 2, length: 4), (r) => expect(r, equals([_nak, 3])));
      reply(frame('Q', 0), (r) => expect(r, equals([_nak, 2])));
      reply(frame('G', 0x02), (r) => expect(r, equals([_ack])));
      reply(frame('W', at, data: data), (r) => expect(r, equals([_nak, 4])));
      reply(frame('S', 0), (r) {
        expect(r.length, equals(1 + 28 + 2), reason: '$r');
        expect(r[0], equals(_ack));
        final body = r.sublist(1, 29);
        expect(word(body, 24), equals(0x80000000), reason: 'RST_CTRL');
        final crc = crc16(body);
        expect(r.sublist(29), equals([crc >> 8, crc & 0xFF]));
      });
      // Cut short: no answer, and dropped after the timeout (2.1 million
      // cycles), so the next frame is answered
      steps.add(('Q 3000000', frame('R', at, length: 4).sublist(0, 5),
          (r) => expect(r, isEmpty)));
      reply(frame('H', 0x02), (r) => expect(r, equals([_ack])));
      // (core 1 has run since the G: its TCM is written again)
      reply(frame('W', at, data: data), (r) => expect(r, equals([_ack])));
      reply(frame('R', at + 4, length: 4), (r) {
        expect(r.sublist(0, 5), equals([_ack, ...le32(words[1])]));
      });
      text('q\x08s\r', (r) => expect(r, contains('rst 80000002')));
      // Two lines at once: the second arrives while pmon answers the first,
      // and waits in the receive FIFO
      text('s\rr 10010f00\r', (r) {
        expect(r, contains('rst 80000002'));
        expect(r, contains('10010F00: 11223344'));
      });

      File('$_dir/script.txt').writeAsStringSync([
        for (final (mode, bytes, _) in steps)
          '$mode ${bytes.map((b) => b.toRadixString(16)).join(' ')}',
      ].join('\n'));

      final objDir = Directory('$_dir/obj_dir');
      if (objDir.existsSync()) objDir.deleteSync(recursive: true);
      final verilator = Platform.environment['VERILATOR'] ?? 'verilator';
      final build = Process.runSync(
        verilator,
        [
          '--cc', '--exe', '--build', '-O3', '-Wno-fatal',
          '--top-module', 'ParcoreUlx3sTop',
          'parcore_ulx3s_top.sv', 'sim_main.cpp',
          '-o', 'VParcoreUlx3sTop',
        ],
        workingDirectory: dir.path,
      );
      expect(build.exitCode, equals(0),
          reason: 'Verilator build failed:\n${build.stderr}');

      final divisor = top.parcore.consoleDivisor;
      final run = Process.runSync(
        '$_dir/obj_dir/VParcoreUlx3sTop',
        const [],
        environment: {
          'MAX_CYCLES': '20000000',
          'DIVISOR': '$divisor',
          'IDLE': '${divisor * 10 * 6}', // 6 bytes' time
          'SCRIPT': '$_dir/script.txt',
        },
      );
      expect(run.exitCode, equals(0), reason: '${run.stderr}');
      final out = '${run.stdout}';
      print(out.split('\n').where((l) => l.startsWith('CYCLES')).join());

      // What came back before each step (the banner before the first)
      final replies = <List<int>>[[]];
      for (final l in out.split('\n')) {
        if (l.startsWith('STEP=')) replies.add([]);
        if (l.startsWith('RX=')) {
          replies.last.add(int.parse(l.substring(3), radix: 16));
        }
      }
      expect(replies.length, equals(steps.length + 1),
          reason: 'not every step ran:\n$out');
      final banner = String.fromCharCodes(replies[0]);
      expect(banner, contains('Parcore conductor console'));
      expect(banner.endsWith('pmon> '), isTrue, reason: banner);
      for (var i = 0; i < steps.length; i++) {
        final (_, bytes, check) = steps[i];
        // A text command's answer starts with its echo
        try {
          check(replies[i + 1]);
        } catch (_) {
          print('step $i sent $bytes, got ${replies[i + 1]}');
          rethrow;
        }
      }
    }, timeout: const Timeout(Duration(minutes: 60)));
  });
}
