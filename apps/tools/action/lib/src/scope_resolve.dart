// ------------------------------------------------------------------------------
// Block scopes for local variables
// ------------------------------------------------------------------------------
//
// Locals follow Go's rules: a local is visible from its declaration to the
// end of the block that declares it; an inner block may declare a name an
// outer block (or a parameter, or a global) already has, which hides it
// there; declaring a name twice in one block is an error, and so is giving a
// local in a function's outermost block the name of one of its parameters.
// A `for` loop's variable belongs to the loop, and each `switch` case is a
// block of its own.
//
// The rest of the compiler keys its tables by name, so this pass gives
// every local that would share a name with another declaration in the same
// function, or with a global variable, an internal name of its own
// (`x~2`), and points each use at the declaration it means. [sourceName]
// turns an internal name back into the one in the source, for messages and
// debug information.

import 'ast.dart';
import 'errors.dart';

/// Marks the internal names [resolveBlockScopes] makes.
const internalNameMark = '~';

final _internalSuffix = RegExp(r'~\d+');

/// [name] (or a message naming locals) as the source writes it.
String sourceName(String name) =>
    name.contains(internalNameMark) ? name.replaceAll(_internalSuffix, '') : name;

/// Resolves the locals of every function body in [root] (see above).
/// [globalVars] names the global variables and [globalNames] the other
/// global names (constants, enum members, functions). Local variables may
/// hide either; local constants keep their name, so that the checker can
/// report one that reuses a global's.
void resolveBlockScopes(ProgramNode root, Set<String> globalVars, Set<String> globalNames) {
  final hoisted = <VarDeclNode>[];
  for (final d in root.decls) {
    if (d is FuncDeclNode && d.body != null && d.scopes == null) {
      _FunctionScopes(d, globalVars, globalNames, hoisted).run();
    }
  }
  // Constant tables and string constants declared in a function are
  // stored with the globals, under a name of their own
  root.decls.addAll(hoisted);
}

/// Numbers the constant tables taken out of functions, program-wide.
int _hoistSerial = 0;

/// One visible declaration: its internal name and where it is declared.
typedef _Visible = ({String internal, String? loc, bool isParam});

class _FunctionScopes {
  final FuncDeclNode func;
  final Set<String> globalVars;
  final Set<String> globalNames;

  /// Innermost last: source name to the declaration it means there.
  final List<Map<String, _Visible>> _blocks = [];

  /// Every name declared so far in the function (parameters too).
  final Set<String> _taken = {};

  /// Where each name was last declared, for the error about a use outside
  /// its block.
  final Map<String, String?> _declaredAt = {};
  late final Set<String> _allLocalNames;
  int _serial = 0;
  late LocalScope _scope;

  /// The location of the statement being resolved, for nodes without one.
  String? _stmtLoc;

  /// Constant tables and string constants taken out of the function, to be
  /// stored with the globals.
  final List<VarDeclNode> hoisted;

  _FunctionScopes(this.func, this.globalVars, this.globalNames, this.hoisted);

  void run() {
    final names = <String>{};
    _collectDeclNames(func.body, names);
    _allLocalNames = names;
    final root = LocalScope(null, null);
    func.scopes = root;
    _scope = root;
    _blocks.add({
      for (final p in func.params) p.name: (internal: p.name, loc: p.loc ?? func.loc, isParam: true)
    });
    _taken.addAll(func.params.map((p) => p.name));
    // The body's statements are in the parameters' block
    _blockStmts(func.body!);
  }

  // ------------------------------------------------------------ blocks

  void _inBlock(AstNode opener, void Function() body, {bool isCase = false}) {
    final outer = _scope;
    final inner = LocalScope(opener, outer, isCase: isCase);
    outer.children.add(inner);
    _scope = inner;
    _blocks.add({});
    body();
    _blocks.removeLast();
    _scope = outer;
  }

  /// A statement that is a block of its own (an `if` or loop body), whether
  /// or not it is written in braces.
  void _body(AstNode node) {
    if (node is BlockNode) {
      _stmt(node);
    } else {
      _inBlock(node, () => _stmt(node));
    }
  }

  // ------------------------------------------------------------ declarations

