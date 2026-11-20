; ==============================================================================
; Parcore RV32IM: Core 0 (Instruction Fetch)
; The FTDI console UART is core 3's: guests reach it as memory-mapped I/O.
; Architecture: Particle 32-bit RISC Assembly
; File: firmware/parcore/riscv/core0_if.asm
; ==============================================================================
.include "lib/vectors.inc"

    RESET_SLOT _reset_vector
    TRAP_SLOT_BRANCH 1, _branch_redirect_handler
    TRAP_SLOT_BRANCH 2, _fence_i_handler
    TRAP_SLOT_UNEXPECTED 3
    TRAP_SLOT_UNEXPECTED 4
    TRAP_SLOT_UNEXPECTED 5
    TRAP_SLOT_UNEXPECTED 6
    TRAP_SLOT_UNEXPECTED 7
    TRAP_SLOT_UNEXPECTED 8
    TRAP_SLOT_UNEXPECTED 9
    TRAP_SLOT_UNEXPECTED 10
    TRAP_SLOT_UNEXPECTED 11
    TRAP_SLOT_UNEXPECTED 12
    TRAP_SLOT_UNEXPECTED 13
    TRAP_SLOT_UNEXPECTED 14
    TRAP_SLOT_UNEXPECTED 15
    UNEXPECTED_TRAP_ROUTINE

_reset_vector:
    LOAD16  R10, 0x0500         ; Guest RV32 PC (Base at 0x00000500)
    LD      R1, 1               ; R1 = 1 (Channel 1: Core 1 ID Stage Queue)
    LD      R9, 0               ; R9 = epoch, sent in PC bit 0; flips on every redirect
    LD      R8, 2               ; R8 = 2 (Channel 2: stores mirrored by Core 3, memToIf)
    LD      R11, 0              ; R11 = the mirror entry being applied, 0 when none

; ==============================================================================
; Main Fetch Loop
; ==============================================================================
_if_main_loop:
    ; Apply one mirrored store, if core 3 sent any (FENCE.I coherence)
    FIFO.STAT R4, R8
    AND       R4, 1             ; Bit 0: empty
    FBRA.NZ   R4, ._check_id_space
    FIFO.R    R11, R8
    LOAD16    R14, _apply_mirror
    JMP       R14, R12
    BBRA      _if_main_loop
._check_id_space:
    ; Ensure ifToId FIFO (Channel 1) is not full/near-full before pushing 2 words
    ; (tested in R14, the register with the longer branch form)
    FIFO.STAT R4, R1
    LD        R14, R4
    AND       R14, 2            ; Bit 1: full flag
    BBRA.NZ   R14, _if_main_loop
    LD        R14, R4
    SHIFTR    R14, 15           ; Check if depth[7] (depth >= 128 words) is set
    BBRA.NZ   R14, _if_main_loop

._fetch_instruction:
    ; 2. Fetch 32-bit RV32 Instruction via Port B Word Read
    LD32    R5, (R10)           ; Load full 32-bit instruction into R5

    ; If instruction word is 0 (end of guest code / uninitialized), skip pushing
    FBRA.Z  R5, ._loop_back

    ; 3. Push Fetch Packet to ID Core via FIFO Channel 1 [PC, Instruction]
    LD      R6, R10             ; Original instruction PC
    OR      R6, R9              ; with the epoch in bit 0
    ADD     R10, 4              ; Advance PC pointer
    FIFO.W  R6, R1              ; Word 0: PC
    FIFO.W  R5, R1              ; Word 1: Instruction Word

._loop_back:
    BBRA    _if_main_loop

; ==============================================================================
; Trap 1: Core 2 (EX) Branch Redirection & Pipeline Flush Handler
; Core 2's MBOX lands at vector 1; its slot branches here
; ==============================================================================
_branch_redirect_handler:
    LOAD16  R14, _apply_mirror  ; finish an entry the MBOX interrupted
    JMP     R14, R12
    LOAD16  R14, MBOX_VALUE
    LD32    R10, (R14)          ; Set primary PC pointer to redirect target
    LD      R7, 1
    XOR     R9, R7              ; New epoch: core 2 drops what was sent before
    BBRA    _if_main_loop

; FENCE.I (MBOX vector 2 from core 2): redirect to the instruction after the
; FENCE.I, but first write into the TCM every store core 3 mirrored before it,
; up to its marker. Nothing new reaches core 2 meanwhile, since nothing is
; fetched, so no other MBOX arrives.
_fence_i_handler:
    LOAD16  R14, _apply_mirror  ; finish an entry the MBOX interrupted
    JMP     R14, R12
    LOAD16  R14, MBOX_VALUE
    LD32    R10, (R14)          ; Set primary PC pointer to redirect target
    LD      R7, 1
    XOR     R9, R7              ; New epoch: core 2 drops what was sent before
._fence_drain:
    FIFO.R  R11, R8             ; waits for core 3
    LD      R4, R11
    SHIFTR  R4, 13
    AND     R4, 3
    SUB     R4, 3               ; kind 3: the marker
    FBRA.Z  R4, ._fence_done
    LOAD16  R14, _apply_mirror
    JMP     R14, R12
    BBRA    ._fence_drain
._fence_done:
    LD      R11, 0
    BBRA    _if_main_loop

; Write the mirror entry in R11 into the TCM and set R11 to 0; returns to R12.
; Entry: [31:16] data, [14:13] kind (1 byte, 2 halfword, 3 marker),
; [12:0] address. Does nothing when R11 is 0 or a marker. Writing an entry
; twice is harmless, so a handler can apply one the MBOX interrupted.
_apply_mirror:
    LD      R14, R11
    FBRA.Z  R14, ._apply_done
    LD      R3, R11
    LOAD16  R4, 0x1FFF
    AND     R3, R4              ; R3 = address
    LD      R5, R11
    SHIFTR  R5, 8
    SHIFTR  R5, 8               ; R5 = data
    LD      R4, R11
    SHIFTR  R4, 13
    AND     R4, 3               ; R4 = kind
    SUB     R4, 1
    FBRA.NZ R4, ._apply_half
    ST8     (R3), R5
    FBRA    ._apply_done
._apply_half:
    SUB     R4, 1
    FBRA.NZ R4, ._apply_done    ; the marker: nothing to write
    ST16    (R3), R5
._apply_done:
    LD      R11, 0
    JMP     R12, R0
