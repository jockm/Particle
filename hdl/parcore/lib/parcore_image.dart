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

/// The usual image: each stage core's firmware at 0x100, and the guest
/// program (if any) at 0x500 in core 0 (which fetches it) and core 3 (which
/// loads and stores it).
Uint8List buildParcoreStageImage({
  required List<int> core0,
  required List<int> core1,
  required List<int> core2,
  required List<int> core3,
  List<int>? guest,
}) {
  for (final (name, kernel) in [('core 0', core0), ('core 3', core3)]) {
    if (guest != null && 0x100 + kernel.length > 0x500) {
      throw ArgumentError('$name\'s firmware (${kernel.length} bytes from '
          '0x100) runs into the guest program at 0x500');
    }
  }
  return buildParcoreImage([
    ParcoreImageSection(1 << 0, 0x100, core0),
    ParcoreImageSection(1 << 1, 0x100, core1),
    ParcoreImageSection(1 << 2, 0x100, core2),
    ParcoreImageSection(1 << 3, 0x100, core3),
    if (guest != null) ParcoreImageSection((1 << 0) | (1 << 3), 0x500, guest),
  ]);
}
