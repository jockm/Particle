// =============================================================================
// File: hdl/parcore/lib/spi_flash_rom.dart
// Architecture: Parcore Conductor boot image source
// Description: An on-chip ROM that answers like an SPI flash chip.
// =============================================================================
//
// The conductor reads its boot image over SPI. Until the ULX3S's flash is
// used, this ROM, built into the bitstream, stands in for the chip: it
// answers the standard read command (0x03, then a 24-bit address, then
// bytes for as long as CS_N stays low) in SPI mode 0, so the conductor's code
// is the same as for the real flash. Moving to the flash only changes which
// pins the SPI controller's lines go to.
//
// The ROM holds [SpiFlashRom.romBytes] bytes, read at flash addresses
// [SpiFlashRom.baseAddr] up to baseAddr + romBytes; other addresses read as
// 0xFF, like erased flash. Any other command is ignored until CS_N goes high.
//
// It runs in the clock domain of the SPI controller that drives it, sampling
// CS_N, SCK and MOSI each clock, so SCK must stay high and low for at least
// two clocks each (the controller's SPI_DIV at least 1). Each byte is read
// from block RAM ahead of time, and each bit goes out on MISO at the falling
// SCK edge before the rising edge where the controller samples it.

import 'package:rohd/rohd.dart';

class SpiFlashRom extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');
  Logic get csN => input('spi_cs_n');
  Logic get sck => input('spi_sck');
  Logic get mosi => input('spi_mosi');
  Logic get miso => output('spi_miso');

  /// Flash address of the ROM's first byte.
  final int baseAddr;

  /// The ROM's size in bytes: a power of two, at least the image's length.
  final int romBytes;

  /// The ROM's contents: the image, with the rest 0xFF.
  final List<int> contents;

  SpiFlashRom({
    required Logic clk,
    required Logic reset,
    required Logic csN,
    required Logic sck,
    required Logic mosi,
    required List<int> image,
    required this.baseAddr,
    int? romBytes,
    String? initFile,
    super.name = 'spi_flash_rom',
  })  : romBytes = romBytes ?? _roundUp(image.length),
        contents = [
          ...image,
          ...List<int>.filled(
              (romBytes ?? _roundUp(image.length)) - image.length, 0xFF),
        ] {
    if (this.romBytes != 1 << (this.romBytes - 1).bitLength ||
        image.length > this.romBytes) {
      throw ArgumentError('romBytes must be a power of two of at least the '
          'image size (${image.length})');
    }
    if (baseAddr % this.romBytes != 0 || baseAddr + this.romBytes > 1 << 24) {
      throw ArgumentError('baseAddr must be a multiple of romBytes, inside the '
          '24-bit flash address space');
    }
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('spi_cs_n', csN);
    addInput('spi_sck', sck);
    addInput('spi_mosi', mosi);
    addOutput('spi_miso');
    _build(initFile);
  }

  static int _roundUp(int n) {
    var size = 256;
    while (size < n) {
      size <<= 1;
    }
    return size;
  }

  /// The $readmemh file for [contents]: one byte in hex per line.
  static String hexFile(List<int> contents) =>
      '${contents.map((b) => b.toRadixString(16).padLeft(2, '0')).join('\n')}\n';

  void _build(String? initFile) {
    final idxBits = (romBytes - 1).bitLength;

    // SCK as it was at the last clock, to find its edges
    final sckPrev = Logic(name: 'sck_prev');
    final sckRise = sck & ~sckPrev;
    final sckFall = ~sck & sckPrev;

    // States: 0 command, 1-3 address bytes, 4 reading the first byte,
    // 5 sending bytes, 6 ignoring an unknown command until CS_N goes high
    final state = Logic(name: 'state', width: 3);
    final bitCount = Logic(name: 'bit_count', width: 3);
    final shiftIn = Logic(name: 'shift_in', width: 8);
    final address = Logic(name: 'address', width: 24); // the next byte to send
    final shiftOut = Logic(name: 'shift_out', width: 8);
    final ramReady = Logic(name: 'ram_ready');
    final fallSeen = Logic(name: 'fall_seen');

    // The byte at [address], read one clock ahead; 0xFF outside the ROM
    final rom = SpiFlashRomBlock(
      clk: clk,
      addr: address.slice(idxBits - 1, 0),
      contents: contents,
      initFile: initFile,
    );
    final inRange = Logic(name: 'in_range');
    Sequential(clk, [
      sckPrev < sck,
      inRange <
          address
              .slice(23, idxBits)
              .eq(Const(baseAddr >> idxBits, width: 24 - idxBits)),
    ]);
    final nextByte = mux(inRange, rom.data, Const(0xFF, width: 8));

    final shifted = [shiftIn.slice(6, 0), mosi].swizzle();
    final byteDone = bitCount.eq(Const(7, width: 3));

    Sequential(clk, reset: reset | csN, resetValues: {
      state: Const(0, width: 3),
      bitCount: Const(0, width: 3),
      shiftIn: Const(0, width: 8),
      address: Const(0, width: 24),
      shiftOut: Const(0xFF, width: 8),
      ramReady: Const(0),
      fallSeen: Const(0),
    }, [
      // Command and address: shift MOSI in on rising edges
      If(state.lt(4) & sckRise, then: [
        shiftIn < shifted,
        bitCount < bitCount + 1,
        If(byteDone, then: [
          Case(state, [
            CaseItem(Const(0, width: 3), [
              state <
                  mux(shifted.eq(Const(0x03, width: 8)), Const(1, width: 3),
                      Const(6, width: 3)),
            ]),
            CaseItem(Const(1, width: 3), [
              address < [shifted, address.slice(15, 0)].swizzle(),
              state < Const(2, width: 3),
            ]),
            CaseItem(Const(2, width: 3), [
              address <
                  [address.slice(23, 16), shifted, address.slice(7, 0)]
                      .swizzle(),
              state < Const(3, width: 3),
            ]),
            CaseItem(Const(3, width: 3), [
              address < [address.slice(23, 8), shifted].swizzle(),
              state < Const(4, width: 3),
              ramReady < Const(0),
              fallSeen < Const(0),
            ]),
          ]),
        ]),
      ]),
      // The address is complete. The first byte goes out once the RAM has
      // answered (one clock for the address to reach it, one for the byte to
      // come back) and the falling edge that ends the address's last bit has
      // passed (with a slow SCK, that comes after the RAM)
      If(state.eq(4), then: [
        ramReady < Const(1),
        If(sckFall, then: [fallSeen < Const(1)]),
        If(ramReady & (fallSeen | sckFall), then: [
          shiftOut < nextByte,
          address < address + 1,
          bitCount < Const(0, width: 3),
          state < Const(5, width: 3),
        ]),
      ]),
      // Sending: the controller samples MISO on a rising edge; the next bit
      // goes out on the falling edge after it, and after a byte's eighth bit,
      // the next byte (already read at [address])
      If(state.eq(5) & sckRise, then: [
        bitCount < bitCount + 1,
      ]),
      If(state.eq(5) & sckFall, then: [
        If(bitCount.eq(0), then: [
          shiftOut < nextByte,
          address < address + 1,
        ], orElse: [
          shiftOut < [shiftOut.slice(6, 0), Const(1)].swizzle(),
        ]),
      ]),
    ]);

    miso <= shiftOut[7] & state.eq(5);
  }
}

