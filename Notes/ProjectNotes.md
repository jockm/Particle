# TODO

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