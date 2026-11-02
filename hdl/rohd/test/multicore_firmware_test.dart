import "dart:io";
import "dart:typed_data";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../lib/constants.dart";
import "../lib/cpu_config.dart";
import "../lib/particle_multi_core.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Core 1 Firmware Dispatch Verification", () {
    late Logic clk;
    late Logic reset;
    late Logic c0MemARData;
    late Logic c0MemBRData;
    late Logic c1MemARData;
    late Logic c1MemBRData;
    late ParticleMultiCore multiCore;

    late Uint8List c1FirmwareBytes;
    late Uint8List c0StimulusBytes;

    int currentTimestamp = 0;

    void stepClock() {
      // Half-cycle before posedge: feed memory combinatorially based on current address
      Simulator.registerAction(currentTimestamp + 2, () {
        if (multiCore.c0MemPortAAddr.value.isValid) {
          final pc0 = multiCore.c0MemPortAAddr.value.toInt();
          final off0 = pc0 - 0x00000100;
          if (off0 >= 0 && off0 + 1 < c0StimulusBytes.length) {
            // Particle binary: [off] = operands (low byte), [off+1] = opcode (high byte)
            c0MemARData
                .put((c0StimulusBytes[off0 + 1] << 8) | c0StimulusBytes[off0]);
          } else {
            c0MemARData.put(0);
          }
        }

        if (multiCore.c1MemPortAAddr.value.isValid) {
          final pc1 = multiCore.c1MemPortAAddr.value.toInt();
          final off1 = pc1 - 0x00000100;
          if (off1 >= 0 && off1 + 1 < c1FirmwareBytes.length) {
            // Particle binary: [off] = operands (low byte), [off+1] = opcode (high byte)
            c1MemARData
                .put((c1FirmwareBytes[off1 + 1] << 8) | c1FirmwareBytes[off1]);
          } else {
            c1MemARData.put(0);
          }
        }
      });

      // Rising clock edge
      Simulator.registerAction(currentTimestamp + 5, () => clk.put(1));

      // Falling clock edge
      Simulator.registerAction(currentTimestamp + 10, () => clk.put(0));

      currentTimestamp += 10;
    }

    setUp(() async {
      clk = Logic(name: 'clk');
      reset = Logic(name: 'reset');
      c0MemARData = Logic(name: 'c0MemARData', width: ParticleWidths.halfWord);
      c0MemBRData = Logic(name: 'c0MemBRData', width: ParticleWidths.word);
      c1MemARData = Logic(name: 'c1MemARData', width: ParticleWidths.halfWord);
      c1MemBRData = Logic(name: 'c1MemBRData', width: ParticleWidths.word);

      final c1Bin = File("../../firmware/parcore/riscv/core1_dispatch.bin");
      expect(c1Bin.existsSync(), isTrue,
          reason: "core1_dispatch.bin must exist");
      c1FirmwareBytes = await c1Bin.readAsBytes();

      final c0Bin = File("build/c0_stimulus.bin");
      expect(c0Bin.existsSync(), isTrue, reason: "c0_stimulus.bin must exist");
      c0StimulusBytes = await c0Bin.readAsBytes();

      multiCore = ParticleMultiCore(
        clk: clk,
        reset: reset,
        c0MemPortARData: c0MemARData,
        c0MemPortBRData: c0MemBRData,
        c1MemPortARData: c1MemARData,
        c1MemPortBRData: c1MemBRData,
        configCore0: const CpuConfig(trapTableBase: 0x00000100),
        configCore1: const CpuConfig(trapTableBase: 0x00000100),
      );

      await multiCore.build();

      currentTimestamp = 0;
      clk.put(0);
      reset.put(1);
      c0MemARData.put(0);
      c0MemBRData.put(0);
      c1MemARData.put(0);
      c1MemBRData.put(0);

      // Reset for 4 clock cycles
      for (int i = 0; i < 4; i++) {
        stepClock();
      }

      // Deassert reset
      Simulator.registerAction(currentTimestamp + 2, () => reset.put(0));
    });

    test("Core 1 boots and stalls on FIFO.R waiting for token", () async {
      // Step 8 cycles post-reset: enough to execute 0x0100 and settle into FIFO.R stall at 0x0102
      // without giving Core 0 enough cycles to emit a FIFO.W push.
      for (int i = 0; i < 8; i++) {
        stepClock();
      }

      await Simulator.run();

      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000102));
    });

    test(
        "Branch TAKEN: Core 0 pushes tokens -> Core 1 evaluates BEQ and strobes MBOX",
        () async {
      bool mboxStrobeSeen = false;
      int mboxVector = 0;

      // Register listener before stepping the clock
      multiCore.c0MboxStrobeIn.changed.listen((event) {
        if (multiCore.c0MboxStrobeIn.value.isValid &&
            multiCore.c0MboxStrobeIn.value.toInt() == 1) {
          mboxStrobeSeen = true;
          if (multiCore.c0MboxVectorIn.value.isValid) {
            mboxVector = multiCore.c0MboxVectorIn.value.toInt();
          }
        }
      });

      for (int i = 0; i < 100; i++) {
        stepClock();
      }

      await Simulator.run();

      expect(mboxStrobeSeen, isTrue,
          reason: "Taken branch must strobe Core 0 MBOX");
      expect(mboxVector, equals(1), reason: "Branch redirect vector is 1");
    });
  });
}
