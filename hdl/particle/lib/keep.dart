// =============================================================================
// File: hdl/particle/lib/keep.dart
// Architecture: Particle 32-bit RISC
// Description: A buffer that Yosys keeps as its own module, so a signal stays
//              one net in synthesis.
// =============================================================================
//
// Yosys's ABC pass is free to fold a signal's logic into every place that
// uses it. For a select that drives many bits (a 55-bit multiplexer, say) it
// may rebuild the select inside each bit: in the ring router that was 460
// LUT4s instead of 66. Passing the select through a ParticleKeep, generated
// as a module marked `(* keep_hierarchy *)`, makes it one net that every bit
// shares. In simulation it is a plain wire.

import 'package:rohd/rohd.dart';

class ParticleKeep extends Module with SystemVerilog {
  Logic get y => output('y');

  ParticleKeep(Logic a, {super.name = 'keep'})
      : super(definitionName: 'ParticleKeep_${a.width}') {
    a = addInput('a', a, width: a.width);
    addOutput('y', width: a.width);
    y <= a;
  }

  @override
  String? definitionVerilog(String definitionType) {
    final w = input('a').width;
    final range = w == 1 ? '' : '[${w - 1}:0] ';
    return '''
(* keep_hierarchy *)
module $definitionType (
  input logic ${range}a,
  output logic ${range}y
);
  assign y = a;
endmodule
''';
  }
}
