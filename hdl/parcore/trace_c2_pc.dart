import 'dart:io';

void main() {
  final file = File('hdl/parcore/test/parcore_rv32_pipeline_test.dart');
  var content = file.readAsStringSync();

  const target = "if (c2Pop.value.isValid && c2Pop.value.toInt() == 1) {";
  const replacement = """if (cycle >= 370 && cycle <= 400) {
          final c2InstVal = core2.input('memPortARData').value.isValid ? core2.input('memPortARData').value.toInt().toRadixString(16).padLeft(4, '0') : 'xxxx';
          print("  [C2 trace cycle \$cycle] PC=0x\${c2Pc.value.toInt().toRadixString(16)} Inst=0x\$c2InstVal Push=\${c2Push.value.toInt()}");
        }
        if (c2Pop.value.isValid && c2Pop.value.toInt() == 1) {""";

  if (content.contains(target)) {
    content = content.replaceFirst(target, replacement);
    file.writeAsStringSync(content);
    print("Added C2 PC trace between cycles 370-400.");
  } else {
    print("Target anchor not found");
  }
}
