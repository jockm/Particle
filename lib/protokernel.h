// =============================================================================
// File: lib/protokernel.h
// Description: Stackless Cooperative Protothreads for Action / Particle
// Attribution & Lineage:
// - Original Protothreads Architecture & Design: Adam Dunkels <adam@sics.se>
// - ProtoKernel Action / Particle Architecture: Jock Murphy
// =============================================================================

#ifndef _PROTOKERNEL_H_
#define _PROTOKERNEL_H_

const u16 PK_WAITING = 0;
const u16 PK_YIELDED = 1;
const u16 PK_EXITED  = 2;
const u16 PK_ENDED   = 3;

type pt {
    u16 lc;
};

// Inline lifecycle initializer
inline void pk_init(type pt p) {
    p.lc = 0;
}

#endif // _PROTOKERNEL_H_
