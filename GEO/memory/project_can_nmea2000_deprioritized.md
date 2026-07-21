---
name: project-can-nmea2000-deprioritized
description: CAN/NMEA2000/Yanmar slice moved to lowest priority in the NewBoard port backlog (2026-07-15)
metadata:
  type: project
---

**2026-07-15 user decision:** CAN / NMEA2000 / Yanmar engine feedback is now the **lowest
priority** item in the OldBoard(_8000) → NewBoard `Rewrite/MFCB_BASE` conversion backlog —
moved to the bottom, below Pololu steering and VP/BR engine types.

**Why it matters:** Log10 (2026-07-14) originally ranked CAN #1 ("biggest remaining slice").
Log11/Log12 (same day) did Stage 1 (CM4 FDCAN loopback) and got it bench-passing after a
multi-revision clock saga. That work is **not wasted** — Stage 1 stays done/passing — but
**Stage 2 onward (ICC forward to CM7, NMEA2000/Yanmar protocol port, real-bus test) should
not be picked up next** unless the user explicitly asks for it again.

**Current priority order (see `.cursor/Logs/Log10-Remaining-conversion-roadmap.md` for the
authoritative, updated list):**
1. ✅ SBUS pass-through to AP (UART6 TX passthrough) — done + bench-verified, `rc_sbus_old.c`
   (Log13)
2. ✅ AP_IMS PWM input (throttle/steering feedback from AP) — done + bench-verified,
   `tools.c` via native `pwm_in_ctrl()`, Rising-edge capture (Log13)
3. Heartbeat master/slave redundancy — **next up**
4. Steering output to Pololu
5. Other engine types (VP, BR)
6. Probably skippable (Modbus TCP, AP_DOcn, USB-CDC debug)
7. **CAN / NMEA2000 / Yanmar — lowest priority** (Stage 1 done; Stage 2+ parked)

**How to apply:** Don't propose continuing CAN Stage 2+ as "the next logical step" — treat it
as parked/backlog. If the user later says "let's pick CAN back up," resume from Log11 Stage 2
(ICC transport CM4→CM7), not from scratch.
