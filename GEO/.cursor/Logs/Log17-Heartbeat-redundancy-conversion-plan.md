# Log 17 — Master/slave heartbeat redundancy: conversion plan (OldBoard → NewBoard)

**Date:** 2026-07-17  
**Status:** ⏸ **Paused 2026-07-17 after CP-0.** Master HB works but edge rate tracks slow CM7
`GEO_ApplicationTask_Update` (~1.5 s square period ≈ ~750 ms/tick this session; see also Log14/Log15
~200 ms issue). User will fix CM7 loop rate in a **new chat** before slave CP-1 / Stage 2–3.  
**Tree:** `NewBoard/Rewrite/MFCB_BASE` (target), `OPS_ZF/` / `OldBoard/` (identical source behaviour)  
**Context:** Closes Log10 §2 item 3 (“Heartbeat master/slave redundancy”). This is **board-to-board**
hot-backup GPIO, not CM4↔CM7 liveness (that is already `IC_CH_WATCHDOG` — see Log7 §7).  
**Related:** Log7 §7 (state-vs-event / do not put this on `IC_CH_CUSTOMER`), Log8 (DAC),
Log10 (roadmap), Log14 (steering ICC — also must respect `systemActive`),
`how_to_use_core_assignment.txt` (GPIO API CM4-owned, callable from CM7),
`how_to_use_peripherals_and_devices_mechanism.txt` (`GPIO_Init` + `gpio_*_by_port_pin`).

### Decision update 2026-07-17 — only GPIO1 / GPIO2 on this board

User confirmed MFCB general-purpose connector GPIOs are **GPIO1 and GPIO2 only**
(matches CURRENT `BLOCK_GPIO1` / `BLOCK_GPIO2`). OldBoard’s “GPIO5 = PE13” name does not
apply as a connector index here.

| Choice | Value |
|---|---|
| Heartbeat pin | **`GPIO1`** (`HEARTBEAT_BOARD_PIN`) |
| Free | **GPIO2** |
| Role v1 | Hardcoded `ModuleRole = master` in `tools.c` — set to `slave` for standby flash |

**Code touched (Stage 0/1):**
- `CM7/Customer/Inc/tools.h` — board-pin macros; `Heartbeat_Init` decl
- `CM7/Customer/Src/tools.c` — init / send / check + Stage 0 port/pin UART print
- `CM7/Customer/Src/GEO-application-task.c` — init + end-of-tick send/check
- `CM7/Customer/Inc/GEO-debug.h` + `Src/GEO-debug.c` — `Heartbeat_DebugPrint` (~1 Hz)

**Bench next:** flash master → confirm UART1 `[CM7 HB] GPIO1(HB) -> P…` and pin toggles /
`[CM7 HB] role=master active=1 pin=0/1`. Then flash `ModuleRole=slave` for timeout test (CP-1).

---

## 0. Starting point (what was true before Stage 0/1)

### Source behaviour (OPS_ZF == OldBoard)

| Item | Value |
|---|---|
| Pin | **GPIO5 = PE13** (`HEARTBEAT_PORT`/`HEARTBEAT_PIN` in `ops-tools.h`) |
| Master period | Toggle every **`HEARTBEAT_MS` = 100** |
| Slave timeout | No edge for **`HEARTBEAT_TIMOUT_MS` = 1000** → `systemActive = 1` |
| Master | `systemActive = 1` always; calls `SendHeartbeat()` |
| Slave | Starts `systemActive = 0`; calls `checkHeartbeat()` |
| Effect | DAC motor writes only when `systemActive` (ZF path) |
| Role select | Hardcoded `ModuleRole = master` in `ops-tools.c` |

Cube MX on OldBoard/OPS_ZF configures PE13 as **INPUT** for everyone, yet master still
`HAL_GPIO_WritePin`s it. On STM32 that does **not** drive the pad. Treat as a source bug /
incomplete bring-up: NewBoard must init **master = output**, **slave = input**.

### NewBoard Rewrite today

