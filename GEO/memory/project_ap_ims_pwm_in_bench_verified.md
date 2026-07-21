---
name: project-ap-ims-pwm-in-bench-verified
description: AP_IMS PWM IN (throttle/steer capture from autopilot) bench-verified on hardware, 2026-07-15 — Rising edge selected
metadata:
  type: project
---

**2026-07-15:** AP_IMS mode is now **bench-verified on hardware**, alongside SBUS
pass-through to the autopilot (UART6 TX mirror, `rc_sbus_old.c`). Full writeup:
`.cursor/Logs/Log13-AP_IMS-PWM_IN-bench-verified.md`.

**What was fixed:** `ProcessAP_IMS()` (`CM7/Customer/Src/tools.c`) had
`req.fetch_uart_fast = true` on its PWM IN1/IN2 fetch calls, which routes `pwm_in_ctrl()`
down a path that never populates `req.task_running` — the gate `ProcessAP_IMS()` used before
updating `PWMVALUE1`/`PWMVALUE2`. Removing that flag let live values propagate.

**What was decided:** PWM IN1/IN2 capture edge is forced to **Rising** at runtime (RAM
only, re-applied every CM7 boot) via `PWM_IN_ForceRisingEdge()`, called once from
`GEO_ApplicationTask_Init()`. Bench-compared all three modes on the real AP signal
(~1.5ms active-high pulse, 50Hz):
- Both edges (factory/EEPROM default) — intermittently flaky on IN2 (confirmed not a wiring
  issue).
- Falling — stable but measures the wrong half-cycle (~18.4ms low time, not the pulse).
- **Rising — stable and correct.** Selected.

**Doc-drift note:** `pwm_input_config.h`'s inline comment for capture-edge values
("0=disabled,1=rising,2=falling,3=both") is wrong. Verified via `strings` on `libops.a`
(web UI HTML): **0=Rising, 1=Falling, 2=Both**.

**How to apply:** AP_IMS / PWM IN is done — don't propose re-investigating the capture-edge
choice or the `fetch_uart_fast` path unless new symptoms appear. If capture edge ever needs
changing again, edit `PWM_IN_ForceRisingEdge()` in `tools.c` (rename to match) — see Log13
for the full edge-mode comparison before changing it.

See also `memory/project_can_nmea2000_deprioritized.md` for the updated backlog order (this
item and SBUS pass-through are now closed; heartbeat redundancy is next).
