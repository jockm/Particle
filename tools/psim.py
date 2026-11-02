#!/usr/bin/env python3
# ==============================================================================
# Particle Cycle-Accurate Simulator & Debugger (psim.py)
# Architecture: Particle 32-bit RISC (16-bit Compact ISA)
# ==============================================================================

import sys
import os
import argparse
from collections import deque

MASK32 = 0xFFFFFFFF
SIGN32 = 0x80000000

def to_signed32(val):
    val = val & MASK32
    return val if val < SIGN32 else val - 0x100000000

def to_unsigned32(val):
    return val & MASK32



class RegisterWindowView:
    def __init__(self, core):
        self.core = core
        self.raw = [0] * 32

    def _eff(self, idx):
        if idx == 0:
            return 0
        return (idx + self.core.rbase) & 0x1F

    def __getitem__(self, idx):
        if isinstance(idx, slice):
            return [self[i] for i in range(*idx.indices(32))]
        return self.raw[self._eff(idx)]

    def __setitem__(self, idx, val):
        phys = self._eff(idx)
        if phys != 0:
            self.raw[phys] = val & MASK32

    def __len__(self):
        return 32

class ParticleCore:
    def __init__(self, mem_size=0x20000, num_fifos=4):
        self.mem_size = mem_size
        self.mem = bytearray(mem_size)
        self.rbase = 0
        self.r = RegisterWindowView(self)
        self.shadow_r = [0] * 32
        self.pc = 0x00000100
        self.fifos = [deque(maxlen=256) for _ in range(num_fifos)]
        self.trap_base = 0x00000100
        self.trap_stride = 64
        self.cycle_count = 0
        self.halted = False
        self.stalled = False

    def reset(self):
        self.r = RegisterWindowView(self)
        self.shadow_r = [0] * 32
        self.rbase = 0
        self.pc = self.trap_base
        self.cycle_count = 0
        self.halted = False
        self.stalled = False

    def trigger_trap(self, trap_idx, return_pc=None):
        if return_pc is None:
            return_pc = (self.pc + 2) & MASK32
        self.r[14] = return_pc

        # Trap 14 Simulation Debug Quit Hook
        if trap_idx == 14:
            print(f"\n[SIM] Debug Quit Trap 14 triggered at PC: 0x{return_pc:08X} (R1=0x{self.r[1]:08X}, Cycles={self.cycle_count})")
            self.halted = True
            return

        self.pc = (self.trap_base + (trap_idx * self.trap_stride)) & MASK32

    def read8(self, addr):
        return self.mem[addr & (self.mem_size - 1)]

    def write8(self, addr, val):
        self.mem[addr & (self.mem_size - 1)] = val & 0xFF

    def read16(self, addr):
        if addr & 1:
            self.trigger_trap(14, self.pc)
            return 0
        a = addr & (self.mem_size - 1)
        return self.mem[a] | (self.mem[(a + 1) & (self.mem_size - 1)] << 8)

    def write16(self, addr, val):
        if addr & 1:
            self.trigger_trap(14, self.pc)
            return
        a = addr & (self.mem_size - 1)
        self.mem[a] = val & 0xFF
        self.mem[(a + 1) & (self.mem_size - 1)] = (val >> 8) & 0xFF

    def read32(self, addr):
        if addr & 3:
            self.trigger_trap(14, self.pc)
            return 0
        a = addr & (self.mem_size - 1)
        return (self.mem[a] |
                (self.mem[(a + 1) & (self.mem_size - 1)] << 8) |
                (self.mem[(a + 2) & (self.mem_size - 1)] << 16) |
                (self.mem[(a + 3) & (self.mem_size - 1)] << 24))

    def write32(self, addr, val):
        if addr & 3:
            self.trigger_trap(14, self.pc)
            return
        a = addr & (self.mem_size - 1)
        self.mem[a] = val & 0xFF
        self.mem[(a + 1) & (self.mem_size - 1)] = (val >> 8) & 0xFF
        self.mem[(a + 2) & (self.mem_size - 1)] = (val >> 16) & 0xFF
        self.mem[(a + 3) & (self.mem_size - 1)] = (val >> 24) & 0xFF

    def eff_idx(self, idx):
        return self.r._eff(idx)

    def get_reg(self, idx):
        return self.r[idx]

    def set_reg(self, idx, val):
        self.r[idx] = val

    def step(self):
        if self.halted or self.pc >= self.mem_size:
            self.halted = True
            return False

        if self.pc & 1:
            self.trigger_trap(14, self.pc)
            return True

        inst = self.read16(self.pc)
        opcode = (inst >> 8) & 0xFF
        rr = (inst >> 4) & 0x0F
        rl = inst & 0x0F
        imm8 = inst & 0xFF
        imm4 = inst & 0x0F

        next_pc = (self.pc + 2) & MASK32

        # ---------------- Register Loads & Immediates (0x00 - 0x06) ----------------
        if opcode == 0x00:    # LD Rr, Rl
            self.set_reg(rr, self.r[rl])
        elif opcode == 0x01:  # LD Rr, Imm4
            self.set_reg(rr, imm4)
        elif opcode == 0x02:  # LD R14, Imm8
            self.set_reg(14, imm8)
        elif opcode == 0x03:  # LD Rr, -Imm4
            self.set_reg(rr, to_unsigned32(-imm4))
        elif opcode == 0x04:  # LD R14, -Imm8
            self.set_reg(14, to_unsigned32(-imm8))
        elif opcode == 0x05:  # PUSH4 Rr, Imm4
            self.set_reg(rr, (self.r[rr] << 4) | imm4)
        elif opcode == 0x06:  # PUSH8 R14, Imm8
            self.set_reg(14, (self.r[14] << 8) | imm8)

        # ---------------- Memory Group (8-bit: 0x10 - 0x19) ----------------
        elif opcode == 0x10:  # LD8 Rr, (Rl)
            self.set_reg(rr, self.read8(self.r[rl]))
        elif opcode == 0x11:  # LD8 Rr, (++Rl)
            addr = (self.r[rl] + 1) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x12:  # LD8 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, (addr + 1) & MASK32)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x13:  # LD8 Rr, (--Rl)
            addr = (self.r[rl] - 1) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x14:  # LD8 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, (addr - 1) & MASK32)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x15:  # ST8 (Rr), Rl
            self.write8(self.r[rr], self.r[rl])
        elif opcode == 0x16:  # ST8 (++Rr), Rl
            addr = (self.r[rr] + 1) & MASK32
            self.set_reg(rr, addr)
            self.write8(addr, self.r[rl])
        elif opcode == 0x17:  # ST8 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr + 1) & MASK32)
            self.write8(addr, self.r[rl])
        elif opcode == 0x18:  # ST8 (--Rr), Rl
            addr = (self.r[rr] - 1) & MASK32
            self.set_reg(rr, addr)
            self.write8(addr, self.r[rl])
        elif opcode == 0x19:  # ST8 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr - 1) & MASK32)
            self.write8(addr, self.r[rl])

        # ---------------- Memory Group (16-bit: 0x20 - 0x29) ----------------
        elif opcode == 0x20:  # LD16 Rr, (Rl)
            self.set_reg(rr, self.read16(self.r[rl]))
        elif opcode == 0x21:  # LD16 Rr, (++Rl)
            addr = (self.r[rl] + 2) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x22:  # LD16 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, (addr + 2) & MASK32)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x23:  # LD16 Rr, (--Rl)
            addr = (self.r[rl] - 2) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x24:  # LD16 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, (addr - 2) & MASK32)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x25:  # ST16 (Rr), Rl
            self.write16(self.r[rr], self.r[rl])
        elif opcode == 0x26:  # ST16 (++Rr), Rl
            addr = (self.r[rr] + 2) & MASK32
            self.set_reg(rr, addr)
            self.write16(addr, self.r[rl])
        elif opcode == 0x27:  # ST16 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr + 2) & MASK32)
            self.write16(addr, self.r[rl])
        elif opcode == 0x28:  # ST16 (--Rr), Rl
            addr = (self.r[rr] - 2) & MASK32
            self.set_reg(rr, addr)
            self.write16(addr, self.r[rl])
        elif opcode == 0x29:  # ST16 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr - 2) & MASK32)
            self.write16(addr, self.r[rl])

        # ---------------- Memory Group (32-bit: 0x30 - 0x39) ----------------
        elif opcode == 0x30:  # LD32 Rr, (Rl)
            self.set_reg(rr, self.read32(self.r[rl]))
        elif opcode == 0x31:  # LD32 Rr, (++Rl)
            addr = (self.r[rl] + 4) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x32:  # LD32 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, (addr + 4) & MASK32)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x33:  # LD32 Rr, (--Rl)
            addr = (self.r[rl] - 4) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x34:  # LD32 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, (addr - 4) & MASK32)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x35:  # ST32 (Rr), Rl
            self.write32(self.r[rr], self.r[rl])
        elif opcode == 0x36:  # ST32 (++Rr), Rl
            addr = (self.r[rr] + 4) & MASK32
            self.set_reg(rr, addr)
            self.write32(addr, self.r[rl])
        elif opcode == 0x37:  # ST32 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr + 4) & MASK32)
            self.write32(addr, self.r[rl])
        elif opcode == 0x38:  # ST32 (--Rr), Rl
            addr = (self.r[rr] - 4) & MASK32
            self.set_reg(rr, addr)
            self.write32(addr, self.r[rl])
        elif opcode == 0x39:  # ST32 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, (addr - 4) & MASK32)
            self.write32(addr, self.r[rl])

        # ---------------- Unsigned Arithmetic (0x40 - 0x47) ----------------
        elif opcode == 0x48:  # NEG Rr
            self.set_reg(rr, to_unsigned32(-to_signed32(self.r[rr])))
        elif opcode == 0x40:  # ADD Rr, Rl
            self.set_reg(rr, self.r[rr] + self.r[rl])
        elif opcode == 0x41:  # SUB Rr, Rl
            self.set_reg(rr, self.r[rr] - self.r[rl])
        elif opcode == 0x42:  # DIV Rr, Rl
            denom = self.r[rl]
            self.set_reg(rr, 0xFFFFFFFF if denom == 0 else self.r[rr] // denom)
        elif opcode == 0x43:  # MOD Rr, Rl
            denom = self.r[rl]
            self.set_reg(rr, self.r[rr] if denom == 0 else self.r[rr] % denom)
        elif opcode == 0x44:  # ADD Rr, Imm4
            self.set_reg(rr, self.r[rr] + imm4)
        elif opcode == 0x45:  # SUB Rr, Imm4
            self.set_reg(rr, self.r[rr] - imm4)
        elif opcode == 0x46:  # DIV Rr, Imm4
            self.set_reg(rr, 0xFFFFFFFF if imm4 == 0 else self.r[rr] // imm4)
        elif opcode == 0x47:  # MOD Rr, Imm4
            self.set_reg(rr, self.r[rr] if imm4 == 0 else self.r[rr] % imm4)

        # ---------------- Signed Arithmetic (0x50 - 0x57) ----------------
        elif opcode == 0x50:  # SADD Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) + to_signed32(self.r[rl]))
        elif opcode == 0x51:  # SSUB Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) - to_signed32(self.r[rl]))
        elif opcode == 0x52:  # SDIV Rr, Rl
            n, d = to_signed32(self.r[rr]), to_signed32(self.r[rl])
            self.set_reg(rr, -1 if d == 0 else int(n / d))
        elif opcode == 0x53:  # SMOD Rr, Rl
            n, d = to_signed32(self.r[rr]), to_signed32(self.r[rl])
            self.set_reg(rr, n if d == 0 else (n - int(n / d) * d))
        elif opcode == 0x54:  # SADD Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            self.set_reg(rr, to_signed32(self.r[rr]) + imm_s)
        elif opcode == 0x55:  # SSUB Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            self.set_reg(rr, to_signed32(self.r[rr]) - imm_s)
        elif opcode == 0x56:  # SDIV Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            n = to_signed32(self.r[rr])
            self.set_reg(rr, -1 if imm_s == 0 else int(n / imm_s))
        elif opcode == 0x57:  # SMOD Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            n = to_signed32(self.r[rr])
            self.set_reg(rr, n if imm_s == 0 else (n - int(n / imm_s) * imm_s))

        # ---------------- Shifts & Logic (0x60 - 0x73) ----------------
        elif opcode == 0x60:  # SHIFTL Rr, Rl
            self.set_reg(rr, self.r[rr] << (self.r[rl] & 31))
        elif opcode == 0x61:  # SEXT8 Rr
            v = self.r[rr] & 0xFF
            self.set_reg(rr, v if v < 0x80 else v - 0x100)
        elif opcode == 0x62:  # SHIFTR Rr, Rl
            self.set_reg(rr, self.r[rr] >> (self.r[rl] & 31))
        elif opcode == 0x63:  # ASHIFTR Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) >> (self.r[rl] & 31))
        elif opcode == 0x64:  # ROTL Rr, Rl
            s = self.r[rl] & 31
            self.set_reg(rr, ((self.r[rr] << s) | (self.r[rr] >> (32 - s))) if s else self.r[rr])
        elif opcode == 0x65:  # ROTR Rr, Rl
            s = self.r[rl] & 31
            self.set_reg(rr, ((self.r[rr] >> s) | (self.r[rr] << (32 - s))) if s else self.r[rr])
        elif opcode == 0x66:  # AND Rr, Rl
            self.set_reg(rr, self.r[rr] & self.r[rl])
        elif opcode == 0x67:  # OR Rr, Rl
            self.set_reg(rr, self.r[rr] | self.r[rl])
        elif opcode == 0x68:  # XOR Rr, Rl
            self.set_reg(rr, self.r[rr] ^ self.r[rl])
        elif opcode == 0x69:  # SHIFTL Rr, Imm4
            self.set_reg(rr, self.r[rr] << imm4)
        elif opcode == 0x6A:  # SEXT16 Rr
            v = self.r[rr] & 0xFFFF
            self.set_reg(rr, v if v < 0x8000 else v - 0x10000)
        elif opcode == 0x6B:  # SHIFTR Rr, Imm4
            self.set_reg(rr, self.r[rr] >> imm4)
        elif opcode == 0x6C:  # ASHIFTR Rr, Imm4
            self.set_reg(rr, to_signed32(self.r[rr]) >> imm4)
        elif opcode == 0x6D:  # ROTL Rr, Imm4
            self.set_reg(rr, ((self.r[rr] << imm4) | (self.r[rr] >> (32 - imm4))) if imm4 else self.r[rr])
        elif opcode == 0x6E:  # ROTR Rr, Imm4
            self.set_reg(rr, ((self.r[rr] >> imm4) | (self.r[rr] << (32 - imm4))) if imm4 else self.r[rr])
        elif opcode == 0x6F:  # AND Rr, Imm4
            self.set_reg(rr, self.r[rr] & imm4)
        elif opcode == 0x70:  # OR Rr, Imm4
            self.set_reg(rr, self.r[rr] | imm4)
        elif opcode == 0x71:  # XOR Rr, Imm4
            self.set_reg(rr, self.r[rr] ^ imm4)
        elif opcode == 0x72:  # NOT Rr
            self.set_reg(rr, ~self.r[rr] & MASK32)
        elif opcode == 0x73:  # NEZ Rr
            self.set_reg(rr, 1 if self.r[rr] != 0 else 0)

        # ---------------- Multipliers (0x78 - 0x7F) ----------------
        elif opcode == 0x78:  # MULL Rr, Rl
            self.set_reg(rr, self.r[rr] * self.r[rl])
        elif opcode == 0x79:  # MULH Rr, Rl
            self.set_reg(rr, (self.r[rr] * self.r[rl]) >> 32)
        elif opcode == 0x7A:  # SMULH Rr, Rl
            p = to_signed32(self.r[rr]) * to_signed32(self.r[rl])
            self.set_reg(rr, p >> 32)
        elif opcode == 0x7B:  # MULHSU Rr, Rl
            p = to_signed32(self.r[rr]) * self.r[rl]
            self.set_reg(rr, p >> 32)
        elif opcode == 0x7C:  # MULL Rr, Imm4
            self.set_reg(rr, self.r[rr] * imm4)
        elif opcode == 0x7D:  # MULH Rr, Imm4
            self.set_reg(rr, (self.r[rr] * imm4) >> 32)
        elif opcode == 0x7E:  # SMULH Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            p = to_signed32(self.r[rr]) * imm_s
            self.set_reg(rr, p >> 32)
        elif opcode == 0x7F:  # MULHSU Rr, Imm4
            p = to_signed32(self.r[rr]) * imm4
            self.set_reg(rr, p >> 32)

        # ---------------- Bit Manipulation & Special (0x80 - 0x8B) ----------------
        elif opcode == 0x80:  # BEXTR Rr, Rl
            pos = self.r[rl] & 0x1F
            length = (self.r[rl] >> 5) & 0x1F
            mask = (1 << length) - 1 if length < 32 else 0xFFFFFFFF
            self.set_reg(rr, (self.r[rr] >> pos) & mask)
        elif opcode == 0x81:  # JTBL Rr
            next_pc = (self.pc + 2 + (self.r[rr] * 2)) & MASK32
        elif opcode == 0x82:  # CLZ Rr, Rl
            val = self.r[rl]
            cnt = 0
            for b in range(31, -1, -1):
                if (val >> b) & 1:
                    break
                cnt += 1
            self.set_reg(rr, cnt)
        elif opcode == 0x83:  # BSET Rr, Rl
            self.set_reg(rr, self.r[rr] | (1 << (self.r[rl] & 31)))
        elif opcode == 0x84:  # BSET Rr, Imm4
            self.set_reg(rr, self.r[rr] | (1 << imm4))
        elif opcode == 0x85:  # BCLR Rr, Rl
            self.set_reg(rr, self.r[rr] & ~(1 << (self.r[rl] & 31)))
        elif opcode == 0x86:  # BCLR Rr, Imm4
            self.set_reg(rr, self.r[rr] & ~(1 << imm4))
        elif opcode == 0x87:  # BINV Rr, Rl
            self.set_reg(rr, self.r[rr] ^ (1 << (self.r[rl] & 31)))
        elif opcode == 0x88:  # BINV Rr, Imm4
            self.set_reg(rr, self.r[rr] ^ (1 << imm4))
        elif opcode == 0x89:  # BGET Rr, Rl
            self.set_reg(rr, (self.r[rr] >> (self.r[rl] & 31)) & 1)
        elif opcode == 0x8A:  # BGET Rr, Imm4
            self.set_reg(rr, (self.r[rr] >> imm4) & 1)
        elif opcode == 0x8B:  # TAS (Rr), Rl
            addr = self.r[rr]
            old_val = self.read32(addr)
            self.write32(addr, self.r[rl])
            self.set_reg(rl, old_val)
        elif opcode == 0x8C:  # REV32 Rr
            v = self.r[rr]
            swapped = (((v & 0x000000FF) << 24) |
                       ((v & 0x0000FF00) << 8) |
                       ((v & 0x00FF0000) >> 8) |
                       ((v & 0xFF000000) >> 24))
            self.set_reg(rr, swapped)
        elif opcode == 0x8C:  # REV32 Rr
            v = self.r[rr]
            swapped = ((v & 0x000000FF) << 24) | ((v & 0x0000FF00) << 8) | ((v & 0x00FF0000) >> 8) | ((v & 0xFF000000) >> 24)
            self.set_reg(rr, swapped)
            addr = self.r[rr]
            old_val = self.read32(addr)
            self.write32(addr, self.r[rl])
            self.set_reg(rl, old_val)

        # ---------------- Comparisons (SLT / SSLT: 0x90 - 0x99) ----------------
        elif opcode == 0x90:  # SLT Rr, Rl
            self.set_reg(rr, 1 if self.r[rr] < self.r[rl] else 0)
        elif opcode == 0x91:  # SLT Rr, Imm4
            self.set_reg(rr, 1 if self.r[rr] < imm4 else 0)
        elif opcode == 0x92:  # SLT Rr, -Imm4
            self.set_reg(rr, 1 if self.r[rr] < to_unsigned32(-imm4) else 0)
        elif opcode == 0x93:  # SLT R14, Imm8
            self.set_reg(14, 1 if self.r[14] < imm8 else 0)
        elif opcode == 0x94:  # SLT R14, -Imm8
            self.set_reg(14, 1 if self.r[14] < to_unsigned32(-imm8) else 0)
        elif opcode == 0x95:  # SSLT Rr, Rl
            self.set_reg(rr, 1 if to_signed32(self.r[rr]) < to_signed32(self.r[rl]) else 0)
        elif opcode == 0x96:  # SSLT Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            self.set_reg(rr, 1 if to_signed32(self.r[rr]) < imm_s else 0)
        elif opcode == 0x97:  # SSLT Rr, -Imm4
            self.set_reg(rr, 1 if to_signed32(self.r[rr]) < -imm4 else 0)
        elif opcode == 0x98:  # SSLT R14, Imm8
            imm_s = imm8 if imm8 < 128 else imm8 - 256
            self.set_reg(14, 1 if to_signed32(self.r[14]) < imm_s else 0)
        elif opcode == 0x99:  # SSLT R14, -Imm8
            self.set_reg(14, 1 if to_signed32(self.r[14]) < -imm8 else 0)
        elif opcode == 0x9A:  # SEQ Rr, Rl
            self.set_reg(rr, 1 if self.r[rr] == self.r[rl] else 0)
        elif opcode == 0x9B:  # SNE Rr, Rl
            self.set_reg(rr, 1 if self.r[rr] != self.r[rl] else 0)
        elif opcode == 0x9C:  # SLE Rr, Rl
            self.set_reg(rr, 1 if self.r[rr] <= self.r[rl] else 0)
        elif opcode == 0x9D:  # SSLE Rr, Rl
            self.set_reg(rr, 1 if to_signed32(self.r[rr]) <= to_signed32(self.r[rl]) else 0)
        # ---------------- Control Flow (0xA0 - 0xA4) ----------------
        elif opcode == 0xA0:  # JMP Rr, Rl
            target = self.r[rr]
            self.set_reg(rl, next_pc)
            next_pc = target
        elif opcode == 0xA1:  # RJUMP Rr, Rl
            target = (self.pc + (to_signed32(self.r[rr]) * 2)) & MASK32
            self.set_reg(rl, next_pc)
            next_pc = target
        elif opcode == 0xA2:  # TRAP Rr
            self.trigger_trap(self.r[rr] & 0x0F, next_pc)
            return True
        elif opcode == 0xA3:  # TRAP Imm4
            self.trigger_trap(imm4 & 0x0F, next_pc)
            return True
        elif opcode == 0xA4:  # BRANCH Rr
            next_pc = (self.pc + (to_signed32(self.r[rr]) * 2)) & MASK32

        # ---------------- Forward Branches (0xB0 - 0xBB) ----------------
        elif opcode == 0xB0:  # FBRA Imm8
            next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB1:
            if self.r[rr] == 0: next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB2:
            if to_signed32(self.r[rr]) < 0: next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB3:
            if to_signed32(self.r[rr]) > 0: next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB4:  # FBRA.Z Rr, Imm4
            if self.r[rr] == 0: next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB5:  # FBRA.N Rr, Imm4
            if to_signed32(self.r[rr]) < 0: next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB6:  # FBRA.P Rr, Imm4
            if to_signed32(self.r[rr]) > 0: next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB7:  # FBRA.Z R14, Imm8
            if self.r[14] == 0: next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB8:  # FBRA.N R14, Imm8
            if to_signed32(self.r[14]) < 0: next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB9:  # FBRA.P R14, Imm8
            if to_signed32(self.r[14]) > 0: next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xBA:  # FBRA.NZ Rr, Imm4
            if self.r[rr] != 0: next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xBB:  # FBRA.NZ R14, Imm8
            if self.r[14] != 0: next_pc = (self.pc + (imm8 * 2)) & MASK32

        # ---------------- Backward Branches (0xC0 - 0xCB) ----------------
        elif opcode == 0xC0:  # BBRA Imm8
            next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC1:
            if self.r[rr] == 0: next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC2:
            if to_signed32(self.r[rr]) < 0: next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC3:
            if to_signed32(self.r[rr]) > 0: next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC4:  # BBRA.Z Rr, Imm4
            if self.r[rr] == 0: next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC5:  # BBRA.N Rr, Imm4
            if to_signed32(self.r[rr]) < 0: next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC6:  # BBRA.P Rr, Imm4
            if to_signed32(self.r[rr]) > 0: next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC7:  # BBRA.Z R14, Imm8
            if self.r[14] == 0: next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC8:  # BBRA.N R14, Imm8
            if to_signed32(self.r[14]) < 0: next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC9:  # BBRA.P R14, Imm8
            if to_signed32(self.r[14]) > 0: next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xCA:  # BBRA.NZ Rr, Imm4
            if self.r[rr] != 0: next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xCB:  # BBRA.NZ R14, Imm8
            if self.r[14] != 0: next_pc = (self.pc - (imm8 * 2)) & MASK32

        # ---------------- Shadow Banks (0xD0 - 0xD2) ----------------
        elif opcode == 0xD0:  # XCHG Rr
            if rr != 0:
                self.r[rr], self.shadow_r[rr] = self.shadow_r[rr], self.r[rr]
        elif opcode == 0xD1:  # XCHGALL
            for i in range(1, 16):
                self.r[i], self.shadow_r[i] = self.shadow_r[i], self.r[i]
        elif opcode == 0xD2:  # XCHGMOST
            for i in range(1, 15):
                phys = self.eff_idx(i)
                self.r[phys], self.shadow_r[phys] = self.shadow_r[phys], self.r[phys]
        elif opcode == 0xD3:  # RBASE Imm8
            self.rbase = imm8 & 0x1F
        elif opcode == 0xD4:  # RBASE Rr
            self.rbase = self.get_reg(rr) & 0x1F

        # ---------------- Streaming FIFOs (0xE0 - 0xE7) ----------------
        elif opcode == 0xE0:  # FIFO.R Rr, chan
            fid = imm4 % len(self.fifos)
            
            # Non-blocking poll of host stdin for Console RX (Channel 0)
            if fid == 0 and not self.fifos[fid]:
                import select
                if select.select([sys.stdin], [], [], 0.0)[0]:
                    ch = sys.stdin.read(1)
                    if ch:
                        self.fifos[fid].append(ord(ch))

            if not self.fifos[fid]:
                return True  # Stall core on empty FIFO
            self.set_reg(rr, self.fifos[fid].popleft())

        elif opcode == 0xE1:  # FIFO.W Rr, chan
            fid = imm4 % len(self.fifos)
            val = self.r[rr] & 0xFF
            if fid == 0:
                # Pipe Channel 0 writes directly to host stdout (UART TX)
                sys.stdout.write(chr(val))
                sys.stdout.flush()
            if len(self.fifos[fid]) < 256:
                self.fifos[fid].append(self.r[rr])

        elif opcode in (0xE4, 0xE5):  # FIFO.STAT
            fid = (self.r[rl] if opcode == 0xE4 else imm4) % len(self.fifos)
            empty_b = 1 if len(self.fifos[fid]) == 0 else 0
            full_b = 2 if len(self.fifos[fid]) >= 256 else 0
            self.set_reg(rr, (len(self.fifos[fid]) << 8) | full_b | empty_b)
        elif opcode == 0xE6:  # FIFO.TRYR
            fid = self.r[rl] % len(self.fifos)
            if self.fifos[fid]:
                self.set_reg(rr, self.fifos[fid].popleft())
                self.set_reg(14, 1)
            else:
                self.set_reg(14, 0)
        elif opcode == 0xE7:  # FIFO.TRYW
            fid = self.r[rl] % len(self.fifos)
            if len(self.fifos[fid]) < 256:
                self.fifos[fid].append(self.r[rr])
                self.set_reg(14, 1)
            else:
                self.set_reg(14, 0)

        self.pc = next_pc
        self.cycle_count += 1
        return True


class Debugger:
    def __init__(self, core):
        self.core = core
        self.breakpoints = set()

    def _parse_num(self, s):
        s = s.strip()
        if s.lower().startswith("0x"):
            return int(s, 16)
        if any(c in "abcdefABCDEF" for c in s) or len(s) == 8:
            return int(s, 16)
        return int(s, 0)

    def _write8(self, addr, val):
        b = val & 0xFF
        if hasattr(self.core, 'write8'):
            self.core.write8(addr, b)
        elif isinstance(self.core.mem, (bytearray, list)):
            self.core.mem[addr & (getattr(self.core, 'mem_size', len(self.core.mem)) - 1)] = b
        elif isinstance(self.core.mem, dict):
            self.core.mem[addr] = b

    def _write16(self, addr, val):
        val = val & 0xFFFF
        if hasattr(self.core, 'write16'):
            self.core.write16(addr, val)
        else:
            self._write8(addr, val & 0xFF)
            self._write8(addr + 1, (val >> 8) & 0xFF)

    def _write32(self, addr, val):
        val = val & 0xFFFFFFFF
        if hasattr(self.core, 'write32'):
            self.core.write32(addr, val)
        else:
            for i in range(4):
                self._write8(addr + i, (val >> (i * 8)) & 0xFF)

    def print_help(self, topic=None):
        commands = {
            'c': "c                  Continue execution until breakpoint, halt, or Ctrl+C",
            's': "s [count]          Step one instruction (or [count] instructions)",
            'r': "r                  Display registers, PC, and cycle count",
            'm': "m <addr> [n]       Dump memory at <addr> (hex or decimal) for [n] bytes",

            'w': "w <addr> <v1> ...   Write 32-bit word(s) to memory (e.g. w 0x180 0xCAFE)",
            'wh': "wh <addr> <h1> ... Write 16-bit halfword(s) to memory (e.g. wh 0x180 0xCAFE)",
            'wb': "wb <addr> <b1> ... Write raw byte(s) to memory (e.g. wb 0x180 0xFE 0xCA)",

            'b': "b <addr>           Set breakpoint at <addr>",
            'q': "q / quit           Exit the debugger",
            'help': "help [cmd]         Display help for all commands or a specific command",
        }
        if topic:
            topic = topic.lower()
            if topic in commands:
                print(f"  {commands[topic]}")
            else:
                print(f"Unknown command '{topic}'. Type 'help' for available commands.")
        else:
            print("\nParticle Debugger (p4db) Commands:")
            for desc in commands.values():
                print(f"  {desc}")
            print()

    def cmdloop(self):
        print("Particle Debugger (p4db) ready. Type 'help' or '?' for commands.")
        while True:
            try:
                line = input("(p4db) ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue

            parts = line.split()
            cmd = parts[0].lower()
            args = parts[1:]

            if cmd in ('q', 'quit', 'exit'):
                break
            elif cmd in ('help', '?'):
                topic = args[0] if args else None
                self.print_help(topic)
            elif cmd == 'r':
                print(f"  PC: 0x{self.core.pc:08X}  Cycles: {self.core.cycle_count}")
                for row in range(4):
                    line_str = "  ".join(f"R{r:02d}: 0x{self.core.r[r]:08X}" for r in range(row * 4, (row + 1) * 4))
                    print(f"  {line_str}")
            elif cmd == 's':
                count = self._parse_num(args[0]) if args else 1
                for _ in range(count):
                    old_pc = self.core.pc
                    active = self.core.step()
                    print(f"Stepped [0x{old_pc:08X}] -> PC: 0x{self.core.pc:08X}")
                    if not active:
                        print("Core halted.")
                        break
            elif cmd == 'c':
                try:
                    while not self.core.halted and self.core.cycle_count < 1000000:
                        if self.core.pc in self.breakpoints:
                            print(f"Breakpoint hit at 0x{self.core.pc:08X}")
                            break
                        self.core.step()
                    if self.core.halted:
                        print(f"Program terminated cleanly by Trap 14 at PC: 0x{self.core.pc:08X} in {self.core.cycle_count} cycles.")
                    elif self.core.cycle_count >= 1000000:
                        print(f"Halted at 0x{self.core.pc:08X} after 1000000 cycles.")
                except KeyboardInterrupt:
                    print(f"\nExecution paused at PC: 0x{self.core.pc:08X}")
            elif cmd == 'b':
                if not args:
                    print("Usage: b <addr>")
                else:
                    try:
                        addr = self._parse_num(args[0])
                        self.breakpoints.add(addr)
                        print(f"Breakpoint set at 0x{addr:08X}")
                    except ValueError:
                        print("Invalid breakpoint address.")
            elif cmd == 'm':
                if not args:
                    print("Usage: m <addr> [count]")
                    continue
                try:
                    addr = self._parse_num(args[0])
                    count = self._parse_num(args[1]) if len(args) > 1 else 16
                except ValueError:
                    print("Invalid address or count")
                    continue
                end_addr = addr + count
                cur = addr & ~0xF
                while cur < end_addr:
                    row_bytes = [self.core.read8(cur + i) for i in range(16)]
                    hex_str = " ".join(f"{b:02X}" for b in row_bytes)
                    ascii_str = "".join(chr(b) if 32 <= b <= 126 else "." for b in row_bytes)
                    print(f"0x{cur:08X}:  {hex_str}   |{ascii_str}|")
                    cur += 16
            elif cmd in ('w', 'set'):
                if len(args) < 2:
                    print("Usage: w <addr> <val1> [val2 ...]")
                    continue
                try:
                    addr = self._parse_num(args[0])
                    for i, val_str in enumerate(args[1:]):
                        target_addr = addr + (i * 4)
                        val = self._parse_num(val_str) & 0xFFFFFFFF
                        self._write32(target_addr, val)
                        print(f"  [0x{target_addr:08X}] <= 0x{val:08X}")
                except ValueError:
                    print("Invalid address or value")
                    
            elif cmd == 'wh':
                if len(args) < 2:
                    print("Usage: wh <addr> <val1> [val2 ...]")
                    continue
                try:
                    addr = self._parse_num(args[0])
                    if addr & 1:
                        print(f"Alignment error: 0x{addr:08X} is not 2-byte aligned.")
                        continue
                    for i, val_str in enumerate(args[1:]):
                        target_addr = addr + (i * 2)
                        val = self._parse_num(val_str) & 0xFFFF
                        self._write16(target_addr, val)
                        print(f"  [0x{target_addr:08X}] <= 0x{val:04X}")
                except ValueError:
                    print("Invalid address or value")

            elif cmd == 'wb':
                if len(args) < 2:
                    print("Usage: wb <addr> <byte1> [byte2 ...]")
                    continue
                try:
                    addr = self._parse_num(args[0])
                    for i, val_str in enumerate(args[1:]):
                        target_addr = addr + i
                        val = self._parse_num(val_str) & 0xFF
                        self._write8(target_addr, val)
                        print(f"  [0x{target_addr:08X}] <= 0x{val:02X}")
                except ValueError:
                    print("Invalid address or byte value")
            else:
                print(f"Unknown command: {cmd}. Type 'help' for available commands.")                

def main():
    parser = argparse.ArgumentParser(description="Particle Simulator & Debugger")
    parser.add_argument("binary", nargs="?", help="Path to binary file")
    parser.add_argument("-d", "--debug", action="store_true", help="Launch interactive debugger")
    parser.add_argument("-b", "--base", default="0x00000100", help="Load address")
    args = parser.parse_args()

    core = ParticleCore()

    if args.binary:
        base_addr = int(args.base, 0)
        with open(args.binary, "rb") as f:
            data = f.read()
        core.mem[base_addr:base_addr + len(data)] = data
        print(f"Loaded {len(data)} bytes at 0x{base_addr:08X}. Particle Debugger (p4db) ready.")

    if args.debug or not args.binary:
        Debugger(core).cmdloop()
    else:
        while not core.halted and core.cycle_count < 10000000:
            core.step()
        print(f"Simulation completed in {core.cycle_count} cycles. PC = 0x{core.pc:08X}")


if __name__ == "__main__":
    main()