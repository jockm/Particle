// =============================================================================
// File: hdl/parcore/test/guest_echo.dart
// Description: Guest RV32 programs that use the UART, for the Parcore tests
//              that check the console end to end (not a test itself).
// =============================================================================

import 'dart:typed_data';

/// Waits for a byte on the guest UART (status at 0x1000_0004, bit 0) and
/// sends it back (data at 0x1000_0000), forever. Runs at 0x500.
const guestEchoProgram = <int>[
  0x10000537, // lui x10, 0x10000     ; x10 = 0x1000_0000, the UART
  0x00452583, // lw x11, 4(x10)       ; 0x504: status
  0x0015f593, // andi x11, x11, 1     ; bit 0: a byte has been received
  0xfe058ce3, // beq x11, x0, -8      ; none: check again
  0x00052603, // lw x12, 0(x10)       ; the byte
  0x00c52023, // sw x12, 0(x10)       ; send it back
  0xfedff06f, // jal x0, -20          ; to 0x504
];

/// Sends "Hi!\n" as four back-to-back stores to the UART data register, so
/// core 3 has to wait for the transmitter between them; then ends (core 0
/// waits at the zero word that follows). Runs at 0x500.
const guestHelloProgram = <int>[
  0x10000537, // lui x10, 0x10000     ; x10 = 0x1000_0000, the UART
  0x04800613, // addi x12, x0, 0x48   ; 'H'
  0x00c52023, // sw x12, 0(x10)       ; send (core 3 waits while busy)
  0x06900613, // addi x12, x0, 0x69   ; 'i'
  0x00c52023, // sw x12, 0(x10)
  0x02100613, // addi x12, x0, 0x21   ; '!'
  0x00c52023, // sw x12, 0(x10)
  0x00a00613, // addi x12, x0, 0x0a   ; '\n'
  0x00c52023, // sw x12, 0(x10)
];

/// A core's kernel (loaded at 0x100) with [guestWords] at 0x500, as one image
/// starting at 0x100. Core 0 and core 3 both hold the guest program.
Uint8List kernelWithGuest(List<int> kernel, List<int> guestWords) {
  const guestOffset = 0x500 - 0x100;
  if (kernel.length > guestOffset) {
    throw StateError('the kernel (${kernel.length} bytes from 0x100) runs '
        'into the guest program at 0x500');
  }
  final image = Uint8List(guestOffset + guestWords.length * 4);
  image.setRange(0, kernel.length, kernel);
  for (var i = 0; i < guestWords.length; i++) {
    final w = guestWords[i];
    for (var b = 0; b < 4; b++) {
      image[guestOffset + i * 4 + b] = (w >> (8 * b)) & 0xFF;
    }
  }
  return image;
}
