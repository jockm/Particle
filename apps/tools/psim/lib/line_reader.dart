// =============================================================================
// File: apps/tools/psim/lib/line_reader.dart
// Description: Interactive terminal reader with ANSI line editing and history.
// =============================================================================

import "dart:io";

class LineReader {
  final List<String> history = [];
  int historyIdx = 0;

  String? readLine(String prompt) {
    if (!stdin.hasTerminal) {
      stdout.write(prompt);
      return stdin.readLineSync();
    }

    final origEcho = stdin.echoMode;
    final origLine = stdin.lineMode;

    try {
      stdin.echoMode = false;
      stdin.lineMode = false;

      stdout.write(prompt);

      final buffer = <int>[];
      var cursor = 0;
      historyIdx = history.length;
      String currentSaved = "";

      void refreshLine() {
        stdout.write("\r\x1b[K$prompt${String.fromCharCodes(buffer)}");
        final backSteps = buffer.length - cursor;
        if (backSteps > 0) {
          stdout.write("\x1b[${backSteps}D");
        }
      }

      while (true) {
        final b = stdin.readByteSync();
        if (b == -1) return null;

        // Enter (LF or CR)
        if (b == 10 || b == 13) {
          stdout.writeln();
          final res = String.fromCharCodes(buffer).trim();
          if (res.isNotEmpty) {
            if (history.isEmpty || history.last != res) {
              history.add(res);
            }
          }
          return res;
        }

        // Ctrl+C or Ctrl+D
        if (b == 3 || b == 4) {
          stdout.writeln();
          return null;
        }

        // Backspace (ASCII 8 or 127)
        if (b == 8 || b == 127) {
          if (cursor > 0) {
            cursor--;
            buffer.removeAt(cursor);
            refreshLine();
          }
          continue;
        }

        // ANSI Escape Sequence (e.g. Arrow keys)
        if (b == 27) {
          final b2 = stdin.readByteSync();
          if (b2 == 91) {
            // '['
            final b3 = stdin.readByteSync();
            if (b3 == 65) {
              // UP Arrow: History previous
              if (history.isNotEmpty && historyIdx > 0) {
                if (historyIdx == history.length) {
                  currentSaved = String.fromCharCodes(buffer);
                }
                historyIdx--;
                buffer.clear();
                buffer.addAll(history[historyIdx].codeUnits);
                cursor = buffer.length;
                refreshLine();
              }
            } else if (b3 == 66) {
              // DOWN Arrow: History next
              if (historyIdx < history.length) {
                historyIdx++;
                buffer.clear();
                if (historyIdx < history.length) {
                  buffer.addAll(history[historyIdx].codeUnits);
                } else {
                  buffer.addAll(currentSaved.codeUnits);
                }
                cursor = buffer.length;
                refreshLine();
              }
            } else if (b3 == 67) {
              // RIGHT Arrow: Move cursor right
              if (cursor < buffer.length) {
                cursor++;
                stdout.write("\x1b[1C");
              }
            } else if (b3 == 68) {
              // LEFT Arrow: Move cursor left
              if (cursor > 0) {
                cursor--;
                stdout.write("\x1b[1D");
              }
            }
          }
          continue;
        }

        // Regular printable character
        if (b >= 32 && b <= 126) {
          buffer.insert(cursor, b);
          cursor++;
          refreshLine();
        }
      }
    } finally {
      try {
        stdin.echoMode = origEcho;
        stdin.lineMode = origLine;
      } catch (_) {}
    }
  }
}
