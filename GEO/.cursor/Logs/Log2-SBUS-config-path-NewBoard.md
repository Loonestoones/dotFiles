# Log 2 — SBUS config path (NewBoard CURRENT → NEWER)

**Date:** 2026-07-06  
**Last updated:** 2026-07-06 — **UART1 debug, UART6 RX, UART7 TX** (3.3 V now)  
**Status:** Phase 1–2 aligned in `NewBoard/Rewrite/MFCB_BASE/`; debug on UART1 in `main.h`  
**Related:** Log1-UART.md, OPS_ZF `UART6_Init4SBUS`, CURRENT `libops.a` vs NEWER preview headers

---

## Port map (agreed)

| Port | Role | Voltage now | **→ 5 V later** |
|------|------|-------------|------------------|
| **UART1** | **Debug** — CM4 + CM7 init/customer text (`CM4_INIT_DEBUG_UART`, `CM7_INIT_DEBUG_UART`, `CUSTOMER_TASK_UART` → `&huart1`) | **3.3 V** (115200 8N1) | N/A — OPS has no `UART_SetVoltage` on UART1 |
| **UART6** | **SBUS RC receive** — OPS_ZF / NEWER inst1 | **3.3 V** | `RC_SBUS_RX_VOLTAGE` → `SUPPLY_VOLTAGE_5V` + `UART_SetVoltage(&huart6, …)` after `UART_Init` |
| **UART7** | **SBUS TX mirror** — same line format, outbound 25-byte frames | **3.3 V** | `RC_SBUS_TX_VOLTAGE` → `SUPPLY_VOLTAGE_5V` + `UART_SetVoltage(&huart7, …)` after `UART_Init` |

**Why:** Manual + OPS — only **UART6/UART7** have `UART_Voltage_Init` / `UART_SetVoltage` for **3.3 ↔ 5 V TX rail**. Debug needs only 3.3 V serial. Both SBUS-capable selectors stay on 6/7.

**Code note:** `rc_sbus_config.h` — `RC_SBUS_UART_TX` = `&huart7`, debug via `CM4/CM7_INIT_DEBUG_UART` → `&huart1`.

---

## Architecture

```
                    ┌── UART1 (115200 debug, CM4+CM7 → ICC)
                    │
RC receiver ──RX──► UART6 (100k SBUS in, CM4)
                         │
                         ▼
              OPS UART RX task + 25-byte framing
                         │
                         ▼
              SRAM4 uart_rx_shared
                         │
                         ▼
              Customer rc_sbus_poll (Phase 3)
                         │
                         ▼ mirror
              uart_send_ctrl × 25 ──► UART7 TX (100k SBUS out)
```

- **CM4 only** for `UART_Init` / `UART_Task_StartAfterInit` on UART6.
- CM7 reads sticks via shared RX (Phase 3) or NEWER `sbus_shared_read`.

---

## Phase 1 — Config builders ✅

**Where:** `NewBoard/Rewrite/MFCB_BASE/CM4/Customer/`

Build **two** SBUS `uart_config_t` profiles (shared 100k 8E2 invert via `rc_sbus_fill_line_params`):

| Profile | Port | Mode | Extra |
|---------|------|------|--------|
| RX | **UART6** | RX-only | Silence start + 25-byte end framing |
| TX | **UART7** | TX-only | No RX framing |

**Voltage in struct (both SBUS profiles):** set `tx_voltage` from macros (3.3 V now).

---

## Phase 2 — Hardware init ✅ (update TX port → UART7)

**Where:** CM4 `rc_sbus_hw_init()` in `CustomerTask_Init`.

```
1. rc_sbus_config_get_rx(&rx)  → UART6
   rc_sbus_config_get_tx(&tx)  → UART7
2. UART_DeInit / UART_Init per port (parity, invert, mode, framing)
3. Explicit BaudRate = 100000 + HAL_UART_DeInit/Init  (CURRENT lib gap)
4. UART_Voltage_Init + UART_SetVoltage on UART6 (RX port rail)
5. UART_Voltage_Init + UART_SetVoltage on UART7 (TX mirror rail)
6. UART_Task_StartAfterInit(&huart6, &rx)   // RX only
```

**Status messages:** print on **UART1** (debug), not UART7.

### 5 V — what to change (no magic elsewhere)

In `rc_sbus_config.h` (or equivalent):

```c
/* NOW */
#define RC_SBUS_RX_VOLTAGE   SUPPLY_VOLTAGE_3V3   /* UART6 SBUS in */
#define RC_SBUS_TX_VOLTAGE   SUPPLY_VOLTAGE_3V3   /* UART7 SBUS mirror out */

/* LATER — 5 V SBUS on connectors that support it (OPS API UART6/7 only) */
/* #define RC_SBUS_RX_VOLTAGE   SUPPLY_VOLTAGE_5V */
/* #define RC_SBUS_TX_VOLTAGE   SUPPLY_VOLTAGE_5V */
```

In `rc_sbus_hw_init()` — must call for **each** SBUS port that uses the selector:

- `UART_SetVoltage(RC_SBUS_UART_RX, RC_SBUS_RX_VOLTAGE);`  /* &huart6 */
- `UART_SetVoltage(RC_SBUS_UART_TX, RC_SBUS_TX_VOLTAGE);`  /* &huart7 */

Also set matching `tx_voltage` in `uart_config_t` before `UART_Init`.

---

## Phase 3 — Runtime ⏳

- Poll `UART_RxShared_FetchLast(6, …)`; mirror with `uart_send_ctrl` on **`&huart7`** (25 bytes).
- Interim decode behind `RC_INPUT_USE_OPS_TRANSLATOR=0`.

---

## Phase 4 — NEWER ⏳

- Translator inst1→UART6, inst2→UART7 remains aligned with this map.
- Swap adapter to `sbus_shared_read`; optional drop explicit Hz patch if new `UART_Init` honors enum 16.

---

## Debug migration checklist

- [ ] `CM4/Core/Inc/main.h` — `CM4_INIT_DEBUG_UART` → `&huart1`
- [ ] `CM7/Core/Inc/main.h` — `CM7_INIT_DEBUG_UART` → `&huart1`
- [ ] `Customer.h` — `CUSTOMER_TASK_UART` → `&huart1` (both cores)
- [ ] `ICC_CM4_TRACE_UART` — consider `&huart1` if ICC trace should follow debug
- [ ] Rebuild CM4 + CM7; one USB-serial on **UART1** @ 115200

---

## Bench checklist

- [ ] Debug on UART1; SBUS init messages on UART1
- [ ] Scope **UART6 RX**: 100k, inverted, 25-byte frames
- [ ] Scope **UART7 TX**: mirror frames (3.3 V now)
- [ ] When needed: flip `RC_SBUS_RX_VOLTAGE` / `RC_SBUS_TX_VOLTAGE` to 5 V and re-test

---

## Cross-references

- `.cursor/Logs/Log1-UART.md`
- `.cursor/rules/current-build-porting-strategy.mdc`
- `.cursor/rules/newboard-knowledge-graph.mdc`
- OPS: `UART_Voltage_Init` / `UART_SetVoltage` — **&huart6 and &huart7 only**
