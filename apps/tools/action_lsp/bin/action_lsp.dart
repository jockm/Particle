// The Action language server. An editor starts it and talks to it over
// stdin/stdout using the Language Server Protocol.

import 'dart:io';

import 'package:action_lsp/action_lsp.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('action_lsp $serverVersion');
    return;
  }
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln('usage: action_lsp [--stdio]\n\n'
        'Language server for Action. An editor starts it and talks to it\n'
        'over stdin and stdout; it is not meant to be run by hand.');
    return;
  }
  final server = ActionLanguageServer(Connection(stdin, stdout));
  final code = await server.run();
  exit(code);
}
