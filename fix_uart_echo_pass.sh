#!/usr/bin/env bash
set -e

echo "==> 1. Updating firmware/parcore/riscv/core0_if_uart.asm..."
cat << 'ASM_EOF' > firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
; Parcore RV32IM_Zbb: Core 0 (Instruction Fetch & FTDI Console Gateway)
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if_uart.asm
; ==============================================================================
.include "lib/common.inc"

.org 0x00000100
_reset_vector:
    LOAD16  R10, 0x0500         ; Guest RV32 PC (Base at 0x00000500)
    LD      R0, 0               ; R0 = 0 (Channel 0: FTDI Console UART)
    LD      R1, 1               ; R1 = 1 (Channel 1: Core 1 ID Stage Queue)

; ==============================================================================
; Main Fetch & Console Loop
; ==============================================================================
_if_main_loop:
    ; 1. Service UART RX (Non-Blocking Console Pass-Through on Channel 0)
    FIFO.TRYR R3, R0
    FBRA.Z    R3, ._fetch_instruction

    ; Character received: Echo character back to UART TX (Channel 0)
    FIFO.W    R3, R0
    BBRA      _if_main_loop     ; Immediately loop back to keep console responsive

._fetch_instruction:
    ; 2. Fetch 32-bit RV32 Instruction (Dual 16-bit Port A Reads)
    LD16    R4, (R10++)         ; inst[15:0]
    LD16    R5, (R10++)         ; inst[31:16]
    SHIFTL  R5, 16
    OR      R5, R4              ; Full 32-bit instruction word

    ; If instruction word is 0 (end of guest code / uninitialized), skip pushing
    FBRA.Z  R5, ._loop_back

    ; 3. Push Fetch Packet to ID Core via FIFO Channel 1 [PC, Instruction]
    SUB     R6, R10, 4          ; Base PC of current instruction
    FIFO.W  R6, R1              ; Outbound Word 0: PC (Channel 1)
    FIFO.W  R5, R1              ; Outbound Word 1: Instruction Word (Channel 1)

._loop_back:
    BBRA    _if_main_loop

; ==============================================================================
; Trap Vector 1: Branch Redirect / Flush from Core 2 (EX)
; Base: 0x00000100 + (1 << 6) = 0x00000140
; ==============================================================================
.org 0x00000140
_mbox_branch_redirect:
    FAST_ENTER_TRAP

    ; R14 carries resolved branch target PC staged by Core 2
    LD      R10, R14

    ; Inject 2-word flush packet into Core 1 to cancel speculative ops
    LOAD32  R6, 0xFFFFFFFF
    FIFO.W  R6, R1              ; Flush Token Marker: PC = -1 (Channel 1)
    FIFO.W  R6, R1              ; Placeholder Instruction Word (Channel 1)

    FAST_EXIT_TRAP
ASM_EOF

echo "==> 2. Re-assembling firmware..."
touch firmware/parcore/riscv/core0_if_uart.asm
make firmware

echo "==> 3. Updating test/parcore_top_test.dart with cycle-bounded reception..."
cat << 'DART_TEST_EOF' > hdl/parcore/test/parcore_top_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

/// Transmits an 8-bit byte over [uartRx] (8-N-1, LSB first).
Future<void> sendUartByte(
  Logic uartRx,
  SimpleClockGenerator clk,
  int byte, {
  int baudCycles = 8,
}) async {
  // Start bit (Low)
  uartRx.put(0);
  await clk.waitCycles(baudCycles);

  // 8 Data Bits (LSB first)
  for (int b = 0; b < 8; b++) {
    uartRx.put((byte >> b) & 1);
    await clk.waitCycles(baudCycles);
  }

  // Stop bit (High)
  uartRx.put(1);
  await clk.waitCycles(baudCycles);
}

/// Awaits start bit on [uartTx] and reads deserialized byte.
Future<int> receiveUartByte(
  Logic uartTx,
  SimpleClockGenerator clk, {
  int baudCycles = 8,
  int timeoutCycles = 1500,
}) async {
  int elapsed = 0;

  // Await falling edge (start bit)
  while (uartTx.value.isValid && uartTx.value.toInt() != 0) {
    await clk.waitCycles(1);
    elapsed++;
    if (elapsed > timeoutCycles) {
      throw TimeoutException('Timed out waiting for UART TX start bit after $elapsed cycles');
    }
  }

  if (!uartTx.value.isValid) {
    throw StateError('uartTx signal became invalid (X/Z)');
  }

  // Advance to middle of start bit
  await clk.waitCycles(baudCycles ~/ 2);

  // Read 8 data bits
  int rxByte = 0;
  for (int b = 0; b < 8; b++) {
    await clk.waitCycles(baudCycles);
    rxByte |= (uartTx.value.toInt() << b);
  }

  // Stop bit
  await clk.waitCycles(baudCycles);

  return rxByte;
}

List<int>? _loadBinary(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsBytesSync() : null;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore 4-Stage Multi-Core System Verification", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0 = _loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0,
        core1Binary: c1,
        core2Binary: c2,
        core3Binary: c3,
      );

      await top.build();
    });

    test("ParcoreTop elaborates, builds synthesis graph, and generates SystemVerilog", () {
      final sv = top.generateSynth();
      expect(sv, contains("module ParcoreTop"));
      expect(sv, contains("parcore_fifo_if_to_id"));
      expect(sv, contains("parcore_fifo_id_to_ex"));
      expect(sv, contains("parcore_fifo_ex_to_mem"));
      expect(sv, contains("parcore_fifo_mem_to_wb"));
      expect(sv, contains("parcore_ftdi_uart"));
    });

    test("ParcoreTop holds reset and maintains valid UART line", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);

      expect(top.uartTx.value.isValid, isTrue);
      expect(top.uartTx.value.toInt(), equals(1));

      await Simulator.endSimulation();
    });

    test("Host-to-Core-0 UART Echo: transmits 0x41 on uartRx and verifies echo on uartTx", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Hold reset for 5 cycles
      await clk.waitCycles(5);
      reset.put(0);

      // Allow Core 0 to settle into polling loop
      await clk.waitCycles(20);

      const testByte = 0x41; // ASCII 'A'

      final rxFuture = receiveUartByte(top.uartTx, clk, baudCycles: 8, timeoutCycles: 1500);
      final txFuture = sendUartByte(uartRx, clk, testByte, baudCycles: 8);

      await txFuture;
      final echoedByte = await rxFuture;

      expect(echoedByte, equals(testByte), reason: "Core 0 failed to echo character back to UART TX");

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
DART_TEST_EOF

echo "==> 4. Executing dart test..."
cd hdl/parcore && dart test test/parcore_top_test.dart

