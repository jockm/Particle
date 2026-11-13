// ------------------------------------------------------------------------------
// Parser
// ------------------------------------------------------------------------------
//
// Recursive-descent parser, ported from act16c.py. The grammar, the order in
// which alternatives are tried and the error messages follow the Python
// implementation, except where the language changed:
//
//  * Action has no pointers. `T*` types, unary `*` and `&`, and `->` are
//    syntax errors. Records and arrays are always passed by reference.
//  * Array dimensions, `@` addresses and coroutine step numbers may be any
//    constant expression (a `const`, an enum member, ...), not only a literal.

import 'ast.dart';
import 'errors.dart';
import 'lexer.dart';

const _primitiveTypes = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'f32', 'f64', 'bool'];

/// Integer types that can receive `.createArray(n)` directly.
const _arrayElemTypes = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool'];

/// The types a value can be converted to with `T(x)`.
const _convertTypes = {'u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64', 'bool', 'f32', 'f64'};

class Parser {
  final List<Token> tokens;
  int pos = 0;
  final Set<String> knownTypes = {};

  /// Type aliases (`type Name = Target;`), each resolved to a type that
  /// is not an alias. Uses of an alias name as a type are replaced by the
  /// target. Filled in by the driver after a first pass over the program.
  final Map<String, String> aliases;

  Parser(this.tokens, {this.aliases = const {}});

  /// [name] with any alias resolved.
  String _resolveAlias(String name) => aliases[name] ?? name;

  /// Action has no pointers: a `*` after a type name is a syntax error.
  void _rejectPointerType(String tName) {
    if (peek().val == '*') {
      final t = peek();
      throw CompileError(
          "${t.loc}: pointer type '${tName.trim()}*' is not supported; Action has no pointers (user-defined types and arrays are passed by reference)");
    }
  }

  /// Parses a constant expression in a position where an assignment cannot
  /// follow (array dimensions, `@` addresses, step numbers).
  AstNode _parseConstExpr() => parseLogicalOr();

  Token peek() => tokens[pos < tokens.length ? pos : tokens.length - 1];

  /// The token [offset] positions ahead of the current one.
  Token ahead(int offset) {
    final i = pos + offset;
    return tokens[i < tokens.length ? i : tokens.length - 1];
  }

  Token consume([String? expectedType, String? expectedVal]) {
    final t = peek();
    if (expectedType != null && t.type != expectedType) {
      throw CompileError(
          "${t.loc}: Expected $expectedType, got ${t.type} ('${t.val}')");
    }
    if (expectedVal != null && t.val != expectedVal) {
      throw CompileError("${t.loc}: Expected '$expectedVal', got '${t.val}'");
    }
    pos++;
    return t;
  }

  Token? match(String val) {
    if (peek().val == val) {
      return consume();
    }
    return null;
  }

  ProgramNode parseProgram() {
    final decls = <AstNode>[];
    while (peek().type != 'EOF') {
      decls.add(parseTopLevel());
    }
    return ProgramNode(decls);
  }

  String parseType() {
    final t = peek();
    if (t.val == 'type') {
      consume();
      final sName = consume('IDENT').val;
      return _resolveAlias(sName);
    } else if ([..._primitiveTypes, 'string', 'void'].contains(t.val)) {
      return consume().val;
    } else if (t.type == 'IDENT') {
      return _resolveAlias(consume().val);
    }
    throw CompileError("${t.loc}: Expected type specifier, got '${t.val}'");
  }

  ImportNode parseImport() {
    consume('KEYWORD', 'import');
    final tok = consume('STRING');
    final rawPath = tok.val.substring(1, tok.val.length - 1);
    if (peek().val == ';') {
      consume('PUNCT', ';');
    }
    return ImportNode(rawPath);
  }

  EnumDeclNode parseEnum() {
    consume('KEYWORD', 'enum');
    final name = consume('IDENT').val;
    consume('PUNCT', '{');
    final members = <(String, AstNode?)>[];
    final memberLocs = <String?>[];
    while (peek().val != '}' && peek().type != 'EOF') {
      memberLocs.add(peek().loc);
      final mName = consume('IDENT').val;
      if (peek().val == '=') {
        consume('OP', '=');
        final expr = parseExpr();
        members.add((mName, expr));
      } else {
        members.add((mName, null));
      }
      if (peek().val == ',') {
        consume('PUNCT', ',');
      }
    }
    consume('PUNCT', '}');
    if (peek().val == ';') {
      consume('PUNCT', ';');
    }
    return EnumDeclNode(name, members)..memberLocs.addAll(memberLocs);
  }

  VerifyNode parseVerify() {
    final tok = consume('KEYWORD', 'verify');
    consume('PUNCT', '(');
    final cond = parseExpr();
    consume('PUNCT', ',');
    final msgTok = consume('STRING');
    final msg = _stripChars(msgTok.val, '"\'');
    consume('PUNCT', ')');
    consume('PUNCT', ';');
    return VerifyNode(cond, msg, tok);
  }

  /// `trap(N) name() { ... }`: a function run when trap N is taken. It
  /// has no return value, takes no arguments (the empty `()` is required)
  /// and must have a body.
  FuncDeclNode _parseTrapHandler() {
    consume(); // trap
    consume('PUNCT', '(');
    final trapExpr = _parseConstExpr();
    consume('PUNCT', ')');
    final nameTok = peek();
    if (nameTok.type != 'IDENT') {
      throw CompileError(
          "${nameTok.loc}: expected the handler's name after 'trap(N)', got '${nameTok.val}'");
    }
    consume();
    final name = nameTok.val;
    if (peek().val != '(') {
      throw CompileError(
          "${peek().loc}: a trap handler is written 'trap(N) $name() { ... }'");
    }
    consume('PUNCT', '(');
    if (peek().val != ')') {
      throw CompileError("${peek().loc}: trap handler '$name' cannot take arguments");
    }
    consume('PUNCT', ')');
    if (peek().val != '{') {
      throw CompileError("${peek().loc}: trap handler '$name' needs a body");
    }
    final body = parseBlock();
    return FuncDeclNode('void', false, name, [], body, trapExpr: trapExpr);
  }