| Item | State |
|---|---|
| `systemActive` | Hardcoded **`1`** in `CM7/Customer/Src/tools.c` (“not ported yet”) |
| `ModuleRole` | Hardcoded **`master`** |
| `SendHeartbeat` / `checkHeartbeat` | Declared in `tools.h`, **not implemented** |
| DAC gate | `if (systemActive)` already wraps `WriteMotorDAC` in `GEO-application-task.c` |
| Steering ICC | Sent **unconditionally** after the DAC block (Log14 path) — standby slave would still command Pololu |
| Constants | `HEARTBEAT_*` still name raw `GPIOE` / `PIN_13` in `tools.h` — replace with board pin API |

### What this is *not*

- **Not** OPS software watchdog / `IC_CH_WATCHDOG` (dual-core ping).
- **Not** an ICC message between CM4 and CM7 for the heartbeat itself (Log7: inter-board GPIO).
- **Not** NEWER-only — CURRENT `gpio.h` / `gpio_functions.h` is enough.
- **Not** EEPROM `BLOCK_GPIO5` — CURRENT `settings_location.h` only has `BLOCK_GPIO1` /
  `BLOCK_GPIO2` (+ PWM GPIO blocks). Hardcode pin init in Customer (same spirit as SBUS
  UART hardcode on CURRENT).

---

## 1. Decisions (lock before coding)

| # | Question | Proposed default | When to revisit |
|---|---|---|---|
| 1 | Board pin for HB? | **Decided 2026-07-17: `GPIO1`**. Board has only GPIO1/GPIO2. Boot prints both MCU maps. | CP-0: read UART print + probe GPIO1 pad |
| 2 | Where does GPIO init + HB tick run? | **CM7 Customer** (`GEO_ApplicationTask_Init` / `_Update`), using core-neutral OPS GPIO APIs (ICC under the hood on CM7). Keeps role/`systemActive` next to the sailing loop that already gates DAC. | Only if Stage 1 shows GPIO ICC too slow/jittery for 100 ms toggle (unlikely) |
| 3 | `ModuleRole` selection for v1? | **Compile-time / hardcoded** (mirror OldBoard). Optional later: `#define` or single Customer setting. | After Stage 2 |
| 4 | What does `systemActive == 0` silence? | **All actuators:** ZF DAC (already) **and** steering ICC (force mid / skip send / or send neutral — pick one in Stage 2; prefer **send mid 1500** so CM4 Pololu fails safe). | Stage 2 CP |
| 5 | Master electrical mode? | **`GPIO_MODE_OUTPUT_PP_E`**, no pull. Slave: **`GPIO_MODE_INPUT_NOPULL_E`** (match OldBoard Cube pull). If two-board wiring fights, consider OD + pull-up — only if Stage 3 fails. | Stage 3 |
| 6 | Fail-safe if slave never sees a master? | Keep OldBoard semantics: after 1 s with no edges, slave **becomes active**. Document that a floating line → slave takes over (by design). | — |

---

## 2. Target architecture

```
Physical wire: MFCB-A GPIO5 (PE13 / EXT_GPIO5)  ←──tied──→  MFCB-B same pin

  Board role = master                         Board role = slave
  ─────────────────                           ────────────────
  Init: OUTPUT                                Init: INPUT
  systemActive = 1 (always)                   systemActive = 0 until timeout
  every tick:                                 every tick:
    SendHeartbeat()  → toggle pin               checkHeartbeat()
                                                  edge? refresh last_ms
                                                  age > 1000 ms → systemActive=1
                                                  else           → systemActive=0
  if (systemActive) {                         if (systemActive) {
    WriteMotorDAC …                             WriteMotorDAC …
    steer ICC (or mid)                          steer ICC (or mid)
  }                                           }
```

**CM4↔CM7:** no new ICC tags for heartbeat. Optional later: CM7 could publish
`systemActive` to CM4 for local Pololu gating — Stage 2 can instead send mid from CM7
so CM4 needs no new logic.

**File touch list (expected):**

