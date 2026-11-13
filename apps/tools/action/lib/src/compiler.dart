// ------------------------------------------------------------------------------
// The Action compiler: one checker, two code generators
// ------------------------------------------------------------------------------
//
// Port of the CodeGen class of act16c.py. [Checker] works out what a program
// means and finds every error in it, the same way for every target. Two code
// generators extend it and run only on a program that has passed:
//
//   [CodeGen]  Particle assembly, through a [Backend] (particle/backend.dart)
//   [LlvmGen]  LLVM IR for a 64-bit host (action_llvm), written directly
//
// Both describe their machine with a [Target] (target.dart). The library is
// one Dart library split over `part` files, because the generators use the
// checker's private members; the folders keep the three apart:
//
//   checker/    target-independent: types, layout, scopes, rules, constants,
//               ownership and flow analysis, coroutines, initializers
//     checker.dart       Checker: program state, types, layout, program checks
//     check_walk.dart    the walk over every function
//     scopes.dart        function scope and block-scoped local constants
//     types.dart         expression typing, sizes, constant evaluation
//     expr_rules.dart    expression rules shared by checker and generators
//     assign_rules.dart  what may be assigned to what
//     constants.dart     exact constants (Go rules) and folding
//     references.dart    record references versus records stored in place
//     ownership.dart     reference flow analysis
//     coroutines.dart    task functions and their operations
//     flow.dart          the flow analysis framework
//     initializers.dart  brace initializers, constant tables, T.create
//     readonly.dart      which parameters a function writes through
//     floats.dart        f32 and f64
//   particle/   CodeGen: Particle assembly
//     codegen.dart       program layout and functions
//     statements.dart    statements and conditional branches
//     expressions.dart   expressions, addressing, calls, loads and stores
//     const_emit.dart    constants and bool values
//     ref_traps.dart     run-time reference checks
//     backend.dart, particle.dart   the Backend (separate libraries)
//   llvm/       LlvmGen: LLVM IR
//     llvm_gen.dart      LlvmTarget, program layout
//     llvm_func.dart     functions
//     llvm_stmt.dart     statements
//     llvm_expr.dart     expressions
//     llvm_debug.dart    DWARF debug information

import 'dart:typed_data';

import 'ast.dart';
import 'errors.dart';
import 'particle/backend.dart';
import 'particle/particle.dart';
import 'scope_resolve.dart';
import 'target.dart';

part 'checker/checker.dart';
part 'checker/check_walk.dart';
part 'checker/scopes.dart';
part 'checker/types.dart';
part 'checker/expr_rules.dart';
part 'checker/assign_rules.dart';
part 'checker/constants.dart';
part 'checker/references.dart';
part 'checker/ownership.dart';
part 'checker/coroutines.dart';
part 'checker/flow.dart';
part 'checker/initializers.dart';
part 'checker/readonly.dart';
part 'checker/floats.dart';
part 'particle/codegen.dart';
part 'particle/statements.dart';
part 'particle/expressions.dart';
part 'particle/const_emit.dart';
part 'particle/ref_traps.dart';
part 'llvm/llvm_gen.dart';
part 'llvm/llvm_func.dart';
part 'llvm/llvm_stmt.dart';
part 'llvm/llvm_expr.dart';
part 'llvm/llvm_debug.dart';
