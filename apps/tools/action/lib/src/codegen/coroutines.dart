part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Protothread coroutines
// ------------------------------------------------------------------------------
//
// `yield(p, step)`, `wait_until(p, step, cond)` and `pk_exit(p)` are declared
// as prototypes in lib/protokernel.act and look like ordinary calls, but the
// compiler generates them in place: they store into the task's continuation
// counter `p.lc` and return from the enclosing function, and a coroutine's
// entry dispatches on `p.lc` to the step label it left from (see genFunc).
//
// A call is generated this way only when the program declares the name as a
// prototype (a declaration without a body), which importing
// lib/protokernel.act does. Without it the name is an ordinary function.
// Status values are taken from the PK_* constants of protokernel.act.

/// Names of the coroutine operations and their argument counts.
const Map<String, int> _coroutineOps = {'yield': 2, 'wait_until': 3, 'pk_exit': 1};

extension _Coroutines on CodeGen {
  /// True when [name] is a coroutine operation the program has declared.
  bool _isCoroutineOp(String name) =>
      _coroutineOps.containsKey(name) && _prototypeNames.contains(name);

  /// Rewrites coroutine operation call statements in [funcs] into
  /// [YieldNode], [WaitUntilNode] and [PkExitNode].
  void _lowerCoroutineOps(List<FuncDeclNode> funcs) {
    for (final f in funcs) {
      if (f.body != null) _lowerIn(f.body!);
    }
  }

  void _lowerIn(AstNode node) {
    if (node is BlockNode) {
      for (var i = 0; i < node.stmts.length; i++) {
        node.stmts[i] = _lowerStmt(node.stmts[i]);
        _lowerIn(node.stmts[i]);
      }
    } else if (node is IfNode) {
      node.thenBody = _lowerStmt(node.thenBody);
      _lowerIn(node.thenBody);
      if (node.elseBody != null) {
        node.elseBody = _lowerStmt(node.elseBody!);
        _lowerIn(node.elseBody!);
      }
    } else if (node is WhileNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    } else if (node is ForRangeNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    } else if (node is SwitchNode) {
      node.body = _lowerStmt(node.body);
      _lowerIn(node.body);
    }
  }

  AstNode _lowerStmt(AstNode stmt) {
    if (stmt is! ExprStmtNode) return stmt;
    final call = stmt.expr;
    if (call is! CallNode || !_isCoroutineOp(call.name)) return stmt;
    final want = _coroutineOps[call.name]!;
    if (call.args.length != want) {
      throw CompileError(
          "'${call.name}' takes $want argument${want == 1 ? '' : 's'}, got ${call.args.length}");
    }
    switch (call.name) {
      case 'yield':
        return YieldNode(call.args[0], call.args[1]);
      case 'wait_until':
        return WaitUntilNode(call.args[0], call.args[1], call.args[2]);
      default:
        return PkExitNode(call.args[0]);
    }
  }

  /// The value of protokernel status constant [name].
  int _pkStatus(String name) {
    final v = constants[name];
    if (v == null) {
      throw CompileError(
          "coroutine status '$name' is not defined; import \"lib/protokernel.act\"");
    }
    return v;
  }
}