  AstNode parseTopLevel() {
    final start = peek();
    try {
      final node = _parseTopLevel();
      node.loc ??= start.loc;
      return node;
    } on CompileError catch (e) {
      throw e.at(start.loc);
    }
  }

  AstNode _parseTopLevel() {
    // asm ReturnType name(params);  -- a routine written in assembly
    if (peek().val == 'asm' && ahead(1).val != '(') {
      final asmTok = consume();
      final decl = parseTopLevel();
      if (decl is! FuncDeclNode ||
          decl.body != null ||
          decl.isInline ||
          decl.trapExpr != null) {
        throw CompileError(
            "${asmTok.loc}: 'asm' must be followed by a function prototype, such as 'asm u32 name(u32 a);'");
      }
      decl.isAsm = true;
      return decl;
    }
    // extern ReturnType name(params);  -- a C function (LLVM compiler only)
    if (peek().val == 'extern') {
      final externTok = consume();
      final decl = parseTopLevel();
      if (decl is! FuncDeclNode ||
          decl.body != null ||
          decl.isInline ||
          decl.trapExpr != null ||
          decl.isTask) {
        throw CompileError(
            "${externTok.loc}: 'extern' must be followed by a function prototype, such as 'extern s32 puts(string s);'");
      }
      decl.isExtern = true;
      return decl;
    }
    if (peek().val == 'import') {
      return parseImport();
    }
    if (peek().val == 'ref') {
      // ref T[] name(...): a function that returns a heap array of references
      if (ahead(2).val == '[' && ahead(3).val == ']' && ahead(5).val == '(') {
        consume('KEYWORD', 'ref');
        final f = _parseTopLevel();
        if (f is! FuncDeclNode) throw CompileError("${peek().loc}: expected a function");
        return f..retRefArray = true;
      }
      return _parseRefArrayDecl(consume());
    }
    if (peek().val == 'enum') {
      return parseEnum();
    }
    if (peek().val == 'verify') {
      return parseVerify();
    }
    var isVolatile = false;
    if (peek().val == 'volatile') {
      consume('KEYWORD', 'volatile');
      isVolatile = true;
    }
    var isInline = false;
    if (peek().val == 'inline') {
      consume();
      isInline = true;
    }

    // task name(State t, ...) { ... }: a coroutine. It is parsed as a
    // function returning its u16 status.
    if (peek().val == 'task' && ahead(1).type == 'IDENT' && ahead(2).val == '(') {
      final taskTok = peek();
      if (isInline || isVolatile) {
        throw CompileError(
            "${taskTok.loc}: a task cannot be ${isInline ? 'inline' : 'volatile'}");
      }
      tokens[pos] = Token('KEYWORD', 'u16', taskTok.lineno, taskTok.col, taskTok.fname);
      final decl = parseTopLevel();
      if (decl is! FuncDeclNode || decl.body == null) {
        throw CompileError("${taskTok.loc}: task '${ahead(0).val}' needs a body");
      }
      if (decl.params.isEmpty) {
        throw CompileError(
            "${taskTok.loc}: task '${decl.name}' needs its state as the first parameter, as in 'task ${decl.name}(pt t)'");
      }
      decl.isTask = true;
      return decl;
    }

    // trap(N) name() { ... }: a trap handler
    if (peek().val == 'trap' && ahead(1).val == '(') {
      if (isInline || isVolatile) {
        throw CompileError(
            "${peek().loc}: a trap handler cannot be ${isInline ? 'inline' : 'volatile'}");
      }
      return _parseTrapHandler();
    }

    // type Name { ... }; or type Name = fn(...) -> RetType;
    if (peek().val == 'struct') {
      final t = peek();
      throw CompileError(
          "${t.loc}: 'struct' is deprecated; use 'type ${ahead(1).val} { ... }' instead");
    }

    if (peek().val == 'type' &&
        ahead(1).type == 'IDENT' &&
        ['{', '='].contains(ahead(2).val)) {
      final typeTok = consume();
      final tName = consume('IDENT').val;
      if (peek().val == '=' && ahead(1).val != 'fn') {
        // type Name = Target;  -- an alias
        consume();
        final target = parseType();
        if (peek().val == '[' || peek().val == '*') {
          throw CompileError(
              "${peek().loc}: '$tName' cannot alias an array; aliases name a scalar, string, user-defined or function type");
        }
        if (peek().val == ';') {
          consume('PUNCT', ';');
        }
        knownTypes.add(tName);
        return TypeAliasNode(tName, target, typeTok.loc);
      }
      if (peek().val == '=') {
        consume();
        consume('KEYWORD', 'fn');
        consume('PUNCT', '(');
        final fnParams = <String>[];
        if (peek().val != ')') {
          while (true) {
            fnParams.add(parseType());
            if (peek().val == ',') {
              consume();
            } else {
              break;
            }
          }
        }
        consume('PUNCT', ')');
        var retT = 'void';
        if (peek().val == '->') {
          consume('OP_ARROW', '->');
          retT = parseType();
        }
        if (peek().val == ';') {
          consume('PUNCT', ';');
        }
        return FnTypeNode(tName, fnParams, retT);
      } else if (peek().val == '{') {
        consume('PUNCT', '{');
        final fields = <FieldDecl>[];
        while (peek().val != '}' && peek().type != 'EOF') {
          // ref T name;  -- a reference to a T stored elsewhere
          if (peek().val == 'ref') {
            final refTok = consume();
            final rType = parseType();
            _rejectPointerType(rType);
            final rName = consume('IDENT').val;
            if (peek().val == '[') {
              // ref T name[N]: a fixed array of references; ref T name[]:
              // a reference to a heap array of references
              final dims = <AstNode>[];
              var heap = false;
              while (peek().val == '[') {
                consume('PUNCT', '[');
                if (peek().val == ']') {
                  consume('PUNCT', ']');
                  if (dims.isNotEmpty || peek().val == '[') {
                    throw CompileError(
                        "${refTok.loc}: field '$rName': a heap array of references is written 'ref $rType $rName[]', with no other dimensions");
                  }
                  heap = true;
                  break;
                }
                dims.add(_parseConstExpr());
                consume('PUNCT', ']');
              }
              if (peek().val == ';') {
                consume('PUNCT', ';');
              }
              fields.add(FieldDecl(rType, heap, rName, dims, false, isArrayRef: heap)
                ..loc = refTok.loc
                ..isRefArray = true);
              continue;
            }
            if (peek().val == ';') {
              consume('PUNCT', ';');
            }
            fields.add(FieldDecl(rType, true, rName, const [], false)..loc = refTok.loc);
            continue;
          }
          final fTok = peek();
          final fType = parseType();
          if (peek().val == ';') {
            consume('PUNCT', ';');
            if (['u8', 's8', 'u16', 's16', 'u32', 's32', 'bool', 'void']
                .contains(fType)) {
              throw CompileError(
                  "Cannot anonymously embed primitive scalar type '$fType'");
            }
            fields.add(FieldDecl(fType, false, fType, const [], true)..loc = fTok.loc);
            continue;
          }
          _rejectPointerType(fType);
          final fName = consume('IDENT').val;
          final fDims = <AstNode>[];
          var arrayRef = false;
          while (peek().val == '[') {
            consume('PUNCT', '[');
            if (peek().val == ']') {
              // T name[]: a reference to a heap array
              consume('PUNCT', ']');
              if (fDims.isNotEmpty || peek().val == '[') {
                throw CompileError(
                    "${fTok.loc}: field '$fName': a heap array reference is written '$fType $fName[]', with no other dimensions");
              }
              arrayRef = true;
              break;
            }
            fDims.add(_parseConstExpr());
            consume('PUNCT', ']');
          }
          if (peek().val == ';') {
            consume('PUNCT', ';');
          }
          fields.add(FieldDecl(fType, arrayRef, fName, fDims, false, isArrayRef: arrayRef)
            ..loc = fTok.loc);
        }
        consume('PUNCT', '}');
        if (peek().val == ';') {
          consume('PUNCT', ';');
        }
        knownTypes.add(tName);
        return TypeDefNode(tName, fields);
      }
    }

    var isConst = false;
    if (peek().val == 'const') {
      consume();
      isConst = true;
    }

    Object tName;
    var isPtr = false;
    if (peek().val == '(') {
      consume('PUNCT', '(');
      final tupleRetTypes = <TupleElemType>[];
      while (true) {
        final retElemT = parseType();
        _rejectPointerType(retElemT);
        // T[]: a heap array (or string) the function hands to its caller
        var elemArray = false;
        if (peek().val == '[' && ahead(1).val == ']') {
          consume('PUNCT', '[');
          consume('PUNCT', ']');
          elemArray = true;
        }
        tupleRetTypes.add((retElemT, elemArray));
        if (peek().val == ',') {
          consume();
        } else {
          break;
        }
      }
      consume('PUNCT', ')');
      if (tupleRetTypes.length > 4) {
        throw CompileError(
            'Maximum 4 scalar return values supported in Particle ABI, got ${tupleRetTypes.length}');
      }
      tName = tupleRetTypes;
      isPtr = false;
    } else {
      final t = parseType();
      tName = t;
      isPtr = false;
      _rejectPointerType(t);
      // T[] name(...): returns a heap array (or heap string)
      if (peek().val == '[' && ahead(1).val == ']') {
        final at = consume('PUNCT', '[');
        consume('PUNCT', ']');
        if (ahead(1).val != '(' && ahead(1).val != '.') {
          throw CompileError("${at.loc}: a heap array variable is written 'T name[]', with the "
              "brackets after the name; 'T[]' before a name is the result of a function");
        }
        isPtr = true;
      }
    }

    var name = consume('IDENT').val;

    String? boundStruct;
    // Oberon-style type-bound procedure: void Point.move(...)
    if (peek().val == '.') {
      consume('PUNCT', '.');
      final methodName = consume('IDENT').val;
      final boundType = _resolveAlias(name);
      boundStruct = boundType;
      name = '${boundType}_$methodName';
    }

    if (peek().val == '(') {
      consume('PUNCT', '(');
      final params = <Param>[];
      Token? variadic;
      if (boundStruct != null) {
        // Automatically prepend receiver 'this' by reference
        params.add(Param(boundStruct, false, 'this'));
      }
      if (peek().val != ')') {
        while (true) {
          if (peek().val == 'void' &&
              params.length == (boundStruct != null ? 1 : 0)) {
            consume();
            break;
          }
          if (peek().val == '...') {
            // A C variadic function: 'extern' checks this, and it must be last
            final dots = consume();
            if (peek().val != ')') {
              throw CompileError("${dots.loc}: '...' must be the last parameter");
            }
            variadic = dots;
            break;
          }
          Token? refTok;
          if (peek().val == 'ref') refTok = consume();
          final pType = parseType();
          var pPtr = false;
          _rejectPointerType(pType);
          final pTok = peek();
          final pName = consume('IDENT').val;
          var isOpenArr = false;
          var openRank = 0;
          while (peek().val == '[') {
            final br = consume('PUNCT', '[');
            if (peek().val != ']') {
              throw CompileError("${br.loc}: an array parameter is open: '$pName[]' takes an "
                  "array of any length, and '$pName[][]' one of two dimensions");
            }
            consume('PUNCT', ']');
            isOpenArr = true;
            pPtr = true;
            openRank++;
          }
          if (openRank > 3) {
            throw CompileError("${pTok.loc}: an open array parameter has at most 3 dimensions");
          }
          if (refTok != null && openRank > 1) {
            throw CompileError("${pTok.loc}: an array of references has one dimension: "
                "'ref $pType $pName[]'");
          }
          if (refTok != null && !isOpenArr) {
            throw CompileError(
                "${refTok.loc}: a parameter of a user-defined type is already passed by reference; 'ref' is for an array of references, such as 'ref $pType $pName[]'");
          }
          params.add(Param(pType, pPtr, pName, isOpenArr)
            ..loc = pTok.loc
            ..isRefArray = refTok != null
            ..openRank = openRank == 0 ? 1 : openRank);
          if (peek().val == ',') {
            consume();
          } else {
            break;
          }
        }
      }
      consume('PUNCT', ')');
      if (peek().val == '@') {
        throw CompileError(
            "${peek().loc}: a trap handler is written 'trap(N) $name() { ... }'");
      }
      if (peek().val == ';') {
        consume('PUNCT', ';');
        return FuncDeclNode(tName, isPtr, name, params, null,
            isInline: isInline)
          ..isVariadic = variadic != null;
      }
      if (variadic != null) {
        throw CompileError(
            "${variadic.loc}: only a C function declared 'extern' can take '...'");
      }
      final body = parseBlock();
      return FuncDeclNode(tName, isPtr, name, params, body, isInline: isInline);
    } else {
      return _finishVarDecl(tName, isPtr, name, isConst, isVolatile);
    }
  }

