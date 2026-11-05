import struct

def encode_r(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

def encode_i(imm, rs1, funct3, rd, opcode=0x13):
    imm12 = imm & 0xFFF
    return (imm12 << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

def encode_s(imm, rs2, rs1, funct3, opcode=0x23):
    imm12 = imm & 0xFFF
    imm_11_5 = (imm12 >> 5) & 0x7F
    imm_4_0 = imm12 & 0x1F
    return (imm_11_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | (imm_4_0 << 7) | (opcode & 0x7F)

def encode_b(imm, rs2, rs1, funct3, opcode=0x63):
    imm13 = imm & 0x1FFF
    b12 = (imm13 >> 12) & 1
    b10_5 = (imm13 >> 5) & 0x3F
    b4_1 = (imm13 >> 1) & 0xF
    b11 = (imm13 >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | (b4_1 << 8) | (b11 << 7) | (opcode & 0x7F)

def encode_u(imm20, rd, opcode=0x37):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

def encode_j(imm, rd, opcode=0x6F):
    imm21 = imm & 0x1FFFFF
    j20 = (imm21 >> 20) & 1
    j10_1 = (imm21 >> 1) & 0x3FF
    j11 = (imm21 >> 11) & 1
    j19_12 = (imm21 >> 12) & 0xFF
    return (j20 << 31) | (j10_1 << 21) | (j11 << 20) | (j19_12 << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

# Shortcuts
def addi(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x13)
def nop(): return addi(0, 0, 0)
def sb(rs2, rs1, imm): return encode_s(imm, rs2, rs1, 0, 0x23)
def sh(rs2, rs1, imm): return encode_s(imm, rs2, rs1, 1, 0x23)
def sw(rs2, rs1, imm): return encode_s(imm, rs2, rs1, 2, 0x23)
def lb(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x03)
def lh(rd, rs1, imm): return encode_i(imm, rs1, 1, rd, 0x03)
def lw(rd, rs1, imm): return encode_i(imm, rs1, 2, rd, 0x03)
def lbu(rd, rs1, imm): return encode_i(imm, rs1, 4, rd, 0x03)
def lhu(rd, rs1, imm): return encode_i(imm, rs1, 5, rd, 0x03)
def slli(rd, rs1, shamt): return encode_i(shamt & 0x1F, rs1, 1, rd, 0x13)
def slti(rd, rs1, imm): return encode_i(imm, rs1, 2, rd, 0x13)
def sltiu(rd, rs1, imm): return encode_i(imm, rs1, 3, rd, 0x13)
def xori(rd, rs1, imm): return encode_i(imm, rs1, 4, rd, 0x13)
def srli(rd, rs1, shamt): return encode_i(shamt & 0x1F, rs1, 5, rd, 0x13)
def srai(rd, rs1, shamt): return encode_i((shamt & 0x1F) | 0x400, rs1, 5, rd, 0x13)
def ori(rd, rs1, imm): return encode_i(imm, rs1, 6, rd, 0x13)
def andi(rd, rs1, imm): return encode_i(imm, rs1, 7, rd, 0x13)

def add(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 0, rd, 0x33)
def sub(rd, rs1, rs2): return encode_r(0x20, rs2, rs1, 0, rd, 0x33)
def sll(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 1, rd, 0x33)
def slt(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 2, rd, 0x33)
def sltu(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 3, rd, 0x33)
def xor_(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 4, rd, 0x33)
def srl(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 5, rd, 0x33)
def sra(rd, rs1, rs2): return encode_r(0x20, rs2, rs1, 5, rd, 0x33)
def or_(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 6, rd, 0x33)
def and_(rd, rs1, rs2): return encode_r(0x00, rs2, rs1, 7, rd, 0x33)

# RV32M Extension
def mul(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 0, rd, 0x33)
def mulh(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 1, rd, 0x33)
def mulhsu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 2, rd, 0x33)
def mulhu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 3, rd, 0x33)
def div(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 4, rd, 0x33)
def divu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 5, rd, 0x33)
def rem(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 6, rd, 0x33)
def remu(rd, rs1, rs2): return encode_r(0x01, rs2, rs1, 7, rd, 0x33)
def lui(rd, imm20): return encode_u(imm20, rd, 0x37)

# Branches
def beq(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 0)
def bne(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 1)
def blt(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 4)
def bge(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 5)
def bltu(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 6)
def bgeu(rs1, rs2, imm): return encode_b(imm, rs2, rs1, 7)

# Jumps
def jal(rd, imm): return encode_j(imm, rd, 0x6F)
def jalr(rd, rs1, imm): return encode_i(imm, rs1, 0, rd, 0x67)

instructions = []

# --- PART 1: Existing Memory Load/Store & Alignment Suite (x1..x17) ---
instructions += [
    addi(1, 0, 100),            # x1 = 100
    addi(2, 0, -86),            # x2 = 0xAA
    addi(3, 0, -69),            # x3 = 0xBB
    addi(4, 0, -52),            # x4 = 0xCC
    addi(5, 0, -35),            # x5 = 0xDD
    sb(2, 1, 0),                # mem[100] = 0xAA
    sb(3, 1, 1),                # mem[101] = 0xBB
    sb(4, 1, 2),                # mem[102] = 0xCC
    sb(5, 1, 3),                # mem[103] = 0xDD
    lw(6, 1, 0),                # x6 = 0xDDCCBBAA
    lbu(7, 1, 1),               # x7 = 0xBB
    lb(8, 1, 1),                # x8 = 0xFFFFFFBB
    lbu(9, 1, 2),               # x9 = 0xCC
    lb(10, 1, 2),               # x10 = 0xFFFFFFCC
    lbu(11, 1, 3),              # x11 = 0xDD
    lb(12, 1, 3),               # x12 = 0xFFFFFFDD
    addi(13, 0, 2000),
    addi(13, 13, 2000),
    addi(13, 13, 660),          # x13 = 0x1234
    lui(14, 8),
    addi(14, 14, 2000),
    addi(14, 14, 475),          # x14 = 0x89AB
    sh(13, 1, 4),               # mem[104..105] = 0x1234
    sh(14, 1, 6),               # mem[106..107] = 0x89AB
    lw(15, 1, 4),               # x15 = 0x89AB1234
    lhu(16, 1, 6),              # x16 = 0x89AB
    lh(17, 1, 6),               # x17 = 0xFFFF89AB
]

# --- PART 2: Section 2 Branches & Jumps Coverage ---
# Setup registers for comparisons:
# x2 = -10 (0xFFFFFFF6), x3 = 10, x4 = 10
instructions += [
    addi(2, 0, -10),            # x2 = -10
    addi(3, 0, 10),             # x3 = +10
    addi(4, 0, 10),             # x4 = +10

    # 1. BEQ taken: x3 == x4 -> jump over bad write to x18
    beq(3, 4, 12),              # jump +12 bytes
    addi(18, 0, 0xbad),         # should be skipped
    nop(),
    addi(18, 0, 0x1),           # x18 = 1 (BEQ taken verified)

    # 2. BNE not-taken fallthrough: x3 != x4 is false -> does NOT branch
    bne(3, 4, 16),              # should fall through
    addi(19, 0, 0x2),           # x19 = 2 (BNE fallthrough verified)
    jal(0, 12),                 # skip over bad branch target
    addi(19, 0, 0xbad),
    nop(),

    # 3. BLT signed taken: x2 (-10) < x3 (+10) -> jump
    blt(2, 3, 12),
    addi(20, 0, 0xbad),
    nop(),
    addi(20, 0, 0x3),           # x20 = 3 (BLT taken verified)

    # 4. BGE signed taken: x3 (+10) >= x2 (-10) -> jump
    bge(3, 2, 12),
    addi(21, 0, 0xbad),
    nop(),
    addi(21, 0, 0x4),           # x21 = 4 (BGE taken verified)

    # 5. BLTU unsigned taken: x3 (10) < x2 (0xFFFFFFF6) -> jump
    bltu(3, 2, 12),
    addi(22, 0, 0xbad),
    nop(),
    addi(22, 0, 0x5),           # x22 = 5 (BLTU taken verified)

    # 6. BGEU unsigned taken: x2 (0xFFFFFFF6) >= x3 (10) -> jump
    bgeu(2, 3, 12),
    addi(23, 0, 0xbad),
    nop(),
    addi(23, 0, 0x6),           # x23 = 6 (BGEU taken verified)

    # 7. JAL: Jump and link into x24, jumping forward
    jal(24, 12),                # x24 gets PC + 4
    addi(25, 0, 0xbad),         # skipped
    nop(),
    addi(25, 0, 0x7),           # x25 = 7 (JAL forward target reached)

    # 8. JALR: Jump indirect using x26 as target
    # Current PC is at 0x500 + len(instructions)*4
]

# Calculate target for JALR
jalr_target_index = len(instructions) + 5
jalr_target_pc = 0x500 + jalr_target_index * 4

instructions += [
    addi(26, 0, jalr_target_pc),# x26 = target PC
    jalr(27, 26, 0),            # jump to x26, x27 gets link (PC + 4)
    addi(28, 0, 0xbad),         # skipped
    nop(),
    nop(),
    addi(28, 0, 0x8),           # x28 = 8 (JALR target reached)
    nop(),
    nop(),
    nop()
]


# ==============================================================================
# Section 3: ALU Immediate & Register-Register Operations
# ==============================================================================
instructions += [
    # Setup operand registers
    addi(1, 0, -16),            # x1 = 0xFFFFFFF0 (-16)
    addi(2, 0, 4),              # x2 = 4

    # Immediate tests
    slli(3, 2, 3),              # x3  = 4 << 3 = 32 (0x20)
    srli(4, 1, 2),              # x4  = 0xFFFFFFF0 >> 2 = 0x3FFFFFFC
    srai(5, 1, 2),              # x5  = 0xFFFFFFF0 >>> 2 = 0xFFFFFFFC (-4)
    slti(6, 1, 4),              # x6  = (-16 < 4) signed = 1
    sltiu(7, 1, 4),             # x7  = (0xFFFFFFF0 < 4) unsigned = 0
    xori(8, 1, 0x0FF),          # x8  = 0xFFFFFFF0 ^ 0x0FF = 0xFFFFFF0F
    ori(9, 2, 0x0F0),           # x9  = 4 | 0x0F0 = 0x0F4
    andi(10, 1, 0x0FF),         # x10 = 0xFFFFFFF0 & 0x0FF = 0x0F0

    # Register-Register tests
    sub(11, 2, 1),              # x11 = 4 - (-16) = 20 (0x14)
    sll(12, 2, 2),              # x12 = 4 << 4 = 64 (0x40)
    slt(13, 1, 2),              # x13 = (-16 < 4) signed = 1
    sltu(14, 1, 2),             # x14 = (0xFFFFFFF0 < 4) unsigned = 0
    xor_(15, 1, 2),             # x15 = 0xFFFFFFF0 ^ 4 = 0xFFFFFFF4
    srl(16, 1, 2),              # x16 = 0xFFFFFFF0 >> 4 = 0x0FFFFFFF
    sra(17, 1, 2),              # x17 = 0xFFFFFFF0 >>> 4 = 0xFFFFFFFF
    or_(18, 1, 2),              # x18 = 0xFFFFFFF0 | 4 = 0xFFFFFFF4
    and_(19, 1, 2),             # x19 = 0xFFFFFFF0 & 4 = 0x00000000

    nop(),
    nop(),
    nop()
]


# ==============================================================================
# Section 4: RV32M Multiply & Divide Extension
# ==============================================================================
instructions += [
    # Use x20, x21, x22 as operands so x1..x19 remain intact
    addi(20, 0, 20),            # x20 = 20
    addi(21, 0, 3),             # x21 = 3
    addi(22, 0, 0),             # x22 = 0 (for div-by-zero checks)

    # 1. MUL: lower 32 bits (20 * 3 = 60 = 0x3C)
    mul(23, 20, 21),            # x23 = 60

    # 2. MULHU: unsigned * unsigned upper 32 bits
    # 0x80000000 * 2 = 0x1_00000000 -> upper = 1
    addi(24, 0, 1),
    slli(24, 24, 31),           # x24 = 0x80000000
    addi(25, 0, 2),             # x25 = 2
    mulhu(26, 24, 25),          # x26 = 1

    # 3. DIV / DIVU
    div(27, 20, 21),            # x27 = 20 / 3 = 6
    divu(28, 20, 21),           # x28 = 20 / 3 = 6

    # 4. REM / REMU
    rem(29, 20, 21),            # x29 = 20 % 3 = 2
    remu(30, 20, 21),           # x30 = 20 % 3 = 2

    # 5. Division / Remainder by zero
    div(31, 20, 22),            # x31 = 20 / 0 = 0xFFFFFFFF (-1)

    nop(),
    nop(),
    nop()
]

with open('build/guest_rv32_test.bin', 'wb') as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print(f"Generated build/guest_rv32_test.bin with {len(instructions)} instructions.")
