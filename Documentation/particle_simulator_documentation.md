# Particle Instruction Simulator & Debugger (`psim.py`)

`psim.py` is an instruction-accurate, cycle-tracking software emulator and interactive debugger (`p4db`) for the Particle processor architecture. It models the native 32-bit datapath, true dual-port memory, multi-channel streaming FIFOs, hardware shadow register banking, and the direct stride exception system. 

It supports both single-core execution and multi-core cluster execution driven by a JSON configuration file, complete with point-to-point FIFO routing, atomic shared-memory MMIO synchronization, and cross-core hardware strobe interrupts (`MBOX`).

---

## 1. Command-Line Usage

```bash
# Single-core execution
python3 tools/psim.py <binary_file> [options]

# Multi-core cluster execution
python3 tools/psim.py -C <cluster_config.json> [options]
```

### CLI Arguments & Options

| Flag | Parameter | Description |
| :--- | :--- | :--- |
| `binary` | `<path>` | Binary image to load in single-core mode (optional if `-C` is passed). |
| `-C`, `--cluster` | `<config.json>` | Path to multi-core JSON configuration file. |
| `-b`, `--base` | `<addr>` | Load address for binary image in single-core mode (default: `0x00000100`). |
| `-d`, `--debug` | None | Launch into interactive `p4db` debugger. |
| `--max-cycles` | `<int>` | Max cycle count threshold before simulation aborts (default: `10000000`). |

---

## 2. Multi-Core Simulation & Architecture

When started with `-C / --cluster`, `psim.py` operates as a lock-step multi-core execution engine:

* **Lock-step Clocking**: All active cores execute one clock cycle in lock-step via `step_all()`. Cores that halt cease execution, and the cluster simulation terminates once all cores have halted or the cycle limit is reached.
* **Shared Memory & MMIO Bus (`SharedMemory`)**:
  * An address window (default: `0x80000000` to `0x80000000 + shared_memory_size`) is shared across all cores.
  * Direct atomic read/write and atomic test-and-set / swap (`TAS (Rr), Rl`) operations across this window are immediately consistent across all cores.
* **Inter-Core Streaming Interconnect (`MultiCoreInterconnect`)**:
  * Point-to-point FIFO virtual channels route streaming packets (`FIFO.W`, `FIFO.TRYW` to `FIFO.R`, `FIFO.TRYR`) between arbitrary core endpoints.
  * A write to channel $X$ on Core $A$ is routed directly to channel $Y$ on Core $B$ according to the configuration routing matrix.
* **Cross-Core Strobe Interrupts (`MBOX`)**:
  * When a core executes `MBOX Rr, Rl` or `MBOX Rr, Imm4`, the target core index ($Rr$) is signaled with vector $Rl$ or `Imm4`, triggering an immediate Direct Stride Trap vector branch on the target core.

---

## 3. JSON Configuration Schema (`cluster_config.json`)

```json
{
  "topology": "point_to_point_fifo",
  "shared_memory_size": 131072,
  "shared_memory_base": "0x80000000",
  "cores": [
    {
      "id": 0,
      "name": "Core_Producer",
      "mem_size": 131072,
      "binary": "build/producer.bin",
      "base_addr": "0x00000100",
      "initial_registers": {
        "R1": "0x00001000",
        "R15": "0x00010000"
      },
      "fifo_connections": {
        "tx": [
          { "channel": 0, "target_core": 1, "target_channel": 0 }
        ]
      }
    },
    {
      "id": 1,
      "name": "Core_Consumer",
      "mem_size": 131072,
      "binary": "build/consumer.bin",
      "base_addr": "0x00000100",
      "initial_registers": {
        "R15": "0x00010000"
      },
      "fifo_connections": {
        "tx": [
          { "channel": 0, "target_core": 0, "target_channel": 0 }
        ]
      }
    }
  ]
}
```

### Configuration Fields

* `topology`: Descriptive interconnect type string (`point_to_point_fifo`, `mesh_fifo`, etc.).
* `shared_memory_size`: Total byte size of shared memory allocated across cores (e.g., `131072` for 128 KB). Set to `0` to disable shared memory.
* `shared_memory_base`: Hexadecimal or integer base address for the shared memory window (e.g., `"0x80000000"`).
* `cores`: Array of core configuration blocks:
  * `id`: Core identifier integer ($0, 1, \dots$).
  * `name`: Friendly display name for logs and `p4db`.
  * `mem_size`: Local private memory size in bytes (default: `131072`).
  * `binary`: Optional file path to raw binary executable image to load into local memory.
  * `base_addr`: Memory address where `binary` is loaded (default: `0x00000100`).
  * `initial_registers`: Key-value pairs of initial register values (e.g., `"R1": "0x00001000"`, `"R15": "0x00010000"`).
  * `fifo_connections.tx`: Routing definitions:
    * `channel`: Local TX channel index ($0 \dots 3$).
    * `target_core`: Remote core ID to deliver data to.
    * `target_channel`: Remote RX channel index on the target core.

---

## 4. Interactive Debugger (`p4db`)

Launching `psim.py` with `-d` (in single-core or multi-core mode) halts execution at cycle 0 and provides an interactive inspection shell.

### Commands

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `cores` | None | Lists all cores in the cluster, their cycle counts, PCs, and status (`RUNNING`, `STALLED`, `HALTED`), indicating the currently selected core. |
| `switch` | `<core_id>` | Switches active debug focus to core `<core_id>`. Subsequent register/memory commands apply to this core. |
| `s` | None | Single-steps one instruction. In multi-core mode, advances all cluster cores synchronously by one cycle. |
| `c` | None | Continues execution until a breakpoint is hit on any core, or all cores halt. |
| `b` | `<addr>` | Sets an instruction breakpoint at hex/decimal address `<addr>`. |
| `r` | None | Displays the active register bank ($R0$–$R15$) and shadow bank ($S0$–$S15$) of the focused core. |
| `m` | `<addr> [count]` | Hex/ASCII memory dump starting at `<addr>` for `[count]` bytes (default: 16). Correctly accesses shared memory if `<addr>` falls in the shared window. |
| `fifo` | None | Displays occupancy depth, head values, and flags for all FIFOs belonging to the focused core. |
| `q` | None | Exits the debugger and terminates the simulation session. |

---

## 5. Architectural Simulation Invariants

1. **R0 Immutability**: All writes targeting $R0$ are discarded; reads always yield `0x00000000`.
2. **Post/Pre-Increment Ordering**: For `LD32 Rr, (Rl++)`, the initial address in $Rl$ is accessed first, and $Rl$ is incremented by 4 subsequently.
3. **Interruptible Stalls & FIFO Blocking**: Operations waiting on empty FIFOs (`FIFO.R`) or full FIFOs (`FIFO.W`) stall the core and hold the Program Counter on the faulting instruction until the condition clears.
4. **Hardware Alignment Traps**: Unaligned memory accesses (halfwords at odd bytes, words not aligned to 4 bytes) or odd $PC$ jump targets vector directly to Trap 14 (`0x00000480`) before committing state changes.
5. **Direct Stride Exception Vectoring**: Reset, traps, and interrupts calculate branch targets directly via:
   $$\text{Vector Target} = \text{TRAP\_TABLE\_BASE} + (\text{Vector Number} \times 64)$$