# TODO

- Rename hdl/rohd to hdl/particle

- Comprehensive Tests for
    - Assembler
    - Compiler
    - RISC-V 
    - Make sure spec is correct

- Particle
    - > 3 stage pipeline?
    - Fix error in monitor
    - Monitor needs way to load files
    - Simulator needs way to load files
    - Build tool
    - More than 32 registers?
    - 64 bit Particle
        - Configuration option?
    - Floating Point?
    - XTRA instruction/Coprocessor interface

- Parcore
    - System Bringup
        - MR4/Particle/PicoRISCV
        - Loads firmware into cores
        - RTOS?
        - Signing/Security?
    - Superscsalar 
    - Out of order
    - JIT

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