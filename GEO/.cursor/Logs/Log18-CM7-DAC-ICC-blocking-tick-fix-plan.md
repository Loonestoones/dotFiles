# Log 18 — CM7 slow tick: DAC `dac_ctrl` ICC blocking (confirmed) + fix plan

**Date:** 2026-07-17  
**Status:** 🔧 **Volts-on-wire v2 (2026-07-20)** — CM7 `prepareDACValue` + ICC µV; CM4 `MotorDac_ClampVoltageUv` + `dac_ctrl`. Flash both cores. Signed µs clamp fixes reverse→3 V class. Guideline (not hard rule): `cm7-process-cm4-io-guideline.mdc`.  
**Tree:** `NewBoard/Rewrite/MFCB_BASE`  
**Related:** Log8 (DAC from CM7 works, latency left open), Log7 (ICC WITH_ID / CM7→CM4), Log14 §5.1 Bug #4, Log15 §1.1, Log17 (HB period tracked slow tick)

---

## 0.5 Stage — CM4 local DAC bench (2026-07-20) ✅ coded

Prove CM4 `dac_ctrl` (SPI) before Stage 1 ICC. No CM7 involvement.

| Item | Detail |
|---|---|
| Gate | `MOTOR_DAC_BENCH_ENABLE` (default **1**) in `CM4/Customer/Inc/motor_dac_bench.h` — **set 0 after pass** |
| Files | `Src/motor_dac_bench.c`, hook in `Customer.c` |
| Cycle | Every 2 s: 1500 → 1650 → 1500 → 1350 µs (both AO1/AO2) |
| Math | Same `prepareDACValue` as CM7 (~1.72 V mid) |
| UART1 | `[CM4 DAC BENCH] us=… V~…` on each step change |

**CP-0.5:** Meter on AO1/AO2 steps with UART prints; no dependence on CM7 tick.

---

## 1. Confirmed root cause

CM7 `GEO_ApplicationTask_Update()` called **`WriteMotorDAC` → `dac_ctrl(DAC_OP_OUTPUT_VOLTAGE)` twice per tick** (CH_A + CH_B) while `systemActive == 1`.

On CM7, `libops` implements that path as:

1. `ICC_SendPacket_WITH_ID` on `IC_CH_DAC_MAINPRINT`
2. `ICC_WaitForResponse` → `osSemaphoreAcquire(..., 1000 ms)` until CM4 SPI server replies

Each round-trip measured in the hundreds of ms under load; **two calls dominated the whole Customer tick**.

| Configuration | `[CM7 UPDATE]` delta for 10 calls | ≈ period |
|---|---|---|
| Both `WriteMotorDAC` active | ~2400–4000 ms | ~240–400 ms |
| Both `WriteMotorDAC` commented out | ~50 ms | **~5 ms** |

Loop delay (`CUSTOMER_TASK_LOOP_DELAY_MS = 10`) and tick rate (1000 Hz) are fine. With DAC removed, the task often runs **faster** than 10 ms because `osThreadFlagsWait` also wakes on SBUS ICC flags.

**Not the cause:** dashboard `network_send` (500 ms throttle), heartbeat GPIO (CM7 local HAL), steering `ICC_SendPacket_NO_ID`, PWM IN FETCH (SRAM4), CM7 task priority alone.

**Current bench state (2026-07-17):** both `WriteMotorDAC` lines temporarily commented in `GEO-application-task.c` for the A/B test — **motors not driven until restored via the fix below**.

---

## 2. Suggested fix (preferred)

**Move DAC apply to CM4; CM7 only publishes motor pulse commands over Customer ICC (NO_ID), same shape as steering.**

Rationale:

- CM4 owns SPI2 / DAC chip (dual-core rule).
- `dac_ctrl` on CM4 is local SPI — no `ICC_WaitForResponse` on the control loop.
- Pattern already proven: CM7→CM4 steering tag → CM4 Pololu (Log14).
- CM7 tick stays ~5–10 ms; DAC update rate is chosen on CM4 (e.g. every 2–20 ms).

### Wire format (proposal)

Extend existing tagged Customer ICC (keep CM4/CM7 `cust_icc.h` identical):

| Field | Value |
|---|---|
| Tag | `CUST_ICC_TAG_MOTOR_DAC` (e.g. `0x03`) — new |
| Payload | `right_us`, `left_us` (`uint16_t`, 1000–2000, 1500 = stop) + optional `active` / version |
| Framing | Same hdr as SBUS/steer (`cust_icc_hdr_t`) |
| Transport | `ICC_SendPacket_NO_ID(IC_CH_CUSTOMER, …)` from CM7 — **no wait** |
| CM4 apply | `WriteMotorDAC` / `dac_ctrl` locally after parse (reuse `tools.c` helpers or thin CM4 copy of `prepareDACValue` + `dac_ctrl`) |

Staleness: if no motor packet for N ms → force mid / safe DAC (mirror steer fail-safe).

### Where code lives

| Side | Change |
|---|---|
| CM7 `GEO-application-task.c` | Remove blocking `WriteMotorDAC`; after state switch, pack+send motor ICC (with steer, or immediately before/after) |
| CM7 `tools.c` | Keep `prepareDACValue` / `WriteMotorDAC` **or** move apply-only helpers to CM4; CM7 may keep voltage math only if still needed for debug |
| CM4 `Customer.c` | Poll motor tag (same `Customer_Icc_GetPacket` / mailbox path as steer); call local `dac_ctrl` |
| Both `cust_icc.h` | New tag + payload struct + max-age constant; document in Log15 |

