// =============================================================================
// File: hdl/particle/test/tas_test.dart
// Description: TAS (Rr), Rl swaps a register with memory, on CoreHarness.
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

  test('TAS (Rr), Rl performs atomic memory-register swap correctly', () async {
    final h = CoreHarness(halfwords([
      0x0114, // 0x100: LD R1, 4      (address 0x200 after the shift)
      0x6917, // 0x102: SHIFTL R1, 7  -> 0x200
      0x0127, // 0x104: LD R2, 7
      0x8B12, // 0x106: TAS (R1), R2
      0xC000, // 0x108: BBRA 0
    ]));
    // The old memory value
    for (var i = 0; i < 4; i++) {
      h.ram.pokeByte(0x200 + i, (0xAA55AA55 >> (8 * i)) & 0xFF);
    }
    await h.start();
    await h.runToHalt();
    expect(h.snapshot().reg(2), equals(0xAA55AA55), reason: 'old value');
    expect(h.ram.peekWord(0x200), equals(7), reason: 'new value');
    await h.stop();
  });
}
