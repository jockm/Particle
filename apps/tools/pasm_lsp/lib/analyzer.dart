// =============================================================================
// File: apps/tools/pasm_lsp/lib/analyzer.dart
// Project: Particle RISC Architecture
// Description: Document analyzer and symbol indexer for pasm_lsp.
// =============================================================================

import "dart:io";
import "package:pasm/isa.dart";
import "package:pasm/preprocessor.dart";
import "package:pasm/assembler.dart";
import "package:pasm_lint/linter.dart";

typedef JsonMap = Map<String, dynamic>;
typedef StringList = List<String>;

/// Represents a source location (0-based line and character columns for LSP).
class SourceLocation {
  final String filePath;
  final int line; // 0-based
  final int startCol; // 0-based
  final int endCol; // 0-based

  const SourceLocation({
    required this.filePath,
    required this.line,
    required this.startCol,
    required this.endCol,
  });

  JsonMap toLspLocation() => {
        "uri": Uri.file(filePath).toString(),
        "range": {
          "start": {"line": line, "character": startCol},
          "end": {"line": line, "character": endCol},
        },
      };
}

/// Represents a symbol definition (label, .define, or .macro) discovered in a file.
class SymbolInfo {
  final String name;
  final String kind; // 'label', 'define', 'macro'
  final SourceLocation location;
  final int? value; // Byte address for labels, constant value for defines
  final StringList? macroParams;
  final StringList? macroBody;
  final String? docComment;

  const SymbolInfo({
    required this.name,
    required this.kind,
    required this.location,
    this.value,
    this.macroParams,
    this.macroBody,
    this.docComment,
  });
}

/// Represents an LSP Diagnostic (1 = Error, 2 = Warning).
class LspDiagnostic {
  final int line; // 0-based
  final int startCol;
  final int endCol;
  final int severity; // 1 = Error, 2 = Warning
  final String message;
  final String source;

  const LspDiagnostic({
    required this.line,
    required this.startCol,
    required this.endCol,
    required this.severity,
    required this.message,
    this.source = "pasm",
  });

  JsonMap toJson() => {
        "range": {
          "start": {"line": line, "character": startCol},
          "end": {"line": line, "character": endCol},
        },
        "severity": severity,
        "source": source,
        "message": message,
      };
}

/// Snapshot of analyzing a single assembly document and its transitive includes.
class DocumentAnalysis {
  final String filePath;
  final StringList lines;
  final List<LspDiagnostic> diagnostics;
  final Map<String, SymbolInfo> labels;
  final Map<String, SymbolInfo> defines;
  final Map<String, SymbolInfo> macros;
  final Map<int, String> includeTargetsByLine;

  const DocumentAnalysis({
    required this.filePath,
    required this.lines,
    required this.diagnostics,
    required this.labels,
    required this.defines,
    required this.macros,
    required this.includeTargetsByLine,
  });
}

const Map<String, String> registerDocs = {
  "R0": "**R0** — Hardwired Zero Register (`0x00000000`). Reads always return `0`; writes are ignored.",
  "R1": "**R1** — Argument / Return Value Register 1 (Caller-saved).",
  "R2": "**R2** — Argument / Return Value Register 2 (Caller-saved).",
  "R3": "**R3** — Argument / Return Value Register 3 (Caller-saved).",
  "R4": "**R4** — Argument / Return Value Register 4 (Caller-saved).",
  "R5": "**R5** — General-Purpose Callee-Saved Register.",
  "R6": "**R6** — General-Purpose Callee-Saved Register.",
  "R7": "**R7** — General-Purpose Callee-Saved Register.",
  "R8": "**R8** — General-Purpose Callee-Saved Register.",
  "R9": "**R9** — General-Purpose Callee-Saved Register.",
  "R10": "**R10** — General-Purpose Callee-Saved Register.",
  "R11": "**R11** — Caller-Saved Scratchpad Register.",
  "R12": "**R12** — Caller-Saved Scratchpad Register.",
  "R13": "**R13** — Caller-Saved Scratchpad Register.",
  "R14": "**R14** — Link Register / Immediate Accumulator (`LOAD16`/`LOAD24`/`LOAD32`, `RCALL`, wide `LD`/`SLT`/`FBRA`/`BBRA` 8-bit forms).",
  "R15": "**R15 (SP)** — Architectural Stack Pointer (Full-descending, 4-byte aligned).",
  "SP": "**SP (R15)** — Architectural Stack Pointer Alias (`R15`, full-descending, 4-byte aligned).",
};

