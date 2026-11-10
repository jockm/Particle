// =============================================================================
// File: apps/tools/pasm/bin/main.dart
// Project: Particle RISC Architecture
// Description: CLI entry point for pasm (Particle Two-Pass Macro Assembler).
// Matches argument parsing and error reporting of tools/pasm.py:main().
// =============================================================================

import "dart:io";
import "package:pasm/isa.dart";
import "package:pasm/preprocessor.dart";
import "package:pasm/assembler.dart";

/// Prints exact CLI usage matching tools/pasm.py
void printUsage() {
  stdout.writeln("usage: pasm [-h] [-I INCLUDE] [-o OUTPUT] [-D DEFINE] [--format {bin,hex}] source");
  stdout.writeln("");
  stdout.writeln("Particle Two-Pass Macro Assembler");
  stdout.writeln("");
  stdout.writeln("positional arguments:");
  stdout.writeln("  source                Source assembly file (.asm)");
  stdout.writeln("");
  stdout.writeln("optional arguments:");
  stdout.writeln("  -h, --help            show this help message and exit");
  stdout.writeln("  -I INCLUDE, --include INCLUDE");
  stdout.writeln("                        Include directory search paths");
  stdout.writeln("  -o OUTPUT, --output OUTPUT");
  stdout.writeln("                        Output binary file (default: a.out)");
  stdout.writeln("  -D DEFINE, --define DEFINE");
  stdout.writeln("                        Define symbol (NAME or NAME=VAL)");
  stdout.writeln("  --format {bin,hex}    Output format (default: bin)");
}

void main(List<String> args) {
  String? source;
  String output = "a.out";
  String format = "bin";
  final includes = <String>[];
  final defines = <String, int>{};

  // Parse command-line options
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-h" || arg == "--help") {
      printUsage();
      exit(0);
    } else if (arg == "-o" || arg == "--output") {
      if (i + 1 < args.length) output = args[++i];
    } else if (arg == "-I" || arg == "--include") {
      if (i + 1 < args.length) includes.add(args[++i]);
    } else if (arg.startsWith("-I")) {
      includes.add(arg.substring(2));
    } else if (arg == "-D" || arg == "--define") {
      if (i + 1 < args.length) {
        final d = args[++i];
        if (d.contains("=")) {
          final parts = d.split("=");
          defines[parts[0].trim()] = int.tryParse(parts[1].trim()) ?? 1;
        } else {
          defines[d.trim()] = 1;
        }
      }
    } else if (arg.startsWith("-D")) {
      final d = arg.substring(2);
      if (d.contains("=")) {
        final parts = d.split("=");
        defines[parts[0].trim()] = int.tryParse(parts[1].trim()) ?? 1;
      } else {
        defines[d.trim()] = 1;
      }
    } else if (arg == "--format") {
      if (i + 1 < args.length) format = args[++i];
    } else if (!arg.startsWith("-")) {
      source = arg;
    }
  }

  if (source == null) {
    printUsage();
    exit(1);
  }

  // Initialize preprocessor and assembler
  final prep = Preprocessor(includeDirs: [".", ...includes], defines: defines);
  final asm = ParticleAssembler(prep);

  Map<int, int> binData;
  int maxAddr;
  List<String> listingLines;

  try {
    final result = asm.assemble(source);
    binData = result.$1;
    maxAddr = result.$2;
    listingLines = result.$3;
  } on AssemblerError catch (e) {
    stderr.writeln("\n[ERROR] $e\n");
    exit(1);
  } on FileSystemException catch (e) {
    stderr.writeln("\n[ERROR] File not found: ${e.message}\n");
    exit(1);
  } catch (e) {
    stderr.writeln("\n[INTERNAL ERROR] $e\n");
    exit(1);
  }

  const int startAddr = 0x00000100;
  final int size = (maxAddr > startAddr) ? (maxAddr - startAddr) : 0;
  final outBytes = List<int>.filled(size, 0);

  // Fill contiguous binary array from sparse address map
  for (final entry in binData.entries) {
    final addr = entry.key;
    final val = entry.value;
    if (addr >= startAddr && (addr - startAddr) < size) {
      outBytes[addr - startAddr] = val;
    }
  }

  // Ensure output directory exists
  final outFile = File(output);
  outFile.parent.createSync(recursive: true);

  // Write machine code output in requested format
  if (format == "hex") {
    final buf = StringBuffer();
    for (int i = 0; i < outBytes.length; i += 2) {
      final b0 = outBytes[i];
      final b1 = (i + 1 < outBytes.length) ? outBytes[i + 1] : 0;
      final word = (b1 << 8) | b0;
      buf.writeln(word.toRadixString(16).padLeft(4, "0").toUpperCase());
    }
    outFile.writeAsStringSync(buf.toString());
  } else {
    outFile.writeAsBytesSync(outBytes);
  }

  // Automatically emit .lst listing file alongside the binary
  final baseName = output.contains(".") ? output.substring(0, output.lastIndexOf(".")) : output;
  final lstPath = "$baseName.lst";
  final lstFile = File(lstPath);
  final lstBuf = StringBuffer();

  lstBuf.writeln("; Listing for $source");
  lstBuf.writeln("; Total Emitted: ${outBytes.length} bytes [${startAddr.toRadixString(16).padLeft(8, "0").toUpperCase()}..${maxAddr.toRadixString(16).padLeft(8, "0").toUpperCase()}]\n");

  for (final line in listingLines) {
    lstBuf.writeln(line);
  }

  lstBuf.writeln("\n; ------------------------------------------------------------------------------");
  lstBuf.writeln("; SYMBOL TABLE");
  lstBuf.writeln("; ------------------------------------------------------------------------------");

  final sortedSymbols = asm.symbols.keys.toList()..sort();
  for (final sym in sortedSymbols) {
    lstBuf.writeln("; ${sym.padRight(32)} = 0x${asm.symbols[sym]!.toRadixString(16).padLeft(8, "0").toUpperCase()}");
  }

  lstFile.writeAsStringSync(lstBuf.toString());

  stdout.writeln("Assembly succeeded: ${outBytes.length} bytes emitted [${startAddr.toRadixString(16).padLeft(8, "0").toUpperCase()}..${maxAddr.toRadixString(16).padLeft(8, "0").toUpperCase()}]. Listing emitted to: $lstPath");
}