| File | Change |
|---|---|
| `CM7/Customer/Inc/tools.h` | Drop raw `GPIOE` macros; keep `HEARTBEAT_MS` / `HEARTBEAT_TIMOUT_MS`; document board pin |
| `CM7/Customer/Src/tools.c` | Implement `Heartbeat_Init`, `SendHeartbeat`, `checkHeartbeat`; stop hardcoding `systemActive = 1` |
| `CM7/Customer/Src/GEO-application-task.c` | Call init; call send/check by role; gate steering on `systemActive` |
| `CM7/Customer/Inc/GEO-debug.h` (+ `.c` if needed) | Optional periodic `[HB] role=… active=… pin=…` for bench |

No Core / TempOPS / libops changes.

---

## 3. Phased plan — prep + three bench stages

Discipline (same as Log11/Log14): **do not start the next stage until the previous
checkpoint PASSes on hardware.**

### Stage 0 — Pin identity + decisions — ✅ coded 2026-07-17 (bench CP open)

**Goal:** Know the exact NewBoard signal; lock GPIO1 vs GPIO2.

1. Locked: HB = **GPIO1**, GPIO2 free (§ decision update above).
2. `Heartbeat_Init` prints both maps via `GPIO_BoardPinLookup`:
   `[CM7 HB] GPIO1(HB) -> P{port}{pin} (mask=…)` and same for GPIO2.
3. Do **not** expect PE13 — follow the printed map + silkscreen.
4. Scope/DMM on connector **GPIO1** while master runs (Stage 1 toggle).

**CP-0 PASS (2026-07-17):** UART + scope on master flash.

```
GPIO1 (HB) -> PI13 (mask=0x2000)
GPIO2      -> PI14 (mask=0x4000)
```

Scope: square ~1.5 s period (not the intended 200 ms full period) — symptom of slow CM7
app tick, not wrong pin map. HB work paused until that is fixed.

---

### Stage 1 — Heartbeat functions + role behaviour (single board) — ✅ coded 2026-07-17 (bench CP open)

**Goal:** Port the two functions correctly; prove master and slave software paths without
needing a second MFCB yet.

**Implemented:**

- `Heartbeat_Init(ModuleRole)` — master OUTPUT_PP / slave INPUT_FLOATING; sets `systemActive`.
- `SendHeartbeat()` / `checkHeartbeat()` via OPS `gpio_*_by_port_pin`.
- End of `GEO_ApplicationTask_Update` (after DAC/steer, like OldBoard order).
- `Heartbeat_DebugPrint()` ~1 Hz when `GEO_DEBUG_ENABLE`.

**Single-board tests:**

| Flash as | Expect |
|---|---|
| **master** (`ModuleRole = master`) | Pin toggles ~10 Hz; `active=1`; DAC still works |
| **slave** (edit `ModuleRole = slave`, pin floating/static) | Within ~1–1.5 s, `active=1` |
| **slave** + external ~10 Hz into GPIO1 | `active=0` while edges present; `1` ~1 s after stop |

**CP-1 PASS:** Both roles behave as in the table; no hang; UART1 `[CM7 HB] role=…`; master
toggle on scope.

---

### Stage 2 — Actuator gating (single board)

**Goal:** Standby means **no motion**, not “DAC off but Pololu still driven”.

1. Keep DAC behind `if (systemActive)`.
2. Steering ICC: when `!systemActive`, send **neutral 1500 µs** (or skip send and rely on
   CM4 stale→0 — prefer explicit mid from CM7 so behaviour is obvious in Log14 path).
3. Optional: dashboard / debug field for `systemActive` so ROC UI can see standby vs live.

**Tests (slave role, force inactive then active):**

| Condition | DAC | Steering ICC payload |
|---|---|---|
| `systemActive == 0` (fresh edges) | no update / hold safe | mid 1500 |
| `systemActive == 1` (timeout or master) | follows sailing state | real `Steeringcommand` |

Easiest force-inactive: slave + inject toggles on the pin for several seconds.

**CP-2 PASS:** With `systemActive == 0`, motors stay safe (mid/Hi-Z as today when not written)
and Pololu/steer path does not follow RC/ROC commands; when active, full control restored.