const Map<String, String> mnemonicDocs = {
  "NOP": "`NOP` (`0x0000`) — No operation. Advances `PC` by 2 bytes.",
  "LD": "`LD Rd, Rs` | `LD Rd, Imm4` | `LD R14, Imm8` — Loads register `Rs` or signed/unsigned immediate (`-15..15` for `R0..R13`/`R15`, `-255..255` for `R14`) into `Rd`.",
  "PUSH4": "`PUSH4 Rd, Imm4` (`0x05`) — Shifts `Rd` left by 4 bits and ORs in the 4-bit immediate.",
  "PUSH8": "`PUSH8 R14, Imm8` (`0x06`) — Shifts `R14` left by 8 bits and ORs in the 8-bit immediate.",
  "LD8": "`LD8 Rd, (Rs)` | `LD8 (Rd), Rs` (`0x10..0x14`) — 8-bit byte load/store supporting `(Rs)`, `(++Rs)`, `(Rs++)`, `(--Rs)`, `(Rs--)`. Zero-extends on load.",
  "ST8": "`ST8 (Rd), Rs` (`0x15..0x19`) — 8-bit byte store to memory address in `Rd`.",
  "LD16": "`LD16 Rd, (Rs)` | `LD16 (Rd), Rs` (`0x20..0x24`) — 16-bit halfword load/store (requires 2-byte alignment). Zero-extends on load.",
  "ST16": "`ST16 (Rd), Rs` (`0x25..0x29`) — 16-bit halfword store to memory address in `Rd` (requires 2-byte alignment).",
  "LD32": "`LD32 Rd, (Rs)` | `LD32 (Rd), Rs` (`0x30..0x34`) — 32-bit word load/store (requires 4-byte alignment).",
  "ST32": "`ST32 (Rd), Rs` (`0x35..0x39`) — 32-bit word store to memory address in `Rd` (requires 4-byte alignment).",
  "ADD": "`ADD Rd, Rs` | `ADD Rd, Imm4` (`0x40` / `0x44`) — Unsigned 32-bit addition: `Rd = Rd + Rs` (or `Imm4` `0..15`).",
  "SUB": "`SUB Rd, Rs` | `SUB Rd, Imm4` (`0x41` / `0x45`) — Unsigned 32-bit subtraction: `Rd = Rd - Rs` (or `Imm4` `0..15`).",
  "DIV": "`DIV Rd, Rs` | `DIV Rd, Imm4` (`0x42` / `0x46`) — Unsigned 32-bit integer division: `Rd = Rd / Rs`.",
  "MOD": "`MOD Rd, Rs` | `MOD Rd, Imm4` (`0x43` / `0x47`) — Unsigned 32-bit modulo: `Rd = Rd % Rs`.",
  "NEG": "`NEG Rd` (`0x48`) — Two's complement negation: `Rd = -Rd`.",
  "SADD": "`SADD Rd, Rs` | `SADD Rd, Imm4` (`0x50` / `0x54`) — Signed 32-bit addition.",
  "SSUB": "`SSUB Rd, Rs` | `SSUB Rd, Imm4` (`0x51` / `0x55`) — Signed 32-bit subtraction.",
  "SDIV": "`SDIV Rd, Rs` | `SDIV Rd, Imm4` (`0x52` / `0x56`) — Signed 32-bit integer division.",
  "SMOD": "`SMOD Rd, Rs` | `SMOD Rd, Imm4` (`0x53` / `0x57`) — Signed 32-bit modulo.",
  "SHIFTL": "`SHIFTL Rd, Rs` | `SHIFTL Rd, Imm4` (`0x60` / `0x69`) — Logical shift left: `Rd = Rd << shift`.",
  "SEXT8": "`SEXT8 Rd` (`0x61`) — Sign-extends the low 8-bit byte in `Rd` to 32 bits.",
  "SHIFTR": "`SHIFTR Rd, Rs` | `SHIFTR Rd, Imm4` (`0x62` / `0x6B`) — Logical shift right (zero-fill): `Rd = Rd >>> shift`.",
  "ASHIFTR": "`ASHIFTR Rd, Rs` | `ASHIFTR Rd, Imm4` (`0x63` / `0x6C`) — Arithmetic shift right (sign-preserving): `Rd = Rd >> shift`.",
  "ROTL": "`ROTL Rd, Rs` | `ROTL Rd, Imm4` (`0x64` / `0x6D`) — 32-bit rotate left.",
  "ROTR": "`ROTR Rd, Rs` | `ROTR Rd, Imm4` (`0x65` / `0x6E`) — 32-bit rotate right.",
  "AND": "`AND Rd, Rs` | `AND Rd, Imm4` (`0x66` / `0x6F`) — Bitwise AND: `Rd = Rd & Rs`.",
  "OR": "`OR Rd, Rs` | `OR Rd, Imm4` (`0x67` / `0x70`) — Bitwise OR: `Rd = Rd | Rs`.",
  "XOR": "`XOR Rd, Rs` | `XOR Rd, Imm4` (`0x68` / `0x71`) — Bitwise XOR: `Rd = Rd ^ Rs`.",
  "SEXT16": "`SEXT16 Rd` (`0x6A`) — Sign-extends the low 16-bit halfword in `Rd` to 32 bits.",
  "NOT": "`NOT Rd` (`0x72`) — Bitwise one's complement inversion: `Rd = ~Rd`.",
  "NEZ": "`NEZ Rd` (`0x73`) — Not-Equal-to-Zero boolean normalization: `Rd = (Rd != 0) ? 1 : 0`.",
  "MULL": "`MULL Rd, Rs` | `MULL Rd, Imm4` (`0x78` / `0x7C`) — Low 32 bits of 32x32-bit product.",
  "MULH": "`MULH Rd, Rs` | `MULH Rd, Imm4` (`0x79` / `0x7D`) — High 32 bits of unsigned 32x32-bit product.",
  "SMULH": "`SMULH Rd, Rs` | `SMULH Rd, Imm4` (`0x7A` / `0x7E`) — High 32 bits of signed 32x32-bit product.",
  "MULHSU": "`MULHSU Rd, Rs` | `MULHSU Rd, Imm4` (`0x7B` / `0x7F`) — High 32 bits of signed `Rd` x unsigned `Rs` product.",
  "BEXTR": "`BEXTR Rd, Rs` (`0x80`) — Bitfield extract from `Rd` using descriptor in `Rs`.",
  "JTBL": "`JTBL Rr` (`0x81`) — Indexed jump table dispatch using `Rr`.",
  "CLZ": "`CLZ Rd` (`0x82`) — Count Leading Zeros in 32-bit register `Rd`.",
  "BSET": "`BSET Rd, Rs` | `BSET Rd, Imm4` (`0x83` / `0x84`) — Sets bit in `Rd` at index `Rs` or `Imm4` (`0..15`).",
  "BCLR": "`BCLR Rd, Rs` | `BCLR Rd, Imm4` (`0x85` / `0x86`) — Clears bit in `Rd` at index `Rs` or `Imm4` (`0..15`).",
  "BINV": "`BINV Rd, Rs` | `BINV Rd, Imm4` (`0x87` / `0x88`) — Inverts bit in `Rd` at index `Rs` or `Imm4` (`0..15`).",
  "BGET": "`BGET Rd, Rs` | `BGET Rd, Imm4` (`0x89` / `0x8A`) — Extracts bit from `Rd` at index `Rs` or `Imm4` (`0..15`): `Rd = (Rd >> bit) & 1`.",
  "TAS": "`TAS (Rr), Rl` (`0x8B`) — Atomic Test-and-Set on memory word at `(Rr)` into `Rl`.",
  "REV32": "`REV32 Rd` (`0x8C`) — Reverses byte order (endian swap) of 32-bit register `Rd`.",
  "SLT": "`SLT Rd, Rs` | `SLT Rd, Imm` (`0x90..0x94`) — Unsigned Set-Less-Than: `Rd = (Rd < Rs) ? 1 : 0`.",
  "SSLT": "`SSLT Rd, Rs` | `SSLT Rd, Imm` (`0x95..0x99`) — Signed Set-Less-Than: `Rd = (Rd < Rs) ? 1 : 0`.",
  "SEQ": "`SEQ Rd, Rs` (`0x9A`) — Set-Equal: `Rd = (Rd == Rs) ? 1 : 0`.",
  "SNE": "`SNE Rd, Rs` (`0x9B`) — Set-Not-Equal: `Rd = (Rd != Rs) ? 1 : 0`.",
  "SLE": "`SLE Rd, Rs` (`0x9C`) — Unsigned Set-Less-Or-Equal: `Rd = (Rd <= Rs) ? 1 : 0`.",
  "SSLE": "`SSLE Rd, Rs` (`0x9D`) — Signed Set-Less-Or-Equal: `Rd = (Rd <= Rs) ? 1 : 0`.",
  "JMP": "`JMP Rtarget, Rlink` (`0xA0`) — Absolute jump to `Rtarget`, storing `PC + 2` into `Rlink` (defaults to `R0`).",
  "RJUMP": "`RJUMP Roffset, Rlink` (`0xA1`) — PC-relative jump by signed byte offset in `Roffset`, saving `PC + 2` into `Rlink`.",
  "TRAP": "`TRAP Rr` | `TRAP Imm4` (`0xA2` / `0xA3`) — Triggers exception vector `0..15` (base `0x00000100`, 64-byte stride), saving `PC + 2` in `R14`.",
  "BRANCH": "`BRANCH Rr` (`0xA4`) — Branches to address in register `Rr`.",
  "FBRA": "`FBRA <label>` (`0xB0`) — Unconditional forward PC-relative branch (`0..255` halfwords ahead).",
  "FBRA.Z": "`FBRA.Z Rr, <label>` (`0xB4` / `0xB7` for `R14`) — Forward branch if `Rr == 0` (`0..15` halfwords, or `0..255` when `Rr` is `R14`).",
  "FBRA.N": "`FBRA.N Rr, <label>` (`0xB5` / `0xB8` for `R14`) — Forward branch if `Rr < 0` (bit 31 set).",
  "FBRA.P": "`FBRA.P Rr, <label>` (`0xB6` / `0xB9` for `R14`) — Forward branch if `Rr > 0` (signed positive).",
  "FBRA.NZ": "`FBRA.NZ Rr, <label>` (`0xBA` / `0xBB` for `R14`) — Forward branch if `Rr != 0`.",
  "BBRA": "`BBRA <label>` (`0xC0`) — Unconditional backward PC-relative branch (`0..255` halfwords back).",
  "BBRA.Z": "`BBRA.Z Rr, <label>` (`0xC4` / `0xC7` for `R14`) — Backward branch if `Rr == 0` (`0..15` halfwords, or `0..255` when `Rr` is `R14`).",
  "BBRA.N": "`BBRA.N Rr, <label>` (`0xC5` / `0xC8` for `R14`) — Backward branch if `Rr < 0` (bit 31 set).",
  "BBRA.P": "`BBRA.P Rr, <label>` (`0xC6` / `0xC9` for `R14`) — Backward branch if `Rr > 0` (signed positive).",
  "BBRA.NZ": "`BBRA.NZ Rr, <label>` (`0xCA` / `0xCB` for `R14`) — Backward branch if `Rr != 0`.",
  "XCHG": "`XCHG Rr` (`0xD0`) — Swaps register `Rr` with its hardware shadow bank counterpart.",
  "XCHGALL": "`XCHGALL` (`0xD100`) — Swaps all registers `R1..R15` with the hardware shadow register bank.",
  "XCHGMOST": "`XCHGMOST` (`0xD200`) — Swaps registers `R1..R13` with the hardware shadow register bank.",
  "RBASE": "`RBASE Imm8` | `RBASE Rr` (`0xD3` / `0xD4`) — Sets the register window base offset (`R1..R15` map to `(idx + rbase) & 0x1F`; `R0` stays `0`).",
  "FIFO.R": "`FIFO.R Rd, chan` (`0xE0`) — Blocking read from streaming hardware FIFO channel `chan` (`0..15`) into `Rd`.",
  "FIFO.W": "`FIFO.W Rs, chan` (`0xE1`) — Blocking write of `Rs` to streaming hardware FIFO channel `chan` (`0..15`).",
  "FIFO.STAT": "`FIFO.STAT Rd, Rchan` (`0xE4`) — Reads FIFO channel status flags into `Rd`.",
  "MBOX": "`MBOX Rs, vec` (`0xE5`) — Sends inter-core mailbox strobe/message from `Rs` to vector `vec`.",
  "FIFO.TRYR": "`FIFO.TRYR Rd, Rchan` (`0xE6`) — Non-blocking FIFO read into `Rd`; sets status in `R14`.",
  "FIFO.TRYW": "`FIFO.TRYW Rs, Rchan` (`0xE7`) — Non-blocking FIFO write from `Rs`; sets status in `R14`.",
};

