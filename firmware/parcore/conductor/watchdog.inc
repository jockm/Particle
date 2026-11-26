; ==============================================================================
; File: firmware/parcore/conductor/watchdog.inc
; The conductor's supervisor loop, with the watchdog: _supervisor_idle (entered
; with R5 = RST_CTRL once the cores run) and _hang. Needs conductor_regs.inc,
; FAULT_HANG, _reset_vector and _fault_delay. WATCH_POLL, WATCH_LIMIT and
; WATCH_RESTART can be set with -D (tests use small ones).
; ==============================================================================

; The watchdog (Road to GHz item 16, 446-447): every WATCH_POLL cycles the
; supervisor reads ACTIVITY. Once cores 1-3 and the ring have done nothing for
; WATCH_LIMIT polls in a row, and core 0 isn't asleep in its WAIT at the end
; of the program, the pipeline has hung: the conductor takes the LEDs back
; and blinks FAULT_HANG, leaving the cores as they are (or, with
; WATCH_RESTART 1, reloads the image and restarts them).
.ifndef WATCH_POLL
.define WATCH_POLL          25000   ; 1 ms at 25 MHz
.endif
.ifndef WATCH_LIMIT
.define WATCH_LIMIT         500     ; 0.5 s
.endif
.ifndef WATCH_RESTART
.define WATCH_RESTART       0
.endif
.define WATCH_MASK          0x010E  ; cores 1-3 and the ring

_supervisor_idle:
    ; R5 = RST_CTRL (0xF000_0000); R6 = polls with nothing done;
    ; R11 = the last poll's CYCLES
    LD      R6, 0
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R11, (R14)
    LD      R14, ACTIVITY_OFFSET
    ADD     R14, R5
    LD32    R14, (R14)              ; clear it
_watch_loop:
    ; FIRE1 reloads the image and restarts the cores
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 6                   ; R2 = BUTTONS (0xF000_0024)
    LD32    R1, (R2)
    AND     R1, 1                   ; FIRE1
    FBRA.Z  R1, ._no_fire
._wait_release:
    LD32    R1, (R2)
    AND     R1, 1
    BBRA.NZ R1, ._wait_release
    JUMP    _reset_vector
._no_fire:
    ; A poll every WATCH_POLL cycles
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    LD      R2, R1
    SUB     R2, R11
    LDI     R3, WATCH_POLL
    SLT     R2, R3                  ; 1 while too early
    JUMP.NZ R2, _watch_loop
    LD      R11, R1
    LD      R14, ACTIVITY_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)               ; and clears it
    LDI     R3, WATCH_MASK
    AND     R1, R3
    JUMP.NZ R1, ._active
    ; Core 0 asleep in its WAIT: the program has ended, not hung
    LD      R14, CORE_STATE_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    AND     R1, 3
    SUB     R1, 1
    FBRA.Z  R1, ._active
    ADD     R6, 1
    LDI     R3, WATCH_LIMIT
    LD      R1, R6
    SUB     R1, R3
    JUMP.NZ R1, _watch_loop
    JUMP    _hang
._active:
    LD      R6, 0
    JUMP    _watch_loop

; The watchdog found the pipeline hung (R5 = RST_CTRL)
_hang:
.if WATCH_RESTART
    JUMP    _reset_vector
.else
._hang_blink:
    LDI     R1, 0x80 + FAULT_HANG   ; the code, with LED 7 on
    SET_LEDS
    RCALL   _fault_delay
    LD      R1, FAULT_HANG
    SET_LEDS
    RCALL   _fault_delay
    ; FIRE1 reloads the image and restarts the cores
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 6                   ; R2 = BUTTONS
    LD32    R1, (R2)
    AND     R1, 1
    JUMP.Z  R1, ._hang_blink
    JUMP    _reset_vector
.endif
