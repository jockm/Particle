part of 'codegen.dart';

// ------------------------------------------------------------------------------
// Flow analysis over a function body
// ------------------------------------------------------------------------------
//
// A small forward data-flow framework over the structured AST. The walker
// handles control flow (if/else, while, for, switch with its implicit break
// and `continue` fall-through, break, continue and return); an analysis
// supplies what happens at expressions and simple statements.
//
// States only grow as loops are iterated to a fixed point, so an error found
// on an intermediate pass would also hold on the final one.

/// Facts known at one point of a function. `null` stands for "unreachable".
abstract class FlowFacts<T extends FlowFacts<T>> {
  T copy();

  /// The facts that hold after either `this` or [other].
  T join(T other);
  bool sameAs(T other);
}

/// Joins two possibly unreachable states.
T? joinFacts<T extends FlowFacts<T>>(T? a, T? b) {
  if (a == null) return b?.copy();
  if (b == null) return a.copy();
  return a.join(b);
}

bool _sameFacts<T extends FlowFacts<T>>(T? a, T? b) {
  if (a == null || b == null) return a == null && b == null;
  return a.sameAs(b);
}

/// What an analysis does at the leaves of control flow.
abstract class FlowAnalysis<T extends FlowFacts<T>> {
  /// A statement without control flow of its own (declaration, expression,
  /// assignment, coroutine operation, asm, verify, tuple assignment).
  /// Returns null if control does not continue (e.g. `pkExit`).
  T? simpleStmt(AstNode stmt, T s);

  /// Evaluates [expr] for its effects on the facts.
  T expr(AstNode expr, T s);

  /// Evaluates a condition; returns the facts when it is true and when it is
  /// false (null when that outcome is impossible).
  (T?, T?) cond(AstNode c, T s) {
    final after = expr(c, s);
    return (after, after.copy());
  }

  /// A range `for` loop's variable is set before the loop.
  T forInit(ForRangeNode loop, T s);

  /// `return` (its value, if any, has not yet been evaluated).
  void onReturn(ReturnNode ret, T s) {}

  /// `return (a, b, ...)`.
  void onTupleReturn(TupleReturnNode ret, T s) {}
}

class _FlowContext2<T extends FlowFacts<T>> {
  final bool isSwitch;
  final List<T?> breaks = [];
  final List<T?> continues = [];

  /// Switch only: the facts on entry to any case, and pending fall-through.
  T? dispatch;
  T? fallThrough;
  _FlowContext2.loop() : isSwitch = false;
  _FlowContext2.switchBlock(this.dispatch) : isSwitch = true;
}

/// Walks statements, applying a [FlowAnalysis].
class FlowWalker<T extends FlowFacts<T>> {
  final FlowAnalysis<T> a;
  final List<_FlowContext2<T>> _ctx = [];
  FlowWalker(this.a);

  /// Returns the facts after [stmt], or null if control cannot continue.
  T? stmt(AstNode stmt, T? s) {
    if (s == null && stmt is! CaseLabelNode && stmt is! DefaultLabelNode) {
      return null; // unreachable code
    }
    if (stmt is BlockNode) {
      T? cur = s;
      for (final st in stmt.stmts) {
        cur = this.stmt(st, cur);
      }
      return cur;
    }
    if (stmt is IfNode) {
      final (t, f) = a.cond(stmt.cond, s!);
      final afterThen = this.stmt(stmt.thenBody, t);
      final afterElse = stmt.elseBody != null ? this.stmt(stmt.elseBody!, f) : f;
      return joinFacts(afterThen, afterElse);
    }
    if (stmt is WhileNode) {
      return _loop(s!, (head) => a.cond(stmt.cond, head), stmt.body);
    }
    if (stmt is ForRangeNode) {
      var entry = a.expr(stmt.startExpr, s!);
      entry = a.expr(stmt.endExpr, entry);
      entry = a.forInit(stmt, entry);
      return _loop(entry, (head) => (head.copy(), head.copy()), stmt.body);
    }
    if (stmt is SwitchNode) {
      final dispatch = a.expr(stmt.expr, s!);
      final ctx = _FlowContext2<T>.switchBlock(dispatch);
      _ctx.add(ctx);
      // Control enters the body only at a case label
      final last = this.stmt(stmt.body, null);
      _ctx.removeLast();
      T? exit = joinFacts(last, ctx.fallThrough);
      for (final b in ctx.breaks) {
        exit = joinFacts(exit, b);
      }
      if (!_hasDefault(stmt.body)) {
        exit = joinFacts(exit, dispatch);
      }
      return exit;
    }
    if (stmt is CaseLabelNode || stmt is DefaultLabelNode) {
      final ctx = _innermostSwitch();
      if (ctx == null) return s;
      // Reaching a label from the case above is an implicit break
      ctx.breaks.add(s?.copy());
      final entered = joinFacts(ctx.dispatch, ctx.fallThrough);
      ctx.fallThrough = null;
      return entered;
    }
    if (stmt is BreakNode) {
      if (_ctx.isNotEmpty) _ctx.last.breaks.add(s!.copy());
      return null;
    }
    if (stmt is ContinueNode) {
      if (_ctx.isNotEmpty) {
        final ctx = _ctx.last;
        if (ctx.isSwitch) {
          ctx.fallThrough = joinFacts(ctx.fallThrough, s);
        } else {
          ctx.continues.add(s!.copy());
        }
      }
      return null;
    }
    if (stmt is ReturnNode) {
      var cur = s!;
      a.onReturn(stmt, cur);
      return null;
    }
    if (stmt is TupleReturnNode) {
      a.onTupleReturn(stmt, s!);
      return null;
    }
    return a.simpleStmt(stmt, s!);
  }

