# Log 12 — CAN Stage 1 retrospective: five revisions of clock trouble, and how NewBoard's CAN now compares to OldBoard's

**Date:** 2026-07-14
**Status:** 📖 Retrospective — Stage 1 (CM4 FDCAN loopback) PASSED same day, see Log11.
**Tree:** `NewBoard/Rewrite/MFCB_BASE/CM4/Customer/` (all changes Customer-only)
**Context:** Companion to Log11 (the plan + running bench state). This log tells the
story: what went wrong bringing up FDCAN1 on the MFCB, why each fix was chosen, and a
side-by-side with OldBoard `_8000`'s implementation. Written for future-us starting the
next peripheral bring-up — most of these lessons are not CAN-specific.

---

## 1. What we were building

Port of OldBoard's CAN receive path (Dekimo `can.c` + `Yanmar.c` + `nmea2000.c`,
NMEA2000 @ 250 kbit/s) to NewBoard. Stage 1 scope: FDCAN1 on CM4, internal loopback,
synthetic PGN 127488 frame out and back, byte-perfect. Sounds trivial. Took six builds.

## 2. The struggles, in order

### 2.1 The silent compile-out (missing include)
First flash: no CAN output at all — not even the FAILED branch. Cause: `Customer.c`
called `CAN_Input_Init()` inside `#if CAN_INPUT_ENABLE`, but never included
`can_input.h` where that macro is defined. **In C, an undefined macro in `#if`
silently evaluates to 0** — the whole block vanished from the build with no warning.
**Lesson:** the `RC_SBUS_ENABLE`-style toggle pattern only works because that macro
lives in `Customer.h`, which every caller already includes. A toggle in a module's own
header must be re-included at every call site — or better, put the toggle in
`Customer.h` next time.

### 2.2 The Core/-edit rule (process struggle, caught by user)
The plan originally put `FDCAN1_IT0_IRQHandler` in `CM4/Core/Src/stm32h7xx_it.c`,
mirroring where the UART handlers live. User rejected it: **generated firmware files
are never edited — Customer/ folders only** (now a saved memory rule). Fix that turned
out cleaner anyway: the startup file declares every IRQ handler as a weak alias of
`Default_Handler`, so a strong `FDCAN1_IT0_IRQHandler` defined inside `can_input.c`
overrides it at link time. HAL callbacks (`HAL_FDCAN_RxFifo0Callback`) work the same
way. **Lesson:** there is a Customer-side route for IRQs and callbacks; no Core/ edit
is ever needed for them.

### 2.3 rev.1 — trusting source code about clocks (predicted 156.25 MHz, measured 400)
Bit timing was pre-computed from CM7 `PeriphCommonClock_Config` (HSE 25 MHz → PLL2Q =
156.25 MHz). CP-1a's very first line proved it wrong: **400 MHz**. Loopback frames
still passed — internal loopback is bitrate-independent (TX and RX share one clock), so
without the printed clock readout this would have shipped transmitting at 640 kbit/s.
**Lesson #1: a checkpoint that *measures* beats a checkpoint that *assumes*.**

### 2.4 rev.2 — trusting the config headers about hardware (HSE that doesn't exist)
Fix attempt: pin the FDCAN mux to the "25 MHz HSE crystal" (`HSE_VALUE=25000000` in
hal_conf). Result: `kernel_clk=0`, zero frames — the HAL reports 0 for a non-ready
oscillator. **This board has no running HSE.** Everything runs from HSI 64 MHz, which
retroactively explained rev.1 exactly: PLL2Q = 64/4 ×50 /2 = 400 MHz. The user's
CubeMX screenshots confirmed it: SYSCLK=64 from HSI in the .ioc, HSE box present but
unselected, and — crucially — the supplier's own intended FDCAN clock visible as
53.33 MHz. **Lesson: `HSE_VALUE` is a promise, not a fact; `HSERDY` is the fact.**
Also: the .ioc clock tree and the runtime clock code are two different worlds — the
"SIMPLE FIX" runtime override reprograms PLL2 far away from the CubeMX intent.

