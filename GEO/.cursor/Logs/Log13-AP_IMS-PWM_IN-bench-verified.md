# Log 13 — AP_IMS PWM IN bench-verified: `fetch_uart_fast` bug + capture-edge selection

**Date:** 2026-07-15
**Status:** ✅ Bench-verified on hardware — AP_IMS mode reads live throttle/steer from the AP.
**Tree:** `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Src/tools.c` (+ `Inc/tools.h`,
`Src/GEO-application-task.c`, `Src/GEO-debug.c` / `Inc/GEO-debug.h`)
**Context:** Phase 3 of the OldBoard(_8000) → NewBoard port. Item #2 from
Log10's backlog — AP_IMS mode's PWM IN1 (throttle) / IN2 (steering) capture from the
autopilot. Code already existed (`ProcessAP_IMS()` using the native `pwm_in_ctrl()` API,
not a hand-rolled TIM port like OldBoard's Dekimo `PWM_input.c`) but was unverified and, it
turned out, buggy.
**Related:** Log10-Remaining-conversion-roadmap.md (item #2),
Log6-OPS-function-inventory.md, Log4-SBUS-UART6-7-working-implementation.md (UART6 TX
passthrough to AP, same session's item #1, also bench-confirmed working alongside this)

---

## 1. Bug found: `PWMVALUE1`/`PWMVALUE2` frozen despite live signal on the wire

Added a throttled UART1 debug print (`PWM_IN_DebugPrint()`, `GEO-debug.c`) that fetches PWM
IN1/IN2 directly via `pwm_in_ctrl(PWM_IN_OP_FETCH)` independent of `ProcessAP_IMS()`. This
showed `valid=1` and live, moving `hz`/`duty`/`pulse_high_us` the whole time — but
`ProcessAP_IMS()`'s own `PWMVALUE1`/`PWMVALUE2` outputs stayed pinned at their startup
defaults.

**Root cause:** `ProcessAP_IMS()`'s fetch requests had `req.fetch_uart_fast = true` set.
That flag routes the driver down a different (debug/raw) path that does **not** populate
`req.task_running` — and `ProcessAP_IMS()`'s logic gated the `PWMVALUE1/2` update on
`task_running` being true, matching the normal "web read" path convention used elsewhere in
this driver. With `fetch_uart_fast = true`, `task_running` stayed false forever, so the
gate never opened and the values never propagated even though the underlying capture was
working correctly the whole time.

**Fix:** removed `req.fetch_uart_fast = true;` from both PWM IN1 and IN2 fetch calls in
`ProcessAP_IMS()`, leaving the request on the normal path (`task_running` now populated).
`PWMVALUE1`/`PWMVALUE2` immediately started tracking the AP signal.

`PWM_IN_DebugPrint()` (the standalone debug print) intentionally still uses
`fetch_uart_fast = true` and therefore always prints `run=0` — that's expected/cosmetic for
that debug path and does not indicate a fault; `valid=1` plus moving `hz`/`duty`/`pulse_high_us`
is the actual health signal there.

## 2. Capture-edge selection: factory "Both edges" was flaky on IN2

With values now propagating, IN2 (steering) intermittently reported invalid samples / wide
pulse excursions under the factory/EEPROM default `PWM_INPUT_FACTORY_CAPTURE_EDGE` = "Both
edges". Confirmed **not** a wiring or AP-source fault: swapping the two AP signal wires kept
the fault on the IN2 *connector*, not following the source signal.

Bench-compared all three capture-edge modes on the real AP signal (~1.1–1.9 ms active-high
pulse / ~18.5 ms low, 50 Hz frame rate):

| Mode | Stability | Correctness |
|---|---|---|
| **Both edges** (factory default) | IN2 (and occasionally IN1) intermittently dropped to invalid/garbage samples | When valid, read the right ~1.5ms segment |
| **Falling** | Rock solid, zero dropouts on either channel | **Wrong** — reported ~18.4ms (the long **low** time), not the ~1.5ms pulse, because the signal is active-high and Falling anchors on the wrong edge for this driver's window convention |
| **Rising** | Rock solid, zero dropouts on either channel | **Correct** — reports the short high-time segment, tracks AP stick movement 1-for-1 |

**Why "Both edges" is less robust:** it resets/restarts the capture window on every
transition, so consecutive samples are alternating half-cycles (short-then-long-then-short…)
rather than one consistent edge-to-edge window — inherently more sensitive to timing jitter
than anchoring on a single reference edge.

**Selected: Rising edge**, forced at runtime (see §3).

### Wire-value doc-drift caught along the way

`pwm_input_config.h`'s own inline comment for the capture-edge field ("0=disabled,1=rising,
2=falling,3=both") is **wrong/stale**. Verified against the compiled library itself
(`strings` on `libops.a`): the shipped `Page_pwm_inputs` HTML `<select>` uses `value=0`
Rising, `value=1` Falling, `value=2` Both — the only reading consistent with
`PWM_INPUT_FACTORY_CAPTURE_EDGE=2` actually being "Both edges" (matches the live web page).
Used this (0/1/2, no "disabled" state) for `PWM_IN_ForceRisingEdge()`. Don't trust the
header comment if this needs revisiting later.

## 3. Runtime override: `PWM_IN_ForceRisingEdge()`

Added to `CM7/Customer/Src/tools.c` (declared in `Inc/tools.h`), called once from
`GEO_ApplicationTask_Init()` (`GEO-application-task.c`) — same "always override in code,
regardless of EEPROM" pattern already used for UART6 SBUS config in `rc_sbus_old.c`:

- Loads the live EEPROM config for PWM IN1/IN2 first (preserves alias/ranges/filter as set
  on the web page), falling back to factory defaults if EEPROM is unreadable.
- Overrides only the capture-edge field to Rising (`0u`).
- Applies via `pwm_in_ctrl(PWM_IN_OP_APPLY)` — **RAM only, not saved to EEPROM**. The web
  page will keep showing "Both edges" until someone explicitly Saves it there, but this call
  wins at runtime and re-applies every CM7 boot.

## 4. Result

Bench log (UART1, `PWM_IN_DebugPrint`, Rising edge active):

```
[CM7 PWM_IN] IN1(throttle) ok=1 run=0 valid=1 hz=50 duty=7% pulse=1496us | IN2(steer) ok=1 run=0 valid=1 hz=50 duty=7% pulse=1496us
```

Stable, correct, zero dropouts on both channels, tracking real AP stick movement. AP_IMS
mode (`ProcessAP_IMS()` → `PWMVALUE1`/`PWMVALUE2`) confirmed working end-to-end.

## Cross-references

- `.cursor/Logs/Log10-Remaining-conversion-roadmap.md` — backlog item #2, now closed
- `.cursor/Logs/Log6-OPS-function-inventory.md` — `pwm_in_ctrl` API inventory
- `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Src/tools.c` — `ProcessAP_IMS()`,
  `PWM_IN_ForceRisingEdge()`
- `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Src/GEO-debug.c` — `PWM_IN_DebugPrint()`
- `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Src/GEO-application-task.c` —
  `GEO_ApplicationTask_Init()` call site
- `NewBoard/Rewrite/MFCB_BASE/CM7/OPS_Lib/include/.../pwm_input_config.h` — stale capture-edge
  doc comment (see §2)
