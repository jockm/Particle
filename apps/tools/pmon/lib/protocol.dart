// The host side of pmon's frames (firmware/parcore/conductor/pmon.inc;
// Documentation/pmon.md).
//
// A frame: SOH, the command, the address (4 bytes) and the length (2), both
// little-endian, the data (W only), and the CRC-16 of the command to the
// data, high byte first. The answer: ACK; NAK and an error code; for R and
// S, ACK, the data and its CRC-16.

import 'dart:async';
import 'dart:typed_data';

const soh = 0x01;
const ack = 0x06;
const nak = 0x15;

/// The most data a frame carries (W) or asks for (R).
const maxFrameData = 256;

/// The cores' TCMs as the conductor sees them: core n at
/// coreWindow + (n << 16).
const coreWindow = 0x10000000;

/// The cores pmon can hold and let go: RST_CTRL bits 5:0.
const coreMask = 0x3F;

/// CRC-16/CCITT-FALSE: polynomial 0x1021, starting at 0xFFFF.
int crc16(List<int> bytes, [int crc = 0xFFFF]) {
  for (final b in bytes) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// The frame for [command] (a letter), [address] and [data]; [length] is
/// data.length unless given (R gives it and no data).
List<int> encodeFrame(String command, int address,
    {List<int> data = const [], int? length}) {
  final len = length ?? data.length;
  if (len < 0 || len > 0xFFFF) throw ArgumentError('length $len');
  final body = [
    command.codeUnitAt(0),
    ...le32(address),
    len & 0xFF,
    len >> 8,
    ...data,
  ];
  final crc = crc16(body);
  return [soh, ...body, crc >> 8, crc & 0xFF];
}

List<int> le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

int readLe32(List<int> b, int at) =>
    (b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24) & 0xFFFFFFFF;

/// pmon's error codes (NAK and one of these).
enum PmonErrorCode {
  crc(1, 'bad CRC'),
  command(2, 'unknown command'),
  align(3, 'address or length not a multiple of 4, or over 256'),
  held(4, "the core isn't held");

  const PmonErrorCode(this.code, this.text);
  final int code;
  final String text;

  static PmonErrorCode? of(int code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

class PmonException implements Exception {
  PmonException(this.message, {this.code});
  final String message;
  final PmonErrorCode? code;
  @override
  String toString() => 'pmon: $message';
}

/// A byte link to pmon: the serial port, or a fake in tests.
abstract class PmonLink {
  void write(List<int> bytes);

  /// The next byte, or null if none comes within [timeout].
  Future<int?> readByte(Duration timeout);

  /// Drops whatever has arrived and not been read.
  void discardInput();

  Future<void> close();
}

/// The state S reports.
class PmonStatus {
  PmonStatus(List<int> words)
      : coreState = words[0],
        cycles = words[1],
        pcs = words.sublist(2, 6),
        rstCtrl = words[6];

  /// CORE_STATE: 2 bits a core.
  final int coreState;
  final int cycles;

  /// The PCs of cores 0-3.
  final List<int> pcs;
  final int rstCtrl;

  static const _states = ['running', 'waiting', 'halted', 'in reset'];

  String stateOf(int core) => _states[(coreState >> (2 * core)) & 3];
  bool held(int core) => (rstCtrl >> core) & 1 == 1;
  bool get booted => (rstCtrl >> 31) & 1 == 1;

  @override
  String toString() {
    String hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';
    return [
      'cycles   ${hex(cycles)}',
      'rst_ctrl ${hex(rstCtrl)}${booted ? ' (booted)' : ''}',
      for (var n = 0; n < 4; n++)
        'core $n   ${stateOf(n).padRight(9)} pc ${hex(pcs[n])}',
    ].join('\n');
  }
}

/// pmon's frames over a [PmonLink]. A frame that gets no answer, or NAK for
/// a bad CRC, is sent again (up to [retries] times), after a pause long
/// enough for pmon to drop a frame it was part way through.
class PmonClient {
  PmonClient(this.link,
      {this.timeout = const Duration(milliseconds: 500),
      this.dropTime = const Duration(milliseconds: 150),
      this.retries = 3});

  final PmonLink link;
  final Duration timeout;
  final Duration dropTime;
  final int retries;

  Future<void> hold(int mask) => _simple('H', mask & coreMask);
  Future<void> go(int mask) => _simple('G', mask & coreMask);

  /// Boot again from flash (pmon answers, then reboots).
  Future<void> boot() => _simple('B', 0);

  Future<PmonStatus> status() async {
    final data = await _withReply('S', 0, 28);
    return PmonStatus([for (var i = 0; i < 28; i += 4) readLe32(data, i)]);
  }

  /// Writes [data] (padded with zeros to a multiple of 4) at [address], in
  /// frames of up to 256 bytes; [progress] hears the bytes written so far.
  Future<void> write(int address, List<int> data,
      {void Function(int done, int total)? progress}) async {
    _checkAligned(address);
    final padded = [...data, ...List.filled((4 - data.length % 4) % 4, 0)];
    for (var at = 0; at < padded.length; at += maxFrameData) {
      final end = (at + maxFrameData).clamp(0, padded.length);
      await _exchange(
          encodeFrame('W', address + at, data: padded.sublist(at, end)), 0);
      progress?.call(end, padded.length);
    }
  }

  /// Reads [length] bytes (a multiple of 4) at [address].
  Future<Uint8List> read(int address, int length,
      {void Function(int done, int total)? progress}) async {
    _checkAligned(address);
    if (length % 4 != 0) {
      throw ArgumentError('the length must be a multiple of 4, not $length');
    }
    final out = BytesBuilder();
    for (var at = 0; at < length; at += maxFrameData) {
      final n = (length - at).clamp(0, maxFrameData);
      out.add(await _withReply('R', address + at, n));
      progress?.call(at + n, length);
    }
    return out.toBytes();
  }

  /// Loads [image] into core [core]'s TCM at [offset]: holds the core,
  /// writes it, reads it back if [verify], and lets the core go if
  /// [release].
  Future<void> load(int core, List<int> image,
      {int offset = 0x100,
      bool verify = true,
      bool release = true,
      void Function(String stage, int done, int total)? progress}) async {
    if (core < 0 || core > 3) throw ArgumentError('core $core: 0 to 3');
    final base = coreWindow + (core << 16) + offset;
    await hold(1 << core);
    await write(base, image,
        progress: (d, t) => progress?.call('write', d, t));
    if (verify) {
      final back = await read(base, (image.length + 3) & ~3,
          progress: (d, t) => progress?.call('verify', d, t));
      for (var i = 0; i < image.length; i++) {
        if (back[i] != image[i]) {
          throw PmonException('verify: byte ${i} (0x'
              '${(base + i).toRadixString(16)}) reads '
              '0x${back[i].toRadixString(16)}, not '
              '0x${image[i].toRadixString(16)}');
        }
      }
    }
    if (release) await go(1 << core);
  }

  void _checkAligned(int address) {
    if (address % 4 != 0) {
      throw ArgumentError(
          'the address must be a multiple of 4, not 0x${address.toRadixString(16)}');
    }
  }

  Future<void> _simple(String cmd, int address) async {
    await _exchange(encodeFrame(cmd, address), 0);
  }

  Future<Uint8List> _withReply(String cmd, int address, int length) =>
      _exchange(encodeFrame(cmd, address, length: length), length);

  /// Sends [frame] and reads the answer: ACK and [replyLength] bytes of
  /// data with their CRC (none if 0). Tries again on silence, a bad CRC
  /// either way, or a short answer.
  Future<Uint8List> _exchange(List<int> frame, int replyLength) async {
    String? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(dropTime);
      link.discardInput();
      link.write(frame);
      final first = await link.readByte(timeout);
      if (first == null) {
        last = 'no answer';
        continue;
      }
      if (first == nak) {
        final code = await link.readByte(timeout);
        final e = code == null ? null : PmonErrorCode.of(code);
        if (e == PmonErrorCode.crc) {
          last = 'NAK: ${e!.text}';
          continue;
        }
        throw PmonException(
            'NAK: ${e?.text ?? 'error ${code ?? '(none)'}'}',
            code: e);
      }
      if (first != ack) {
        last = 'answer 0x${first.toRadixString(16)}, not ACK or NAK';
        continue;
      }
      if (replyLength == 0) return Uint8List(0);
      final reply = <int>[];
      while (reply.length < replyLength + 2) {
        final b = await link.readByte(timeout);
        if (b == null) break;
        reply.add(b);
      }
      if (reply.length < replyLength + 2) {
        last = 'answer cut short (${reply.length} of ${replyLength + 2} bytes)';
        continue;
      }
      if (crc16(reply) != 0) {
        last = "the answer's CRC is wrong";
        continue;
      }
      return Uint8List.fromList(reply.sublist(0, replyLength));
    }
    throw PmonException('$last (after ${retries + 1} tries)');
  }
}
