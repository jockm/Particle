; ==============================================================================
; File: firmware/parcore/conductor/watchdog.inc
; The conductor's supervisor loop, with the watchdog and the pmon console:
; _supervisor_idle (entered with R5 = RST_CTRL once the cores run) and _hang.
; Needs conductor_regs.inc, pmon.inc, FAULT_HANG and _reset_vector.
; WATCH_POLL, WATCH_LIMIT, WATCH_RESTART and WATCH_BLINK can be set with -D
; (tests use small ones).
; ==============================================================================

; The watchdog (Road to GHz item 16, 446-447): every WATCH_POLL cycles the
; supervisor reads ACTIVITY. Once cores 1-3 and the ring have done nothing for
; WATCH_LIMIT polls in a row, and core 0 isn't asleep in its WAIT at the end
; of the program, the pipeline has hung: the conductor says so on the console,
; takes the LEDs back and blinks FAULT_HANG, leaving the cores as they are
; for inspection with pmon (or, with WATCH_RESTART 1, reloads the image and
; restarts them). Cores held in reset (by pmon, say) aren't watched.
.ifndef WATCH_POLL
.define WATCH_POLL          25000   ; 1 ms at 25 MHz
.endif
.ifndef WATCH_LIMIT
.define WATCH_LIMIT         500     ; 0.5 s
.endif
.ifndef WATCH_RESTART
.define WATCH_RESTART       0
.endif
.ifndef WATCH_BLINK
.define WATCH_BLINK         0x4C    ; LED 7 toggles every 0x4C << 16 cycles
.endif                              ; (0.2 s at 25 MHz)
.define WATCH_MASK          0x010E  ; cores 1-3 and the ring

_supervisor_idle:
    ; R5 = RST_CTRL (0xF000_0000); R6 = polls with nothing done;
    ; R11 = the last poll's CYCLES; R13 = pmon's line length
    LD      R6, 0
    LD      R13, 0
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R11, (R14)
    LD      R14, ACTIVITY_OFFSET
    ADD     R14, R5
    LD32    R14, (R14)              ; clear it
    LDI     R2, _str_hello
    RCALL   _con_puts
    RCALL   _pmon_prompt
_watch_loop:
    RCALL   _pmon_poll
    RCALL   _fire1                  ; FIRE1 reloads and restarts
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
    ; Of cores 1-3, only those not held in reset are watched (with the
    ; ring); none: nothing to watch
    LD32    R2, (R5)
    LD      R14, 0x0E
    AND     R2, R14                 ; held, of cores 1-3
    LD      R3, R2
    SUB     R3, R14
    JUMP.Z  R3, ._active
    LDI     R3, WATCH_MASK
    XOR     R3, R2
    AND     R1, R3
    JUMP.NZ R1, ._active
    ; Core 0 asleep in its WAIT: the program has ended, not hung
    LD      R14, CORE_STATE_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    AND     R1, 3
    SUB     R1, 1
    JUMP.Z  R1, ._active
    ADD     R6, 1
    LDI     R3, WATCH_LIMIT
    LD      R1, R6
    SUB     R1, R3
    JUMP.NZ R1, _watch_loop
    JUMP    _hang
._active:
    LD      R6, 0
    JUMP    _watch_loop

; FIRE1 pressed: wait for its release, then reload the image and restart
; the cores; returns if it isn't pressed (uses R1, R2)
_fire1:
    LD      R2, R5
    ADD     R2, 15
    ADD     R2, 15
    ADD     R2, 6                   ; R2 = BUTTONS (0xF000_0024)
    LD32    R1, (R2)
    AND     R1, 1                   ; FIRE1
    FBRA.NZ R1, ._wait_release
    RRET
._wait_release:
    LD32    R1, (R2)
    AND     R1, 1
    BBRA.NZ R1, ._wait_release
    JUMP    _reset_vector

; The watchdog found the pipeline hung (R5 = RST_CTRL)
_hang:
.if WATCH_RESTART
    JUMP    _reset_vector
.else
    ; FAULT_HANG on the LEDs, then the news on the console; then blink LED 7
    ; and keep the console going (R6: LED 7; R11: when it last changed)
    LDI     R6, 0x80
    LD      R1, FAULT_HANG
    OR      R1, R6
    SET_LEDS
    LDI     R2, _str_hang
    RCALL   _con_puts
    RCALL   _pmon_status_text
    RCALL   _pmon_prompt
    LD      R13, 0
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R11, (R14)
._hang_leds:
    LD      R1, FAULT_HANG
    OR      R1, R6
    SET_LEDS
._hang_loop:
    RCALL   _pmon_poll
    RCALL   _fire1
    LD      R14, CYCLES_OFFSET
    ADD     R14, R5
    LD32    R1, (R14)
    LD      R2, R1
    SUB     R2, R11
    SHIFTR  R2, 15
    SHIFTR  R2, 1                   ; >> 16
    LDI     R3, WATCH_BLINK
    SLT     R2, R3
    JUMP.NZ R2, ._hang_loop
    LD      R11, R1
    LDI     R1, 0x80
    XOR     R6, R1                  ; LED 7
    JUMP    ._hang_leds
.endif
