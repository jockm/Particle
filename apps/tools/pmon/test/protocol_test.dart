// The host side of pmon against a model of the conductor's frame handling
// (firmware/parcore/conductor/pmon.inc), over a link that can lose and
// corrupt bytes.

import 'dart:async';
import 'dart:collection';

import 'package:pmon/protocol.dart';
import 'package:test/test.dart';

/// pmon's frames, as the firmware handles them, over memory.
class FakePmon {
  FakePmon({this.flashWritable = false});

  final memory = <int, int>{}; // byte address -> byte
  final flashMemory = <int, int>{}; // erased (0xFF) where absent
  final bool flashWritable;
  var erases = 0;
  var programs = 0;
  int rstCtrl = 0x80000000;
  int cycles = 1000;
  final List<int> pcs = [0x2000, 0x268, 0x230, 0x21A];

  final _in = <int>[];
  final out = <int>[];

  /// A byte from the host; answers once a frame is whole.
  void receive(int b) {
    if (_in.isEmpty && b != soh) return; // text: not modelled
    _in.add(b);
    if (_in.length < 8) return;
    final cmd = String.fromCharCode(_in[1]);
    final len = _in[6] | _in[7] << 8;
    final dataLen = cmd == 'W' || cmd == 'P' ? len : 0;
    if (_in.length < 8 + dataLen + 2) return;
    final f = List.of(_in);
    _in.clear();
    _frame(f, cmd, readLe32(f, 2), len);
  }

  /// Drops a frame cut short (the firmware's timeout).
  void timeout() => _in.clear();

  void _frame(List<int> f, String cmd, int addr, int len) {
    final aligned = (addr | len) % 4 == 0 && len <= 256;
    var err = aligned ? 0 : 3;
    if (cmd == 'W' && err == 0 && addr >> 28 == 1) {
      final core = (addr >> 16) & 7;
      if ((rstCtrl >> core) & 1 == 0) err = 4;
    }
    if (crc16(f.sublist(1)) != 0) return _nak(1);
    switch (cmd) {
      case 'H':
        rstCtrl |= addr & coreMask;
        out.add(ack);
      case 'G':
        rstCtrl &= ~(addr & coreMask);
        out.add(ack);
      case 'W':
        if (err != 0) return _nak(err);
        for (var i = 0; i < len; i++) {
          memory[addr + i] = f[8 + i];
        }
        out.add(ack);
      case 'R':
        if (err != 0) return _nak(err);
        _reply([for (var i = 0; i < len; i++) memory[addr + i] ?? 0]);
      case 'S':
        _reply([
          for (final w in [0xC0, cycles, ...pcs, rstCtrl]) ...le32(w),
        ]);
      case 'B':
        out.add(ack);
      case 'F':
        if (err != 0) return _nak(err);
        _reply([for (var i = 0; i < len; i++) flashMemory[addr + i] ?? 0xFF]);
      case 'E':
        if (addr % 4096 != 0) return _nak(3);
        if (!flashWritable) return _nak(6);
        if (addr < 0x400000 || addr + 4096 > 0x1000000) return _nak(5);
        for (var i = 0; i < 4096; i++) {
          flashMemory.remove(addr + i);
        }
        erases++;
        out.add(ack);
      case 'P':
        if (err != 0) return _nak(err);
        if (addr % 256 + len > 256) return _nak(3);
        if (!flashWritable) return _nak(6);
        if (addr < 0x400000 || addr + len > 0x1000000) return _nak(5);
        for (var i = 0; i < len; i++) {
          flashMemory[addr + i] = (flashMemory[addr + i] ?? 0xFF) & f[8 + i];
        }
        programs++;
        out.add(ack);
      default:
        _nak(2);
    }
  }

  void _nak(int code) => out.addAll([nak, code]);

  void _reply(List<int> data) {
    final crc = crc16(data);
    out.addAll([ack, ...data, crc >> 8, crc & 0xFF]);
  }
}

/// A link to a [FakePmon]; [corrupt] may change or drop each byte either
/// way (return null to drop it).
class FakeLink implements PmonLink {
  FakeLink(this.pmon, {this.corrupt});

  final FakePmon pmon;
  int? Function(int index, int byte, bool toPmon)? corrupt;
  final _pending = Queue<int>();
  var _sent = 0;
  var _received = 0;
  final written = <List<int>>[];

  @override
  void write(List<int> bytes) {
    written.add(List.of(bytes));
    for (final b in bytes) {
      final c = corrupt == null ? b : corrupt!(_sent, b, true);
      _sent++;
      if (c != null) pmon.receive(c);
    }
    for (final b in pmon.out) {
      final c = corrupt == null ? b : corrupt!(_received, b, false);
      _received++;
      if (c != null) _pending.add(c);
    }
    pmon.out.clear();
  }