/// Analyzer engine managing workspace include paths, in-memory overlays,
/// and per-document symbol/diagnostic snapshots.
class ParticleAnalyzer {
  String workspaceRoot;
  final Map<String, StringList> openOverlays = <String, StringList>{};
  final Map<String, DocumentAnalysis> cache = <String, DocumentAnalysis>{};

  ParticleAnalyzer({this.workspaceRoot = "."});

  String canonicalize(String filePath) {
    final f = File(filePath);
    if (f.existsSync()) {
      return f.resolveSymbolicLinksSync();
    }
    return f.absolute.path;
  }

  StringList includeDirsFor(String filePath) {
    final f = File(filePath);
    final parent = f.parent.path;
    return <String>{
      if (parent.isNotEmpty) parent,
      workspaceRoot,
      "$workspaceRoot/lib",
      ".",
      "lib",
    }.toList();
  }

  DocumentAnalysis updateDocument(String filePath, String content) {
    final canon = canonicalize(filePath);
    final lines = content.split(RegExp(r"\r?\n"));
    openOverlays[canon] = lines;
    return analyzeDocument(canon, lines);
  }

  void closeDocument(String filePath) {
    final canon = canonicalize(filePath);
    openOverlays.remove(canon);
    cache.remove(canon);
  }

  DocumentAnalysis analyzeDocument(String canonPath, [StringList? overrideLines]) {
    final lines = overrideLines ??
        openOverlays[canonPath] ??
        (File(canonPath).existsSync() ? File(canonPath).readAsLinesSync() : <String>[]);

    final incDirs = includeDirsFor(canonPath);
    final diagnostics = <LspDiagnostic>[];

    // 1. Run pasm_lint static & flow checks (errors + warnings)
    final lintRes = lintLines(canonPath, lines, incDirs);
    for (final (lno, msg) in lintRes.errors) {
      final (startCol, endCol) = _lineSpan(lines, lno - 1);
      diagnostics.add(LspDiagnostic(
        line: (lno - 1).clamp(0, lines.isEmpty ? 0 : lines.length - 1),
        startCol: startCol,
        endCol: endCol,
        severity: 1,
        message: msg,
        source: "pasm_lint",
      ));
    }
    for (final (lno, msg) in lintRes.warnings) {
      final (startCol, endCol) = _lineSpan(lines, lno - 1);
      diagnostics.add(LspDiagnostic(
        line: (lno - 1).clamp(0, lines.isEmpty ? 0 : lines.length - 1),
        startCol: startCol,
        endCol: endCol,
        severity: 2,
        message: msg,
        source: "pasm_lint",
      ));
    }

    // 2. Run Preprocessor + ParticleAssembler (Pass 1 & Pass 2) with in-memory overlays
    final overlays = Map<String, StringList>.from(openOverlays);
    overlays[canonPath] = lines;

    final prep = Preprocessor(
      includeDirs: incDirs,
      defines: <String, int>{},
      fileOverlays: overlays,
    );
    final asm = ParticleAssembler(prep);

    try {
      asm.assemble(canonPath);
    } on AssemblerError catch (e) {
      final errFile = e.filename != null ? canonicalize(e.filename!) : canonPath;
      if (errFile == canonPath) {
        final lno0 = ((e.lineno ?? 1) - 1).clamp(0, lines.isEmpty ? 0 : lines.length - 1);
        final alreadyReported = diagnostics.any((d) => d.line == lno0 && d.severity == 1);
        if (!alreadyReported) {
          final (startCol, endCol) = _lineSpan(lines, lno0);
          diagnostics.add(LspDiagnostic(
            line: lno0,
            startCol: startCol,
            endCol: endCol,
            severity: 1,
            message: e.message,
            source: "pasm",
          ));
        }
      }
    } catch (_) {}

    // 3. Index labels, defines, macros, and .include links
    final labels = <String, SymbolInfo>{};
    final defines = <String, SymbolInfo>{};
    final macros = <String, SymbolInfo>{};
    final includeTargetsByLine = <int, String>{};

    _indexFileSymbols(
      canonPath,
      lines,
      prep,
      asm.symbols,
      labels,
      defines,
      macros,
      includeTargetsByLine,
      <String>{},
      isRoot: true,
    );

    for (final entry in prep.macros.entries) {
      final m = entry.value;
      if (!macros.containsKey(m.name)) {
        macros[m.name] = SymbolInfo(
          name: m.name,
          kind: "macro",
          location: SourceLocation(
            filePath: m.filename,
            line: (m.lineno - 1).clamp(0, 1000000),
            startCol: 0,
            endCol: m.name.length,
          ),
          macroParams: m.params,
          macroBody: m.lines,
        );
      }
    }

    final analysis = DocumentAnalysis(
      filePath: canonPath,
      lines: lines,
      diagnostics: diagnostics,
      labels: labels,
      defines: defines,
      macros: macros,
      includeTargetsByLine: includeTargetsByLine,
    );
    cache[canonPath] = analysis;
    return analysis;
  }

