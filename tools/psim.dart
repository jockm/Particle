#!/usr/bin/env dart
// ==============================================================================
// Particle Cycle-Accurate Simulator & Debugger (psim.dart)
// Architecture: Particle 32-bit RISC (16-bit Compact ISA)
//
// Dart port of psim.py. Same command line, help/usage text, debugger commands
// and simulation results.
//
//   dart run tools/psim.dart [-h] [-d] [-b BASE] [binary]
//   dart compile exe tools/psim.dart -o psim
// ==============================================================================

import 'dart:io';

import 'psim_core.dart';
import 'psim_debugger.dart';
import 'psim_pycompat.dart';

// ------------------------------------------------------------------------------
// Command line parsing: a faithful emulation of the argparse parser used by
// psim.py (abbreviations, -dbVALUE style clustering, '--', error messages and
// exit codes), with:
//   parser.add_argument("binary", nargs="?", help="Path to binary file")
//   parser.add_argument("-d", "--debug", action="store_true", ...)
//   parser.add_argument("-b", "--base", default="0x00000100", ...)
// ------------------------------------------------------------------------------

class ParsedArgs {
  final bool debug;
  final String base;
  final String? binary;
  ParsedArgs(this.debug, this.base, this.binary);
}

/// Thrown when argument parsing finishes the program (help or usage error).
class ArgExit implements Exception {
  final int code;
  final String out;
  final String err;
  ArgExit(this.code, {this.out = '', this.err = ''});
}

class _ArgError implements Exception {
  final String message;
  _ArgError(this.message);
}

class _OptTuple {
  final String? action; // 'help' | 'debug' | 'base' | null (unknown option)
  final String optionString;
  final String? sep;
  final String? explicit;
  _OptTuple(this.action, this.optionString, this.sep, this.explicit);
}

// Insertion order matters for the "ambiguous option" message.
const List<String> _optionStrings = [
  '-h', '--help', '-d', '--debug', '-b', '--base', //
];
const Map<String, String> _actionOf = {
  '-h': 'help',
  '--help': 'help',
  '-d': 'debug',
  '--debug': 'debug',
  '-b': 'base',
  '--base': 'base',
};
const Map<String, String> _displayName = {
  'help': '-h/--help',
  'debug': '-d/--debug',
  'base': '-b/--base',
};
final RegExp _negativeNumber = RegExp(r'^-\d+$|^-\d*\.\d+$');

String usageLine(String prog) => 'usage: $prog [-h] [-d] [-b BASE] [binary]\n';

String helpText(String prog) => '${usageLine(prog)}'
    '\n'
    'Particle Simulator & Debugger\n'
    '\n'
    'positional arguments:\n'
    '  binary           Path to binary file\n'
    '\n'
    'options:\n'
    '  -h, --help       show this help message and exit\n'
    '  -d, --debug      Launch interactive debugger\n'
    '  -b, --base BASE  Load address\n';

/// argparse's _parse_optional: null means "positional".
List<_OptTuple>? _parseOptional(String a) {
  if (a.isEmpty) return null;
  if (a[0] != '-') return null;
  final exact = _actionOf[a];
  if (exact != null) return [_OptTuple(exact, a, null, null)];
  if (a.length == 1) return null;
  final eq = a.indexOf('=');
  if (eq >= 0) {
    final opt = a.substring(0, eq);
    final act = _actionOf[opt];
    if (act != null) return [_OptTuple(act, opt, '=', a.substring(eq + 1))];
  }
  final tuples = <_OptTuple>[];
  if (a[1] == '-') {
    final String prefix;
    final String? explicit;
    final String? sep;
    if (eq >= 0) {
      prefix = a.substring(0, eq);
      explicit = a.substring(eq + 1);
      sep = '=';
    } else {
      prefix = a;
      explicit = null;
      sep = null;
    }
    for (final o in _optionStrings) {
      if (o.startsWith(prefix)) {
        tuples.add(_OptTuple(_actionOf[o], o, sep, explicit));
      }
    }
  } else {
    final short = a.substring(0, 2);
    final act = _actionOf[short];
    if (act != null) tuples.add(_OptTuple(act, short, '', a.substring(2)));
  }
  if (tuples.isNotEmpty) return tuples;
  if (_negativeNumber.hasMatch(a)) return null;
  if (a.contains(' ')) return null;
  return [_OptTuple(null, a, null, null)];
}

