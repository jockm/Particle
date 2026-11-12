// ------------------------------------------------------------------------------
// AST Nodes
// ------------------------------------------------------------------------------
//
// One class per node kind of act16c.py. Fields keep the Python names (in
// lowerCamelCase) so the code generator reads the same way.

import 'lexer.dart';

/// Base class of every syntax tree node.
abstract class AstNode {
  /// Where the node starts in the source (`file:line:col`), for error
  /// messages. Null for nodes the compiler makes itself.
  String? loc;

  /// The node's `expr` child, for the node kinds that have one. The Python
  /// type inference walked through such wrappers with `hasattr(e, 'expr')`.
  AstNode? get innerExpr => null;

  /// The node's `name`, for the node kinds that have one (Python
  /// `getattr(node, 'name', None)`).
  String? get nodeName => null;
}

class ImportNode extends AstNode {
  final String path;
  ImportNode(this.path);
}

class ArrayAccessNode extends AstNode {
  AstNode base;
  AstNode index;
  ArrayAccessNode(this.base, this.index);
}

class SliceNode extends AstNode {
  AstNode base;
  AstNode? startExpr;
  AstNode? endExpr;
  SliceNode(this.base, this.startExpr, this.endExpr);
}

class CompoundAssignNode extends AstNode {
  final String op;
  AstNode lhs;
  AstNode rhs;
  CompoundAssignNode(this.op, this.lhs, this.rhs);
}

class YieldNode extends AstNode {
  AstNode taskRef;

  /// Resume point number, assigned by the compiler (1, 2, ... in order).
  int stepConst = 0;
  YieldNode(this.taskRef);
}

class WaitUntilNode extends AstNode {
  AstNode taskRef;
  AstNode cond;

  /// Resume point number, assigned by the compiler (1, 2, ... in order).
  int stepConst = 0;
  WaitUntilNode(this.taskRef, this.cond);
}

/// `pk_exit(task)`: resets the task's continuation and returns PK_EXITED.
class PkExitNode extends AstNode {
  AstNode taskRef;
  PkExitNode(this.taskRef);
}

/// `type Name = Target;`: another name for an existing type. The parser
/// replaces uses of [name] with the resolved target (see Parser.aliases).
class TypeAliasNode extends AstNode {
  final String name;
  final String target;

  /// Source location, for error messages.
  final String loc;
  TypeAliasNode(this.name, this.target, this.loc);
  @override
  String? get nodeName => name;
}

class FnTypeNode extends AstNode {
  final String name;
  final List<String> paramTypes;
  final String retType;
  FnTypeNode(this.name, this.paramTypes, this.retType);
  @override
  String? get nodeName => name;
}

class EnumDeclNode extends AstNode {
  final String name;

  /// Member name and its explicit value expression (null when implicit).
  final List<(String, AstNode?)> members;

  /// Where each member's name is (`file:line:col`), in member order.
  final List<String?> memberLocs = [];
  EnumDeclNode(this.name, this.members);
  @override
  String? get nodeName => name;
}

class VerifyNode extends AstNode {
  AstNode cond;
  String msg;
  Token? token;
  VerifyNode(this.cond, this.msg, [this.token]);
}

class SizeofNode extends AstNode {
  /// Either a type/variable name (String) or an expression (AstNode).
  Object target;
  SizeofNode(this.target);
}

class ProgramNode extends AstNode {
  final List<AstNode> decls;
  ProgramNode(this.decls);
}

/// One field of a `type` declaration.
class FieldDecl {
  String type;
  bool isPtr;
  String name;

  /// Array dimensions as written (constant expressions).
  final List<AstNode> dimExprs;

  /// `null`, a single dimension (int) or several dimensions (List<int>),
  /// evaluated from [dimExprs] during layout.
  Object? dim;
  bool isEmbedded;

  /// `T name[]`: a reference to a heap array ([isPtr] is also true). A
  /// field with [isPtr] alone is `ref T name`, a reference to one `T`.
  bool isArrayRef;

  /// Where the field is declared (`file:line:col`).
  String? loc;
  FieldDecl(this.type, this.isPtr, this.name, this.dimExprs, this.isEmbedded,
      {this.isArrayRef = false});
}

class TypeDefNode extends AstNode {
  final String name;
  final List<FieldDecl> fields;
  TypeDefNode(this.name, this.fields);
  @override
  String? get nodeName => name;
}

/// Element of a tuple return type: `(type, isPtr)`.
typedef TupleElemType = (String, bool);

class VarDeclNode extends AstNode {
  /// A type name, or for tuple targets the list of element types.
  Object typeName;
  bool isPtr;
  String name;
  AstNode? initExpr;
  bool isConst;
  bool isVolatile;

  /// Array dimensions as written (constant expressions).
  List<AstNode> dimExprs = [];

  /// The `@` address as written (a constant expression), if any.
  AstNode? boundAddrExpr;

  /// [dimExprs] and [boundAddrExpr] evaluated by the code generator.
  List<int>? arrayDims;
  int? arrayDim;
  int? boundAddr;
  VarDeclNode(this.typeName, this.isPtr, this.name,
      [this.initExpr, this.isConst = false, this.isVolatile = false]);
  @override
  String? get nodeName => name;
}

/// A function parameter: `(type, isPtr, name, isOpenArray)`.
class Param {
  String type;
  bool isPtr;
  String name;
  bool isOpenArr;

  /// Where the parameter's name is (`file:line:col`); null for `this`.
  String? loc;
  Param(this.type, this.isPtr, this.name, [this.isOpenArr = false]);
}