  void _indexFileSymbols(
    String filePath,
    StringList fileLines,
    Preprocessor prep,
    Map<String, int> resolvedAddresses,
    Map<String, SymbolInfo> labels,
    Map<String, SymbolInfo> defines,
    Map<String, SymbolInfo> macros,
    Map<int, String> includeTargetsByLine,
    Set<String> visited, {
    required bool isRoot,
  }) {
    final canon = canonicalize(filePath);
    if (visited.contains(canon)) return;
    visited.add(canon);

    final labelRe = RegExp(r"^(\s*)([A-Za-z0-9_\.]+):");
    final defineRe = RegExp(r"^(\s*)\.(?:define|equ)\s+([A-Za-z0-9_\.]+)", caseSensitive: false);
    final macroRe = RegExp(r"^(\s*)\.macro\s+([A-Za-z0-9_\.]+)(.*)$", caseSensitive: false);
    final incRe = RegExp(r"^\s*\.include\s+(.+)$", caseSensitive: false);

    for (var i = 0; i < fileLines.length; i++) {
      final raw = fileLines[i];
      final clean = raw.replaceAll(RegExp(r";.*"), "");
      if (clean.trim().isEmpty) continue;

      final mInc = incRe.firstMatch(clean);
      if (mInc != null) {
        var incTarget = mInc.group(1)!.trim();
        if ((incTarget.startsWith('"') && incTarget.endsWith('"')) ||
            (incTarget.startsWith("'") && incTarget.endsWith("'"))) {
          incTarget = incTarget.substring(1, incTarget.length - 1);
        }
        try {
          final resolved = prep.resolveInclude(canon, incTarget);
          if (isRoot) {
            includeTargetsByLine[i] = resolved;
          }
          final incLines = openOverlays[resolved] ??
              (File(resolved).existsSync() ? File(resolved).readAsLinesSync() : <String>[]);
          _indexFileSymbols(
            resolved,
            incLines,
            prep,
            resolvedAddresses,
            labels,
            defines,
            macros,
            includeTargetsByLine,
            visited,
            isRoot: false,
          );
        } catch (_) {}
        continue;
      }

      final mMacro = macroRe.firstMatch(clean);
      if (mMacro != null) {
        final name = mMacro.group(2)!;
        final startCol = raw.indexOf(name);
        final doc = _extractLeadingComment(fileLines, i);
        final prepMacro = prep.macros[name];
        macros[name] = SymbolInfo(
          name: name,
          kind: "macro",
          location: SourceLocation(
            filePath: canon,
            line: i,
            startCol: startCol >= 0 ? startCol : 0,
            endCol: (startCol >= 0 ? startCol : 0) + name.length,
          ),
          macroParams: prepMacro?.params ??
              mMacro
                  .group(3)!
                  .split(",")
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList(),
          macroBody: prepMacro?.lines,
          docComment: doc,
        );
        continue;
      }

      final mDef = defineRe.firstMatch(clean);
      if (mDef != null) {
        final name = mDef.group(2)!;
        final startCol = raw.indexOf(name);
        final doc = _extractLeadingComment(fileLines, i);
        defines[name] = SymbolInfo(
          name: name,
          kind: "define",
          location: SourceLocation(
            filePath: canon,
            line: i,
            startCol: startCol >= 0 ? startCol : 0,
            endCol: (startCol >= 0 ? startCol : 0) + name.length,
          ),
          value: prep.defines[name],
          docComment: doc,
        );
        continue;
      }

      final mLbl = labelRe.firstMatch(clean);
      if (mLbl != null) {
        final name = mLbl.group(2)!;
        final startCol = mLbl.group(1)!.length;
        final doc = _extractLeadingComment(fileLines, i);
        labels[name] = SymbolInfo(
          name: name,
          kind: "label",
          location: SourceLocation(
            filePath: canon,
            line: i,
            startCol: startCol,
            endCol: startCol + name.length,
          ),
          value: resolvedAddresses[name],
          docComment: doc,
        );
      }
    }
  }

