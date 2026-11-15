# TODO

- Change Vector Stride to 8 instructions
    - 8 instructions is 16 bytes
    - vector table becomes 256 bytes
    - each vector is basically 
    - something is wrong with how action generates the vector table, there are two xchngmost in a row
    - move code start to 0? we don't seem to be using the pseudo zero page much/at all

- Comprehensive Tests for
    - Assembler

- Particle
    - Fix errors in monitor
    - Monitor needs way to load files
    - Simulator needs way to load files
    - Build tool
    - More than 32 registers?
    - 64 bit Particle
        - Configuration option?
    - Floating Point?
    - XTRA instruction/Coprocessor interface

- Parcore
    - System Bringup (aka the conductor)
        - MR4/Particle/PicoRISCV
        - Loads firmware into cores
        - RTOS?
        - Signing/Security?
    - Proposals:
        - "The Plan"
            1. Architecture Proposal: The Parcore Conductor
            2. Parcore Cluster Performance Optimization Proposal
            3. Parcore Multi-EX & Dynamic Out-of-Order Architecture Proposal
            4. Parcore Tiered Execution Architecture Proposal: Interpreted Cold Paths & Hotspot JIT
            5. Parcore Architecture Proposal 05: Dynamic Code Cache Management, On-Stack Replacement (OSR), and Configurable Software-Assisted MMU
            6. Parcore Architecture Proposal 06: Verification & Golden Trace Co-Simulation Suite
            7. Parcore Architecture Proposal 07: Unified Interrupt Architecture, Real-Time Timer & Inter-Processor Interrupt (IPI) Subsystem
            8. Parcore Architecture Proposal 08: Unified Memory Hierarchy, Multi-Master L1/L2 Cache Coherency, and SDRAM DMA Fabric
            9. Parcore Architecture Proposal 09: Dynamic Multi-ISA Personality Overlays and Runtime Reconfiguration
            10. Parcore Architecture Proposal 10: High-Speed Host Debug Engine, GDB Remote Serial Bridge & Non-Intrusive Trace Architecture
        - Addenda
            1. Architectural Proposal: Autonomous Accelerator & Functional Extension Subsystem in Parcore
            2. Addendum 02: Particle 64-Bit Architecture Extension Proposal

# Things to remember:

# Vector table & Startup
With the exception of Vector 0, which sets up the stack and heap etc, every vector only needs to be 9 instructions long, but if we have a specialized verision of LOAD32 it could be 8:

```
FAST_ENTER_TRAP                                     ; (1) Save all the registers
LOAD_R14_32      _vector_n_handler                  ; (5) Load the vector handler address (this could be 3 if load 16)
JMP              R1, R14                            ; (1) Jump (and link) to the vector handler
FAST_EXIT_TRAP                                      ; (2) Restore registers and return from trap
```

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


## Thoughts 