#ifndef _PROTOKERNEL_H_
#define _PROTOKERNEL_H_

// Lifecycle constants
const u16 PK_WAITING = 0;
const u16 PK_YIELDED = 1;
const u16 PK_EXITED  = 2;
const u16 PK_ENDED   = 3;

// Minimal Continuation Control Block
type pt {
    u16 lc;
};

// Function type for task coroutines
type TaskFn = fn(pt) -> u16;

// Type-bound initialization method
inline void pt.init(pt self) {
    self.lc = 0;
}

// Scheduling predicate
inline u16 pk_schedule(u16 status) {
    return status < PK_EXITED;
}

#endif
