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

  /// `pub` in front of a top-level declaration: visible outside its package.
  bool isPub = false;

  /// The node's `expr` child, for the node kinds that have one. The Python
  /// type inference walked through such wrappers with `hasattr(e, 'expr')`.
  AstNode? get innerExpr => null;

  /// The node's `name`, for the node kinds that have one (Python
  /// `getattr(node, 'name', None)`).
  String? get nodeName => null;
}

class ImportNode extends AstNode {
  final String path;

  /// `import "path" as alias;`: the name the importing file uses for the
  /// package (else the name the package declares).
  final String? alias;

  /// Where the alias is written, when there is one.
  final String? aliasLoc;

  ImportNode(this.path, [this.alias, this.aliasLoc]);

  /// An import of a file (`import "lib/string.act";`), not of a package.
  bool get isFile => path.endsWith('.act');
}

/// `package name;` at the top of a file of a package.
class PackageNode extends AstNode {
  final String name;
  PackageNode(this.name);
}

/// What the loader learned about a package of the program, for the
/// language server.
class PackageInfo {
  /// The name the package declares (`uart`).
  final String name;

  /// The prefix of its declarations' internal names: its folder inside the
  /// module, with `.` between the parts (`drivers.uart`).
  final String prefix;

  /// Its import path (`github.com/jockm/Particle/drivers/uart`).
  final String path;

  /// Its folder.
  final String folder;

  /// Its top-level names as written, and those of them that are `pub`.
  final Set<String> names;
  final Set<String> pubNames;

  /// Names that keep their spelling outside the package: `asm` and
  /// `extern` prototypes (a label or a C name).
  final Set<String> plainNames;

  PackageInfo(this.name, this.prefix, this.path, this.folder, this.names, this.pubNames,
      this.plainNames);

  /// The internal name of [name] declared in this package.
  String internal(String name) => '$prefix..$name';
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

/// `pkExit(task)`: resets the task's continuation and returns PK_EXITED.
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

  /// Warnings found while loading the program (such as an unused import).
  final List<(String, String?)> loadWarnings = [];

  /// The packages of the program, by prefix, and for each file the
  /// package each import name of it stands for.
  final Map<String, PackageInfo> packages = {};
  final Map<String, Map<String, PackageInfo>> fileImports = {};

  /// The package each file of an imported package belongs to (the
  /// program's own files, and the prelude, are not here).
  final Map<String, PackageInfo> filePackages = {};
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

  /// `ref T name[N]` (a fixed array of references) or, with [isArrayRef],
  /// `ref T name[]` (a reference to a heap array of references).
  bool isRefArray = false;

  /// Where the field is declared (`file:line:col`).
  String? loc;

  /// `pub T name;`: visible outside the type's package.
  bool isPub = false;
  FieldDecl(this.type, this.isPtr, this.name, this.dimExprs, this.isEmbedded,
      {this.isArrayRef = false});
}

class TypeDefNode extends AstNode {
  final String name;
  final List<FieldDecl> fields;

  /// `const T NAME = value;` written in the body: constants of the type,
  /// used as `Name.NAME`. Each is also a top-level constant named
  /// `Name.NAME` (see [typeConstName]).
  final List<VarDeclNode> consts = [];
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

  /// `fast T name;`: a global the Particle compiler places in the zero page
  /// (0x0004 to 0x00FF), where its address loads in one instruction. The
  /// LLVM compiler places it as any other global.
  bool isFast = false;

  /// Array dimensions as written (constant expressions).
  List<AstNode> dimExprs = [];

  /// The `@` address as written (a constant expression), if any.
  AstNode? boundAddrExpr;

  /// [dimExprs] and [boundAddrExpr] evaluated by the code generator.
  List<int>? arrayDims;
  int? arrayDim;
  int? boundAddr;

  /// `ref T name[N]`: an array of references to `T` values.
  bool isRefArray = false;

  /// `ref T name;`: a reference to a `T` that starts empty.
  bool isRefDecl = false;

  /// `= {...}`: the brace initializer as written. A local's is turned into
  /// assignments after the declaration ([expanded]); a global's is the
  /// initial contents of its storage.
  AstNode? initList;
  bool expanded = false;

  /// `const T name[N] = {...}`: a table that cannot be written.
  bool isReadOnly = false;

  /// Declared in a block inside the function's outermost one: its storage
  /// may have been used by an earlier block, so its declaration clears it.
  bool nested = false;
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

  /// `ref T name[]`: an open array of references to `T` values.
  bool isRefArray = false;