  /// A loop: [condOf] tests the head facts; [body] runs when true.
  T? _loop(T entry, (T?, T?) Function(T head) condOf, AstNode body) {
    T? head = entry.copy();
    T? exitFalse;
    late _FlowContext2<T> ctx;
    for (var pass = 0; pass < 1000; pass++) {
      final (t, f) = condOf(head!);
      exitFalse = f;
      ctx = _FlowContext2<T>.loop();
      _ctx.add(ctx);
      final out = stmt(body, t);
      _ctx.removeLast();
      T? next = joinFacts(entry, out);
      for (final c in ctx.continues) {
        next = joinFacts(next, c);
      }
      if (_sameFacts(next, head)) break;
      head = next;
    }
    T? exit = exitFalse;
    for (final b in ctx.breaks) {
      exit = joinFacts(exit, b);
    }
    return exit;
  }

  _FlowContext2<T>? _innermostSwitch() {
    for (final c in _ctx.reversed) {
      if (c.isSwitch) return c;
    }
    return null;
  }

  bool _hasDefault(AstNode node) {
    if (node is DefaultLabelNode) return true;
    if (node is BlockNode) return node.stmts.any(_hasDefault);
    if (node is IfNode) {
      return _hasDefault(node.thenBody) ||
          (node.elseBody != null && _hasDefault(node.elseBody!));
    }
    return false;
  }
}

/// Visits the sub-expressions of [e] in evaluation order. `&&` and `||`
/// evaluate their right side only sometimes, so [visit] gets the facts for
/// both outcomes joined. Calls [leaf] on every node (after its children).
T walkExpr<T extends FlowFacts<T>>(
    AstNode e, T s, T Function(AstNode node, T s) leaf) {
  T sub(AstNode? n, T st) => n == null ? st : walkExpr(n, st, leaf);
  if (e is BinaryOpNode) {
    if (e.op == '&&' || e.op == '||') {
      final afterLeft = sub(e.left, s);
      final afterRight = sub(e.right, afterLeft.copy());
      return leaf(e, afterLeft.join(afterRight));
    }
    if (e.op == '=') {
      // The right side is evaluated first; the target is handled by [leaf]
      final afterRight = sub(e.right, s);
      return leaf(e, _subLvalue(e.left, afterRight, leaf));
    }
    return leaf(e, sub(e.right, sub(e.left, s)));
  }
  if (e is CompoundAssignNode) {
    return leaf(e, _subLvalue(e.lhs, sub(e.rhs, s), leaf));
  }
  if (e is UnaryOpNode) return leaf(e, sub(e.operand, s));
  if (e is CallNode) {
    var cur = s;
    for (final arg in e.args) {
      cur = sub(arg, cur);
    }
    return leaf(e, cur);
  }
  if (e is MemberAccessNode) return leaf(e, sub(e.expr, s));
  if (e is ArrayAccessNode) return leaf(e, sub(e.index, sub(e.base, s)));
  if (e is SliceNode) return leaf(e, sub(e.endExpr, sub(e.startExpr, sub(e.base, s))));
  if (e is HeapArrayAllocNode) return leaf(e, sub(e.countExpr, s));
  if (e is HeapStringAllocNode) return leaf(e, sub(e.capExpr, s));
  if (e is HeapAllocNode) {
    var cur = s;
    for (final arg in e.args) {
      cur = sub(arg, cur);
    }
    return leaf(e, cur);
  }
  if (e is HeapFreeNode) return leaf(e, sub(e.expr, s));
  if (e is HeapArrayFreeNode) return leaf(e, sub(e.expr, s));
  if (e is HeapArrayResizeNode) return leaf(e, sub(e.newLenExpr, sub(e.expr, s)));
  if (e is ExistsNode) return leaf(e, sub(e.expr, s));
  if (e is ConvertNode) return leaf(e, sub(e.expr, s));
  if (e is SizeofNode) return s; // not evaluated
  return leaf(e, s);
}

/// The sub-expressions of an assignment target that are evaluated (indexes
/// and the bases of fields), but not the target variable itself.
T _subLvalue<T extends FlowFacts<T>>(
    AstNode target, T s, T Function(AstNode node, T s) leaf) {
  if (target is VarAccessNode) return s;
  if (target is MemberAccessNode) return walkExpr(target.expr, s, leaf);
  if (target is ArrayAccessNode) {
    return walkExpr(target.index, walkExpr(target.base, s, leaf), leaf);
  }
  return walkExpr(target, s, leaf);
}
