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
// With writable: true it is a model of a writable flash for tests (448,
// 452): it also answers write enable (0x06) and disable (0x04), read status
// (0x05: bit 0 WIP, busy; bit 1 WEL, write enabled), page program (0x02, an
// address, then bytes, which clear bits as a flash does and wrap within the
// 256-byte page) and sector erase (0x20, the 4 KiB sector at an address).
// Programming and erasing need WEL, which they clear; each starts when CS_N
// goes high and keeps WIP set for busyCycles clocks (an erase at least 4096,
// a byte a clock), during which only read status is answered. Writes outside
// the ROM's range change nothing. The ULX3S's real flash answers the same
// commands.
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

  /// The ROM's contents: the image, with the rest 0xFF. In writable mode
  /// the Dart simulation keeps its writes here too.
  final List<int> contents;

  /// A writable flash model (for tests) rather than a ROM.
  final bool writable;

  /// Writable: how long WIP stays set after a page program, and at least
  /// after a sector erase.
  final int busyCycles;

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
    this.writable = false,
    this.busyCycles = 1000,
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
    if (writable) {
      _buildWritable(initFile);
    } else {
      _build(initFile);
    }
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

  void _buildWritable(String? initFile) {
    final idxBits = (romBytes - 1).bitLength;
    Const c(int v, int w) => Const(v, width: w);

    final sckPrev = Logic(name: 'sck_prev');
    final csPrev = Logic(name: 'cs_prev');
    final sckRise = sck & ~sckPrev;
    final sckFall = ~sck & sckPrev;
    final csRise = csN & ~csPrev; // a transaction has just ended

    // A transaction's states: 0 command, 1-3 address bytes, 4 reading the
    // first byte, 5 sending bytes, 6 ignoring the rest, 7 a page program's
    // data, 8 sending the status, 9 an erase's address received
    final state = Logic(name: 'state', width: 4);
    final cmd = Logic(name: 'cmd', width: 8);
    final bitCount = Logic(name: 'bit_count', width: 3);
    final shiftIn = Logic(name: 'shift_in', width: 8);
    final address = Logic(name: 'address', width: 24);
    final shiftOut = Logic(name: 'shift_out', width: 8);
    final ramReady = Logic(name: 'ram_ready');
    final fallSeen = Logic(name: 'fall_seen');

    // Kept from one transaction to the next
    final wel = Logic(name: 'wel');
    final busy = Logic(name: 'busy', width: 32);
    final erasing = Logic(name: 'erasing');
    final eraseAddr = Logic(name: 'erase_addr', width: 24);
    final eraseLeft = Logic(name: 'erase_left', width: 13);
    final wip = busy.neq(c(0, 32)) | erasing;
    final status = [c(0, 6), wel, wip].swizzle();

    Logic inRangeOf(Logic a) =>
        a.slice(23, idxBits).eq(c(baseAddr >> idxBits, 24 - idxBits));
    final shifted = [shiftIn.slice(6, 0), mosi].swizzle();
    final byteDone = bitCount.eq(c(7, 3));

    // Writes: a programmed byte as it arrives (its bits can only clear, so
    // it is ANDed with the byte there), or an erase's next byte
    final oldByte = Logic(name: 'old_byte', width: 8);
    final progWrite =
        state.eq(c(7, 4)) & sckRise & byteDone & inRangeOf(address);
    final eraseWrite = erasing & inRangeOf(eraseAddr);
    final rom = SpiFlashRomBlock(
      clk: clk,
      addr: address.slice(idxBits - 1, 0),
      contents: contents,
      initFile: initFile,
      wEn: progWrite | eraseWrite,
      wAddr: mux(erasing, eraseAddr, address).slice(idxBits - 1, 0),
      wData: mux(erasing, c(0xFF, 8), shifted & oldByte),
    );
    oldByte <= rom.data;
    final inRange = Logic(name: 'in_range');
    Sequential(clk, [
      sckPrev < sck,
      csPrev < csN,
      inRange < inRangeOf(address),
    ]);
    final nextByte = mux(inRange, rom.data, c(0xFF, 8));

    // Commands that change the state kept between transactions
    final cmdDone = state.eq(c(0, 4)) & sckRise & byteDone;
    final setWel = cmdDone & shifted.eq(c(0x06, 8)) & ~wip;
    final clearWel = cmdDone & shifted.eq(c(0x04, 8)) & ~wip;
    final startProgram = csRise & state.eq(c(7, 4));
    final startErase = csRise & state.eq(c(9, 4));
    Sequential(clk, reset: reset, resetValues: {
      wel: c(0, 1),
      busy: c(0, 32),
      erasing: c(0, 1),
      eraseAddr: c(0, 24),
      eraseLeft: c(0, 13),
    }, [
      If(setWel, then: [wel < c(1, 1)]),
      If(clearWel | startProgram | startErase, then: [wel < c(0, 1)]),
      If(startProgram | startErase, then: [
        busy < c(busyCycles, 32),
      ], orElse: [
        If(busy.neq(c(0, 32)), then: [busy < busy - 1]),
      ]),
      If(startErase, then: [
        erasing < c(1, 1),
        eraseAddr < [address.slice(23, 12), c(0, 12)].swizzle(),
        eraseLeft < c(4096, 13),
      ]),
      If(erasing, then: [
        eraseAddr < eraseAddr + 1,
        eraseLeft < eraseLeft - 1,
        If(eraseLeft.eq(c(1, 13)), then: [erasing < c(0, 1)]),
      ]),
    ]);

    // While busy, only read status is answered; program and erase need WEL
    final firstState = mux(
        shifted.eq(c(0x05, 8)),
        c(8, 4),
        mux(
            wip,
            c(6, 4),
            mux(
                shifted.eq(c(0x03, 8)) |
                    (wel & (shifted.eq(c(0x02, 8)) | shifted.eq(c(0x20, 8)))),
                c(1, 4),
                c(6, 4))));

    Sequential(clk, reset: reset | csN, resetValues: {
      state: c(0, 4),
      cmd: c(0, 8),
      bitCount: c(0, 3),
      shiftIn: c(0, 8),
      address: c(0, 24),
      shiftOut: c(0xFF, 8),
      ramReady: c(0, 1),
      fallSeen: c(0, 1),
    }, [
      // Command, address and a page program's data: shift MOSI in on
      // rising edges
      If((state.lt(4) | state.eq(c(7, 4))) & sckRise, then: [
        shiftIn < shifted,
        bitCount < bitCount + 1,
        If(byteDone, then: [
          Case(state, [
            CaseItem(c(0, 4), [cmd < shifted, state < firstState]),
            CaseItem(c(1, 4), [
              address < [shifted, address.slice(15, 0)].swizzle(),
              state < c(2, 4),
            ]),
            CaseItem(c(2, 4), [
              address <
                  [address.slice(23, 16), shifted, address.slice(7, 0)]
                      .swizzle(),
              state < c(3, 4),
            ]),
            CaseItem(c(3, 4), [
              address < [address.slice(23, 8), shifted].swizzle(),
              state <
                  mux(cmd.eq(c(0x03, 8)), c(4, 4),
                      mux(cmd.eq(c(0x02, 8)), c(7, 4), c(9, 4))),
              ramReady < c(0, 1),
              fallSeen < c(0, 1),
            ]),
            // A page program: the next byte, within the page
            CaseItem(c(7, 4), [
              address <
                  [address.slice(23, 8), address.slice(7, 0) + 1].swizzle(),
            ]),
          ]),
        ]),
      ]),
      // Reading: as the ROM does
      If(state.eq(c(4, 4)), then: [
        ramReady < c(1, 1),
        If(sckFall, then: [fallSeen < c(1, 1)]),
        If(ramReady & (fallSeen | sckFall), then: [
          shiftOut < nextByte,
          address < address + 1,
          bitCount < c(0, 3),
          state < c(5, 4),
        ]),
      ]),
      If((state.eq(c(5, 4)) | state.eq(c(8, 4))) & sckRise, then: [
        bitCount < bitCount + 1,
      ]),
      If(state.eq(c(5, 4)) & sckFall, then: [
        If(bitCount.eq(0), then: [
          shiftOut < nextByte,
          address < address + 1,
        ], orElse: [
          shiftOut < [shiftOut.slice(6, 0), c(1, 1)].swizzle(),
        ]),
      ]),
      // The status, again and again: the falling edge after the command's
      // last bit sends its first bit
      If(state.eq(c(8, 4)) & sckFall, then: [
        If(bitCount.eq(0), then: [
          shiftOut < status,
        ], orElse: [
          shiftOut < [shiftOut.slice(6, 0), c(1, 1)].swizzle(),
        ]),
      ]),
    ]);

    miso <= shiftOut[7] & (state.eq(c(5, 4)) | state.eq(c(8, 4)));
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

  /// [contents]; with a write port, also the bytes written.
  final List<int> contents;

  /// Has a write port (wEn, wAddr, wData: written at the clock edge).
  final bool writable;

  /// $readmemh file for the generated SystemVerilog; without one the bytes
  /// are written out in it.
  final String? initFile;

  SpiFlashRomBlock({
    required Logic clk,
    required Logic addr,
    required this.contents,
    this.initFile,
    Logic? wEn,
    Logic? wAddr,
    Logic? wData,
    super.name = 'spi_flash_rom_block',
  }) : writable = wEn != null {
    addInput('clk', clk);
    addInput('addr', addr, width: addr.width);
    addOutput('data', width: 8);
    Logic? capWEn, capWAddr, capWData;
    if (wEn != null) {
      wEn = addInput('w_en', wEn);
      wAddr = addInput('w_addr', wAddr!, width: addr.width);
      wData = addInput('w_data', wData!, width: 8);
      capWEn = Logic(name: 'cap_w_en');
      capWAddr = Logic(name: 'cap_w_addr', width: addr.width);
      capWData = Logic(name: 'cap_w_data', width: 8);
      Sequential(input('clk'),
          [capWEn < wEn, capWAddr < wAddr, capWData < wData]);
    }

    // The address from the last rising edge (captured by a Sequential, which
    // sees values from before the edge; see ParticleBlockRamTdp)
    final capAddr = Logic(name: 'cap_addr', width: addr.width);
    Sequential(input('clk'), [capAddr < input('addr')]);
    data.put(0xFF);
    clk.posedge.listen((_) {
      // Read first, then the write (both from before the edge)
      final a = capAddr.value;
      data.put(a.isValid ? contents[a.toInt()] : 0xFF);
      if (capWEn != null && capWEn.value.isValid && capWEn.value.toBool()) {
        final wa = capWAddr!.value;
        final wd = capWData!.value;
        if (wa.isValid && wd.isValid) contents[wa.toInt()] = wd.toInt();
      }
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
    final writePort = writable
        ? '\nalways_ff @(posedge ${p}_clk) if (${ports['w_en']}) '
            '${p}_mem[${ports['w_addr']}] <= ${ports['w_data']};'
        : '';
    return '''
// ---- $p: SpiFlashRomBlock, $n bytes, synchronous read${writable ? ', a write port' : ''} ----
logic [7:0] ${p}_mem [0:${n - 1}];
$init
wire ${p}_clk = ${ports['clk']};
wire [${aW - 1}:0] ${p}_addr = ${ports['addr']};
logic [7:0] ${p}_q;
always_ff @(posedge ${p}_clk) ${p}_q <= ${p}_mem[${p}_addr];$writePort
assign ${ports['data']} = ${p}_q;
// ---- end $p ----''';
  }
}