---

### Stage 3 — Two-board failover (integration)

**Goal:** Real redundancy wire between two MFCBs (or one MFCB + a known-good toggle source
that can be cut).

**Setup:**

- Board A: `ModuleRole = master`, drives GPIO5.
- Board B: `ModuleRole = slave`, reads GPIO5, common GND.
- Both powered; only one should drive ZF/steer at a time under normal conditions.

**Sequence:**

1. Both up, wire connected → A `systemActive=1`, B `systemActive=0`. Confirm only A’s
   actuators respond to a known RC/ROC command.
2. Power-cycle or halt A (or disconnect HB wire) → within ~1 s B becomes active and
   responds to commands.
3. Restore A while B still active → **document actual behaviour** (OldBoard does not demote
   a live slave when master returns; both can be active if master is back — note risk).
   Decide explicitly:
   - **v1 (match OldBoard):** no auto-demote; operator power-cycles slave after repair, or
   - **v1+ (optional improvement):** slave clears `systemActive` when edges return.

**CP-3 PASS:** Failover B←A within ~1 s after master loss; no smoke; behaviour on master
return is documented and accepted.

---

## 4. Suggested implementation sketch (reference only — not applied)

```c
/* tools.c — shape only */
#define HB_BOARD_PIN  EXT_GPIO5   /* confirm Stage 0 */

void Heartbeat_Init(ModuleType role)
{
    gpio_config_t cfg;
    gpio_config_factory(&cfg);
    GPIO_ConfigFromBoardPin(&cfg, HB_BOARD_PIN);
    if (role == master) {
        cfg.mode = GPIO_MODE_OUTPUT_PP_E;
        systemActive = 1;
    } else {
        cfg.mode = GPIO_MODE_INPUT_NOPULL_E; /* name per gpio_config enums */
        systemActive = 0;
    }
    (void)GPIO_Init(&cfg);
    ModuleRole = role;
}

void SendHeartbeat(void) { /* 100 ms toggle via gpio_set_pin_by_port_pin */ }
void checkHeartbeat(void) { /* edge refresh + 1000 ms → systemActive */ }
```

```c
/* GEO-application-task.c — end of Update */
if (ModuleRole == master) {
    SendHeartbeat();
} else {
    checkHeartbeat();
}
/* DAC already gated; steer: use Steeringcommand if systemActive else PWM_MID_VALUE */
```

---

## 5. Risks and non-goals

| Risk | Mitigation |
|---|---|
| Wrong board pin vs OldBoard PE13 | Stage 0 lookup + probe |
| Master OUTPUT fighting slave OUTPUT | Role-based init; never flash two masters on one wire |
| Slave floats into active | By design; document for bench |
| GPIO via ICC from CM7 adds latency | 100 ms period has huge margin; fall back to CM4 Customer tick only if CP-1 fails |
| Master return → dual-active | Stage 3 documents OldBoard parity vs optional demote |
| Confusing with dual-core watchdog | Do not touch `Middleware/Watchdog` for this slice |

**Out of scope for this log:** EEPROM/web role UI, open-drain redesign unless Stage 3 needs it,
CM4-local Pololu `systemActive` mirror, Modbus HB coils (`COIL_CLIENT_HB` etc. on OldBoard).

---

## 6. Done criteria (end product)

- [ ] Master toggles HB pin at ~10 Hz; slave standby while edges present.
- [ ] Slave takeover within ~1 s of master loss.
- [ ] `systemActive == 0` silences **DAC and steering**.
- [ ] No use of `IC_CH_WATCHDOG` / new ICC tags for the inter-board signal.
- [ ] OPS GPIO APIs only (no Customer `#if CORE_CM4` around the pin).
- [ ] This log updated with CP-0…CP-3 results when each stage finishes.

---

## 7. Cross-links to update when implementing

- Log10 §2 item 3 → mark in progress / done.
- knowledge-graph row “Master/slave heartbeat | TBD” → point at this log + Rewrite files.
- Log14 Stage 4: note steering must honour `systemActive` (Stage 2 of this plan).
