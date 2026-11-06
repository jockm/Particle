#!/usr/bin/env python3
import struct

def encode_r(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_i(imm, rs1, funct3, rd, opcode):
    imm12 = imm & 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def addi(rd, rs1, imm): return encode_i(imm, rs1, 0x0, rd, 0x13)
def slli(rd, rs1, shamt): return encode_i(shamt & 0x1F, rs1, 0x1, rd, 0x13)
def div(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0x4, rd, 0x33)
def divu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0x5, rd, 0x33)
def rem(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0x6, rd, 0x33)
def remu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0x7, rd, 0x33)
def nop(): return addi(0, 0, 0)

instructions = [
    # Operands:
    # x1 = -20 (0xFFFFFFEC)
    # x2 = 3
    # x3 = -3  (0xFFFFFFFD)
    # x4 = 20
    # x5 = 0
    addi(1, 0, -20),
    addi(2, 0, 3),
    addi(3, 0, -3),
    addi(4, 0, 20),
    addi(5, 0, 0),

    # 1. Sign combinations:
    # (-20) / 3 = -6 (0xFFFFFFFA), (-20) % 3 = -2 (0xFFFFFFFE)
    div(6, 1, 2),
    rem(7, 1, 2),

    # 20 / (-3) = -6 (0xFFFFFFFA), 20 % (-3) = 2 (0x00000002)
    div(8, 4, 3),
    rem(9, 4, 3),

    # (-20) / (-3) = 6 (0x00000006), (-20) % (-3) = -2 (0xFFFFFFFE)
    div(10, 1, 3),
    rem(11, 1, 3),

    # 2. Signed Overflow: -2147483648 / -1
    # x12 = -2147483648 (0x80000000)
    # x13 = -1 (0xFFFFFFFF)
    addi(12, 0, 1),
    slli(12, 12, 31),
    addi(13, 0, -1),
    div(14, 12, 13),            # x14 = 0x80000000
    rem(15, 12, 13),            # x15 = 0

    # 3. Remainder by zero: x % 0 = x
    rem(16, 4, 5),              # x16 = 20
    remu(17, 4, 5),             # x17 = 20

    nop(),
    nop(),
    nop(),
    nop(),
    nop()
]

with open('build/guest_rv32_signed_div.bin', 'wb') as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print(f"Generated build/guest_rv32_signed_div.bin with {len(instructions)} instructions.")