/// The ROM's memory: [contents] in block RAM, read synchronously (the byte at
/// the address from the last rising clock edge). Its own module so that its
/// SystemVerilog is a plain memory with initial contents, which Yosys maps to
/// block RAM; simulation uses a Dart model of the same behaviour.
class SpiFlashRomBlock extends Module with SystemVerilog {
  Logic get clk => input('clk');
  Logic get addr => input('addr');
  Logic get data => output('data');

  final List<int> contents;

  /// $readmemh file for the generated SystemVerilog; without one the bytes
  /// are written out in it.
  final String? initFile;

  SpiFlashRomBlock({
    required Logic clk,
    required Logic addr,
    required this.contents,
    this.initFile,
    super.name = 'spi_flash_rom_block',
  }) {
    addInput('clk', clk);
    addInput('addr', addr, width: addr.width);
    addOutput('data', width: 8);

    // The address from the last rising edge (captured by a Sequential, which
    // sees values from before the edge; see ParticleBlockRamTdp)
    final capAddr = Logic(name: 'cap_addr', width: addr.width);
    Sequential(clk, [capAddr < addr]);
    data.put(0xFF);
    clk.posedge.listen((_) {
      final a = capAddr.value;
      data.put(a.isValid ? contents[a.toInt()] : 0xFF);
    });
  }

  @override
  String instantiationVerilog(
      String instanceType, String instanceName, Map<String, String> ports) {
    final p = instanceName;
    final aW = addr.width;
    final n = contents.length;
    // Every byte is written out (a single initial block, so there's no
    // question of order between blocks)
    final init = initFile != null
        ? 'initial \$readmemh("$initFile", ${p}_mem);'
        : 'initial begin\n${[
            for (var i = 0; i < n; i++)
              '  ${p}_mem[$i] = 8\'h${contents[i].toRadixString(16).padLeft(2, '0')};'
          ].join('\n')}\nend';
    return '''
// ---- $p: SpiFlashRomBlock, $n bytes, synchronous read ----
logic [7:0] ${p}_mem [0:${n - 1}];
$init
wire ${p}_clk = ${ports['clk']};
wire [${aW - 1}:0] ${p}_addr = ${ports['addr']};
logic [7:0] ${p}_q;
always_ff @(posedge ${p}_clk) ${p}_q <= ${p}_mem[${p}_addr];
assign ${ports['data']} = ${p}_q;
// ---- end $p ----''';
  }
}