### Rates (update Log15 when implemented)

| Path | Suggested rate |
|---|---|
| CM7 send motor cmd | Every CM7 tick (~5–10 ms) — cheap NO_ID |
| CM4 DAC apply | Every packet or throttle 10–20 ms if SPI load matters |
| Steer ICC age timeout | Can tighten from 500 ms toward ~150 ms once CM7 tick is healthy |

---

## 3. Alternative fixes (if preferred path delayed)

| Option | Pros | Cons |
|---|---|---|
| **A. Change-only on CM7** — call `dac_ctrl` only when µs value changes | Tiny diff | Still stalls CM7 for ~200–400 ms on every stick movement |
| **B. Throttle on CM7** — e.g. DAC at most every 50–100 ms | Simple | Periodic multi‑hundred‑ms hitches remain |
| **C. Fire-and-forget DAC** | Ideal if library supported it from Customer | CURRENT `dac_ctrl` always WITH_ID + wait on CM7 — not selectable from app |

Use A/B only as a short interim; **do not treat as the end state**.

---

## 4. Phased plan

### Stage 0 — Record + restore safety ✅

- Root cause written (Log15 §1.1, rule, this log). Log19 ICC inventory created.

### Stage 1a — ICC motor command print-only (2026-07-20) ✅ bench pass

1. ✅ Tag `0x03`, CM7 NO_ID send, CM4 per-tag print — delta ~50–100 ms / 10 calls; ICC values OK.

### Stage 1b — CM4 local `dac_ctrl` apply (2026-07-20) ✅ coded — bench open

1. ✅ `CM4/Customer/Src/motor_dac_output.c` — `MotorDac_Service()` change-only + mid once on enter-stale.
2. ✅ Wired from `Customer.c` after motor ICC take; age vs `CUST_ICC_MOTOR_DAC_MAX_AGE_MS` (100 ms).
3. ⚠️ **Build trap (2026-07-20):** Cube `Debug/Customer/Src/subdir.mk` omitted `motor_dac_output.c` — flashed ELF stayed Stage **1a** (print-only). AO stuck ~1.24 V = leftover Stage 0.5 bench; UART sticks still printed. Fix: ensure `motor_dac_output.c` is in the build, Clean+Build CM4, confirm boot banner `Stage 1b: motor ICC → local dac_ctrl`.
4. **CP-1a:** `[CM7 UPDATE]` delta stays ~50–100 ms / 10 calls with AO live.
5. **CP-1b:** AO1/AO2 track RC/ROC (scope/meter); UART still prints `[CM4 MOTOR ICC]`.
6. **CP-1c:** Stop / stale → mid (~1.70 V).

### Stage 2 — Timing cleanup

1. Re-measure steer `last_rx` cadence (expect ~5–20 ms).
2. Tighten `CUST_ICC_STEER_MAX_AGE_MS` if bench allows (Log15).
3. Re-check Log17 heartbeat: master toggle should approach 100 ms / 200 ms full period.
4. Remove temporary `[CM7 UPDATE]` spam (or gate behind `GEO_DEBUG_ENABLE`).

### Stage 3 — Optional polish

- Throttle CM4 DAC apply if needed.
- Change-only on CM4 to cut SPI traffic.
- Document final rates in Log15.

---

## 5. Checkpoints / pass criteria

| ID | Pass |
|---|---|
| CP-0 | DAC commented → delta ≈ 50 ms / 10 calls (already seen 2026-07-17) |
| CP-1a | DAC live via CM4 path → delta still ≈ 50–150 ms / 10 calls |
| CP-1b | Right/left motor voltages follow commands |
| CP-1c | Fail-safe mid on stop/stale |
| CP-2 | Steering ICC age typically ≪ 500 ms; HB period sane |

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| `IC_CH_CUSTOMER` slot overwrite (steer vs motor vs SBUS) | Tagged mailbox already on CM7 for SBUS; CM4 single slot — **drain/parse by tag each poll**, or dual latest-value slots per tag (prefer per-tag latest like CM7 mailbox) |
| CM4 loop busy → DAC lag | Apply DAC every 2 ms loop iteration; SPI is fast vs UART Pololu |
| Duplicate `prepareDACValue` on two cores | One shared math in a small `.c` built on both, or CM7 sends already-scaled µV (heavier payload) |

---

## 7. Out of scope

- Changing `libops.a` / making `dac_ctrl` fire-and-forget on CM7  
- Moving sailing state machine off CM7  
- NEWER-build SBUS translator (unrelated)

---

## 8. Decision

| # | Question | Answer |
|---|---|---|
| 1 | End-state DAC owner? | **CM4** (local `dac_ctrl`) |
| 2 | CM7 role? | Publish `right`/`left` µs via Customer ICC NO_ID |
| 3 | Interim CM7 throttle/change-only? | Only if Stage 1 slips; not the goal |
| 4 | Keep `[CM7 UPDATE]` print? | Until CP-1a, then debug-gate or remove |