### 2.5 rev.3/rev.4 — in-spec source hunting, and the corruption that named itself
rev.3 made timing self-deriving (`can_pick_timing`: measured clock → exact-division
prescaler/segments, fails loudly if no exact 250k divide). Back on PLL2 400 MHz,
frames flowed — but **~20% arrived corrupted at exactly 32-bit-word granularity**:
`word1|word1` and `word1|word0` patterns instead of `word0|word1`. Never byte-noise,
always whole words. That signature ruled the ring out (identical test frames cannot
word-swap by racing — a race between identical data reproduces identical data) and
pointed at the FDCAN message RAM being read across misaligned clock domains: kernel
400 MHz vs APB1 100 MHz (user's own datapoint — CM4 @ 200 MHz → APB = /2). rev.4
added `__DMB()` ring barriers (correctness insurance; changed nothing, as predicted)
and a source picker — which measured **PLL1Q = 800 MHz**: no in-spec mux source exists
on this board at all. **Lesson: corruption patterns are diagnostic data. Word-granular
= bus/RAM domain problem, not logic; and the kernel-clock-≤-APB rule is real, we have
the bench capture to prove it.**

### 2.6 rev.5 — minimal PLL surgery (the fix)
Only lever left: PLL2's Q divider. `can_lower_pll2q()` does the smallest possible
operation — read current Q and measured Q-frequency to infer VCO (800 MHz), PLL2 off,
rewrite **only the Q field** of `PLL2DIVR` (/2 → /16), PLL2 on, timeouts on both
waits. M, N, FRACN, ranges, and the P/R outputs are never written, so the ADC's PLL2P
returns at the identical frequency; the cost is a sub-millisecond PLL2 outage once at
customer-task start (user-approved). Result: kernel = 50 MHz, solver lands on
prescaler 1 / 200 tq / SP 87%, **zero bitrate error, 34/34 frames byte-perfect,
drop=0** (longer soak running). **Lesson: when touching shared clock hardware, change
the one register field you need and preserve everything else from live registers —
don't rebuild the PLL from config structs you now know not to trust.**

## 3. Comparison: OldBoard `_8000` vs what NewBoard now has

| Aspect | OldBoard (`Dekimo_HAL/can/can.c`, H743 single-core) | NewBoard (`CM4/Customer/Src/can_input.c`) |
|---|---|---|
| Bit timing | Hardcoded prescaler lookup (4 → "250k") + fixed Seg1/Seg2, valid only for that board's clock config | Measured kernel clock at every boot + exact-division solver; fails loudly on mismatch; boot print shows clock/prescaler/tq/bitrate |
| Kernel clock | Never questioned (Dekimo board config was internally consistent) | Discovered inconsistent (400/800 MHz sources, no HSE); pinned to PLL2Q lowered to 50 MHz ≤ APB1 |
| RX filter | Standard-ID range 0x000–0x7FF; NMEA2000's 29-bit frames arrive only via the accept-all global filter (back door) | One extended-ID range filter 0x0–0x1FFFFFFF → FIFO0; global filter rejects everything else incl. remote frames |
| RX path | Poll **one** frame per main-loop tick straight off FIFO0 (drop risk at bus load); RX IRQ handler **commented out** in `stm32h7xx_it.c:628` — its debug callback (printf/UART/USB in IRQ context!) never ran, which is the only reason the poll worked | IRQ drains FIFO while fill>0 into a 32-slot lock-free ring (copy-only, Log9 rule, `__DMB()` ordered); task drains the ring; drop counter must stay 0 |
| TX | `FDCAN_STANDARD_ID` hardcoded — could never correctly transmit NMEA2000 | Extended-ID TX header (self-test frame uses it) |
| Message RAM | 64-element RX FIFO configured, mostly unused headroom | 32 RX + 8 TX elements, offset 0 documented (FDCAN2 must get nonzero offset if ever used) |
| Core/ICC | Single core, everything in one loop | CM4 owns FDCAN (matches supplier core-assignment + libops placeholder-init ownership); frames go to CM7 logic over ICC (Stage 2) |
| Public API | `CAN_Init/CAN_SetBitrate/CAN_Send/CAN_Receive` | Same signatures preserved as the CM7 facade (Stage 2) so `Yanmar.c`/`nmea2000.c` port ~verbatim |
| Diagnostics | printf in IRQ (dead code), no counters | Boot status line (clock/source/timing), rx/drop counters, throttled task-context frame prints |

Bottom line: OldBoard's CAN worked because its board never stressed the weak spots —
one consistent clock config, low bus load, and a dead interrupt path hiding the
dangerous debug callback. The port kept its API and its behavior, and fixed the five
latent defects underneath (timing assumptions, filter back door, poll drop risk,
IRQ-context printing, standard-ID TX).

## 4. Transferable checklist for the next peripheral bring-up on MFCB

1. Never trust `main.c` clock code, the `.ioc` tree, or `*_VALUE` macros — **print the
   measured kernel clock first** (`HAL_RCCEx_GetPeriphCLKFreq`), decide second.
2. `#if TOGGLE` without the defining header = silent 0. Grep every call site's includes.
3. IRQ handlers and HAL callbacks belong in Customer files via weak-symbol override —
   Core/ stays untouched, always.
4. Self-test checkpoints must check **data content**, not just counters — the counters
   were perfect while 20% of payloads were garbage.
5. Corruption shape is evidence: word-granular → clock/bus domain; identical-data races
   can't produce differing data.
6. Shared-PLL changes: modify the single divider field from live registers, preserve
   sibling outputs, timeout the ready-waits, get user sign-off (other subsystems hang
   off these clocks).
7. Statistical pass criteria need sample sizes matched to the observed failure rate
   (34 clean frames vs a 1.6% fault ≈ 40% chance of luck — soak longer).