  /// Declares [name] in the current block; returns its internal name.
  String _declare(String name, String? loc, {bool isConst = false, bool unique = false}) {
    final block = _blocks.last;
    final prior = block[name];
    if (prior != null) {
      final what = isConst ? 'constant' : 'variable';
      if (prior.isParam) {
        throw CompileError("$what '$name' has the name of a parameter of '${func.name}'; "
                "only a block inside the function's outermost one can reuse it")
            .at(loc);
      }
      throw CompileError("$what '$name' is already declared in this block"
              "${prior.loc != null ? ' (at ${prior.loc})' : ''}")
          .at(loc);
    }
    // Constants keep a global's name, so the checker can report it
    final hidesGlobal = !isConst && (globalVars.contains(name) || globalNames.contains(name));
    final internal = unique
        ? '$name$internalNameMark${100000 + ++_hoistSerial}'
        : _taken.contains(name) || hidesGlobal
            ? '$name$internalNameMark${++_serial}'
            : name;
    _taken.add(name);
    _declaredAt[name] = loc;
    block[name] = (internal: internal, loc: loc, isParam: false);
    return internal;
  }

  /// [name] as the use at [loc] means it.
  String _use(String name, String? loc) {
    for (var i = _blocks.length - 1; i >= 0; i--) {
      final v = _blocks[i][name];
      if (v != null) return v.internal;
    }
    if (_allLocalNames.contains(name) &&
        !globalVars.contains(name) &&
        !globalNames.contains(name)) {
      final at = _declaredAt[name];
      throw CompileError("undefined identifier '$name'; the '$name' declared "
              "${at != null ? 'at $at ' : 'later in this function '}is not in scope here")
          .at(loc ?? _stmtLoc);
    }
    return name;
  }

  bool _isVisible(String name) => _blocks.any((b) => b.containsKey(name));

  // ------------------------------------------------------------ statements

  void _stmt(AstNode? node) {
    if (node == null) return;
    final outerLoc = _stmtLoc;
    if (node.loc != null) _stmtLoc = node.loc;
    try {
      _stmtInner(node);
    } finally {
      _stmtLoc = outerLoc;
    }
  }

  /// The statements of [block], with a constant table or string constant
  /// taken out to the globals (an empty block takes its place).
  void _blockStmts(BlockNode block) {
    for (var i = 0; i < block.stmts.length; i++) {
      final s = block.stmts[i];
      if (s is VarDeclNode && s.isReadOnly) {
        final outerLoc = _stmtLoc;
        _stmtLoc = s.loc ?? _stmtLoc;
        for (final e in s.dimExprs) {
          _expr(e);
        }
        _expr(s.initExpr);
        _initValues(s.initList);
        s.name = _declare(s.name, s.loc, unique: true);
        _stmtLoc = outerLoc;
        hoisted.add(s);
        block.stmts[i] = BlockNode([])..loc = s.loc;
        continue;
      }
      _stmt(s);
    }
  }

  /// The values in a brace initializer.
  void _initValues(AstNode? init) {
    if (init is InitListNode) {
      init.elems.forEach(_initValues);
    } else if (init is RecordInitNode) {
      for (final (_, v) in init.fields) {
        _initValues(v);
      }
    } else {
      _expr(init);
    }
  }

  void _stmtInner(AstNode node) {
    if (node is BlockNode) {
      if (identical(node, func.body)) {
        _blockStmts(node);
      } else {
        _inBlock(node, () => _blockStmts(node));
      }
    } else if (node is VarDeclNode) {
      // The initializer and dimensions see the names outside: `u32 x = x;`
      // in an inner block reads the outer x
      for (final e in node.dimExprs) {
        _expr(e);
      }
      _expr(node.boundAddrExpr);
      _expr(node.initExpr);
      node.name = _declare(node.name, node.loc, isConst: node.isConst);
      if (!node.isConst && node.boundAddrExpr == null) {
        node.nested = _scope.parent != null;
        _scope.decls.add(node);
      }
    } else if (node is IfNode) {
      _expr(node.cond);
      _body(node.thenBody);
      if (node.elseBody != null) _body(node.elseBody!);
    } else if (node is WhileNode) {
      _expr(node.cond);
      _body(node.body);
    } else if (node is ForRangeNode) {
      _expr(node.startExpr);
      _expr(node.endExpr);
      _inBlock(node, () {
        node.varName = _declare(node.varName, node.loc);
        _scope.decls
          ..add(node.loopVar)
          ..add(node.loopEnd);
        _body(node.body);
      });
    } else if (node is SwitchNode) {
      _expr(node.expr);
      _switchBody(node.body);
    } else if (node is TupleAssignNode) {
      _expr(node.expr);
      for (final t in node.targets) {
        if (t.isWildcard || t.name == null) continue;
        if (t.typeName != null) {
          t.name = _declare(t.name!, node.loc);
        } else {
          t.name = _use(t.name!, node.loc);
        }
      }
      _scope.decls.addAll(node.targetDecls);
    } else if (node is CaseLabelNode) {
      _expr(node.expr);
    } else {
      _expr(node);
    }
  }

