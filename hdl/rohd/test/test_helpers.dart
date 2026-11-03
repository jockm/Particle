// =============================================================================
// File: hdl/rohd/test/test_helpers.dart
// =============================================================================

import 'package:rohd/rohd.dart';

extension ClockWaitCycles on SimpleClockGenerator {
  /// Safely steps [cycles] clock cycles by listening to posedge events.
  Future<void> waitCycles(int cycles) async {
    for (int i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }
}