  String? _extractLeadingComment(StringList lines, int lineIndex) {
    final commentLines = <String>[];
    for (var idx = lineIndex - 1; idx >= 0; idx--) {
      final trimmed = lines[idx].trim();
      if (trimmed.startsWith(";")) {
        final text = trimmed.replaceFirst(RegExp(r"^;+\s*"), "").trim();
        if (!text.startsWith("---") && !text.startsWith("===")) {
          commentLines.insert(0, text);
        }
      } else {
        break;
      }
    }
    return commentLines.isEmpty ? null : commentLines.join("\n");
  }

  (int, int) _lineSpan(StringList lines, int lineIndex) {
    if (lineIndex < 0 || lineIndex >= lines.length) return (0, 1);
    final raw = lines[lineIndex];
    final codePart = raw.replaceAll(RegExp(r";.*"), "");
    final trimmed = codePart.trim();
    if (trimmed.isEmpty) return (0, raw.length);
    final start = raw.indexOf(trimmed);
    return (start, start + trimmed.length);
  }

  (String, int, int)? wordAt(StringList lines, int line, int character) {
    if (line < 0 || line >= lines.length) return null;
    final text = lines[line];
    if (text.isEmpty) return null;
    final col = character.clamp(0, text.length - 1);

    final tokenRe = RegExp(r"[A-Za-z0-9_\.]+");
    for (final m in tokenRe.allMatches(text)) {
      if (col >= m.start && col <= m.end) {
        return (m.group(0)!, m.start, m.end);
      }
    }
    return null;
  }

