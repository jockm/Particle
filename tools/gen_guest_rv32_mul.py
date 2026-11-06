import struct
import os

def encode_r(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_i(imm, rs1, funct3, rd, opcode):
    imm = imm & 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def addi(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x13)
def slli(rd, rs1, shamt): return encode_i(shamt & 0x1F, rs1, 1, rd, 0x13)
def mul(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0, rd, 0x33)
def mulh(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 1, rd, 0x33)
def mulhsu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 2, rd, 0x33)
def mulhu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 3, rd, 0x33)
def nop(): return addi(0, 0, 0)

instructions = [
    # Setup operand registers:
    # x1 = 20
    addi(1, 0, 20),
    # x2 = -3 (0xFFFFFFFD)
    addi(2, 0, -3),
    # x3 = 2
    addi(3, 0, 2),
    # x4 = -1 (0xFFFFFFFF)
    addi(4, 0, -1),
    # x5 = 0x40000000
    addi(5, 0, 1),
    slli(5, 5, 30),
    # x6 = 0x80000000
    addi(6, 0, 1),
    slli(6, 6, 31),

    # 1. MUL (lower 32 bits)
    # x7 = 20 * (-3) = -60 (0xFFFFFFC4)
    mul(7, 1, 2),

    # 2. MULH (signed * signed, upper 32 bits)
    # x8 = 0x40000000 * 2 = 0x080000000 -> upper 32 bits = 0
    mulh(8, 5, 3),
    # x9 = (-1) * 2 = -2 (0xFFFFFFFFFFFFFFFE) -> upper 32 bits = -1 (0xFFFFFFFF)
    mulh(9, 4, 3),
    # x10 = (-1) * (-3) = 3 (0x0000000000000003) -> upper 32 bits = 0
    mulh(10, 4, 2),

    # 3. MULHSU (signed * unsigned, upper 32 bits)
    # x11 = (-1) * 2 = upper 32 bits = -1 (0xFFFFFFFF)
    mulhsu(11, 4, 3),
    # x12 = (-1) * 0x80000000:
    # Signed -1 * Unsigned 2^31 = -2^31 = 0xFFFFFFFF80000000 -> upper = -1 (0xFFFFFFFF)
    mulhsu(12, 4, 6),
    # x13 = 20 (signed) * 0x80000000 (unsigned):
    # 20 * 2^31 = 10 * 2^32 -> upper 32 bits = 10 (0x0000000A)
    mulhsu(13, 1, 6),

    # 4. MULHU (unsigned * unsigned, upper 32 bits)
    # x14 = 0x80000000 * 2 = 0x1_00000000 -> upper 32 bits = 1
    mulhu(14, 6, 3),
    # x15 = 0xFFFFFFFF * 0xFFFFFFFF = 0xFFFFFFFE_00000001 -> upper = 0xFFFFFFFE
    mulhu(15, 4, 4),

    nop(),
    nop(),
    nop()
]

os.makedirs('build', exist_ok=True)
with open('build/guest_rv32_mul_test.bin', 'wb') as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print(f"Generated build/guest_rv32_mul_test.bin with {len(instructions)} instructions.")
