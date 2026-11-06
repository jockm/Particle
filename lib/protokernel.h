/*
 * Copyright (c) 2026 Jock Murphy (Particle / Parcore Project)
 * Copyright (c) 2004-2005, Swedish Institute of Computer Science.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notices, this list of conditions, and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notices, this list of conditions, and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the Institute nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 * -----------------------------------------------------------------------------
 * Attribution & Credits:
 * - Original Protothreads Architecture & Design: Adam Dunkels <adam@sics.se>
 * - ProtoKernel ACT16 / Particle Architecture: Jock Murphy
 * -----------------------------------------------------------------------------
 */

#ifndef _PROTOKERNEL_H_
#define _PROTOKERNEL_H_

#define PK_WAITING   0
#define PK_YIELDED   1
#define PK_EXITED    2
#define PK_ENDED     3

struct pt {
    u16 lc;
};

#define PK_INIT(p) (p)->lc = 0
#define PK_SCHEDULE(call_expr) ((call_expr) < PK_EXITED)

#define PK_BEGIN(p) switch ((p)->lc) { case 0:
#define PK_YIELD(p, s) (p)->lc = s; return PK_YIELDED; case s:
#define PK_WAIT_UNTIL(p, s, cond) (p)->lc = s; case s: if (!(cond)) return PK_WAITING;
#define PK_EXIT(p) (p)->lc = 0; return PK_EXITED;
#define PK_RESTART(p) (p)->lc = 0
#define PK_END(p) } (p)->lc = 0; return PK_ENDED;

#endif /* _PROTOKERNEL_H_ */