  /// Parses the rest of a variable declaration after its type and name:
  /// array dimensions (`[N]`, or `[]` for an array reference), an optional
  /// `@ address`, an optional initializer and the closing `;`.
  VarDeclNode _finishVarDecl(
      Object tName, bool isPtr, String name, bool isConst, bool isVolatile) {
    final dimExprs = <AstNode>[];
    AstNode? boundAddrExpr;
    while (peek().val == '[') {
      consume('PUNCT', '[');
      if (peek().val == ']') {
        consume('PUNCT', ']');
        isPtr = true;
        break;
      }
      dimExprs.add(_parseConstExpr());
      consume('PUNCT', ']');
    }
    if (peek().val == '@') {
      consume('PUNCT', '@');
      boundAddrExpr = _parseConstExpr();
    }
    AstNode? initExpr;
    AstNode? initList;
    if (match('=') != null) {
      if (peek().val == '{') {
        initList = _parseInitializer();
      } else {
        initExpr = parseExpr();
      }
    }
    consume('PUNCT', ';');
    if (boundAddrExpr != null) {
      isVolatile = true;
    }
    if (initList != null && isPtr) {
      throw CompileError("${initList.loc}: '$name' is a reference to a heap array; a brace "
          'initializer gives values to an array or record stored in place, so give a heap '
          'array its elements after createArray()');
    }
    // const string NAME = "text": a read-only string, sized to fit
    if (isConst && dimExprs.isEmpty && !isPtr && tName == 'string') {
      if (initExpr is! StringLitNode) {
        throw CompileError("${peek().loc}: string constant '$name' is given a string literal: "
            'const string $name = "...";');
      }
      dimExprs.add(IntLitNode(initExpr.val.length + 1));
    }
    // const T name[N] = {...}: a read-only table, not a compile-time value
    final isTable = isConst && dimExprs.isNotEmpty;
    final node = VarDeclNode(tName, isPtr, name, initExpr, isConst && !isTable, isVolatile);
    node.dimExprs = dimExprs;
    node.boundAddrExpr = boundAddrExpr;
    node.initList = initList;
    node.isReadOnly = isTable;
    return node;
  }

