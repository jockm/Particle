// ------------------------------------------------------------------------------
// Command-line interface
// ------------------------------------------------------------------------------
//
// A small hand-written option parser that accepts the same options as the
// Python compiler's argparse interface:
//
//   action [-h] [-o OUTPUT] [-D DEFINE] [-I INCLUDE_DIR]
//          [-fbounds-check] [-fno-bounds-check]
//          [-freference-check] [-fno-reference-check] [--stack-top ADDR]
//          sources [sources ...]
//   action --fetch | --vendor | --verify
//
// action_llvm takes the same options except --stack-top, and -g / -g0 for
// debug information.

import 'dart:io';

import 'driver.dart';
import 'errors.dart';
import 'modules.dart';
import 'paths.dart' as p;

const String toolName = 'action';
const String llvmToolName = 'action_llvm';

const String usageLine =
    'usage: $toolName [-h] [-o OUTPUT] [-D DEFINE] [-I INCLUDE_DIR] [-fbounds-check]\n'
    '              [-fno-bounds-check] [-freference-check] [-fno-reference-check]\n'
    '              [--stack-top ADDR] sources [sources ...]\n'
    '       $toolName --fetch | --vendor | --verify';

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
  -fno-reference-check  Disable runtime null reference checking
  --stack-top ADDR      Initial stack pointer, set at startup (default 0x00010000);
                        a multiple of 4'''
    '\n\nmodules (in the folder of action.json or below it; see action.json "requires"):\n  --fetch               Fetch the required module versions with git into the\n                        cache (\$ACTION_CACHE, or ~/.cache/action) and record\n                        their checksums in action.sum\n  --vendor              Copy the module versions the build uses into vendor/\n  --verify              Check the cache and vendor/ against action.sum';

const String llvmUsageLine =
    'usage: $llvmToolName [-h] [-o OUTPUT] [-D DEFINE] [-I INCLUDE_DIR] [-g] [-g0]\n'
    '              [-fbounds-check] [-fno-bounds-check] [-freference-check]\n'
    '              [-fno-reference-check] sources [sources ...]\n'
    '       $llvmToolName --fetch | --vendor | --verify';

const String llvmHelpText = '''$llvmUsageLine

Action Systems Language Compiler for LLVM: writes LLVM IR (.ll) for a 64-bit
host. Use llbuild to compile and link it.

positional arguments:
  sources               Input Action source file(s) (.act)

