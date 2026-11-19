// =============================================================================
// File: hdl/particle/test/branch_test.dart
// Architecture: Particle 32-bit RISC Core
// Description: Reset PC and a JTBL computed jump, on CoreHarness (the
//              differential ISA test covers every branch form against psim).
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'core_harness.dart';

/// Little-endian bytes for 16-bit instruction words.
List<int> halfwords(List<int> words) =>
    [for (final w in words) ...[w & 0xFF, (w >> 8) & 0xFF]];

void main() {
  tearDown(() async {
    // A failed test may leave its simulation running
    await CoreHarness.stopActive();
  });

  test('Core initializes PC to trapTableBase on reset', () async {
    final h = CoreHarness(halfwords([0xC000])); // BBRA 0 (jump to itself)
    await h.start();
    expect(h.pc, equals(0x100));
    expect(h.core.memPortAAddr.value.toInt(), equals(0x100));
    await h.stop();
  });

  test('JTBL Rr computed table jump updates PC correctly', () async {
    final h = CoreHarness(halfwords([
      0x0113, // 0x100: LD R1, 3
      0x8110, // 0x102: JTBL R1 -> 0x102 + 2 + 3 * 2 = 0x10A
      0x0125, // 0x104: LD R2, 5 (skipped)
      0x0125, // 0x106
      0x0125, // 0x108
      0x0137, // 0x10A: LD R3, 7
      0xC000, // 0x10C: BBRA 0
    ]));
    await h.start();
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.pc, equals(0x10C));
    expect(st.reg(2), equals(0));
    expect(st.reg(3), equals(7));
    await h.stop();
  });
}