ParsedArgs parseArgs(List<String> argv, String prog) {
  var debug = false;
  var base = '0x00000100';
  String? binary;
  var positionalUsed = false;
  final extras = <String>[];

  // Classify every argument: 'A' positional, '-' the '--' marker, 'O' option.
  final n = argv.length;
  final pattern = <String>[];
  final optInfo = <int, List<_OptTuple>>{};
  for (var i = 0; i < n; i++) {
    final a = argv[i];
    if (a == '--') {
      pattern.add('-');
      for (var j = i + 1; j < n; j++) {
        pattern.add('A');
      }
      break;
    }
    final t = _parseOptional(a);
    if (t == null) {
      pattern.add('A');
    } else {
      pattern.add('O');
      optInfo[i] = t;
    }
  }

  void consumePositionalChunk(int start, int end) {
    if (positionalUsed) {
      extras.addAll(argv.sublist(start, end));
      return;
    }
    positionalUsed = true;
    // nargs='?' pattern: -*A?-*
    var j = start;
    while (j < end && pattern[j] == '-') {
      j++;
    }
    if (j < end && pattern[j] == 'A') j++;
    while (j < end && pattern[j] == '-') {
      j++;
    }
    final args = argv.sublist(start, j);
    if (pattern.sublist(start, j).contains('-')) args.remove('--');
    binary = args.isNotEmpty ? args[0] : null;
    extras.addAll(argv.sublist(j, end));
  }

  try {
    var idx = 0;
    while (idx < n) {
      if (pattern[idx] != 'O') {
        var end = idx;
        while (end < n && pattern[end] != 'O') {
          end++;
        }
        consumePositionalChunk(idx, end);
        idx = end;
        continue;
      }
      final tuples = optInfo[idx]!;
      if (tuples.length > 1) {
        final matches = tuples.map((t) => t.optionString).join(', ');
        throw _ArgError(
            'ambiguous option: ${argv[idx]} could match $matches');
      }
      var action = tuples[0].action;
      var opt = tuples[0].optionString;
      var sep = tuples[0].sep;
      var explicit = tuples[0].explicit;
      final taken = <List<String?>>[]; // [action, value]
      var stop = idx + 1;
      while (true) {
        if (action == null) {
          extras.add(argv[idx]);
          break;
        }
        if (explicit != null) {
          final count = action == 'base' ? 1 : 0;
          if (count == 0 && opt[1] != '-' && explicit != '') {
            if ((sep != null && sep.isNotEmpty) || explicit[0] == '-') {
              throw _ArgError('argument ${_displayName[action]}: '
                  'ignored explicit argument ${pyRepr(explicit)}');
            }
            taken.add([action, null]);
            opt = '-${explicit[0]}';
            final next = _actionOf[opt];
            if (next != null) {
              action = next;
              explicit = explicit.substring(1);
              if (explicit.isEmpty) {
                sep = null;
                explicit = null;
              } else if (explicit[0] == '=') {
                sep = '=';
                explicit = explicit.substring(1);
              } else {
                sep = '';
              }
            } else {
              extras.add('-$explicit');
              break;
            }
          } else if (count == 1) {
            taken.add([action, explicit]);
            break;
          } else {
            throw _ArgError('argument ${_displayName[action]}: '
                'ignored explicit argument ${pyRepr(explicit)}');
          }
        } else {
          if (action == 'base') {
            if (idx + 1 < n && pattern[idx + 1] == 'A') {
              taken.add([action, argv[idx + 1]]);
              stop = idx + 2;
            } else {
              throw _ArgError('argument -b/--base: expected one argument');
            }
          } else {
            taken.add([action, null]);
          }
          break;
        }
      }
      for (final t in taken) {
        final act = t[0];
        if (act == 'help') {
          throw ArgExit(0, out: helpText(prog));
        } else if (act == 'debug') {
          debug = true;
        } else {
          base = t[1]!;
        }
      }
      idx = stop;
    }
    if (extras.isNotEmpty) {
      throw _ArgError('unrecognized arguments: ${extras.join(' ')}');
    }
  } on _ArgError catch (e) {
    throw ArgExit(2, err: '${usageLine(prog)}$prog: error: ${e.message}\n');
  }
  return ParsedArgs(debug, base, binary);
}