  /// The number of `[]` of an open array: `T m[][]` is 2. For a string the
  /// last is its capacity, as in `string names[3][8]`.
  int openRank = 1;
  Param(this.type, this.isPtr, this.name, [this.isOpenArr = false]);
}

class FuncDeclNode extends AstNode {
  /// Return type name, or `List<TupleElemType>` for tuple returns.
  Object retType;

  /// The function returns a reference: a heap array (`T[] f()`), a heap
  /// string (`string[] f()`) or, with [retRefArray], a heap array of
  /// references (`ref T[] f()`).
  bool retPtr;
  bool retRefArray = false;
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
  /// (a u16) and may pause with yield, waitUntil and pkExit.
  bool isTask = false;

  /// `extern ReturnType name(params);`: a C function, for the LLVM
  /// compiler. [isVariadic] when its parameters end with `...`.
  bool isExtern = false;
  bool isVariadic = false;

  /// The body's blocks and the locals each declares, set by
  /// [resolveBlockScopes].
  LocalScope? scopes;

  /// For a function made from a lambda: how messages name it (`lambda 'cmp'`
  /// or `lambda at main.act:12:9`).
  String? lambdaShown;

  /// `static T Type.name(params)`: a function of a type that takes no
  /// `this`, called as `Type.name(args)`.
  bool isStatic = false;

  /// Declared in the prelude (lib/string.act, lib/integer.act) of a
  /// program made of packages: compiled only when the program uses it.
  bool inPrelude = false;

  /// The name as declared, before an overloaded function is given its
  /// own name (see [overloadName]).
  late String declaredName = name;
  FuncDeclNode(this.retType, this.retPtr, this.name, this.params, this.body,
      {this.isInline = false, this.trapExpr});
  @override
  String? get nodeName => name;
}

class BlockNode extends AstNode {
  final List<AstNode> stmts;

  /// Where the closing brace is (`file:line:col`), when the source has one.
  String? endLoc;
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

  /// The loop variable and its end value as locals, made once.
  late final VarDeclNode loopVar = VarDeclNode(varType, false, varName)..loc = loc;
  late final VarDeclNode loopEnd = VarDeclNode('u32', false, loopEndName(varName))..loc = loc;
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

  /// The locals the targets with a type declare, made once.
  late final List<VarDeclNode> targetDecls = [
    for (final t in targets)
      if (!t.isWildcard && t.typeName != null) VarDeclNode(t.typeName!, t.isPtr, t.name!)..loc = loc
  ];
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

  /// `a.sameAs(b)`: an `==` of two references (whether they are the same
  /// value). A plain `==` of references is an error.
  bool identity = false;

  /// `r.unset()`: an `=` that empties reference `r` (its right side is 0).
  bool isUnset = false;
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

/// The name of a [CallNode] that calls a function value computed by an
/// expression (`t[i](x)`): `args[0]` is the value, the rest its arguments.
///
/// Names the compiler makes up contain `~` or `.`, which a program cannot
/// write in a name, so they can never clash with the program's own names.
const callValueName = '~callValue';

/// The name of the [CallNode] for `a.copyFrom(b)`.
const copyFromName = '~copyFrom';

const _methodCallMark = '~method~';

/// The name of the [CallNode] for a method call `x.name(...)` (the receiver
/// is `args[0]`), before the method is resolved.
String methodCallName(String method) => '$_methodCallMark$method';

/// Whether [callName] is a method call made by [methodCallName].
bool isMethodCall(String callName) => callName.startsWith(_methodCallMark);

/// The method a [methodCallName] call names.
String methodOfCall(String callName) => callName.substring(_methodCallMark.length);

/// The function that is the method [method] of type [type] (`Point.move`).
String methodFuncName(String type, String method) => '$type.$method';

/// The constant [name] declared in the body of type [type] (`Integer.MAX_U8`).
String typeConstName(String type, String name) => '$type.$name';

/// What separates an overloaded function's name from its parameter types
/// in its own name (`Integer.min~~u8.u8`); its label writes it `..`
/// (`_Integer.min..u8.u8`).
const overloadMark = '~~';

/// The name of the overload of [name] whose parameters are [paramTypes]
/// (each as [overloadTypeName] writes it).
String overloadName(String name, List<String> paramTypes) =>
    '$name$overloadMark${paramTypes.isEmpty ? 'void' : paramTypes.join('.')}';

/// [name] without an overload's parameter types.
String withoutOverload(String name) {
  final i = name.indexOf(overloadMark);
  return i < 0 ? name : name.substring(0, i);
}

/// A parameter's type in an overload's name: the type (a package's `..`
/// written `.`), `_a` per dimension of an open array, `ref_` in front of
/// an array of references.
String overloadTypeName(String type, {bool open = false, int rank = 1, bool refArray = false}) {
  final t = type.replaceAll('..', '.');
  return '${refArray ? 'ref_' : ''}$t${open ? '_a' * rank : ''}';
}

/// The parameter types of [f] as written, for telling a second definition
/// of a function from an overload before types are resolved.
String writtenParamKey(FuncDeclNode f) => '${f.isStatic ? 'static ' : ''}${[
      for (final p in f.params)
        if (p.name != 'this') overloadTypeName(p.type, open: p.isOpenArr, rank: p.openRank, refArray: p.isRefArray)
    ].join(',')}';

