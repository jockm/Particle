; HALT: the core stops there for good (in psim the run ends), with the
; registers as they were; the instructions after it never run. WAIT needs an
; MBOX from another core, so it is checked in cpu_core_test.dart and psim's
; cluster test wait_halt.
.include "lib/vectors.inc"
    VECTOR_TABLE _start
_start:
    LD      R1, 5
    LD      R2, 7
    ADD     R1, R2
    HALT
    LD      R1, 15          ; never runs
    LD      R3, 15
_halt:
    BBRA    _halt