class FuncDeclNode extends AstNode {
  /// Return type name, or `List<TupleElemType>` for tuple returns.
  Object retType;
  bool retPtr;
  String name;
  List<Param> params;
  BlockNode? body;
  bool isInline;

  /// `trap(N) name() { ... }`: the trap number expression, when the function
  /// is a trap handler.
  AstNode? trapExpr;

  /// `asm ReturnType name(params);`: a prototype for a routine written in
  /// assembly, supplied by an .asm file.
  bool isAsm = false;

  /// `task name(State t, ...) { ... }`: a coroutine. It returns its status
  /// (a u16) and may pause with yield, wait_until and pk_exit.
  bool isTask = false;
  FuncDeclNode(this.retType, this.retPtr, this.name, this.params, this.body,
      {this.isInline = false, this.trapExpr});
  @override
  String? get nodeName => name;
}

class BlockNode extends AstNode {
  final List<AstNode> stmts;
  BlockNode(this.stmts);
}

class IfNode extends AstNode {
  AstNode cond;
  AstNode thenBody;
  AstNode? elseBody;
  IfNode(this.cond, this.thenBody, [this.elseBody]);
}

class CaseLabelNode extends AstNode {
  AstNode expr;
  int? val;
  String? label;
  CaseLabelNode(this.expr, [this.label]);
  @override
  AstNode? get innerExpr => expr;
}

class DefaultLabelNode extends AstNode {
  String? label;
  DefaultLabelNode([this.label]);
}

class SwitchNode extends AstNode {
  AstNode expr;
  AstNode body;
  SwitchNode(this.expr, this.body);
  @override
  AstNode? get innerExpr => expr;
}

class WhileNode extends AstNode {
  AstNode cond;
  AstNode body;
  WhileNode(this.cond, this.body);
}

class ForRangeNode extends AstNode {
  String varType;
  String varName;
  AstNode startExpr;
  AstNode endExpr;
  AstNode body;
  ForRangeNode(
      this.varType, this.varName, this.startExpr, this.endExpr, this.body);
}

class BreakNode extends AstNode {}

/// `continue;` — the next loop iteration, or, directly inside a `switch`
/// case, fall through into the next case.
class ContinueNode extends AstNode {}

class AsmNode extends AstNode {
  final String asmText;
  AsmNode(this.asmText);
}

class TupleTarget {
  String? name;
  String? typeName;
  bool isPtr;
  bool isWildcard;
  TupleTarget(
      {this.name, this.typeName, this.isPtr = false, this.isWildcard = false});
}

class TupleReturnNode extends AstNode {
  final List<AstNode> exprs;
  TupleReturnNode(this.exprs);
}

class TupleAssignNode extends AstNode {
  final List<TupleTarget> targets;
  AstNode expr;
  TupleAssignNode(this.targets, this.expr);
  @override
  AstNode? get innerExpr => expr;
}

class ReturnNode extends AstNode {
  AstNode? expr;
  ReturnNode([this.expr]);
  @override
  AstNode? get innerExpr => expr;
}

class ExprStmtNode extends AstNode {
  AstNode expr;
  ExprStmtNode(this.expr);
  @override
  AstNode? get innerExpr => expr;
}

class BinaryOpNode extends AstNode {
  final String op;
  AstNode left;
  AstNode right;
  BinaryOpNode(this.op, this.left, this.right);
}

class UnaryOpNode extends AstNode {
  final String op;
  AstNode operand;
  UnaryOpNode(this.op, this.operand);
}

class MemberAccessNode extends AstNode {
  AstNode expr;
  String member;
  MemberAccessNode(this.expr, this.member);
}

class StringLitNode extends AstNode {
  final String val;
  StringLitNode(this.val);
}

class TrapNode extends AstNode {
  final int trapNum;
  TrapNode(this.trapNum);
}

class CallNode extends AstNode {
  String name;
  List<AstNode> args;
  CallNode(this.name, this.args);
  @override
  String? get nodeName => name;
}

class VarAccessNode extends AstNode {
  final String name;
  VarAccessNode(this.name);
  @override
  String? get nodeName => name;
}

class IntLitNode extends AstNode {
  final int val;
  IntLitNode(this.val);
}

class HeapAllocNode extends AstNode {
  final String typeName;
  final List<AstNode> args;
  HeapAllocNode(this.typeName, [List<AstNode>? args]) : args = args ?? [];
}

class HeapArrayAllocNode extends AstNode {
  final String typeName;
  AstNode countExpr;
  HeapArrayAllocNode(this.typeName, this.countExpr);
}

class HeapStringAllocNode extends AstNode {
  AstNode capExpr;
  HeapStringAllocNode(this.capExpr);
}

class HeapFreeNode extends AstNode {
  AstNode expr;
  HeapFreeNode(this.expr);
  @override
  AstNode? get innerExpr => expr;
}

class HeapArrayFreeNode extends AstNode {
  AstNode expr;
  HeapArrayFreeNode(this.expr);
  @override
  AstNode? get innerExpr => expr;
}

class HeapArrayResizeNode extends AstNode {
  AstNode expr;
  AstNode newLenExpr;
  HeapArrayResizeNode(this.expr, this.newLenExpr);
  @override
  AstNode? get innerExpr => expr;
}

class ExistsNode extends AstNode {
  AstNode expr;
  ExistsNode(this.expr);
  @override
  AstNode? get innerExpr => expr;
}