  JsonMap? findDefinition(String filePath, int line, int character) {
    final canon = canonicalize(filePath);
    final analysis = cache[canon] ?? analyzeDocument(canon);

    if (analysis.includeTargetsByLine.containsKey(line)) {
      final incPath = analysis.includeTargetsByLine[line]!;
      return SourceLocation(
        filePath: incPath,
        line: 0,
        startCol: 0,
        endCol: 0,
      ).toLspLocation();
    }

    final wordInfo = wordAt(analysis.lines, line, character);
    if (wordInfo == null) return null;
    final token = wordInfo.$1;

    if (analysis.labels.containsKey(token)) {
      return analysis.labels[token]!.location.toLspLocation();
    }
    if (analysis.defines.containsKey(token)) {
      return analysis.defines[token]!.location.toLspLocation();
    }
    if (analysis.macros.containsKey(token)) {
      return analysis.macros[token]!.location.toLspLocation();
    }
    final upper = token.toUpperCase();
    if (analysis.macros.containsKey(upper)) {
      return analysis.macros[upper]!.location.toLspLocation();
    }

    return null;
  }

  JsonMap? getHover(String filePath, int line, int character) {
    final canon = canonicalize(filePath);
    final analysis = cache[canon] ?? analyzeDocument(canon);

    final wordInfo = wordAt(analysis.lines, line, character);
    if (wordInfo == null) return null;
    final (token, startCol, endCol) = wordInfo;
    final upper = token.toUpperCase();

    String? markdown;

    if (registerDocs.containsKey(upper)) {
      markdown = registerDocs[upper];
    } else if (analysis.macros.containsKey(token) || analysis.macros.containsKey(upper)) {
      final m = analysis.macros[token] ?? analysis.macros[upper]!;
      final sig = ".macro ${m.name} ${m.macroParams?.join(", ") ?? ""}".trim();
      final body = (m.macroBody ?? const <String>[]).join("\n");
      final doc = m.docComment != null ? "${m.docComment}\n\n" : "";
      markdown = "**Macro** `${m.name}`\n\n$doc```pasm\n$sig\n$body\n.endmacro\n```";
    } else if (mnemonicDocs.containsKey(upper)) {
      markdown = mnemonicDocs[upper];
    } else if (analysis.labels.containsKey(token)) {
      final lbl = analysis.labels[token]!;
      final hexAddr = lbl.value != null
          ? "`0x${lbl.value!.toRadixString(16).padLeft(8, '0').toUpperCase()}`"
          : "unresolved";
      final doc = lbl.docComment != null ? "\n\n${lbl.docComment}" : "";
      markdown = "**Label** `$token` — Address: $hexAddr$doc";
    } else if (analysis.defines.containsKey(token)) {
      final def = analysis.defines[token]!;
      final valStr = def.value != null
          ? "${def.value} (`0x${def.value!.toRadixString(16).toUpperCase()}`)"
          : "defined";
      final doc = def.docComment != null ? "\n\n${def.docComment}" : "";
      markdown = "**Constant** `.define $token` = $valStr$doc";
    }

    if (markdown == null) return null;

    return {
      "contents": {
        "kind": "markdown",
        "value": markdown,
      },
      "range": {
        "start": {"line": line, "character": startCol},
        "end": {"line": line, "character": endCol},
      },
    };
  }