/// The hidden variable holding the length of dimension [k] of the open
/// array parameter [array] (`xs~len`, then `xs~len1`, ...).
String lenName(String array, [int k = 0]) => k == 0 ? '$array~len' : '$array~len$k';

/// The hidden variable holding the end of the range loop over [loopVar].
String loopEndName(String loopVar) => '$loopVar~end';

class CallNode extends AstNode {
  String name;
  List<AstNode> args;
  CallNode(this.name, this.args);
  @override
  String? get nodeName => name;
}

class VarAccessNode extends AstNode {
  /// The variable's name; for a block-scoped local, the internal name
  /// [resolveBlockScopes] gave it.
  String name;
  VarAccessNode(this.name);
  @override
  String? get nodeName => name;
}

/// `fn [name](params) [-> Ret] { body }`: a lambda, a function written where
/// a function value is expected. It cannot use the variables of the function
/// it is written in. The scope pass ([resolveBlockScopes]) makes it a hidden
/// top-level function and sets [name] (inherited: this node is then a use of
/// that function's name, its address).
class LambdaNode extends VarAccessNode {
  /// The name written after `fn`, visible only inside [body].
  final String? lambdaName;
  final List<Param> params;
  final Object retType;
  final BlockNode body;
  LambdaNode(this.lambdaName, this.params, this.retType, this.body) : super('');
}

/// `{a, b, c}`: the values of an array's elements (or rows), in order.
class InitListNode extends AstNode {
  final List<AstNode> elems;
  InitListNode(this.elems);
}

/// `{x: 1, y: 2}`: the values of a record's fields, by name.
class RecordInitNode extends AstNode {
  final List<(String, AstNode)> fields;
  final List<String?> fieldLocs;
  RecordInitNode(this.fields, this.fieldLocs);
}

/// `T(x)`: [expr] converted to scalar type [typeName] (Go's form). Integer
/// conversions truncate, or extend by the operand's signedness.
class ConvertNode extends AstNode {
  final String typeName;
  AstNode expr;
  ConvertNode(this.typeName, this.expr);
}

/// A floating-point literal (`1.5`, `1e-3`): an untyped constant that takes
/// the type (`f32` or `f64`) of what it is used with.
class FloatLitNode extends AstNode {
  final double val;
  final String text;
  FloatLitNode(this.val, this.text);
}

class IntLitNode extends AstNode {
  final int val;
  IntLitNode(this.val);
}

class HeapAllocNode extends AstNode {
  final String typeName;

  /// The values of `T.create(field: value, ...)`, one per field (or element
  /// of an array field) given, in order; [fieldPaths] says where each goes:
  /// field names and element indexes, such as `['corners', 1, 'x']`.
  final List<AstNode> args;
  final List<List<Object>> fieldPaths;
  HeapAllocNode(this.typeName, [List<AstNode>? args, List<List<Object>>? paths])
      : args = args ?? [],
        fieldPaths = paths ?? [];
}

class HeapArrayAllocNode extends AstNode {
  final String typeName;
  AstNode countExpr;

  /// Set by the checker when the array is given to an array of references
  /// (`ref T xs[] = T.createArray(n)`): its elements are references.
  bool refElems = false;
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

/// A block of a function body (the outermost one, a nested block, a `for`
/// loop, or a `switch` case) and the locals it declares.
class LocalScope {
  /// The node that opens the block (null for the outermost one).
  final AstNode? opener;
  final LocalScope? parent;

  /// The locals, in order (constants and `@` variables are left out).
  final List<VarDeclNode> decls = [];
  final List<LocalScope> children = [];

  /// A `switch` case: its debug scope is the enclosing block's.
  final bool isCase;
  LocalScope(this.opener, this.parent, {this.isCase = false});

