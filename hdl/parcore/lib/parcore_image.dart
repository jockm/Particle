// =============================================================================
// File: hdl/parcore/lib/parcore_image.dart
// Architecture: Parcore Conductor boot image
// Description: Builds the firmware image the conductor loads (format 2).
// =============================================================================
//
// Format (all words little-endian; see conductor.asm):
//   Header, 16 bytes:
//     +0  Magic 0x50415243 ("PARC")
//     +4  Number of sections, 1..8
//     +8  CRC-32 of the whole image, with these four bytes taken as zero:
//         the standard CRC-32 (zlib's), over the image's bytes in order
//     +12 Format version: 2
//   Section n, 12 bytes at 16 + 12*n:
//     +0  Cores: bit i set writes the payload into core i's TCM (bits 0..5)
//     +4  Offset in those TCMs (a multiple of 4)
//     +8  Payload length in bytes (a multiple of 4)
//   Then the payloads, in section order.

import 'dart:typed_data';

/// Where the conductor reads the image: 4 MiB into the SPI flash, past any
/// ECP5-85F bitstream (the ULX3S 3.1.7 has 16 MiB).
const parcoreImageFlashAddr = 0x00400000;

const parcoreImageMagic = 0x50415243;
const parcoreImageVersion = 2;
const parcoreImageMaxSections = 8;

/// One section: [payload] written at [offset] into each core in [coreMask].
class ParcoreImageSection {
  final int coreMask;
  final int offset;
  final List<int> payload;

  const ParcoreImageSection(this.coreMask, this.offset, this.payload);
}

/// The standard CRC-32 (reflected polynomial 0xEDB88320, as zlib).
int parcoreCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// The image for [sections]. Payloads are padded with zeros to a multiple of
/// 4 bytes.
Uint8List buildParcoreImage(List<ParcoreImageSection> sections) {
  if (sections.isEmpty || sections.length > parcoreImageMaxSections) {
    throw ArgumentError(
        'an image has 1 to $parcoreImageMaxSections sections, not ${sections.length}');
  }
  final payloads = <List<int>>[];
  for (final s in sections) {
    if (s.coreMask <= 0 || s.coreMask > 0x3F) {
      throw ArgumentError('core mask 0x${s.coreMask.toRadixString(16)}: '
          'it must name cores 0 to 5');
    }
    if (s.offset % 4 != 0) {
      throw ArgumentError('offset 0x${s.offset.toRadixString(16)} is not a '
          'multiple of 4');
    }
    payloads.add([
      ...s.payload,
      ...List<int>.filled((4 - s.payload.length % 4) % 4, 0),
    ]);
  }
  final tableEnd = 16 + 12 * sections.length;
  final total = tableEnd + payloads.fold<int>(0, (n, p) => n + p.length);
  final image = Uint8List(total);
  final bd = ByteData.sublistView(image);
  bd.setUint32(0, parcoreImageMagic, Endian.little);
  bd.setUint32(4, sections.length, Endian.little);
  bd.setUint32(12, parcoreImageVersion, Endian.little);
  var at = tableEnd;
  for (var i = 0; i < sections.length; i++) {
    bd.setUint32(16 + 12 * i, sections[i].coreMask, Endian.little);
    bd.setUint32(20 + 12 * i, sections[i].offset, Endian.little);
    bd.setUint32(24 + 12 * i, payloads[i].length, Endian.little);
    image.setRange(at, at + payloads[i].length, payloads[i]);
    at += payloads[i].length;
  }
  // The CRC field is zero while the CRC is computed
  bd.setUint32(8, parcoreCrc32(image), Endian.little);
  return image;
}

/// The guest area in cores 0 and 3: 0x500 up to 0x2000.
const parcoreGuestStart = 0x500;
const parcoreGuestEnd = 0x2000;

/// The sections for a firmware binary assembled from 0x100 into the cores in
/// [coreMask]. Core 0's firmware has code on both sides of the guest area:
/// below 0x500 and from 0x2000. Its bytes in the guest area must be zero
/// (the assembler fills the gap with zeros); they become two sections, so
/// the gap isn't in the image and the guest isn't overwritten.
List<ParcoreImageSection> parcoreFirmwareSections(
    int coreMask, List<int> binary, String name) {
  const guestFrom = parcoreGuestStart - 0x100;
  const guestTo = parcoreGuestEnd - 0x100;
  if (binary.length <= guestFrom) {
    return [ParcoreImageSection(coreMask, 0x100, binary)];
  }
  for (var i = guestFrom; i < guestTo && i < binary.length; i++) {
    if (binary[i] != 0) {
      throw ArgumentError('$name\'s firmware has code at '
          '0x${(0x100 + i).toRadixString(16)}, in the guest area '
          '(0x500-0x1FFF)');
    }
  }
  return [
    ParcoreImageSection(coreMask, 0x100, binary.sublist(0, guestFrom)),
    if (binary.length > guestTo)
      ParcoreImageSection(coreMask, parcoreGuestEnd, binary.sublist(guestTo)),
  ];
}

/// The usual image: each stage core's firmware from 0x100, and the guest
/// program (if any) at 0x500 in core 0 (which fetches it) and core 3 (which
/// loads and stores it). Core 0's firmware may continue from 0x2000.
Uint8List buildParcoreStageImage({
  required List<int> core0,
  required List<int> core1,
  required List<int> core2,
  required List<int> core3,
  List<int>? guest,
}) {
  if (guest != null && 0x100 + core3.length > parcoreGuestStart) {
    throw ArgumentError('core 3\'s firmware (${core3.length} bytes from '
        '0x100) runs into the guest program at 0x500');
  }
  return buildParcoreImage([
    ...parcoreFirmwareSections(1 << 0, core0, 'core 0'),
    ParcoreImageSection(1 << 1, 0x100, core1),
    ParcoreImageSection(1 << 2, 0x100, core2),
    ParcoreImageSection(1 << 3, 0x100, core3),
    if (guest != null)
      ParcoreImageSection((1 << 0) | (1 << 3), parcoreGuestStart, guest),
  ]);
}
