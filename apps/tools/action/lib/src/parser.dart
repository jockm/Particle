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

const _primitiveTypes = ['u8', 's8', 'u16', 's16', 'u32', 's32', 'u64', 's64'];

class Parser {
  final List<Token> tokens;
  int pos = 0;
  final Set<String> knownTypes = {};

  Parser(this.tokens);

  /// Action has no pointers: a `*` after a type name is a syntax error.
  void _rejectPointerType(String tName) {
    if (peek().val == '*') {
      final t = peek();
      throw CompileError(
          "${t.loc}: pointer type '${tName.trim()}*' is not supported; Action has no pointers (records and arrays are passed by reference)");
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
      return sName;
    } else if ([..._primitiveTypes, 'string', 'void'].contains(t.val)) {
      return consume().val;
    } else if (t.type == 'IDENT') {
      return consume().val;
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
    while (peek().val != '}' && peek().type != 'EOF') {
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
    return EnumDeclNode(name, members);
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
    if (peek().val == 'import') {
      return parseImport();
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
      consume();
      final tName = consume('IDENT').val;
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
          final fType = parseType();
          if (peek().val == ';') {
            consume('PUNCT', ';');
            if (['u8', 's8', 'u16', 's16', 'u32', 's32', 'void']
                .contains(fType)) {
              throw CompileError(
                  "Cannot anonymously embed primitive scalar type '$fType'");
            }
            fields.add(FieldDecl(fType, false, fType, const [], true));
            continue;
          }
          _rejectPointerType(fType);
          final fName = consume('IDENT').val;
          final fDims = <AstNode>[];
          while (peek().val == '[') {
            consume('PUNCT', '[');
            fDims.add(_parseConstExpr());
            consume('PUNCT', ']');
          }
          if (peek().val == ';') {
            consume('PUNCT', ';');
          }
          fields.add(FieldDecl(fType, false, fName, fDims, false));
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
        tupleRetTypes.add((retElemT, false));
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
    }

    var name = consume('IDENT').val;

    String? boundStruct;
    // Oberon-style type-bound procedure: void Point.move(...)
    if (peek().val == '.') {
      consume('PUNCT', '.');
      final methodName = consume('IDENT').val;
      final boundType = name;
      boundStruct = boundType;
      name = '${boundType}_$methodName';
    }

    if (peek().val == '(') {
      consume('PUNCT', '(');
      final params = <Param>[];
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
          final pType = parseType();
          var pPtr = false;
          _rejectPointerType(pType);
          final pName = consume('IDENT').val;
          var isOpenArr = false;
          if (peek().val == '[') {
            consume('PUNCT', '[');
            consume('PUNCT', ']');
            isOpenArr = true;
            pPtr = true;
          }
          params.add(Param(pType, pPtr, pName, isOpenArr));
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
            isInline: isInline);
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
    if (match('=') != null) {
      initExpr = parseExpr();
    }
    consume('PUNCT', ';');
    if (boundAddrExpr != null) {
      isVolatile = true;
    }
    final node = VarDeclNode(tName, isPtr, name, initExpr, isConst, isVolatile);
    node.dimExprs = dimExprs;
    node.boundAddrExpr = boundAddrExpr;
    return node;
  }

  BlockNode parseBlock() {
    consume('PUNCT', '{');
    final stmts = <AstNode>[];
    while (peek().val != '}' && peek().type != 'EOF') {
      stmts.add(parseStatement());
    }
    consume('PUNCT', '}');
    return BlockNode(stmts);
  }

  AstNode parseStatement() {
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
              targets.add(TupleTarget(
                  name: vN, typeName: tN, isPtr: false, isWildcard: false));
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

  AstNode parseAssignment() {
    final node = parseLogicalOr();
    final tok = peek();
    if (tok.val == '=') {
      consume();
      final rhs = parseAssignment();
      return BinaryOpNode('=', node, rhs);
    } else if (tok.type == 'COMPOUND_ASSIGN' ||
        ['+=', '-=', '*=', '/=', '&=', '|=', '^=', '<<=', '>>=']
            .contains(tok.val)) {
      final op = consume().val;
      final rhs = parseAssignment();
      return CompoundAssignNode(op, node, rhs);
    }
    return node;
  }

  AstNode parseLogicalOr() {
    var node = parseLogicalAnd();
    while (peek().val == '||') {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseLogicalAnd());
    }
    return node;
  }

  AstNode parseLogicalAnd() {
    var node = parseRelational();
    while (peek().val == '&&') {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseRelational());
    }
    return node;
  }

  AstNode parseRelational() {
    var node = parseBitwise();
    while (['==', '!=', '<', '<=', '>', '>='].contains(peek().val)) {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseBitwise());
    }
    return node;
  }