options:
  -h, --help            show this help message and exit
  -o, --output OUTPUT   Output LLVM IR file (.ll)
  -D, --define DEFINE   Predefine symbol (KEY[=VALUE])
  -I, --include-dir INCLUDE_DIR
                        Add include search directory
  -g                    Emit debug information (default)
  -g0                   Emit no debug information
  -fbounds-check        Enable runtime array bounds checking (default)
  -fno-bounds-check     Disable runtime array bounds checking
  -freference-check     Enable runtime null reference checking (default)
  -fno-reference-check  Disable runtime null reference checking'''
    '\n\nmodules (in the folder of action.json or below it; see action.json "requires"):\n  --fetch               Fetch the required module versions with git into the\n                        cache (\$ACTION_CACHE, or ~/.cache/action) and record\n                        their checksums in action.sum\n  --vendor              Copy the module versions the build uses into vendor/\n  --verify              Check the cache and vendor/ against action.sum';

/// argparse-style option names used in error messages.
const _displayName = {
  'output': '-o/--output',
  'define': '-D/--define',
  'include': '-I/--include-dir',
  'stack': '--stack-top',
};

/// Parsed command-line arguments.
class CliArgs {
  final List<String> sources = [];
  String? output;
  final List<String> defines = [];
  final List<String> includeDirs = [];
  bool boundsCheck = true;
  bool referenceCheck = true;
  bool debugInfo = true;
  bool help = false;

  /// --stack-top, when given
  int? stackTop;

  /// `--fetch`, `--vendor` or `--verify`, when given: work on the modules
  /// instead of compiling
  String? moduleMode;
}

/// Raised for invalid command-line usage (argparse exits with status 2).
class UsageError implements Exception {
  final String message;
  UsageError(this.message);
}

/// Parses [argv]. Options may be given as `-o FILE`, `-oFILE`,
/// `--output FILE` or `--output=FILE`; `--` ends option parsing.
CliArgs parseArgs(List<String> argv, {bool llvm = false}) {
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

  final valueOpts = {
    if (!llvm) '--stack-top': 'stack',
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
      case 'stack':
        final v = value.toLowerCase().startsWith('0x')
            ? int.tryParse(value.substring(2), radix: 16)
            : int.tryParse(value);
        if (v == null || v <= 0 || v > 0xFFFFFFFF || v % 4 != 0) {
          throw UsageError("argument --stack-top: '$value' is not an address that is a "
              'multiple of 4 (such as 0x00010000)');
        }
        a.stackTop = v;
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
    } else if (arg == '--fetch' || arg == '--vendor' || arg == '--verify') {
      if (a.moduleMode != null && a.moduleMode != arg) {
        throw UsageError('argument $arg: not allowed with argument ${a.moduleMode}');
      }
      a.moduleMode = arg;
    } else if (arg == '-fbounds-check') {
      a.boundsCheck = true;
    } else if (arg == '-fno-bounds-check') {
      a.boundsCheck = false;
    } else if (arg == '-freference-check') {
      a.referenceCheck = true;
    } else if (arg == '-fno-reference-check') {
      a.referenceCheck = false;
    } else if (llvm && arg == '-g') {
      a.debugInfo = true;
    } else if (llvm && arg == '-g0') {
      a.debugInfo = false;
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
  if (a.moduleMode != null) {
    if (a.sources.isNotEmpty) {
      throw UsageError('argument ${a.moduleMode}: takes no source files');
    }
    if (unknown.isNotEmpty) {
      throw UsageError('unrecognized arguments: ${unknown.join(' ')}');
    }
    return a;
  }
  if (a.sources.isEmpty) {
    throw UsageError('the following arguments are required: sources');
  }
  if (unknown.isNotEmpty) {
    throw UsageError('unrecognized arguments: ${unknown.join(' ')}');
  }
  return a;
}

/// Runs the compiler with [argv] and returns the process exit code. With
/// [llvm], it is action_llvm and writes LLVM IR.
int runCli(List<String> argv, {bool llvm = false}) {
  final tool = llvm ? llvmToolName : toolName;
  final CliArgs args;
  try {
    args = parseArgs(argv, llvm: llvm);
  } on UsageError catch (e) {
    stderr.writeln(llvm ? llvmUsageLine : usageLine);
    stderr.writeln('$tool: error: ${e.message}');
    return 2;
  }
  if (args.help) {
    stdout.writeln(llvm ? llvmHelpText : helpText);
    return 0;
  }
  moduleCommand = tool;
  if (args.moduleMode != null) return _runModuleMode(args.moduleMode!, tool);

  var output = args.output;
  if (output == null || output.isEmpty) {
    final base = p.withoutExtension(p.basename(args.sources[0]));
    output = llvm ? p.join('build', 'llvm', '$base.ll') : p.join('build', '$base.asm');
  }

  final outDir = p.dirname(output);
  if (outDir.isNotEmpty) {
    Directory(outDir).createSync(recursive: true);
  }

  final notes = <CompileNote>[];
  final options = CompileOptions(
      includeDirs: args.includeDirs,
      defines: args.defines,
      boundsCheck: args.boundsCheck,
      referenceCheck: args.referenceCheck,
      stackTop: args.stackTop ?? defaultStackTop);
  try {
    final code = llvm
        ? compileLlvm(args.sources, notes: notes, options: options, debugInfo: args.debugInfo)
        : compile(args.sources, notes: notes, options: options);
    File(output).writeAsStringSync(code);
  } on CompileError catch (e) {
    _printNotes(notes, tool);
    stderr.writeln('$tool: error: ${e.message}');
    return 1;
  }
  _printNotes(notes, tool);
  return 0;
}

/// Warnings and information go to stderr; they do not change the exit
/// status.
void _printNotes(List<CompileNote> notes, String tool) {
  for (final n in notes) {
    stderr.writeln(n.format(tool));
  }
}

/// `--fetch`, `--vendor` or `--verify`, for the module whose action.json
/// is in the current folder or one above it.
int _runModuleMode(String mode, String tool) {
  try {
    final main = findModuleFile(Directory.current.path);
    if (main == null) {
      stderr.writeln('$tool: error: no action.json naming a module was found in this folder or '
          'above it; add "module": { "name": "..." } to the "action" section of action.json');
      return 1;
    }
    switch (mode) {
      case '--fetch':
        fetchModules(main).forEach(stdout.writeln);
      case '--vendor':
        vendorModules(main).forEach(stdout.writeln);
      default:
        final (lines, ok) = verifyModules(main);
        lines.forEach(stdout.writeln);
        if (!ok) {
          stderr.writeln('$tool: error: some modules do not match action.sum');
          return 1;
        }
    }
    return 0;
  } on CompileError catch (e) {
    stderr.writeln('$tool: error: ${e.message}');
    return 1;
  }
}