/// argparse uses os.path.basename(sys.argv[0]) as the program name.
String programName() {
  try {
    final segs = Platform.script.pathSegments;
    if (segs.isNotEmpty && segs.last.isNotEmpty) return segs.last;
  } on Object {
    // fall through
  }
  return 'psim';
}

// ------------------------------------------------------------------------------
// Python-style reporting of an escaped OSError from open(path, 'rb').
// ------------------------------------------------------------------------------

class _PyOSError implements Exception {
  final String text;
  _PyOSError(this.text);
}

List<int> _readBinary(String path) {
  if (FileSystemEntity.isDirectorySync(path)) {
    throw _PyOSError(
        'IsADirectoryError: [Errno 21] Is a directory: ${pyRepr(path)}');
  }
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode ?? 0;
    final String kind;
    final String msg;
    if (code == 2 || (code == 0 && !File(path).existsSync())) {
      kind = 'FileNotFoundError';
      msg = '[Errno 2] No such file or directory';
    } else if (code == 13) {
      kind = 'PermissionError';
      msg = '[Errno 13] Permission denied';
    } else if (code == 21) {
      kind = 'IsADirectoryError';
      msg = '[Errno 21] Is a directory';
    } else {
      kind = 'OSError';
      msg = '[Errno $code] ${e.osError?.message ?? e.message}';
    }
    throw _PyOSError('$kind: $msg: ${pyRepr(path)}');
  }
}

// ------------------------------------------------------------------------------

Future<int> _run(List<String> argv) async {
  final prog = programName();
  final ParsedArgs args;
  try {
    args = parseArgs(argv, prog);
  } on ArgExit catch (e) {
    stdout.write(e.out);
    stderr.write(e.err);
    return e.code;
  }

  final core = ParticleCore();
  final binary = args.binary;
  final hasBinary = binary != null && binary.isNotEmpty;

  try {
    if (hasBinary) {
      final baseAddr = pyInt(args.base, 0);
      final data = _readBinary(binary!);
      core.loadImage(baseAddr, data);
      stdout.write('Loaded ${data.length} bytes at 0x${hex8(baseAddr)}. '
          'Particle Debugger (p4db) ready.\n');
    }

    if (args.debug || !hasBinary) {
      await Debugger(core).cmdloop();
    } else {
      await runToCompletion(core, 10000000);
      stdout.write('Simulation completed in ${core.cycleCount} cycles. '
          'PC = 0x${hex8(core.pc)}\n');
    }
  } on PyValueError catch (e) {
    stderr.write('$e\n');
    return 1;
  } on _PyOSError catch (e) {
    stderr.write('${e.text}\n');
    return 1;
  } on KeyboardInterrupt {
    stderr.write('\nKeyboardInterrupt\n');
    return 130;
  }
  return 0;
}

Future<void> main(List<String> argv) async {
  final code = await _run(argv);
  try {
    await stdout.flush();
    await stderr.flush();
  } on Object {
    // Output closed (e.g. piped into `head`); nothing more to do.
  }
  // stdin may still be subscribed; exit explicitly so the process ends.
  exit(code);
}