  /// True when this block or one inside it declares a local.
  bool get hasDecls => decls.isNotEmpty || children.any((c) => c.hasDecls);
}

// ------------------------------------------------------------------------------
// Rewriting the tree
// ------------------------------------------------------------------------------

/// Visits [node] and everything below it, children before parents, and
/// puts what [f] returns in each node's place (returning the node itself
/// keeps it). The body of a lambda is visited only with [intoLambdas]
/// (after [resolveBlockScopes] a lambda's body is also a function of its
/// own).
AstNode rewriteTree(AstNode node, AstNode Function(AstNode n) f, {bool intoLambdas = false}) {
  AstNode r(AstNode n) => rewriteTree(n, f, intoLambdas: intoLambdas);
  AstNode? ro(AstNode? n) => n == null ? null : r(n);
  void list(List<AstNode> xs) {
    for (var i = 0; i < xs.length; i++) {
      xs[i] = r(xs[i]);
    }
  }

  switch (node) {
    case ProgramNode():
      list(node.decls);
    case FuncDeclNode():
      final b = node.body;
      if (b != null) list(b.stmts);
      node.trapExpr = ro(node.trapExpr);
    case TypeDefNode():
      for (final fd in node.fields) {
        list(fd.dimExprs);
      }
    case EnumDeclNode():
      for (var i = 0; i < node.members.length; i++) {
        final (n, e) = node.members[i];
        node.members[i] = (n, ro(e));
      }
    case VerifyNode():
      node.cond = r(node.cond);
    case SizeofNode():
      final t = node.target;
      if (t is AstNode) node.target = r(t);
    case VarDeclNode():
      node.initExpr = ro(node.initExpr);
      list(node.dimExprs);
      node.boundAddrExpr = ro(node.boundAddrExpr);
      node.initList = ro(node.initList);
    case BlockNode():
      list(node.stmts);
    case IfNode():
      node.cond = r(node.cond);
      node.thenBody = r(node.thenBody);
      node.elseBody = ro(node.elseBody);
    case CaseLabelNode():
      node.expr = r(node.expr);
    case SwitchNode():
      node.expr = r(node.expr);
      node.body = r(node.body);
    case WhileNode():
      node.cond = r(node.cond);
      node.body = r(node.body);
    case ForRangeNode():
      node.startExpr = r(node.startExpr);
      node.endExpr = r(node.endExpr);
      node.body = r(node.body);
    case TupleReturnNode():
      list(node.exprs);
    case TupleAssignNode():
      node.expr = r(node.expr);
    case ReturnNode():
      node.expr = ro(node.expr);
    case ExprStmtNode():
      node.expr = r(node.expr);
    case BinaryOpNode():
      node.left = r(node.left);
      node.right = r(node.right);
    case UnaryOpNode():
      node.operand = r(node.operand);
    case CompoundAssignNode():
      node.lhs = r(node.lhs);
      node.rhs = r(node.rhs);
    case MemberAccessNode():
      node.expr = r(node.expr);
    case ArrayAccessNode():
      node.base = r(node.base);
      node.index = r(node.index);
    case SliceNode():
      node.base = r(node.base);
      node.startExpr = ro(node.startExpr);
      node.endExpr = ro(node.endExpr);
    case CallNode():
      list(node.args);
    case LambdaNode():
      if (intoLambdas) list(node.body.stmts);
    case InitListNode():
      list(node.elems);
    case RecordInitNode():
      for (var i = 0; i < node.fields.length; i++) {
        final (n, e) = node.fields[i];
        node.fields[i] = (n, r(e));
      }
    case ConvertNode():
      node.expr = r(node.expr);
    case HeapAllocNode():
      list(node.args);
    case HeapArrayAllocNode():
      node.countExpr = r(node.countExpr);
    case HeapStringAllocNode():
      node.capExpr = r(node.capExpr);
    case HeapFreeNode():
      node.expr = r(node.expr);
    case HeapArrayFreeNode():
      node.expr = r(node.expr);
    case HeapArrayResizeNode():
      node.expr = r(node.expr);
      node.newLenExpr = r(node.newLenExpr);
    case ExistsNode():
      node.expr = r(node.expr);
    case YieldNode():
      node.taskRef = r(node.taskRef);
    case WaitUntilNode():
      node.taskRef = r(node.taskRef);
      node.cond = r(node.cond);
    case PkExitNode():
      node.taskRef = r(node.taskRef);
    default:
      break;
  }
  return f(node);
}