  /// A brace initializer: `{v, v, ...}` (elements, each a value or another
  /// brace list) or `{field: v, ...}` (a record). A trailing comma is allowed.
  AstNode _parseInitializer() {
    if (peek().val != '{') return parseExpr();
    final open = consume('PUNCT', '{');
    if (peek().type == 'IDENT' && ahead(1).val == ':') {
      final fields = <(String, AstNode)>[];
      final locs = <String?>[];
      while (peek().val != '}') {
        final nameTok = consume('IDENT');
        consume('PUNCT', ':');
        fields.add((nameTok.val, _parseInitializer()));
        locs.add(nameTok.loc);
        if (peek().val != ',') break;
        consume('PUNCT', ',');
      }
      consume('PUNCT', '}');
      return RecordInitNode(fields, locs)..loc = open.loc;
    }
    final elems = <AstNode>[];
    while (peek().val != '}') {
      elems.add(_parseInitializer());
      if (peek().val != ',') break;
      consume('PUNCT', ',');
    }
    consume('PUNCT', '}');
    return InitListNode(elems)..loc = open.loc;
  }

  /// The assignments that give a local declared with a brace initializer
  /// its values, one per element or field, after its declaration.
  List<AstNode> _expandInitializer(VarDeclNode d) {
    final out = <AstNode>[];
    void walk(AstNode target, AstNode init) {
      if (init is InitListNode) {
        for (var i = 0; i < init.elems.length; i++) {
          walk(ArrayAccessNode(target, IntLitNode(i))..loc = init.elems[i].loc ?? init.loc,
              init.elems[i]);
        }
      } else if (init is RecordInitNode) {
        for (var i = 0; i < init.fields.length; i++) {
          final (f, v) = init.fields[i];
          walk(MemberAccessNode(target, f)..loc = init.fieldLocs[i] ?? init.loc, v);
        }
      } else {
        out.add(ExprStmtNode(BinaryOpNode('=', target, init)..loc = init.loc ?? d.loc)
          ..loc = init.loc ?? d.loc);
      }
    }

    walk(VarAccessNode(d.name)..loc = d.loc, d.initList!);
    d.expanded = true;
    return out;
  }