  List<JsonMap> getDocumentSymbols(String filePath) {
    final canon = canonicalize(filePath);
    final analysis = cache[canon] ?? analyzeDocument(canon);
    final symbols = <JsonMap>[];

    JsonMap? currentRoutine;

    for (final entry in analysis.labels.values) {
      if (entry.location.filePath != canon) continue;
      final isLocal = entry.name.startsWith(".");
      final symItem = <String, dynamic>{
        "name": entry.name,
        "detail": entry.value != null
            ? "0x${entry.value!.toRadixString(16).padLeft(8, '0').toUpperCase()}"
            : "label",
        "kind": isLocal ? 13 : 12,
        "range": {
          "start": {"line": entry.location.line, "character": entry.location.startCol},
          "end": {"line": entry.location.line, "character": entry.location.endCol},
        },
        "selectionRange": {
          "start": {"line": entry.location.line, "character": entry.location.startCol},
          "end": {"line": entry.location.line, "character": entry.location.endCol},
        },
        "children": <JsonMap>[],
      };

      if (!isLocal) {
        currentRoutine = symItem;
        symbols.add(symItem);
      } else if (currentRoutine != null) {
        (currentRoutine["children"] as List<JsonMap>).add(symItem);
      } else {
        symbols.add(symItem);
      }
    }

    for (final def in analysis.defines.values) {
      if (def.location.filePath != canon) continue;
      symbols.add({
        "name": def.name,
        "detail": def.value != null ? "= ${def.value}" : ".define",
        "kind": 14,
        "range": {
          "start": {"line": def.location.line, "character": def.location.startCol},
          "end": {"line": def.location.line, "character": def.location.endCol},
        },
        "selectionRange": {
          "start": {"line": def.location.line, "character": def.location.startCol},
          "end": {"line": def.location.line, "character": def.location.endCol},
        },
      });
    }

    for (final mac in analysis.macros.values) {
      if (mac.location.filePath != canon) continue;
      symbols.add({
        "name": mac.name,
        "detail": ".macro (${mac.macroParams?.join(', ') ?? ''})",
        "kind": 12,
        "range": {
          "start": {"line": mac.location.line, "character": mac.location.startCol},
          "end": {"line": mac.location.line, "character": mac.location.endCol},
        },
        "selectionRange": {
          "start": {"line": mac.location.line, "character": mac.location.startCol},
          "end": {"line": mac.location.line, "character": mac.location.endCol},
        },
      });
    }

    return symbols;
  }

