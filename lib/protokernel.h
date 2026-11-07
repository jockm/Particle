// =============================================================================
// File: lib/protokernel.h
// Description: Stackless Cooperative Protothreads for ACT16 / Particle
// Attribution & Lineage:
// - Original Protothreads Architecture & Design: Adam Dunkels <adam@sics.se>
// - ProtoKernel ACT16 / Particle Architecture: Jock Murphy
// =============================================================================

#ifndef _PROTOKERNEL_H_
#define _PROTOKERNEL_H_

#define PK_WAITING   0
#define PK_YIELDED   1
#define PK_EXITED    2
#define PK_ENDED     3

type pt {
    u16 lc;
};

#define PK_INIT(p)        (p.lc = 0)
#define PK_SCHEDULE(expr) ((expr) < PK_EXITED)

#define PK_BEGIN(p)       switch (p.lc) { case 0:
#define PK_YIELD(p, s)    p.lc = s; return PK_YIELDED; case s:
#define PK_WAIT_UNTIL(p, s, cond) p.lc = s; case s: if (!(cond)) return PK_WAITING;
#define PK_EXIT(p)        p.lc = 0; return PK_EXITED;
#define PK_RESTART(p)     (p.lc = 0)
#define PK_END(p)         } p.lc = 0; return PK_ENDED;

#endif // _PROTOKERNEL_H_