  /// A `switch` body: each case, from its label to the next, is a block.
  void _switchBody(AstNode body) {
    if (body is! BlockNode) {
      _body(body);
      return;
    }
    LocalScope? caseScope;
    final outer = _scope;
    void closeCase() {
      if (caseScope != null) {
        _blocks.removeLast();
        _scope = outer;
        caseScope = null;
      }
    }

    var afterLabel = false;
    for (final s in body.stmts) {
      if (s is CaseLabelNode || s is DefaultLabelNode) {
        // Consecutive labels share one case. Case values are constants from
        // outside the cases.
        if (!afterLabel) closeCase();
        if (s is CaseLabelNode) _stmt(s);
        if (!afterLabel) {
          caseScope = LocalScope(s, outer, isCase: true);
          outer.children.add(caseScope!);
          _scope = caseScope!;
          _blocks.add({});
        }
        afterLabel = true;
        continue;
      }
      afterLabel = false;
      _stmt(s);
    }
    closeCase();
  }

  // ------------------------------------------------------------ expressions

  void _expr(AstNode? e) {
    if (e == null) return;
    if (e is VarAccessNode) {
      e.name = _use(e.name, e.loc);
    } else if (e is CallNode) {
      // A call through a local function variable
      if (_isVisible(e.name)) e.name = _use(e.name, e.loc);
      for (final a in e.args) {
        _expr(a);
      }
    } else if (e is SizeofNode) {
      final t = e.target;
      if (t is String) {
        if (_isVisible(t)) e.target = _use(t, e.loc);
      } else {
        _expr(t as AstNode);
      }
    } else if (e is BinaryOpNode) {
      _expr(e.left);
      _expr(e.right);
    } else if (e is UnaryOpNode) {
      _expr(e.operand);
    } else if (e is ArrayAccessNode) {
      _expr(e.base);
      _expr(e.index);
    } else if (e is SliceNode) {
      _expr(e.base);
      _expr(e.startExpr);
      _expr(e.endExpr);
    } else if (e is CompoundAssignNode) {
      _expr(e.lhs);
      _expr(e.rhs);
    } else if (e is MemberAccessNode) {
      _expr(e.expr);
    } else if (e is YieldNode) {
      _expr(e.taskRef);
    } else if (e is WaitUntilNode) {
      _expr(e.taskRef);
      _expr(e.cond);
    } else if (e is PkExitNode) {
      _expr(e.taskRef);
    } else if (e is VerifyNode) {
      _expr(e.cond);
    } else if (e is HeapAllocNode) {
      for (final a in e.args) {
        _expr(a);
      }
    } else if (e is HeapArrayAllocNode) {
      _expr(e.countExpr);
    } else if (e is HeapStringAllocNode) {
      _expr(e.capExpr);
    } else if (e is HeapFreeNode) {
      _expr(e.expr);
    } else if (e is HeapArrayFreeNode) {
      _expr(e.expr);
    } else if (e is HeapArrayResizeNode) {
      _expr(e.expr);
      _expr(e.newLenExpr);
    } else if (e is ExistsNode) {
      _expr(e.expr);
    } else if (e is ConvertNode) {
      _expr(e.expr);
    } else if (e is ReturnNode) {
      _expr(e.expr);
    } else if (e is TupleReturnNode) {
      for (final x in e.exprs) {
        _expr(x);
      }
    } else if (e is ExprStmtNode) {
      _expr(e.expr);
    } else if (e is CaseLabelNode) {
      _expr(e.expr);
    }
    // Literals, traps, asm, break, continue and labels name no variables
  }

  // ------------------------------------------------------------ pre-scan

  /// Every name a local declaration in [node] declares.
  static void _collectDeclNames(AstNode? node, Set<String> out) {
    if (node == null) return;
    if (node is BlockNode) {
      for (final s in node.stmts) {
        _collectDeclNames(s, out);
      }
    } else if (node is VarDeclNode) {
      out.add(node.name);
    } else if (node is IfNode) {
      _collectDeclNames(node.thenBody, out);
      _collectDeclNames(node.elseBody, out);
    } else if (node is WhileNode) {
      _collectDeclNames(node.body, out);
    } else if (node is ForRangeNode) {
      out.add(node.varName);
      _collectDeclNames(node.body, out);
    } else if (node is SwitchNode) {
      _collectDeclNames(node.body, out);
    } else if (node is TupleAssignNode) {
      for (final t in node.targets) {
        if (!t.isWildcard && t.typeName != null && t.name != null) out.add(t.name!);
      }
    }
  }
}
