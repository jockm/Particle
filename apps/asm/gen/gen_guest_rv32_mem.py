import struct
import os

def encode_r(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_i(imm, rs1, funct3, rd, opcode):
    imm = imm & 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_s(imm, rs1, rs2, funct3, opcode):
    imm = imm & 0xFFF
    imm11_5 = (imm >> 5) & 0x7F
    imm4_0 = imm & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_0 << 7) | opcode

def addi(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x13)
def slli(rd, rs1, shamt): return encode_i(shamt & 0x1F, rs1, 1, rd, 0x13)

# Loads (opcode 0x03)
def lb(rd, rs1, imm):  return encode_i(imm, rs1, 0, rd, 0x03)
def lh(rd, rs1, imm):  return encode_i(imm, rs1, 1, rd, 0x03)
def lw(rd, rs1, imm):  return encode_i(imm, rs1, 2, rd, 0x03)
def lbu(rd, rs1, imm): return encode_i(imm, rs1, 4, rd, 0x03)
def lhu(rd, rs1, imm): return encode_i(imm, rs1, 5, rd, 0x03)

# Stores (opcode 0x23)
def sb(rs1, rs2, imm): return encode_s(imm, rs1, rs2, 0, 0x23)
def sh(rs1, rs2, imm): return encode_s(imm, rs1, rs2, 1, 0x23)
def sw(rs1, rs2, imm): return encode_s(imm, rs1, rs2, 2, 0x23)

def nop(): return addi(0, 0, 0)

# Use free RAM in the TCM as a scratchpad (e.g., 0x0800)
instructions = [
    # Base Pointer x1 = 0x00000800
    addi(1, 0, 2),
    slli(1, 1, 10),           # x1 = 0x800

    # Test data preparation
    addi(2, 0, 0x5A),         # x2 = 0x0000005A (Positive byte)
    addi(3, 0, -14),          # x3 = 0xFFFFFFF2 (Negative byte: 0xF2)
    addi(4, 0, 0x12),
    slli(4, 4, 8),
    addi(4, 4, 0x34),         # x4 = 0x00001234 (Positive halfword)
    addi(5, 0, -2),           # x5 = 0xFFFFFFFE (Negative halfword: 0xFFFE)

    # 1. Byte Stores (SB) across byte offsets
    sb(1, 2, 0),              # Mem[0x800] = 0x5A
    sb(1, 3, 1),              # Mem[0x801] = 0xF2
    sb(1, 2, 2),              # Mem[0x802] = 0x5A
    sb(1, 3, 3),              # Mem[0x803] = 0xF2

    # 2. Byte Loads & Zero/Sign Extension
    lb(6, 1, 0),              # x6  = lb(0x800)  -> 0x0000005A (Positive)
    lb(7, 1, 1),              # x7  = lb(0x801)  -> 0xFFFFFFF2 (Sign-extended)
    lbu(8, 1, 1),             # x8  = lbu(0x801) -> 0x000000F2 (Zero-extended)

    # 3. Halfword Stores (SH) & Loads (LH, LHU)
    sh(1, 4, 4),              # Mem[0x804..0x805] = 0x1234
    sh(1, 5, 6),              # Mem[0x806..0x807] = 0xFFFE
    lh(9, 1, 4),              # x9  = lh(0x804)  -> 0x00001234
    lh(10, 1, 6),             # x10 = lh(0x806)  -> 0xFFFFFFFE (Sign-extended)
    lhu(11, 1, 6),            # x11 = lhu(0x806) -> 0x0000FFFE (Zero-extended)

    # 4. Word Store (SW) & Word Load (LW) verification
    lw(12, 1, 0),             # x12 = lw(0x800)  -> 0xF25AF25A
    lw(13, 1, 4),             # x13 = lw(0x804)  -> 0xFFFE1234

    nop(),
    nop(),
    nop()
]

os.makedirs('build', exist_ok=True)
with open('build/guest_rv32_mem_test.bin', 'wb') as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print(f"Generated build/guest_rv32_mem_test.bin with {len(instructions)} instructions.")
