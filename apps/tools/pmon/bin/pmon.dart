// pmon: the host side of the Parcore conductor's console
// (Documentation/pmon.md).
//
//   pmon [--port PORT] [--baud 115200] COMMAND ...
//
// The port defaults to $PMON_PORT.

import 'dart:async';
import 'dart:io';

import 'package:pmon/protocol.dart';
import 'package:pmon/serial.dart';

const usage = '''
Usage: pmon [--port PORT] [--baud BAUD] COMMAND ...

The port defaults to \$PMON_PORT; the baud rate to 115200.

Commands:
  status                    The cores' states and PCs, CYCLES and RST_CTRL
  hold MASK                 Hold cores in reset (bit n: core n)
  go MASK                   Let cores go
  read ADDR [LENGTH]        Read LENGTH bytes (default 4), as words
  write ADDR WORD ...       Write words
  load FILE --core N [--offset OFF] [--no-verify] [--no-go]
                            Load a binary into core N's TCM at OFF (default
                            0x100): hold the core, write, read back, let it go
  boot                      Boot again from flash
  console                   The text monitor and the guest's console; Ctrl-]
                            leaves

Numbers are decimal, or hex with 0x.''';

Never fail(String message) {
  stderr.writeln('pmon: $message');
  exit(2);
}

int number(String s, String what) {
  final v = s.startsWith('0x') || s.startsWith('0X')
      ? int.tryParse(s.substring(2), radix: 16)
      : int.tryParse(s);
  if (v == null) fail('$what: not a number: $s');
  return v;
}

String hex8(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

Future<void> main(List<String> argv) async {
  var port = Platform.environment['PMON_PORT'];
  var baud = 115200;
  final args = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--port' && i + 1 < argv.length) {
      port = argv[++i];
    } else if (a == '--baud' && i + 1 < argv.length) {
      baud = number(argv[++i], '--baud');
    } else if (a == '-h' || a == '--help') {
      print(usage);
      exit(0);
    } else {
      args.add(a);
    }
  }
  if (args.isEmpty) {
    stderr.writeln(usage);
    exit(2);
  }
  if (port == null || port.isEmpty) {
    fail('no port: give --port PORT or set PMON_PORT');
  }

  final SerialLink link;
  try {
    link = await SerialLink.open(port, baud: baud);
  } on PmonException catch (e) {
    fail(e.message);
  }
  var code = 0;
  try {
    code = await run(link, args.first, args.sublist(1));
  } on PmonException catch (e) {
    stderr.writeln(e);
    code = 1;
  } on ArgumentError catch (e) {
    stderr.writeln('pmon: ${e.message}');
    code = 2;
  }
  await link.close();
  exit(code);
}

Future<int> run(SerialLink link, String command, List<String> args) async {
  final pmon = PmonClient(link);
  switch (command) {
    case 'status':
      print(await pmon.status());
    case 'hold' || 'go':
      if (args.length != 1) fail('$command MASK');
      final mask = number(args[0], 'MASK');
      command == 'hold' ? await pmon.hold(mask) : await pmon.go(mask);
    case 'read':
      if (args.isEmpty || args.length > 2) fail('read ADDR [LENGTH]');
      final addr = number(args[0], 'ADDR');
      final len = args.length > 1 ? number(args[1], 'LENGTH') : 4;
      final data = await pmon.read(addr, len);
      for (var i = 0; i < data.length; i += 4) {
        print('${hex8(addr + i)}: ${hex8(readLe32(data, i))}');
      }
    case 'write':
      if (args.length < 2) fail('write ADDR WORD ...');
      final addr = number(args[0], 'ADDR');
      await pmon.write(addr, [
        for (final w in args.skip(1)) ...le32(number(w, 'WORD')),
      ]);
    case 'load':
      String? file;
      int? core;
      var offset = 0x100;
      var verify = true;
      var release = true;
      for (var i = 0; i < args.length; i++) {
        final a = args[i];
        if (a == '--core' && i + 1 < args.length) {
          core = number(args[++i], '--core');
        } else if (a == '--offset' && i + 1 < args.length) {
          offset = number(args[++i], '--offset');
        } else if (a == '--no-verify') {
          verify = false;
        } else if (a == '--no-go') {
          release = false;
        } else if (file == null) {
          file = a;
        } else {
          fail('load: unexpected $a');
        }
      }
      if (file == null || core == null) fail('load FILE --core N');
      final image = File(file).readAsBytesSync();
      final sw = Stopwatch()..start();
      var lastStage = '';
      await pmon.load(core, image,
          offset: offset, verify: verify, release: release,
          progress: (stage, done, total) {
        if (stage != lastStage && lastStage.isNotEmpty) stdout.writeln();
        lastStage = stage;
        stdout.write('\r$stage ${done * 100 ~/ total}% ($done/$total)');
      });
      stdout.writeln();
      print('loaded ${image.length} bytes into core $core at '
          '${hex8(coreWindow + (core << 16) + offset)} in '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
          '${release ? '' : ' (held)'}');
    case 'boot':
      await pmon.boot();
    case 'console':
      return console(link);
    default:
      fail('unknown command $command\n$usage');
  }
  return 0;
}

/// The port to the terminal and back, until Ctrl-].
Future<int> console(SerialLink link) async {
  if (!stdin.hasTerminal) fail('console needs a terminal');
  stderr.writeln('pmon console on ${link.port} (Ctrl-] leaves)');
  link.onData = stdout.add;
  stdin.echoMode = false;
  stdin.lineMode = false;
  final done = Completer<void>();
  final sub = stdin.listen((data) {
    final quit = data.indexOf(0x1D);
    if (quit >= 0) {
      if (quit > 0) link.write(data.sublist(0, quit));
      if (!done.isCompleted) done.complete();
      return;
    }
    link.write(data);
  }, onDone: () {
    if (!done.isCompleted) done.complete();
  });
  // A prompt to start with
  link.write([13]);
  await done.future;
  await sub.cancel();
  stdin.lineMode = true;
  stdin.echoMode = true;
  stderr.writeln();
  return 0;
}