  AstNode parseBitwise() {
    var node = parseShift();
    while (['&', '|', '^'].contains(peek().val)) {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseShift());
    }
    return node;
  }

  AstNode parseShift() {
    var node = parseAdditive();
    while (['<<', '>>'].contains(peek().val)) {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseAdditive());
    }
    return node;
  }

  AstNode parseAdditive() {
    var node = parseMultiplicative();
    while (['+', '-'].contains(peek().val)) {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseMultiplicative());
    }
    return node;
  }

  AstNode parseMultiplicative() {
    var node = parseUnary();
    while (['*', '/', '%'].contains(peek().val)) {
      final op = consume().val;
      node = BinaryOpNode(op, node, parseUnary());
    }
    return node;
  }

  AstNode parseUnary() {
    final t = peek();
    if (t.val == '*' || t.val == '&') {
      final what = t.val == '*' ? 'pointer dereference' : 'address-of';
      throw CompileError(
          "${t.loc}: $what '${t.val}' is not supported; Action has no pointers (records and arrays are passed by reference)");
    }
    if (['-', '~', '!'].contains(t.val)) {
      final op = consume().val;
      return UnaryOpNode(op, parseUnary());
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
      if (peek().val == '.') {
        consume();
        final member = consume('IDENT').val;
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

          // Intercept dynamic allocation pseudo-constructors
          // Receiver node is a VarAccessNode naming a type, or identifier 'string'
          final rcvName = node is VarAccessNode ? node.name : null;

          if (member == 'create') {
            if (rcvName == 'string') {
              if (args.length != 1) {
                throw CompileError(
                    'string.create(capacity) requires exactly 1 argument (capacity)');
              }
              node = HeapStringAllocNode(args[0]);
            } else if (rcvName != null) {
              node = HeapAllocNode(rcvName, args);
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
      } else {
        break;
      }
    }
    return node;
  }

  AstNode parsePrimary() {
    final tok = peek();
    if (tok.val == 'sizeof') {
      consume('KEYWORD', 'sizeof');
      consume('PUNCT', '(');
      final argTok = peek();
      if ([..._primitiveTypes, 'void', 'string'].contains(argTok.val)) {
        final tArg = consume().val;
        _rejectPointerType(tArg);
        consume('PUNCT', ')');
        final sz = ['u8', 's8', 'string'].contains(tArg)
            ? 1
            : (['u16', 's16'].contains(tArg)
                ? 2
                : (['u64', 's64'].contains(tArg) ? 8 : 4));
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
        return SizeofNode(tArg);
      } else {
        final expr = parseExpr();
        consume('PUNCT', ')');
        return SizeofNode(expr);
      }
    }
    if (tok.type == 'INT' || tok.type == 'HEX') {
      consume();
      return IntLitNode(parseIntAuto(tok.val));
    }
    if (tok.type == 'CHAR') {
      consume();
      final raw = decodeEscapes(tok.val.substring(1, tok.val.length - 1));
      final val = raw.isNotEmpty ? raw.codeUnitAt(0) : 0;
      return IntLitNode(val);
    }
    if (tok.type == 'STRING') {
      consume();
      final raw = decodeEscapes(tok.val.substring(1, tok.val.length - 1));
      return StringLitNode(raw);
    }
    if (tok.type == 'IDENT' ||
        ([..._primitiveTypes.take(6), 'string'].contains(tok.val) &&
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
          return TrapNode((args[0] as IntLitNode).val);
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