  @override
  Future<int?> readByte(Duration timeout) async {
    if (_pending.isEmpty) {
      pmon.timeout(); // the host waited: pmon has dropped a part frame
      return null;
    }
    return _pending.removeFirst();
  }

  @override
  void discardInput() => _pending.clear();

  @override
  Future<void> close() async {}
}

/// The error [f] ends with (it must end with one).
Future<Object> errorOf(Future<void> f) async {
  try {
    await f;
  } catch (e) {
    return e;
  }
  fail('no error');
}

PmonClient client(FakeLink link) => PmonClient(link,
    timeout: Duration.zero, dropTime: Duration.zero, retries: 3);

void main() {
  test('crc16 is CRC-16/CCITT-FALSE, and runs to 0 over its own CRC', () {
    expect(crc16('123456789'.codeUnits), equals(0x29B1));
    final data = [1, 2, 3, 0xFF];
    final c = crc16(data);
    expect(crc16([...data, c >> 8, c & 0xFF]), equals(0));
  });

  test('encodeFrame lays out SOH, command, address, length, data, CRC', () {
    final f = encodeFrame('W', 0x10010100, data: [0xAA, 0xBB, 0xCC, 0xDD]);
    expect(f.sublist(0, 8),
        equals([soh, 0x57, 0x00, 0x01, 0x01, 0x10, 4, 0]));
    expect(f.sublist(8, 12), equals([0xAA, 0xBB, 0xCC, 0xDD]));
    expect(crc16(f.sublist(1)), equals(0));
    final r = encodeFrame('R', 0x100, length: 256);
    expect(r.length, equals(10));
    expect(r.sublist(6, 8), equals([0, 1]));
  });

  test('hold, go and status', () async {
    final pmon = FakePmon();
    final c = client(FakeLink(pmon));
    await c.hold(0x0A);
    expect(pmon.rstCtrl, equals(0x8000000A));
    await c.go(0x02);
    expect(pmon.rstCtrl, equals(0x80000008));
    final s = await c.status();
    expect(s.rstCtrl, equals(0x80000008));
    expect(s.booted, isTrue);
    expect(s.held(3), isTrue);
    expect(s.held(1), isFalse);
    expect(s.pcs, equals([0x2000, 0x268, 0x230, 0x21A]));
    expect(s.stateOf(3), equals('in reset'));
    expect(s.stateOf(0), equals('running'));
    expect(s.toString(), contains('core 3   in reset'));
  });

  test('load writes in 256-byte frames, verifies, and lets the core go',
      () async {
    final pmon = FakePmon();
    final link = FakeLink(pmon);
    final image = [for (var i = 0; i < 1000; i++) (i * 7) & 0xFF];
    final stages = <String>{};
    await client(link).load(2, image,
        progress: (stage, done, total) => stages.add(stage));
    for (var i = 0; i < image.length; i++) {
      expect(pmon.memory[0x10020100 + i], equals(image[i]));
    }
    // Padded to 1000 (a multiple of 4): 4 W frames, the last of 232 bytes
    final ws = link.written.where((f) => f[1] == 0x57).toList();
    expect(ws.map((f) => f[6] | f[7] << 8).toList(),
        equals([256, 256, 256, 232]));
    expect(stages.toList(), equals(['write', 'verify']));
    expect(pmon.rstCtrl & 0x04, equals(0), reason: 'core 2 let go');
  });

  test('load --no-go leaves the core held', () async {
    final pmon = FakePmon();
    await client(FakeLink(pmon)).load(1, [1, 2, 3], release: false);
    expect(pmon.rstCtrl & 0x02, equals(0x02));
    expect([for (var i = 0; i < 4; i++) pmon.memory[0x10010100 + i]],
        equals([1, 2, 3, 0]));
  });

  test('A byte corrupted on the way to pmon: NAK 1, sent again', () async {
    final pmon = FakePmon()..rstCtrl = 0x80000002;
    var hit = false;
    final link = FakeLink(pmon, corrupt: (i, b, toPmon) {
      if (toPmon && i == 10 && !hit) {
        hit = true;
        return b ^ 0x10;
      }
      return b;
    });
    await client(link).write(0x10010100, [9, 8, 7, 6]);
    expect(pmon.memory[0x10010100], equals(9));
    expect(link.written.length, equals(2));
  });

  test('A byte lost on the way: no answer, sent again after the timeout',
      () async {
    final pmon = FakePmon()..rstCtrl = 0x80000002;
    var hit = false;
    final link = FakeLink(pmon, corrupt: (i, b, toPmon) {
      if (toPmon && i == 5 && !hit) {
        hit = true;
        return null;
      }
      return b;
    });
    await client(link).write(0x10010100, [1, 1, 1, 1]);
    expect(pmon.memory[0x10010100], equals(1));
    expect(link.written.length, equals(2));
  });

  test("An answer's CRC wrong: read again", () async {
    final pmon = FakePmon();
    for (var i = 0; i < 8; i++) {
      pmon.memory[0x200 + i] = i + 1;
    }
    var hit = false;
    final link = FakeLink(pmon, corrupt: (i, b, toPmon) {
      if (!toPmon && i == 3 && !hit) {
        hit = true;
        return b ^ 1;
      }
      return b;
    });
    expect(await client(link).read(0x200, 8),
        equals([1, 2, 3, 4, 5, 6, 7, 8]));
    expect(link.written.length, equals(2));
  });

  test('Errors other than a bad CRC are not retried', () async {
    final pmon = FakePmon(); // core 1 not held
    final link = FakeLink(pmon);
    final e = await errorOf(client(link).write(0x10010100, [1, 2, 3, 4]));
    expect(e is PmonException && e.code == PmonErrorCode.held, isTrue,
        reason: '$e');
    expect(link.written.length, equals(1));
  });

  test('Silence every time: gives up after the retries', () async {
    final pmon = FakePmon();
    final link = FakeLink(pmon, corrupt: (i, b, toPmon) => null);
    final e = await errorOf(client(link).hold(1));
    expect(e is PmonException, isTrue, reason: '$e');
    expect('$e', contains('after 4 tries'));
    expect(link.written.length, equals(4));
  });

  test('flash erases the sectors, programs the pages, skips blank ones, '
      'and verifies', () async {
    final pmon = FakePmon(flashWritable: true);
    pmon.flashMemory[0x401000] = 0x00; // old data, erased first
    final image = [
      for (var i = 0; i < 5001; i++) i < 256 || i >= 512 ? (i * 3) & 0xFF : 0xFF,
    ];
    final stages = <String>[];
    await client(FakeLink(pmon)).flash(0x400000, image,
        progress: (stage, done, total) {
      if (stages.isEmpty || stages.last != stage) stages.add(stage);
    });
    expect(pmon.erases, equals(2));
    // 5004 bytes (padded with 0xFF): 20 pages, the blank second one skipped
    expect(pmon.programs, equals(19));
    for (var i = 0; i < image.length; i++) {
      expect(pmon.flashMemory[0x400000 + i] ?? 0xFF, equals(image[i]));
    }
    expect(pmon.flashMemory[0x401000 + 905] ?? 0xFF, equals(0xFF),
        reason: 'past the image, still erased');
    expect(stages, equals(['erase', 'program', 'verify']));
  });

  test('readFlash reads the flash (or the on-chip ROM)', () async {
    final pmon = FakePmon();
    pmon.flashMemory[0x400000] = 0x50;
    pmon.flashMemory[0x400001] = 0x41;
    expect(await client(FakeLink(pmon)).readFlash(0x400000, 4),
        equals([0x50, 0x41, 0xFF, 0xFF]));
  });

  test("The flash can't be written without PARCORE_REAL_FLASH: NAK 6",
      () async {
    final c = client(FakeLink(FakePmon()));
    final e = await errorOf(c.eraseSector(0x400000));
    expect(e is PmonException && e.code == PmonErrorCode.noFlash, isTrue,
        reason: '$e');
  });

  test('Below 0x400000 (the bitstream): refused by the tool, NAK 5 by pmon',
      () async {
    final c = client(FakeLink(FakePmon(flashWritable: true)));
    expect(await errorOf(c.flash(0x3FF000, [1, 2, 3, 4])) is ArgumentError,
        isTrue);
    final e = await errorOf(c.eraseSector(0x3FF000));
    expect(e is PmonException && e.code == PmonErrorCode.range, isTrue,
        reason: '$e');
    expect(await errorOf(c.programPage(0x4000FC, List.filled(8, 0))) is
        ArgumentError, isTrue, reason: 'across a page');
  });

  test('Misaligned addresses and lengths are refused before sending',
      () async {
    final c = client(FakeLink(FakePmon()));
    for (final f in <Future<void> Function()>[
      () => c.read(0x202, 4),
      () => c.read(0x200, 6),
      () => c.write(0x201, [1]),
    ]) {
      expect(await errorOf(f()) is ArgumentError, isTrue);
    }
  });
}
