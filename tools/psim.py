#!/usr/bin/env python3
"""
================================================================================
Particle Instruction-Level Simulator & Debugger (psim.py)
Architecture: Particle 32-bit RISC (SH-2 / ARM Thumb inspired)
Features:
  - Exact 32-bit arithmetic, barrel shift, CLZ, and TAS atomic semantics
  - Direct Stride Exception Table (Base: 0x0100, Stride: 64 bytes)
  - Hardware Shadow Bank (R1-R15) single-cycle context switching
  - Hardware multi-channel streaming FIFOs and MBOX strobe dispatch
  - Dual UART Emulation:
      * FIFO Channel 0: ULX3S Fixed 3 Mbps FTDI UART (tied to console stdin/stdout)
      * FIFO Channel 1: Aux GPIO UART with MMIO Baud Divisor Register at 0xF0000010
  - Multi-Core cluster execution via JSON configuration
  - Shared Memory MMIO synchronization
  - Full-featured p4db interactive debugger (breakpoints, single-step, dumps)
================================================================================
"""

import sys
import os
import cmd
import json
import argparse
import select
from collections import deque
from typing import List, Dict, Optional

MASK32 = 0xFFFFFFFF
SIGN32 = 0x80000000

# MMIO Registers
MMIO_AUX_UART_DIVISOR = 0xF0000010

def to_signed32(val):
    val = val & MASK32
    return val if val < 0x80000000 else val - 0x100000000

def to_unsigned32(val):
    return val & MASK32

class SharedMemory:
    """
    Simulated shared memory bus accessible by multiple ParticleCore instances
    mapped to high address ranges (e.g. 0x80000000+).
    """
    def __init__(self, size=0x20000, base_addr=0x80000000):
        self.size = size
        self.base_addr = base_addr
        self.mem = bytearray(size)

    def is_in_range(self, addr):
        return self.base_addr <= addr < (self.base_addr + self.size)

    def read8(self, addr):
        return self.mem[addr - self.base_addr]

    def write8(self, addr, val):
        self.mem[addr - self.base_addr] = val & 0xFF

    def read16(self, addr):
        offset = addr - self.base_addr
        return self.mem[offset] | (self.mem[offset + 1] << 8)

    def write16(self, addr, val):
        offset = addr - self.base_addr
        self.mem[offset] = val & 0xFF
        self.mem[offset + 1] = (val >> 8) & 0xFF

    def read32(self, addr):
        offset = addr - self.base_addr
        return (self.mem[offset] | (self.mem[offset + 1] << 8) |
                (self.mem[offset + 2] << 16) | (self.mem[offset + 3] << 24))

    def write32(self, addr, val):
        offset = addr - self.base_addr
        self.mem[offset] = val & 0xFF
        self.mem[offset + 1] = (val >> 8) & 0xFF
        self.mem[offset + 2] = (val >> 16) & 0xFF
        self.mem[offset + 3] = (val >> 24) & 0xFF

    def tas(self, addr, val):
        offset = addr - self.base_addr
        old_val = (self.mem[offset] | (self.mem[offset + 1] << 8) |
                   (self.mem[offset + 2] << 16) | (self.mem[offset + 3] << 24))
        self.write32(addr, val)
        return old_val

class MultiCoreInterconnect:
    """
    Routes streaming FIFO packets and cross-core MBOX strobe interrupts
    between ParticleCore instances.
    """
    def __init__(self, core_count: int, num_fifos_per_core: int = 4):
        self.core_count = core_count
        self.num_fifos = num_fifos_per_core
        self.fifo_routes: Dict[tuple, tuple] = {}
        self.fifos = [[deque(maxlen=256) for _ in range(num_fifos_per_core)] for _ in range(core_count)]
        self.cores_ref = []

    def register_route(self, src_core: int, src_chan: int, dst_core: int, dst_chan: int):
        self.fifo_routes[(src_core, src_chan)] = (dst_core, dst_chan)

    def write_fifo(self, src_core: int, chan: int, val: int) -> bool:
        route = self.fifo_routes.get((src_core, chan))
        if route is None:
            dst_core, dst_chan = src_core, chan
        else:
            dst_core, dst_chan = route

        q = self.fifos[dst_core][dst_chan]
        if len(q) < 256:
            q.append(val)
            return True
        return False

    def read_fifo(self, core_id: int, chan: int) -> Optional[int]:
        q = self.fifos[core_id][chan]
        if q:
            return q.popleft()
        return None

    def fifo_status(self, core_id: int, chan: int) -> int:
        q = self.fifos[core_id][chan]
        empty_bit = 1 if len(q) == 0 else 0
        full_bit = 2 if len(q) >= 256 else 0
        depth = len(q) << 8
        return depth | full_bit | empty_bit

    def send_mbox(self, src_core: int, target_core: int, vector_idx: int):
        if 0 <= target_core < len(self.cores_ref):
            core = self.cores_ref[target_core]
            core.trigger_trap(vector_idx)

