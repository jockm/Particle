# TODO

- Parcore
    - RISC-V Extensions to Add:
        - 32 Bit
        - 64 Bit
            - R64 support
            - D double precision floating point
                - At this point we would have R64G
        - Down the line:
            - Vector (Zv...)
            - Cryptography (Zk.../Zv...)
            - Privileged, Security & Debug (S...)
    - System Bringup (aka the conductor)
        - Signing/Security?

    - Proposals:
        - "The Plan"
            - Completed
            - In Progress
                1. Parcore Architecture Proposal 01: The Parcore Conductor
            - Pending
                1. Parcore Architecture Proposal 02: Parcore Cluster Performance Optimization and:
                    1. Zba (Address Generation):
                    2. Zbs (Single-Bit Manipulation):
                    3. Zicond (Integer Conditional Operations
                3. Add ISAs:
                    1. Add C (Compact) Instruction Set extension
                    2. Zcb (Additional 16-bit Compressed Instructions):
                    3. Zicsr (Control and Status Registers) + Zicntr (Base Counters/Timers)
                    4. Zifencei (Instruction-Fetch Fence)
                4. Parcore Architecture Proposal 03: Verification & Golden Trace Co-Simulation Suite
                5. Parcore Architecture Proposal 04: Parcore Multi-EX & Dynamic Out-of-Order Architecture
                6. Add ISAs:
                    1. F (32-Bit Floating Point)
                6. Parcore Architecture Proposal 05: Autonomous Accelerator & Functional Extension Subsystem
                7. Parcore Architecture Proposal 06: Unified Memory Hierarchy, Multi-Master L1/L2 Cache Coherency, and SDRAM DMA Fabric
                    1. Add A (Atomics) Instruction Set Extension
                8. Unified Interrupt Architecture, Real-Time Timer & Inter-Processor Interrupt (IPI) Subsystem
                9. Parcore Architecture Proposal 08: Tiered Execution Model — Interpreted Cold Paths & Hotspot JIT
                10. Parcore Architecture Proposal 09: Dynamic Code Cache Management, On-Stack Replacement (OSR), and Configurable Software-Assisted MMU
                11. Parcore Architecture Proposal 10: Dynamic Multi-ISA Personality Overlays and Runtime Reconfiguration
                12. Parcore Architecture Proposal 11: High-Speed Host Debug Engine, GDB Remote Serial Bridge & Non-Intrusive Trace Architecture
                13. Parcore Architecture Proposal 12: Particle 64-Bit Architecture Extension
            - Addenda
                1. Addendum A: CPU Hinting (`HINT` / `0xFE`)

# Thoughts

- you could have cores that do AOT compilation
- hotspot like JIT
- a core with 64+ particles that run a helios like OS
- the MMU is entirely software based (see transmeta)
- spare particle cores for specialized jobs like
    - garbage collection
    - power management
    - software updating
    - failover
- Implement python (or whatever) compiler/interpreter as a core triggered by the larger system


## Thoughts on JIT

### Notes:
- HP Dynamo: https://dl.acm.org/doi/10.1145/358438.349303
    - https://cseweb.ucsd.edu/classes/sp00/cse231/dynamopldi.pdf
- HP PA-RISC to IA64 (Ares?) 
    - https://www.semanticscholar.org/paper/PA-RISC-to-IA-64%3A-Transparent-Execution%2C-No-Zheng-Thompson/da33e45c803199b6c5ed2acf76d1b6ea4dcaa66a
    - https://www.computer.org/csdl/magazine/co/2000/03/r3047/13rRUxNmPM9

Parcore could identify code ranges that when hit transfer control to a JITed replacement that would be run, and then the program counter would be updated:
```
    type JITReplacement {
        u64 startAddress
        u64 length
        u16 targetCore
        u32 targetAddress
    }

    JITReplacement jitReplacements[]
```

The trick becomes identifying these replacements, and what code can run in parallel. 

JIT for RISC-V should be fairly straightforward, however for other architectures it becomes more difficult and a table driven approach might be required.  This would mean hand crafted replacements for instructions... or possibly clusters of instructions providing some peephole optimization.


### AOT->JIT 

Levels of AOT:

- 3: A tool that takes risc-v binaries and does a stage 0 AOT on them.  Basically obvious translations
- 2: above but does peephole optimizations
- 1 above but also identifies AOT routines to cache and trigger

Normal Operation:

0: Straight CPU emulation (including tool converted binaries)

Levels JIT:

+ 1: Live identification of instruction level JIT
+ 2: Live identification of peephole
+ 3: Live identification of hotspots to JIT

and then what glues these all together is a new Parcore instruction:
HINT {8-bit CPU Hint}

what hints do is identify precompiled sections, areas of code the AOT has looked at and shouldn't be looked at by the CPU Hotspot system, static analysis of branch more likely to be taken, etc.  Anything that tunes the behavior of the running Parcore system.  

## Thoughts 