  /// `ref T name[N];`, a local or global array of references, after the
  /// `ref`.
  VarDeclNode _parseRefArrayDecl(Token refTok) {
    final tName = parseType();
    _rejectPointerType(tName);
    final name = consume('IDENT').val;
    final d = _finishVarDecl(tName, false, name, false, false);
    if (d.dimExprs.isEmpty && d.isPtr) {
      // ref T name[]: a reference to a heap array of references
      if (d.boundAddrExpr != null) {
        throw CompileError("${refTok.loc}: an array of references cannot be at a fixed address");
      }
      return d..isRefArray = true;
    }
    if (d.initList != null) {
      throw CompileError("${refTok.loc}: '$name' holds references; a brace initializer gives "
          'values to an array or record stored in place');
    }
    if (d.dimExprs.isEmpty) {
      // ref T name;: a reference that starts empty
      if (d.boundAddrExpr != null) {
        throw CompileError("${refTok.loc}: a reference cannot be at a fixed address");
      }
      return d..isRefDecl = true;
    }
    if (d.boundAddrExpr != null) {
      throw CompileError("${refTok.loc}: an array of references cannot be at a fixed address");
    }
    if (d.initExpr != null) {
      throw CompileError(
          "${refTok.loc}: an array of references cannot have an initializer; its references start null");
    }
    return d..isRefArray = true;
  }

  BlockNode parseBlock() {
    consume('PUNCT', '{');
    final stmts = <AstNode>[];
    while (peek().val != '}' && peek().type != 'EOF') {
      final st = parseStatement();
      stmts.add(st);
      if (st is VarDeclNode && st.initList != null && !st.isReadOnly) {
        stmts.addAll(_expandInitializer(st));
      }
    }
    final close = peek();
    consume('PUNCT', '}');
    return BlockNode(stmts)..endLoc = close.loc;
  }

  AstNode parseStatement() {
    final start = peek();
    try {
      final node = _parseStatement();
      node.loc ??= start.loc;
      return node;
    } on CompileError catch (e) {
      throw e.at(start.loc);
    }
  }

  AstNode _parseStatement() {
    var tok = peek();
    if (tok.val == 'verify') {
      return parseVerify();
    }
    if (tok.val == ';') {
      consume('PUNCT', ';');
      return BlockNode([]);
    }
    if (tok.val == '{') {
      return parseBlock();
    }
    if (tok.val == 'if') {
      consume();
      consume('PUNCT', '(');
      final cond = parseExpr();
      consume('PUNCT', ')');
      final thenBody = parseStatement();
      AstNode? elseBody;
      if (peek().val == 'else') {
        consume();
        elseBody = parseStatement();
      }
      return IfNode(cond, thenBody, elseBody);
    }
    if (tok.val == 'case') {
      consume('KEYWORD', 'case');
      final caseExpr = parseExpr();
      consume('PUNCT', ':');
      return CaseLabelNode(caseExpr);
    }

    if (tok.val == 'default') {
      consume('KEYWORD', 'default');
      consume('PUNCT', ':');
      return DefaultLabelNode();
    }

    if (tok.val == 'switch') {
      consume();
      consume('PUNCT', '(');
      final expr = parseExpr();
      consume('PUNCT', ')');
      final body = parseStatement();
      return SwitchNode(expr, body);
    }

    if (tok.val == 'for') {
      consume('KEYWORD', 'for');
      consume('PUNCT', '(');
      final varType = parseType();
      final varName = consume('IDENT').val;
      consume('PUNCT', ':');
      final startExpr = parseExpr();
      consume('OP_RANGE', '..');
      final endExpr = parseExpr();
      consume('PUNCT', ')');
      final body = parseStatement();
      return ForRangeNode(varType, varName, startExpr, endExpr, body);
    }

    if (tok.val == 'while') {
      consume();
      consume('PUNCT', '(');
      final cond = parseExpr();
      consume('PUNCT', ')');
      final body = parseStatement();
      return WhileNode(cond, body);
    }

    if (tok.val == 'asm') {
      consume();
      consume('PUNCT', '(');
      final asmTok = consume('STRING');
      consume('PUNCT', ')');
      consume('PUNCT', ';');
      final rawText =
          decodeEscapes(asmTok.val.substring(1, asmTok.val.length - 1));
      return AsmNode(rawText);
    }

    if (tok.val == 'break') {
      consume();
      consume('PUNCT', ';');
      return BreakNode();
    }

    if (tok.val == 'continue') {
      consume();
      consume('PUNCT', ';');
      return ContinueNode();
    }

    if (tok.val == 'return') {
      consume();
      if (peek().val == '(') {
        // Check if this is a tuple return (e1, e2, ...) vs parenthesized single expression
        final savedPos = pos;
        consume('PUNCT', '(');
        var parenDepth = 1;
        var hasCommaAtDepth1 = false;
        var curPos = pos;
        while (curPos < tokens.length && parenDepth > 0) {
          final tVal = tokens[curPos].val;
          if (tVal == '(') {
            parenDepth++;
          } else if (tVal == ')') {
            parenDepth--;
          } else if (tVal == ',' && parenDepth == 1) {
            hasCommaAtDepth1 = true;
          }
          curPos++;
        }
        pos = savedPos;

        if (hasCommaAtDepth1) {
          consume('PUNCT', '(');
          final retExprs = <AstNode>[];
          while (true) {
            retExprs.add(parseExpr());
            if (peek().val == ',') {
              consume();
            } else {
              break;
            }
          }
          consume('PUNCT', ')');
          consume('PUNCT', ';');
          if (retExprs.length > 4) {
            throw CompileError(
                'Maximum 4 scalar return values supported in Particle ABI, got ${retExprs.length}');
          }
          return TupleReturnNode(retExprs);
        }
      }

      AstNode? expr;
      if (peek().val != ';') {
        expr = parseExpr();
      }
      consume('PUNCT', ';');
      return ReturnNode(expr);
    }

    // Destructuring assignment / tuple declaration: (u32 a, _) = fn(); or (a, b) = fn();
    if (tok.val == '(') {
      final savedPos = pos;
      consume('PUNCT', '(');
      var parenDepth = 1;
      var hasCommaOrWildcard = false;
      var curPos = pos;
      while (curPos < tokens.length && parenDepth > 0) {
        final tVal = tokens[curPos].val;
        if (tVal == '(') {
          parenDepth++;
        } else if (tVal == ')') {
          parenDepth--;
        } else if ((tVal == ',' || tVal == '_') && parenDepth == 1) {
          hasCommaOrWildcard = true;
        }
        curPos++;
      }
      pos = savedPos;

      if (hasCommaOrWildcard) {
        consume('PUNCT', '(');
        final targets = <TupleTarget>[];
        while (true) {
          if (peek().val == '_') {
            consume();
            targets.add(TupleTarget(isWildcard: true));
          } else {
            // Could be: 'type name', 'type* name', or simply existing variable 'name'
            final pTok = peek();
            var isDecl = false;
            if ([..._primitiveTypes, 'string'].contains(pTok.val) ||
                knownTypes.contains(pTok.val)) {
              isDecl = true;
            } else if (pTok.type == 'IDENT' && ahead(1).type == 'IDENT') {
              isDecl = true;
            }

            if (isDecl) {
              final tN = parseType();
              _rejectPointerType(tN);
              final vN = consume('IDENT').val;
              // T name[]: a heap array (or string) from the tuple
              var isArr = false;
              if (peek().val == '[' && ahead(1).val == ']') {
                consume('PUNCT', '[');
                consume('PUNCT', ']');
                isArr = true;
              }
              targets.add(TupleTarget(
                  name: vN, typeName: tN, isPtr: isArr, isWildcard: false));
            } else {
              final vN = consume('IDENT').val;
              targets.add(TupleTarget(name: vN, isWildcard: false));
            }
          }

          if (peek().val == ',') {
            consume();
          } else {
            break;
          }
        }
        consume('PUNCT', ')');
        consume('OP', '=');
        final rhsExpr = parseExpr();
        consume('PUNCT', ';');
        if (targets.length > 4) {
          throw CompileError(
              'Maximum 4 scalar return values supported in Particle ABI, got ${targets.length}');
        }
        return TupleAssignNode(targets, rhsExpr);
      }
    }

    // Local Variable / Array Declaration
    var isVolatile = false;
    if (tok.val == 'volatile') {
      consume('KEYWORD', 'volatile');
      isVolatile = true;
      tok = peek();
    }

    var isConst = false;
    if (tok.val == 'const') {
      consume();
      isConst = true;
      tok = peek();
    }

    if (tok.val == 'ref' && !isConst && !isVolatile) {
      return _parseRefArrayDecl(consume());
    }
    if ([..._primitiveTypes, 'string'].contains(tok.val) ||
        tok.val == 'type' ||
        (tok.type == 'IDENT' && ahead(1).type == 'IDENT')) {
      final tName = parseType();
      _rejectPointerType(tName);
      final name = consume('IDENT').val;
      return _finishVarDecl(tName, false, name, isConst, isVolatile);
    }

    final expr = parseExpr();
    consume('PUNCT', ';');
    return ExprStmtNode(expr);
  }