class ParticleCore:
    def __init__(self, core_id=0, name="Core_0", mem_size=0x20000, num_fifos=4, shared_mem: Optional[SharedMemory] = None):
        self.core_id = core_id
        self.name = name
        self.mem_size = mem_size
        self.mem = bytearray(mem_size)
        self.shared_mem = shared_mem
        
        # Architectural State
        self.r = [0] * 16
        self.shadow_r = [0] * 16
        self.pc = 0x00000100   # Reset vector
        
        # Local FIFOs (FIFO 0: FTDI UART, FIFO 1: Aux GPIO UART, FIFO 2..3: General)
        self.fifos = [deque(maxlen=256) for _ in range(num_fifos)]
        
        # Aux GPIO UART Baud Rate Divisor register (default ~115200 at 25MHz -> 217)
        self.aux_uart_divisor = 217
        self.aux_uart_rx_buffer = deque(maxlen=256)
        self.aux_uart_tx_buffer = deque(maxlen=256)

        # External hook redirects
        self.ext_read_fifo = None
        self.ext_write_fifo = None
        self.ext_stat_fifo = None
        self.ext_mbox = None
        
        # Control & Trap Parameters
        self.trap_base = 0x00000100
        self.trap_stride = 64
        self.stalled = False
        self.cycle_count = 0
        self.halted = False

    def reset(self):
        self.r = [0] * 16
        self.shadow_r = [0] * 16
        self.pc = self.trap_base
        self.stalled = False
        self.halted = False

    def trigger_trap(self, trap_idx, return_pc=None):
        if return_pc is None:
            return_pc = (self.pc + 2) & MASK32
        self.r[14] = return_pc
        self.pc = (self.trap_base + (trap_idx * self.trap_stride)) & MASK32

    # Memory Accessors with MMIO and Alignment checks
    def read8(self, addr):
        if addr == MMIO_AUX_UART_DIVISOR:
            return self.aux_uart_divisor & 0xFF
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            return self.shared_mem.read8(addr)
        addr = addr & (self.mem_size - 1)
        return self.mem[addr]

    def write8(self, addr, val):
        if addr == MMIO_AUX_UART_DIVISOR:
            self.aux_uart_divisor = (self.aux_uart_divisor & 0xFF00) | (val & 0xFF)
            return
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            self.shared_mem.write8(addr, val)
            return
        addr = addr & (self.mem_size - 1)
        self.mem[addr] = val & 0xFF

    def read16(self, addr):
        if addr & 1:
            self.trigger_trap(14, self.pc)  # Alignment Error
            return 0
        if addr == MMIO_AUX_UART_DIVISOR:
            return self.aux_uart_divisor & 0xFFFF
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            return self.shared_mem.read16(addr)
        addr = addr & (self.mem_size - 1)
        return self.mem[addr] | (self.mem[addr + 1] << 8)

    def write16(self, addr, val):
        if addr & 1:
            self.trigger_trap(14, self.pc)
            return
        if addr == MMIO_AUX_UART_DIVISOR:
            self.aux_uart_divisor = val & 0xFFFF
            return
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            self.shared_mem.write16(addr, val)
            return
        addr = addr & (self.mem_size - 1)
        self.mem[addr] = val & 0xFF
        self.mem[addr + 1] = (val >> 8) & 0xFF

    def read32(self, addr):
        if addr & 3:
            self.trigger_trap(14, self.pc)
            return 0
        if addr == MMIO_AUX_UART_DIVISOR:
            return self.aux_uart_divisor & 0xFFFF
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            return self.shared_mem.read32(addr)
        addr = addr & (self.mem_size - 1)
        return (self.mem[addr] | (self.mem[addr + 1] << 8) |
                (self.mem[addr + 2] << 16) | (self.mem[addr + 3] << 24))

    def write32(self, addr, val):
        if addr & 3:
            self.trigger_trap(14, self.pc)
            return
        if addr == MMIO_AUX_UART_DIVISOR:
            self.aux_uart_divisor = val & 0xFFFF
            return
        if self.shared_mem and self.shared_mem.is_in_range(addr):
            self.shared_mem.write32(addr, val)
            return
        addr = addr & (self.mem_size - 1)
        self.mem[addr] = val & 0xFF
        self.mem[addr + 1] = (val >> 8) & 0xFF
        self.mem[addr + 2] = (val >> 16) & 0xFF
        self.mem[addr + 3] = (val >> 24) & 0xFF

    def set_reg(self, reg_idx, val):
        if reg_idx != 0:
            self.r[reg_idx] = val & MASK32

    # FIFO helper dispatch with dual UART handling
    def _read_fifo_val(self, ch):
        ch = ch & 3
        if self.ext_read_fifo:
            return self.ext_read_fifo(ch)

        # Standalone UART Channel 0: ULX3S FTDI UART (Console In)
        if ch == 0:
            q = self.fifos[0]
            if not q:
                # Check non-blocking stdin
                if select.select([sys.stdin], [], [], 0)[0]:
                    ch_in = sys.stdin.read(1)
                    if ch_in:
                        return ord(ch_in)
                return None
            return q.popleft()

        # Standalone UART Channel 1: Aux GPIO UART
        if ch == 1:
            if self.aux_uart_rx_buffer:
                return self.aux_uart_rx_buffer.popleft()
            q = self.fifos[1]
            return q.popleft() if q else None

        q = self.fifos[ch]
        return q.popleft() if q else None

    def _write_fifo_val(self, ch, val):
        ch = ch & 3
        if self.ext_write_fifo:
            return self.ext_write_fifo(ch, val)

        # Standalone UART Channel 0: ULX3S FTDI UART (Console Out)
        if ch == 0:
            char_out = chr(val & 0xFF)
            sys.stdout.write(char_out)
            sys.stdout.flush()
            return True

        # Standalone UART Channel 1: Aux GPIO UART
        if ch == 1:
            if len(self.aux_uart_tx_buffer) < 256:
                self.aux_uart_tx_buffer.append(val & 0xFF)
            q = self.fifos[1]
            if len(q) < 256:
                q.append(val)
                return True
            return False

        q = self.fifos[ch]
        if len(q) < 256:
            q.append(val)
            return True
        return False

    def _get_fifo_stat(self, ch):
        ch = ch & 3
        if self.ext_stat_fifo:
            return self.ext_stat_fifo(ch)

        if ch == 0:
            # Check stdin readiness
            has_input = bool(self.fifos[0]) or bool(select.select([sys.stdin], [], [], 0)[0])
            empty_bit = 0 if has_input else 1
            full_bit = 0
            depth = (len(self.fifos[0]) + (1 if has_input else 0)) << 8
            return depth | full_bit | empty_bit

        if ch == 1:
            empty_bit = 1 if len(self.fifos[1]) == 0 else 0
            full_bit = 2 if len(self.fifos[1]) >= 256 else 0
            depth = len(self.fifos[1]) << 8
            return depth | full_bit | empty_bit

        q = self.fifos[ch]
        empty_bit = 1 if len(q) == 0 else 0
        full_bit = 2 if len(q) >= 256 else 0
        depth = len(q) << 8
        return depth | full_bit | empty_bit

    def step(self):
        if self.halted:
            return False

        if self.pc & 1:
            self.trigger_trap(14, self.pc)
            return True

        if self.pc >= self.mem_size:
            self.halted = True
            return False

        inst = self.read16(self.pc)
        opcode = (inst >> 8) & 0xFF
        rr = (inst >> 4) & 0x0F
        rl = inst & 0x0F
        imm8 = inst & 0xFF
        imm4 = inst & 0x0F

        next_pc = (self.pc + 2) & MASK32
        self.cycle_count += 1

        # ---------------- Load & Immediate Instructions ----------------
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

        # ---------------- Memory Group (8-bit) ----------------
        elif opcode == 0x10:  # LD8 Rr, (Rl)
            self.set_reg(rr, self.read8(self.r[rl]))
        elif opcode == 0x11:  # LD8 (Rr), Rl
            self.write8(self.r[rr], self.r[rl])
        elif opcode == 0x12:  # LD8 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, addr + 1)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x13:  # LD8 Rr, (++Rl)
            addr = (self.r[rl] + 1) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x14:  # LD8 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, addr - 1)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x15:  # LD8 Rr, (--Rl)
            addr = (self.r[rl] - 1) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read8(addr))
        elif opcode == 0x16:  # LD8 (--Rr), Rl
            addr = (self.r[rr] - 1) & MASK32
            self.set_reg(rr, addr)
            self.write8(addr, self.r[rl])
        elif opcode == 0x17:  # LD8 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr - 1)
            self.write8(addr, self.r[rl])
        elif opcode == 0x18:  # LD8 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr + 1)
            self.write8(addr, self.r[rl])
        elif opcode == 0x19:  # LD8 (++Rr), Rl
            addr = (self.r[rr] + 1) & MASK32
            self.set_reg(rr, addr)
            self.write8(addr, self.r[rl])

        # ---------------- Memory Group (16-bit) ----------------
        elif opcode == 0x20:  # LD16 Rr, (Rl)
            self.set_reg(rr, self.read16(self.r[rl]))
        elif opcode == 0x21:  # LD16 (Rr), Rl
            self.write16(self.r[rr], self.r[rl])
        elif opcode == 0x22:  # LD16 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, addr + 2)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x23:  # LD16 Rr, (++Rl)
            addr = (self.r[rl] + 2) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x24:  # LD16 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, addr - 2)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x25:  # LD16 Rr, (--Rl)
            addr = (self.r[rl] - 2) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read16(addr))
        elif opcode == 0x26:  # LD16 (--Rr), Rl
            addr = (self.r[rr] - 2) & MASK32
            self.set_reg(rr, addr)
            self.write16(addr, self.r[rl])
        elif opcode == 0x27:  # LD16 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr - 2)
            self.write16(addr, self.r[rl])
        elif opcode == 0x28:  # LD16 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr + 2)
            self.write16(addr, self.r[rl])
        elif opcode == 0x29:  # LD16 (++Rr), Rl
            addr = (self.r[rr] + 2) & MASK32
            self.set_reg(rr, addr)
            self.write16(addr, self.r[rl])

        # ---------------- Memory Group (32-bit) ----------------
        elif opcode == 0x30:  # LD32 Rr, (Rl)
            self.set_reg(rr, self.read32(self.r[rl]))
        elif opcode == 0x31:  # LD32 (Rr), Rl
            self.write32(self.r[rr], self.r[rl])
        elif opcode == 0x32:  # LD32 Rr, (Rl++)
            addr = self.r[rl]
            self.set_reg(rl, addr + 4)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x33:  # LD32 Rr, (++Rl)
            addr = (self.r[rl] + 4) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x34:  # LD32 Rr, (Rl--)
            addr = self.r[rl]
            self.set_reg(rl, addr - 4)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x35:  # LD32 Rr, (--Rl)
            addr = (self.r[rl] - 4) & MASK32
            self.set_reg(rl, addr)
            self.set_reg(rr, self.read32(addr))
        elif opcode == 0x36:  # LD32 (--Rr), Rl
            addr = (self.r[rr] - 4) & MASK32
            self.set_reg(rr, addr)
            self.write32(addr, self.r[rl])
        elif opcode == 0x37:  # LD32 (Rr--), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr - 4)
            self.write32(addr, self.r[rl])
        elif opcode == 0x38:  # LD32 (Rr++), Rl
            addr = self.r[rr]
            self.set_reg(rr, addr + 4)
            self.write32(addr, self.r[rl])
        elif opcode == 0x39:  # LD32 (++Rr), Rl
            addr = (self.r[rr] + 4) & MASK32
            self.set_reg(rr, addr)
            self.write32(addr, self.r[rl])

        # ---------------- Unsigned Arithmetic ----------------
        elif opcode == 0x40:  # Add Rr, Rl
            self.set_reg(rr, self.r[rr] + self.r[rl])
        elif opcode == 0x41:  # Sub Rr, Rl
            self.set_reg(rr, self.r[rr] - self.r[rl])
        elif opcode == 0x42:  # Div Rr, Rl
            denom = self.r[rl]
            self.set_reg(rr, 0xFFFFFFFF if denom == 0 else self.r[rr] // denom)
        elif opcode == 0x43:  # Mod Rr, Rl
            denom = self.r[rl]
            self.set_reg(rr, self.r[rr] if denom == 0 else self.r[rr] % denom)
        elif opcode == 0x44:  # Add Rr, Imm4
            self.set_reg(rr, self.r[rr] + imm4)
        elif opcode == 0x45:  # Sub Rr, Imm4
            self.set_reg(rr, self.r[rr] - imm4)
        elif opcode == 0x46:  # Div Rr, Imm4
            self.set_reg(rr, 0xFFFFFFFF if imm4 == 0 else self.r[rr] // imm4)
        elif opcode == 0x47:  # Mod Rr, Imm4
            self.set_reg(rr, self.r[rr] if imm4 == 0 else self.r[rr] % imm4)

        # ---------------- Signed Arithmetic ----------------
        elif opcode == 0x50:  # SAdd Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) + to_signed32(self.r[rl]))
        elif opcode == 0x51:  # SSub Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) - to_signed32(self.r[rl]))
        elif opcode == 0x52:  # SDiv Rr, Rl
            n, d = to_signed32(self.r[rr]), to_signed32(self.r[rl])
            if d == 0:
                res = -1
            elif n == -0x80000000 and d == -1:
                res = -0x80000000
            else:
                res = int(n / d)
            self.set_reg(rr, res)
        elif opcode == 0x53:  # SMod Rr, Rl
            n, d = to_signed32(self.r[rr]), to_signed32(self.r[rl])
            res = n if d == 0 else (n - int(n / d) * d)
            self.set_reg(rr, res)
        elif opcode == 0x54:  # SAdd Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            self.set_reg(rr, to_signed32(self.r[rr]) + imm_s)
        elif opcode == 0x55:  # SSub Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            self.set_reg(rr, to_signed32(self.r[rr]) - imm_s)
        elif opcode == 0x56:  # SDiv Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            n = to_signed32(self.r[rr])
            self.set_reg(rr, -1 if imm_s == 0 else int(n / imm_s))
        elif opcode == 0x57:  # SMod Rr, Imm4
            imm_s = imm4 if imm4 < 8 else imm4 - 16
            n = to_signed32(self.r[rr])
            self.set_reg(rr, n if imm_s == 0 else (n - int(n / imm_s) * imm_s))

        # ---------------- Shifts, Logic & Bit Manipulation ----------------
        elif opcode == 0x60:  # ShiftL Rr, Rl
            self.set_reg(rr, self.r[rr] << (self.r[rl] & 31))
        elif opcode == 0x61:  # SEXT8 Rr
            v = self.r[rl] & 0xFF
            self.set_reg(rl, v if v < 0x80 else v - 0x100)
        elif opcode == 0x62:  # ShiftR Rr, Rl
            self.set_reg(rr, self.r[rr] >> (self.r[rl] & 31))
        elif opcode == 0x63:  # AShiftR Rr, Rl
            self.set_reg(rr, to_signed32(self.r[rr]) >> (self.r[rl] & 31))
        elif opcode == 0x64:  # RotL Rr, Rl
            s = self.r[rl] & 31
            self.set_reg(rr, ((self.r[rr] << s) | (self.r[rr] >> (32 - s))) if s else self.r[rr])
        elif opcode == 0x65:  # RotR Rr, Rl
            s = self.r[rl] & 31
            self.set_reg(rr, ((self.r[rr] >> s) | (self.r[rr] << (32 - s))) if s else self.r[rr])
        elif opcode == 0x66:  # And Rr, Rl
            self.set_reg(rr, self.r[rr] & self.r[rl])
        elif opcode == 0x67:  # Or Rr, Rl
            self.set_reg(rr, self.r[rr] | self.r[rl])
        elif opcode == 0x68:  # Xor Rr, Rl
            self.set_reg(rr, self.r[rr] ^ self.r[rl])
        elif opcode == 0x69:  # ShiftL Rr, Imm4
            self.set_reg(rr, self.r[rr] << imm4)
        elif opcode == 0x6A:  # SEXT16 Rr
            v = self.r[rl] & 0xFFFF
            self.set_reg(rl, v if v < 0x8000 else v - 0x10000)
        elif opcode == 0x6B:  # ShiftR Rr, Imm4
            self.set_reg(rr, self.r[rr] >> imm4)
        elif opcode == 0x6C:  # AShiftR Rr, Imm4
            self.set_reg(rr, to_signed32(self.r[rr]) >> imm4)
        elif opcode == 0x6D:  # RotL Rr, Imm4
            self.set_reg(rr, ((self.r[rr] << imm4) | (self.r[rr] >> (32 - imm4))) if imm4 else self.r[rr])
        elif opcode == 0x6E:  # RotR Rr, Imm4
            self.set_reg(rr, ((self.r[rr] >> imm4) | (self.r[rr] << (32 - imm4))) if imm4 else self.r[rr])
        elif opcode == 0x6F:  # And Rr, Imm4
            self.set_reg(rr, self.r[rr] & imm4)
        elif opcode == 0x70:  # Or Rr, Imm4
            self.set_reg(rr, self.r[rr] | imm4)
        elif opcode == 0x71:  # Xor Rr, Imm4
            self.set_reg(rr, self.r[rr] ^ imm4)

        # ---------------- Multipliers ----------------
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

        # ---------------- Bit Operations & Direct Jump ----------------
        elif opcode == 0x80:  # BEXTR Rr, Rl
            pos = self.r[rl] & 0x1F
            length = (self.r[rl] >> 5) & 0x1F
            mask = (1 << length) - 1 if length < 32 else 0xFFFFFFFF
            self.set_reg(rr, (self.r[rr] >> pos) & mask)
        elif opcode == 0x81:  # JTBL Rr, Rl
            target = self.read32(self.r[rr] + (self.r[rl] << 2))
            next_pc = target
        elif opcode == 0x82:  # CLZ Rr, Rl
            val = self.r[rl]
            count = 0
            for b in range(31, -1, -1):
                if (val >> b) & 1:
                    break
                count += 1
            self.set_reg(rr, count)
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
        elif opcode == 0x8B:  # TAS (Rr), Rl (Atomic Swap)
            addr = self.r[rr]
            if self.shared_mem and self.shared_mem.is_in_range(addr):
                old_val = self.shared_mem.tas(addr, self.r[rl])
            else:
                old_val = self.read32(addr)
                self.write32(addr, self.r[rl])
            self.set_reg(rl, old_val)

        # ---------------- Comparisons ----------------
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

        # ---------------- Control Flow ----------------
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

        # ---------------- Forward Branches ----------------
        elif opcode == 0xB0:  # FBRA Imm8
            next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB1 and self.r[rr] == 0:
            next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB2 and to_signed32(self.r[rr]) < 0:
            next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB3 and to_signed32(self.r[rr]) > 0:
            next_pc = (self.pc + (self.r[rl] * 2)) & MASK32
        elif opcode == 0xB4 and self.r[rr] == 0:
            next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB5 and to_signed32(self.r[rr]) < 0:
            next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB6 and to_signed32(self.r[rr]) > 0:
            next_pc = (self.pc + (imm4 * 2)) & MASK32
        elif opcode == 0xB7 and self.r[14] == 0:
            next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB8 and to_signed32(self.r[14]) < 0:
            next_pc = (self.pc + (imm8 * 2)) & MASK32
        elif opcode == 0xB9 and to_signed32(self.r[14]) > 0:
            next_pc = (self.pc + (imm8 * 2)) & MASK32

        # ---------------- Backward Branches ----------------
        elif opcode == 0xC0:  # BBRA Imm8
            next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC1 and self.r[rr] == 0:
            next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC2 and to_signed32(self.r[rr]) < 0:
            next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC3 and to_signed32(self.r[rr]) > 0:
            next_pc = (self.pc - (self.r[rl] * 2)) & MASK32
        elif opcode == 0xC4 and self.r[rr] == 0:
            next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC5 and to_signed32(self.r[rr]) < 0:
            next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC6 and to_signed32(self.r[rr]) > 0:
            next_pc = (self.pc - (imm4 * 2)) & MASK32
        elif opcode == 0xC7 and self.r[14] == 0:
            next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC8 and to_signed32(self.r[14]) < 0:
            next_pc = (self.pc - (imm8 * 2)) & MASK32
        elif opcode == 0xC9 and to_signed32(self.r[14]) > 0:
            next_pc = (self.pc - (imm8 * 2)) & MASK32

        # ---------------- Shadow Bank Exchanges ----------------
        elif opcode == 0xD0:  # XCHG Rr
            if rr != 0:
                self.r[rr], self.shadow_r[rr] = self.shadow_r[rr], self.r[rr]
        elif opcode == 0xD1:  # XCHGALL
            for i in range(1, 16):
                self.r[i], self.shadow_r[i] = self.shadow_r[i], self.r[i]
        elif opcode == 0xD2:  # XCHGMOST (Preserves R15 SP)
            for i in range(1, 15):
                self.r[i], self.shadow_r[i] = self.shadow_r[i], self.r[i]

        # ---------------- FIFO & MBOX ----------------
        elif opcode in (0xE0, 0xE1):  # FIFO.R
            fid = (self.r[rl] if opcode == 0xE0 else imm4)
            val = self._read_fifo_val(fid)
            if val is None:
                return True
            self.set_reg(rr, val)

        elif opcode in (0xE2, 0xE3):  # FIFO.W
            fid = (self.r[rl] if opcode == 0xE2 else imm4)
            if not self._write_fifo_val(fid, self.r[rr]):
                return True

        elif opcode in (0xE4, 0xE5):  # FIFO.STAT
            fid = (self.r[rl] if opcode == 0xE4 else imm4)
            stat = self._get_fifo_stat(fid)
            self.set_reg(rr, stat)

        elif opcode == 0xE6:  # FIFO.TRYR
            fid = self.r[rl]
            val = self._read_fifo_val(fid)
            if val is not None:
                self.set_reg(rr, val)
                self.set_reg(14, 1)
            else:
                self.set_reg(14, 0)

        elif opcode == 0xE7:  # FIFO.TRYW
            fid = self.r[rl]
            if self._write_fifo_val(fid, self.r[rr]):
                self.set_reg(14, 1)
            else:
                self.set_reg(14, 0)

        elif opcode in (0xE8, 0xE9):  # MBOX
            v_idx = (self.r[rl] if opcode == 0xE8 else imm4) & 0x0F
            if self.ext_mbox:
                self.ext_mbox(rr, v_idx)
            else:
                self.trigger_trap(v_idx, next_pc)
            return True

        else:
            self.trigger_trap(15, self.pc)
            return True

        self.pc = next_pc
        return True


class ParticleMultiCoreSimulator:
    """
    Manages multi-core cluster execution, JSON config parsing, and FIFO/MBOX routing.
    """
    def __init__(self, config_file: str):
        self.config_path = config_file
        with open(config_file, "r") as f:
            self.config = json.load(f)

        self.cores: List[ParticleCore] = []
        self.core_configs = self.config.get("cores", [])
        num_cores = len(self.core_configs)
        
        shared_size = int(str(self.config.get("shared_memory_size", 0x20000)), 0)
        shared_base = int(str(self.config.get("shared_memory_base", "0x80000000")), 0)
        self.shared_mem = SharedMemory(size=shared_size, base_addr=shared_base) if shared_size > 0 else None

        self.interconnect = MultiCoreInterconnect(num_cores)
        self._init_cores()
        self.interconnect.cores_ref = self.cores

    def _init_cores(self):
        for idx, cfg in enumerate(self.core_configs):
            core_id = cfg.get("id", idx)
            mem_size = int(str(cfg.get("mem_size", 0x20000)), 0)
            
            core = ParticleCore(
                core_id=core_id,
                name=cfg.get("name", f"Core_{core_id}"),
                mem_size=mem_size,
                shared_mem=self.shared_mem
            )

            core.ext_read_fifo = lambda ch, c=core_id: self.interconnect.read_fifo(c, ch)
            core.ext_write_fifo = lambda ch, val, c=core_id: self.interconnect.write_fifo(c, ch, val)
            core.ext_stat_fifo = lambda ch, c=core_id: self.interconnect.fifo_status(c, ch)
            core.ext_mbox = lambda target, vec, c=core_id: self.interconnect.send_mbox(c, target, vec)

            bin_path = cfg.get("binary")
            if bin_path and os.path.exists(bin_path):
                base_addr = int(str(cfg.get("base_addr", "0x00000100")), 0)
                with open(bin_path, "rb") as bf:
                    data = bf.read()
                core.mem[base_addr:base_addr + len(data)] = data

            init_regs = cfg.get("initial_registers", {})
            for rname, rval in init_regs.items():
                ridx = int(rname.upper().replace("R", ""))
                val_int = int(str(rval), 0)
                core.set_reg(ridx, val_int)

            routes = cfg.get("fifo_connections", {}).get("tx", [])
            for r in routes:
                self.interconnect.register_route(
                    src_core=core_id,
                    src_chan=r["channel"],
                    dst_core=r["target_core"],
                    dst_chan=r["target_channel"]
                )

            self.cores.append(core)

    def step_all(self) -> bool:
        all_halted = True
        for core in self.cores:
            if not core.halted:
                core.step()
                all_halted = False
        return not all_halted

    def run(self, max_cycles: int = 1000000):
        cycle = 0
        while cycle < max_cycles:
            active = self.step_all()
            cycle += 1
            if not active:
                break
        print(f"Simulation completed at cycle {cycle}.")
        for core in self.cores:
            status = "HALTED" if core.halted else "RUNNING/STALLED"
            print(f"[{core.name} (ID {core.core_id})] Status: {status} | PC: 0x{core.pc:08X} | Cycles: {core.cycle_count}")


class Debugger(cmd.Cmd):
    intro = "Particle Debugger (p4db) with Dual UART support. Type 'help' or '?' for commands."
    prompt = "(p4db) "

    def __init__(self, core, cluster_sim: Optional[ParticleMultiCoreSimulator] = None):
        super().__init__()
        self.core = core
        self.cluster_sim = cluster_sim
        self.breakpoints = set()

    def do_switch(self, arg):
        """Switch active debug core: switch <core_id>"""
        if not self.cluster_sim:
            print("Multi-core cluster is not active.")
            return
        try:
            cid = int(arg.strip())
            if 0 <= cid < len(self.cluster_sim.cores):
                self.core = self.cluster_sim.cores[cid]
                print(f"Switched to {self.core.name} (ID {self.core.core_id})")
            else:
                print(f"Invalid core ID. Available: 0..{len(self.cluster_sim.cores)-1}")
        except Exception:
            print("Usage: switch <core_id>")

    def do_cores(self, arg):
        """List all cores and execution states: cores"""
        if not self.cluster_sim:
            print(f"Single Core mode: {self.core.name}")
            return
        print("Cluster Cores:")
        for c in self.cluster_sim.cores:
            active_marker = "==>" if c == self.core else "   "
            st = "HALTED" if c.halted else "RUNNING/STALLED"
            print(f"{active_marker} [{c.core_id}] {c.name:<16} PC: 0x{c.pc:08X} Cycles: {c.cycle_count:<8} Status: {st}")

    def do_r(self, arg):
        """Display registers and shadow bank: r"""
        print(f"[{self.core.name}] PC: 0x{self.core.pc:08X}  Cycles: {self.core.cycle_count}")
        print(f"UART Aux Divisor: 0x{self.core.aux_uart_divisor:04X} ({self.core.aux_uart_divisor})")
        print("Active Registers:")
        for row in range(4):
            line = "  ".join(f"R{r:<2}: 0x{self.core.r[r]:08X}" for r in range(row * 4, (row + 1) * 4))
            print(f"  {line}")
        print("Shadow Registers:")
        for row in range(4):
            line = "  ".join(f"S{r:<2}: 0x{self.core.shadow_r[r]:08X}" for r in range(row * 4, (row + 1) * 4))
            print(f"  {line}")

    def do_s(self, arg):
        """Single-step one instruction: s"""
        if self.cluster_sim:
            self.cluster_sim.step_all()
            print(f"Stepped cluster. Current core [{self.core.name}] PC: 0x{self.core.pc:08X}")
        else:
            if self.core.halted:
                print("Core is halted.")
                return
            cur_pc = self.core.pc
            self.core.step()
            print(f"Stepped [0x{cur_pc:08X}] -> PC: 0x{self.core.pc:08X}")

    def do_c(self, arg):
        """Continue execution until breakpoint or halt: c"""
        try:
            if self.cluster_sim:
                while True:
                    hit = any(c.pc in self.breakpoints for c in self.cluster_sim.cores)
                    if hit:
                        print("Breakpoint hit on cluster core.")
                        break
                    active = self.cluster_sim.step_all()
                    if not active:
                        print("All cluster cores halted.")
                        break
            else:
                while not self.core.halted:
                    if self.core.pc in self.breakpoints:
                        print(f"Breakpoint hit at 0x{self.core.pc:08X}")
                        break
                    self.core.step()
                if self.core.halted:
                    print(f"Halted at 0x{self.core.pc:08X}")
        except KeyboardInterrupt:
            print(f"\nExecution paused by user at PC: 0x{self.core.pc:08X}")

    def do_b(self, arg):
        """Set breakpoint: b <hex_addr>"""
        try:
            addr = int(arg.strip(), 0)
            self.breakpoints.add(addr)
            print(f"Breakpoint set at 0x{addr:08X}")
        except Exception:
            print("Usage: b <addr>")

    def do_m(self, arg):
        """Memory inspect: m <addr> [count]"""
        parts = arg.split()
        if not parts:
            print("Usage: m <addr> [count]")
            return
        addr = int(parts[0], 0)
        count = int(parts[1], 0) if len(parts) > 1 else 16
        for i in range(0, count, 16):
            chunk = [self.core.read8(addr + i + j) for j in range(min(16, count - i))]
            hex_str = " ".join(f"{b:02X}" for b in chunk)
            ascii_str = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
            print(f"0x{addr+i:08X}:  {hex_str:<48}  |{ascii_str}|")

    def do_fifo(self, arg):
        """Inspect FIFOs and UART buffers: fifo"""
        print(f"--- Core {self.core.name} FIFOs ---")
        print(f"  FIFO #0 (ULX3S FTDI 3Mbps UART): Depth={len(self.core.fifos[0])}/256")
        print(f"  FIFO #1 (Aux GPIO UART): Depth={len(self.core.fifos[1])}/256  (TX buf={len(self.core.aux_uart_tx_buffer)})")
        for i in range(2, 4):
            q = self.core.fifos[i]
            head = f"0x{q[0]:08X}" if q else "EMPTY"
            print(f"  FIFO #{i}: Depth={len(q)}/256 Head={head}")

    def do_inject_uart1(self, arg):
        """Inject bytes into Aux GPIO UART RX buffer: inject_uart1 <string>"""
        text = arg.strip()
        for b in text.encode('utf-8'):
            self.core.aux_uart_rx_buffer.append(b)
        print(f"Injected {len(text)} bytes into Aux GPIO UART RX buffer.")

    def do_quit(self, arg):
        """Exit debugger"""
        return True


def main():
    parser = argparse.ArgumentParser(description="Particle Instruction-Level Simulator (Dual UART Edition)")
    parser.add_argument("binary", nargs="?", help="Binary image to load (single-core mode)")
    parser.add_argument("-C", "--cluster", help="Path to multi-core JSON configuration file")
    parser.add_argument("-b", "--base", default="0x00000100", help="Load address (default: 0x0100)")
    parser.add_argument("-d", "--debug", action="store_true", help="Launch interactive debugger")
    parser.add_argument("--max-cycles", type=int, default=10000000, help="Max execution cycles")
    args = parser.parse_args()

    if args.cluster:
        sim = ParticleMultiCoreSimulator(args.cluster)
        if args.debug:
            dbg = Debugger(sim.cores[0], cluster_sim=sim)
            while True:
                try:
                    dbg.cmdloop()
                    break
                except KeyboardInterrupt:
                    print("^C")
        else:
            try:
                sim.run(max_cycles=args.max_cycles)
            except KeyboardInterrupt:
                print("\nSimulation aborted by user.")
    else:
        core = ParticleCore()
        if args.binary:
            load_addr = int(args.base, 0)
            with open(args.binary, "rb") as f:
                data = f.read()
            core.mem[load_addr:load_addr+len(data)] = data
            print(f"Loaded {len(data)} bytes at 0x{load_addr:08X}")

        if args.debug or not args.binary:
            dbg = Debugger(core)
            while True:
                try:
                    dbg.cmdloop()
                    break
                except KeyboardInterrupt:
                    print("^C")
        else:
            try:
                while not core.halted and core.cycle_count < args.max_cycles:
                    core.step()
                print(f"Simulation completed in {core.cycle_count} cycles. PC = 0x{core.pc:08X}")
            except KeyboardInterrupt:
                print(f"\nSimulation stopped at PC = 0x{core.pc:08X} (Cycle {core.cycle_count})")
                
if __name__ == "__main__":
    main()
