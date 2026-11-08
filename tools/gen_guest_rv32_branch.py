import struct
import os

def encode_i(imm, rs1, funct3, rd, opcode):
    imm = imm & 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_b(imm, rs1, rs2, funct3, opcode=0x63):
    imm = imm & 0x1FFE
    imm12   = (imm >> 12) & 0x1
    imm10_5 = (imm >> 5)  & 0x3F
    imm4_1  = (imm >> 1)  & 0xF
    imm11   = (imm >> 11) & 0x1
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_1 << 8) | (imm11 << 7) | opcode

def encode_j(imm, rd, opcode=0x6F):
    imm = imm & 0x1FFFFE
    imm20   = (imm >> 20) & 0x1
    imm10_1 = (imm >> 1)  & 0x3FF
    imm11   = (imm >> 11) & 0x1
    imm19_12= (imm >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (rd << 7) | opcode

def addi(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x13)
def jalr(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x67)
def jal(rd, imm):       return encode_j(imm, rd, 0x6F)

def beq(rs1, rs2, imm):  return encode_b(imm, rs1, rs2, 0)
def bne(rs1, rs2, imm):  return encode_b(imm, rs1, rs2, 1)
def blt(rs1, rs2, imm):  return encode_b(imm, rs1, rs2, 4)
def bge(rs1, rs2, imm):  return encode_b(imm, rs1, rs2, 5)
def bltu(rs1, rs2, imm): return encode_b(imm, rs1, rs2, 6)
def bgeu(rs1, rs2, imm): return encode_b(imm, rs1, rs2, 7)
def nop(): return addi(0, 0, 0)

instructions = [
    # Test 1: BEQ Taken & Pipeline Squash
    addi(1, 0, 10),              # 0x500: x1 = 10
    addi(2, 0, 10),              # 0x504: x2 = 10
    beq(1, 2, 12),               # 0x508: beq x1, x2, +12 -> targets 0x514
    addi(3, 0, 0xBAD),           # 0x50C: POISON
    addi(3, 0, 0xBAD),           # 0x510: POISON
    addi(3, 0, 0x42),            # 0x514: Target: x3 = 0x42

    # Test 2: BNE Not Taken (Fall-through)
    bne(1, 2, 12),               # 0x518: bne x1, x2, +12 -> fall-through
    addi(4, 0, 0x55),            # 0x51C: x4 = 0x55

    # Test 3: BLT Signed Comparison
    addi(5, 0, -5),              # 0x520: x5 = -5
    addi(6, 0, 5),               # 0x524: x6 = 5
    blt(5, 6, 12),               # 0x528: blt -5, 5, +12 -> targets 0x534
    addi(7, 0, 0xBAD),           # 0x52C: POISON
    addi(7, 0, 0xBAD),           # 0x530: POISON
    addi(7, 0, 0x77),            # 0x534: Target: x7 = 0x77

    # Test 4: BGEU Unsigned Comparison (-5 unsigned >= 5)
    bgeu(5, 6, 12),              # 0x538: bgeu 0xFFFFFFFB >= 5 -> targets 0x544
    addi(8, 0, 0xBAD),           # 0x53C: POISON
    addi(8, 0, 0xBAD),           # 0x540: POISON
    addi(8, 0, 0x88),            # 0x544: Target: x8 = 0x88

    # Test 5: JAL (Jump and Link)
    jal(9, 12),                  # 0x548: jal x9, +12 -> targets 0x554; x9 = 0x54C
    addi(10, 0, 0xBAD),          # 0x54C: POISON
    addi(10, 0, 0xBAD),          # 0x550: POISON
    addi(10, 0, 0x99),           # 0x554: Target: x10 = 0x99

    # Test 6: JALR (Jump and Link Register)
    addi(11, 0, 0x564),          # 0x558: x11 = target 0x564
    jalr(12, 11, 0),             # 0x55C: jalr x12, 0(x11) -> jump 0x564; x12 = 0x560
    addi(13, 0, 0xBAD),          # 0x560: POISON
    addi(13, 0, 0xAA),           # 0x564: Target: x13 = 0xAA

    nop(),
    nop(),
    nop(),
]

os.makedirs('build', exist_ok=True)
with open('build/guest_rv32_branch.bin', 'wb') as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print(f"Generated build/guest_rv32_branch.bin with {len(instructions)} instructions.")