  AstNode parseExpr() => parseAssignment();

  /// Gives [node] the location of [tok] (unless it has one) and returns it.
  T _at<T extends AstNode>(Token tok, T node) {
    node.loc ??= tok.loc;
    return node;
  }

  AstNode parseAssignment() {
    final node = parseLogicalOr();
    final tok = peek();
    if (tok.val == '=') {
      consume();
      final rhs = parseAssignment();
      return _at(tok, BinaryOpNode('=', node, rhs));
    } else if (tok.type == 'COMPOUND_ASSIGN' ||
        ['+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=']
            .contains(tok.val)) {
      final op = consume().val;
      final rhs = parseAssignment();
      return _at(tok, CompoundAssignNode(op, node, rhs));
    }
    return node;
  }

  AstNode parseLogicalOr() {
    var node = parseLogicalAnd();
    while (peek().val == '||') {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseLogicalAnd()));
    }
    return node;
  }

  AstNode parseLogicalAnd() {
    var node = parseRelational();
    while (peek().val == '&&') {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseRelational()));
    }
    return node;
  }

  AstNode parseRelational() {
    var node = parseBitwise();
    while (['==', '!=', '<', '<=', '>', '>='].contains(peek().val)) {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseBitwise()));
    }
    return node;
  }

  AstNode parseBitwise() {
    var node = parseShift();
    while (['&', '|', '^'].contains(peek().val)) {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseShift()));
    }
    return node;
  }

  AstNode parseShift() {
    var node = parseAdditive();
    while (['<<', '>>'].contains(peek().val)) {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseAdditive()));
    }
    return node;
  }

  AstNode parseAdditive() {
    var node = parseMultiplicative();
    while (['+', '-'].contains(peek().val)) {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseMultiplicative()));
    }
    return node;
  }

  AstNode parseMultiplicative() {
    var node = parseUnary();
    while (['*', '/', '%'].contains(peek().val)) {
      final opTok = consume();
      node = _at(opTok, BinaryOpNode(opTok.val, node, parseUnary()));
    }
    return node;
  }

  AstNode parseUnary() {
    final t = peek();
    if (t.val == '*' || t.val == '&') {
      final what = t.val == '*' ? 'pointer dereference' : 'address-of';
      throw CompileError(
          "${t.loc}: $what '${t.val}' is not supported; Action has no pointers (user-defined types and arrays are passed by reference)");
    }
    if (['-', '~', '!'].contains(t.val)) {
      final op = consume().val;
      return _at(t, UnaryOpNode(op, parseUnary()));
    }
    return parsePostfix();
  }

  AstNode parseArrayAccess(AstNode baseNode) {
    consume('PUNCT', '[');
    final idx = parseExpr();
    consume('PUNCT', ']');
    return ArrayAccessNode(baseNode, idx);
  }

  AstNode parsePostfix() {
    var node = parsePrimary();
    while (true) {
      if (peek().val == '->') {
        final t = peek();
        throw CompileError(
            "${t.loc}: '->' is not supported; Action has no pointers, use '.'");
      }
      final postTok = peek();
      if (peek().val == '.') {
        consume();
        final member = consume('IDENT').val;
        if (peek().val == '(') {
          final openTok = consume('PUNCT', '(');
          final args = <AstNode>[];
          // T.create(field: value, ...): named values
          final named = <(String, AstNode)>[];
          final namedLocs = <String?>[];
          if (peek().val != ')') {
            while (true) {
              if (peek().type == 'IDENT' && ahead(1).val == ':') {
                final nameTok = consume('IDENT');
                consume('PUNCT', ':');
                named.add((nameTok.val, _parseInitializer()));
                namedLocs.add(nameTok.loc);
              } else {
                if (named.isNotEmpty) {
                  throw CompileError('${peek().loc}: after a named value, every value is named');
                }
                args.add(parseExpr());
              }
              if (peek().val == ',') {
                consume();
              } else {
                break;
              }
            }
          }
          consume('PUNCT', ')');
          if (named.isNotEmpty && member != 'create') {
            throw CompileError("${openTok.loc}: named values (field: value) are given only to "
                "T.create(...), not to '$member'");
          }

          // Intercept dynamic allocation pseudo-constructors
          // Receiver node is a VarAccessNode naming a type, or identifier 'string'
          final rcvName = node is VarAccessNode ? _resolveAlias(node.name) : null;

          if (member == 'create') {
            if (rcvName == 'string') {
              if (args.length != 1) {
                throw CompileError(
                    'string.create(capacity) requires exactly 1 argument (capacity)');
              }
              node = HeapStringAllocNode(args[0]);
            } else if (rcvName != null) {
              if (args.isNotEmpty) {
                throw CompileError("${openTok.loc}: $rcvName.create() gives fields their values by "
                    'name, as in $rcvName.create(x: 1, y: 2); it takes no other arguments');
              }
              final values = <AstNode>[];
              final paths = <List<Object>>[];
              void flatten(List<Object> path, AstNode v) {
                if (v is RecordInitNode) {
                  for (final (f, fv) in v.fields) {
                    flatten([...path, f], fv);
                  }
                } else if (v is InitListNode) {
                  for (var i = 0; i < v.elems.length; i++) {
                    flatten([...path, i], v.elems[i]);
                  }
                } else {
                  values.add(v);
                  paths.add(path);
                }
              }

              for (final (f, v) in named) {
                flatten([f], v);
              }
              node = HeapAllocNode(rcvName, values, paths)..loc = openTok.loc;
            } else {
              node = CallNode('__METHOD__$member', [node, ...args]);
            }
          } else if (member == 'createArray') {
            if (rcvName == null) {
              throw CompileError(
                  'createArray(N) must be called on a type identifier (e.g. Type.createArray(N))');
            }
            if (args.length != 1) {
              throw CompileError(
                  'createArray(N) requires exactly 1 argument (element count)');
            }
            node = HeapArrayAllocNode(rcvName, args[0]);
          } else if (member == 'destroy' || member == 'destroyArray') {
            if (args.isNotEmpty) {
              throw CompileError('$member() takes no arguments');
            }
            node = HeapFreeNode(node);
          } else if (member == 'resize') {
            if (args.length != 1) {
              throw CompileError(
                  'resize(N) requires exactly 1 argument (new element count)');
            }
            node = HeapArrayResizeNode(node, args[0]);
          } else if (member == 'exists') {
            if (args.isNotEmpty) {
              throw CompileError('exists() takes no arguments');
            }
            node = ExistsNode(node);
          } else if (member == 'copyFrom') {
            if (args.length != 1) {
              throw CompileError('copyFrom(source) takes exactly 1 argument, the value to copy');
            }
            node = CallNode('__copyFrom', [node, args[0]])..loc = openTok.loc;
          } else if (member == 'sameAs') {
            if (args.length != 1) {
              throw CompileError('sameAs(other) takes exactly 1 argument, the other reference');
            }
            node = BinaryOpNode('==', node, args[0])..identity = true;
          } else if (member == 'unset') {
            if (args.isNotEmpty) {
              throw CompileError('unset() takes no arguments');
            }
            node = BinaryOpNode('=', node, IntLitNode(0))..isUnset = true;
          } else {
            node = CallNode('__METHOD__$member', [node, ...args]);
          }
        } else {
          node = MemberAccessNode(node, member);
        }
      } else if (peek().val == '[') {
        consume('PUNCT', '[');
        if (peek().val == '..') {
          consume('OP_RANGE', '..');
          AstNode? endExpr;
          if (peek().val != ']') {
            endExpr = parseExpr();
          }
          consume('PUNCT', ']');
          node = SliceNode(node, null, endExpr);
        } else {
          final startExpr = parseExpr();
          if (peek().val == '..') {
            consume('OP_RANGE', '..');
            AstNode? endExpr;
            if (peek().val != ']') {
              endExpr = parseExpr();
            }
            consume('PUNCT', ']');
            node = SliceNode(node, startExpr, endExpr);
          } else {
            consume('PUNCT', ']');
            node = ArrayAccessNode(node, startExpr);
          }
        }
      } else if (peek().val == '(' && (node is ArrayAccessNode || node is CallNode)) {
        // t[i](x), f()(x): a call through a function value
        consume('PUNCT', '(');
        final args = <AstNode>[];
        if (peek().val != ')') {
          while (true) {
            args.add(parseExpr());
            if (peek().val != ',') break;
            consume();
          }
        }
        consume('PUNCT', ')');
        node = CallNode(callValueName, [node, ...args])..loc = postTok.loc;
      } else {
        break;
      }
      node.loc ??= postTok.loc;
    }
    return node;
  }

  AstNode parsePrimary() {
    final start = peek();
    try {
      final node = _parsePrimary();
      node.loc ??= start.loc;
      return node;
    } on CompileError catch (e) {
      throw e.at(start.loc);
    }
  }

  AstNode _parsePrimary() {
    final tok = peek();
    if (tok.val == 'sizeof') {
      consume('KEYWORD', 'sizeof');
      consume('PUNCT', '(');
      final argTok = peek();
      if ([..._primitiveTypes, 'void', 'string'].contains(argTok.val)) {
        final tArg = consume().val;
        _rejectPointerType(tArg);
        consume('PUNCT', ')');
        final sz = ['u8', 's8', 'bool', 'string'].contains(tArg)
            ? 1
            : (['u16', 's16'].contains(tArg)
                ? 2
                : (['u64', 's64', 'f64'].contains(tArg) ? 8 : 4));
        return IntLitNode(sz);
      } else if (argTok.type == 'IDENT' &&
          ahead(1).val == '*' &&
          ahead(2).val == ')') {
        final tArg = consume('IDENT').val;
        _rejectPointerType(tArg);
        throw StateError('unreachable');
      } else if (argTok.type == 'IDENT' && ahead(1).val == ')') {
        final tArg = consume('IDENT').val;
        consume('PUNCT', ')');
        if (aliases.containsKey(tArg)) {
          final target = aliases[tArg]!;
          if (const ['u8', 's8', 'bool', 'string'].contains(target)) return IntLitNode(1);
          if (const ['u16', 's16'].contains(target)) return IntLitNode(2);
          if (const ['u32', 's32'].contains(target)) return IntLitNode(4);
          return SizeofNode(target);
        }
        return SizeofNode(tArg);
      } else {
        final expr = parseExpr();
        consume('PUNCT', ')');
        return SizeofNode(expr);
      }
    }
    if (tok.type == 'FLOAT') {
      consume();
      final v = double.tryParse(tok.val.replaceAll('_', ''));
      if (v == null || v.isInfinite) {
        throw CompileError("${tok.loc}: invalid number '${tok.val}'");
      }
      return FloatLitNode(v, tok.val);
    }
    if (tok.type == 'INT' || tok.type == 'HEX' || tok.type == 'BIN') {
      consume();
      try {
        return IntLitNode(parseIntAuto(tok.val));
      } on CompileError catch (e) {
        throw e.at(tok.loc);
      }
    }
    if (tok.type == 'CHAR') {
      consume();
      final raw = decodeEscapes(tok.val.substring(1, tok.val.length - 1));
      final val = raw.isNotEmpty ? raw.codeUnitAt(0) : 0;
      return IntLitNode(val);
    }
    if (tok.val == 'true' || tok.val == 'false') {
      consume();
      return IntLitNode(tok.val == 'true' ? 1 : 0);
    }
    if (tok.type == 'STRING') {
      consume();
      final raw = decodeEscapes(tok.val.substring(1, tok.val.length - 1));
      return StringLitNode(raw);
    }
    // T(x): a conversion to a scalar type (or an alias of one)
    if (pos + 1 < tokens.length &&
        ahead(1).val == '(' &&
        ((tok.type == 'KEYWORD' && _convertTypes.contains(tok.val)) ||
            (tok.type == 'IDENT' &&
                aliases.containsKey(tok.val) &&
                _convertTypes.contains(_resolveAlias(tok.val))))) {
      consume();
      consume('PUNCT', '(');
      final e = parseExpr();
      if (peek().val == ',') {
        throw CompileError("${tok.loc}: a conversion '${tok.val}(...)' takes exactly one value");
      }
      consume('PUNCT', ')');
      return ConvertNode(_resolveAlias(tok.val), e)..loc = tok.loc;
    }
    if (tok.type == 'IDENT' ||
        ([..._arrayElemTypes, 'string'].contains(tok.val) &&
            pos + 1 < tokens.length &&
            ahead(1).val == '.')) {
      final name = consume().val;
      if (peek().val == '(') {
        consume('PUNCT', '(');
        final args = <AstNode>[];
        if (peek().val != ')') {
          while (true) {
            args.add(parseExpr());
            if (peek().val == ',') {
              consume();
            } else {
              break;
            }
          }
        }
        consume('PUNCT', ')');
        if (name == 'trap' && args.length == 1 && args[0] is IntLitNode) {
          final n = (args[0] as IntLitNode).val;
          if (n < 0 || n > 15) {
            throw CompileError('${tok.loc}: trap number $n is out of range (0-15)');
          }
          return TrapNode(n);
        }
        return CallNode(name, args);
      }
      return VarAccessNode(name);
    }
    if (tok.val == '(') {
      consume('PUNCT', '(');
      final node = parseExpr();
      if (peek().val == ',') {
        throw CompileError(
            '${tok.loc}: Bare tuple expression not permitted in scalar expression context');
      }
      consume('PUNCT', ')');
      return node;
    }
    throw CompileError("${tok.loc}: Unexpected token '${tok.val}'");
  }
}

/// Python `str.strip(chars)`.
String _stripChars(String s, String chars) {
  var start = 0;
  var end = s.length;
  while (start < end && chars.contains(s[start])) {
    start++;
  }
  while (end > start && chars.contains(s[end - 1])) {
    end--;
  }
  return s.substring(start, end);
}