  List<JsonMap> getCompletions(String filePath) {
    final canon = canonicalize(filePath);
    final analysis = cache[canon] ?? analyzeDocument(canon);
    final items = <JsonMap>[];

    for (final mnem in allValidMnemonics) {
      items.add({
        "label": mnem,
        "kind": 14,
        "detail": "Particle RISC Instruction",
        if (mnemonicDocs.containsKey(mnem))
          "documentation": {
            "kind": "markdown",
            "value": mnemonicDocs[mnem],
          },
      });
    }

    for (final entry in registerDocs.entries) {
      items.add({
        "label": entry.key,
        "kind": 21,
        "detail": "Particle 32-bit Register",
        "documentation": {
          "kind": "markdown",
          "value": entry.value,
        },
      });
    }

    for (final dir in [
      ".include",
      ".macro",
      ".endmacro",
      ".define",
      ".ifdef",
      ".ifndef",
      ".if",
      ".else",
      ".endif",
      ".org",
      ".align",
      ".byte",
      ".half",
      ".word",
      ".asciz",
    ]) {
      items.add({
        "label": dir,
        "kind": 14,
        "detail": "Assembler Directive",
      });
    }

    for (final m in analysis.macros.values) {
      items.add({
        "label": m.name,
        "kind": 3,
        "detail": "Macro (${m.macroParams?.join(', ') ?? ''})",
        if (m.docComment != null)
          "documentation": {
            "kind": "markdown",
            "value": m.docComment,
          },
      });
    }

    for (final lbl in analysis.labels.values) {
      items.add({
        "label": lbl.name,
        "kind": 6,
        "detail": lbl.value != null
            ? "Label (0x${lbl.value!.toRadixString(16).padLeft(8, '0').toUpperCase()})"
            : "Label",
      });
    }

    for (final def in analysis.defines.values) {
      items.add({
        "label": def.name,
        "kind": 21,
        "detail": def.value != null ? "Constant = ${def.value}" : "Constant",
      });
    }

    return items;
  }
}
