// =============================================================================
// File: hdl/particle/test/bitops_test.dart
// Description: BEXTR, BSET, BINV and BCLR on CoreHarness (the differential
//              ISA test covers every bit operation against psim).
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'core_harness.dart';

List<int> halfwords(List<int> words) =>
    [for (final w in words) ...[w & 0xFF, (w >> 8) & 0xFF]];

void main() {
  tearDown(() async {
    // A failed test may leave its simulation running
    await CoreHarness.stopActive();
  });

  test('BEXTR, BSET, BINV, BCLR execute correctly in core', () async {
    final h = CoreHarness(halfwords([
      0x0115, // LD R1, 5
      0x8011, // BEXTR R1, R1: pos 5, length 0 -> 0
      0x8413, // BSET R1, 3 -> 8
      0x8810, // BINV R1, 0 -> 9
      0x8613, // BCLR R1, 3 -> 1
      0xC000, // BBRA 0
    ]));
    await h.start();
    await h.runToHalt();
    expect(h.snapshot().reg(1), equals(1));
    await h.stop();
  });
}
