// =============================================================================
// File: hdl/rohd/test/memory_bus_test.dart
// Architecture: Particle 32-bit RISC
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/memory_bus.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle Memory Bus & Alignment Tests', () {
    late Logic addr;
    late Logic wData;
    late Logic size;
    late Logic wEn;
    late Logic rEn;
    late Logic rDataRaw;
    late ParticleMemoryBus bus;

    setUp(() async {
      await Simulator.reset();
      addr = Logic(name: 'addr', width: ParticleWidths.word);
      wData = Logic(name: 'wData', width: ParticleWidths.word);
      size = Logic(name: 'size', width: 2);
      wEn = Logic(name: 'wEn');
      rEn = Logic(name: 'rEn');
      rDataRaw = Logic(name: 'rDataRaw', width: ParticleWidths.word);

      bus = ParticleMemoryBus(
        addr: addr,
        wData: wData,
        size: size,
        wEn: wEn,
        rEn: rEn,
        rDataRaw: rDataRaw,
      );
      await bus.build();
    });

    test('32-bit Word access requires 4-byte alignment', () {
      size.put(2);
      wEn.put(1);
      rEn.put(0);
      wData.put(0);
      rDataRaw.put(0);

      addr.put(0x00001000);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0xF));

      addr.put(0x00001001);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(1));

      addr.put(0x00001002);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(1));
    });

    test('16-bit Halfword access generates correct lane enables', () {
      size.put(1);
      wEn.put(1);
      rEn.put(0);
      wData.put(0);
      rDataRaw.put(0);

      addr.put(0x00002000);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0x3));

      addr.put(0x00002002);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0xC));

      addr.put(0x00002003);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(1));
    });

    test('8-bit Byte access steers byte lanes without alignment faults', () {
      size.put(0);
      wEn.put(1);
      rEn.put(0);
      wData.put(0);
      rDataRaw.put(0);

      addr.put(0x00003000);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0x1));

      addr.put(0x00003001);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0x2));

      addr.put(0x00003002);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0x4));

      addr.put(0x00003003);
      Simulator.tick();
      expect(bus.alignFault.value.toInt(), equals(0));
      expect(bus.bEn.value.toInt(), equals(0x8));
    });
  });
}
