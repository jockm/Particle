// ------------------------------------------------------------------------------
// Command-line interface
// ------------------------------------------------------------------------------
//
// A small hand-written option parser that accepts the same options as the
// Python compiler's argparse interface:
//
//   action [-h] [-o OUTPUT] [-D DEFINE] [-I INCLUDE_DIR]
//          [-fbounds-check] [-fno-bounds-check]
//          [-freference-check] [-fno-reference-check] sources [sources ...]

import 'dart:io';

import 'driver.dart';
import 'errors.dart';
import 'paths.dart' as p;

const String toolName = 'action';

const String usageLine =
    'usage: $toolName [-h] [-o OUTPUT] [-D DEFINE] [-I INCLUDE_DIR] [-fbounds-check]\n'
    '              [-fno-bounds-check] [-freference-check] [-fno-reference-check]\n'
    '              sources [sources ...]';

const String helpText = '''$usageLine

Action Systems Language Compiler for Particle

positional arguments:
  sources               Input Action source file(s) (.act)

options:
  -h, --help            show this help message and exit
  -o, --output OUTPUT   Output assembly file (.asm)
  -D, --define DEFINE   Predefine symbol (KEY[=VALUE])
  -I, --include-dir INCLUDE_DIR
                        Add include search directory
  -fbounds-check        Enable runtime array bounds checking (default)
  -fno-bounds-check     Disable runtime array bounds checking
  -freference-check     Enable runtime null reference checking (default)
  -fno-reference-check  Disable runtime null reference checking''';

/// argparse-style option names used in error messages.
const _displayName = {
  'output': '-o/--output',
  'define': '-D/--define',
  'include': '-I/--include-dir',
};

/// Parsed command-line arguments.
class CliArgs {
  final List<String> sources = [];
  String? output;
  final List<String> defines = [];
  final List<String> includeDirs = [];
  bool boundsCheck = true;
  bool referenceCheck = true;
  bool help = false;
}

/// Raised for invalid command-line usage (argparse exits with status 2).
class UsageError implements Exception {
  final String message;
  UsageError(this.message);
}

/// Parses [argv]. Options may be given as `-o FILE`, `-oFILE`,
/// `--output FILE` or `--output=FILE`; `--` ends option parsing.
CliArgs parseArgs(List<String> argv) {
  final a = CliArgs();
  var i = 0;
  var optionsDone = false;

  String takeValue(String opt, String? inline) {
    if (inline != null) return inline;
    if (i + 1 >= argv.length || (argv[i + 1].startsWith('-') && argv[i + 1] != '-')) {
      throw UsageError('argument $opt: expected one argument');
    }
    i++;
    return argv[i];
  }

  const valueOpts = {
    '-o': 'output',
    '--output': 'output',
    '-D': 'define',
    '--define': 'define',
    '-I': 'include',
    '--include-dir': 'include',
  };

  void store(String kind, String value) {
    switch (kind) {
      case 'output':
        a.output = value;
      case 'define':
        a.defines.add(value);
      case 'include':
        a.includeDirs.add(value);
    }
  }

  final unknown = <String>[];
  while (i < argv.length) {
    final arg = argv[i];
    if (optionsDone || !arg.startsWith('-') || arg == '-') {
      a.sources.add(arg);
    } else if (arg == '--') {
      optionsDone = true;
    } else if (arg == '-h' || arg == '--help') {
      a.help = true;
    } else if (arg == '-fbounds-check') {
      a.boundsCheck = true;
    } else if (arg == '-fno-bounds-check') {
      a.boundsCheck = false;
    } else if (arg == '-freference-check') {
      a.referenceCheck = true;
    } else if (arg == '-fno-reference-check') {
      a.referenceCheck = false;
    } else if (arg.startsWith('--')) {
      final eq = arg.indexOf('=');
      final name = eq < 0 ? arg : arg.substring(0, eq);
      final inline = eq < 0 ? null : arg.substring(eq + 1);
      final kind = valueOpts[name];
      if (kind == null) {
        unknown.add(arg);
      } else {
        store(kind, takeValue(_displayName[kind]!, inline));
      }
    } else {
      final short = arg.substring(0, 2);
      final kind = valueOpts[short];
      if (kind == null) {
        unknown.add(arg);
      } else {
        final inline = arg.length > 2 ? arg.substring(2) : null;
        store(kind, takeValue(_displayName[kind]!, inline));
      }
    }
    i++;
  }
  if (a.help) return a;
  if (a.sources.isEmpty) {
    throw UsageError('the following arguments are required: sources');
  }
  if (unknown.isNotEmpty) {
    throw UsageError('unrecognized arguments: ${unknown.join(' ')}');
  }
  return a;
}

/// Runs the compiler with [argv] and returns the process exit code.
int runCli(List<String> argv) {
  final CliArgs args;
  try {
    args = parseArgs(argv);
  } on UsageError catch (e) {
    stderr.writeln(usageLine);
    stderr.writeln('$toolName: error: ${e.message}');
    return 2;
  }
  if (args.help) {
    stdout.writeln(helpText);
    return 0;
  }

  var output = args.output;
  if (output == null || output.isEmpty) {
    final base = p.withoutExtension(p.basename(args.sources[0]));
    output = p.join('build', '$base.asm');
  }

  final outDir = p.dirname(output);
  if (outDir.isNotEmpty) {
    Directory(outDir).createSync(recursive: true);
  }

  try {
    final asmCode = compile(args.sources,
        options: CompileOptions(
            includeDirs: args.includeDirs,
            defines: args.defines,
            boundsCheck: args.boundsCheck,
            referenceCheck: args.referenceCheck));
    File(output).writeAsStringSync(asmCode);
  } on CompileError catch (e) {
    stderr.writeln('$toolName: error: ${e.message}');
    return 1;
  }
  return 0;
}
