# Log 3 — UART6 / UART7 traffic (current state)

**Date:** 2026-07-06  
**Last updated:** 2026-07-06 — CM7 UART test gated (`CM7_UART_TEST_ENABLED 0`)  
**Tree:** `NewBoard/Rewrite/MFCB_BASE/`  
**Context:** After Phase 2 SBUS bring-up (`rc_sbus_hw_init OK` on UART1). Bench confirmed CM4+CM7 Customer init on UART1.  
**Related:** Log1-UART.md, Log2-SBUS-config-path-NewBoard.md

---

## Port roles (agreed)

| Port | Role | Line format |
|------|------|-------------|
| **UART1** | CM4 + CM7 debug / Customer text | 115200 8N1 |
| **UART6** | SBUS **RX** (RC in) | 100k, 9E2, inverted |
| **UART7** | SBUS **TX mirror** (Phase 3) | 100k, 9E2, inverted |

Debug and Customer output were moved to UART1. UART6/7 should be SBUS-only.

---

## Summary table — what uses UART6 / UART7 **today**

| Source | UART6 | UART7 | Active now? |
|--------|-------|-------|-------------|
| `rc_sbus_hw_init()` — SBUS RX task | **RX** @ 100k | — | **Yes** (`RC_SBUS_ENABLE 1`) |
| `rc_sbus_hw_init()` — SBUS TX line init | — | configured, **no app TX** | **Yes** (Phase 3 mirror not coded) |
| CM4 `StartUartTestTask` | TX spam | TX spam | **No** — `CM4_UART_TEST_ENABLED 0` |
| CM4 `StartMonitorTask` | — | TX logs | **No** — `CM4_MONITOR_TASK_ENABLED 0` |
| CM7 `StartUartTestTask` | TX spam | TX spam | **No** — `CM7_UART_TEST_ENABLED 0` (fixed 2026-07-06) |
| CM7 `StartMonitorTask` | — | — | **No** — `CM7_MONITOR_TASK_ENABLED 0` |
| Customer / `rc_sbus` status strings | — | — | **No** — UART1 only |
| CM4/CM7 `CMx_INIT_DEBUG` | — | — | **No** — flags 0; UART → `&huart1` |
| OPS module debug (settings, I2C, web, ETH, ICC trace, …) | if flag=1 | if flag=1 | **No** — defaults 0 in headers |

---

## UART6 — detail

### Active (intended)

- **`rc_sbus_hw_init()`** (CM4 `CustomerTask_Init`):
  - `UART_DeInit` / `UART_Init` / explicit **100000** Hz HAL re-init
  - `UART_SetVoltage` @ 3.3 V (`RC_SBUS_RX_VOLTAGE`)
  - `UART_Task_StartAfterInit(&huart6, &rx_cfg)` — silence 5000 µs + 25-byte frames
  - **Inbound:** Futaba SBUS from RC receiver when connected
  - **Outbound text:** none from Customer/SBUS code

### Active (unintended — fix recommended)

- **CM7 `StartUartTestTask`** (`CM7/Core/Src/main.c`):
  - Every **5 s**: `"UART6 CM7 cnt N\r\n"` via `uart_send_ctrl(&huart6, …)`
  - Path: CM7 → ICC → CM4 UART proxy → **physical UART6 TX**
  - Line is already **100k** after SBUS init (not 115200)

### Disabled

- CM4 UART test (`CM4_UART_TEST_ENABLED 0` in `CM4/Core/Inc/main.h`)
- `IRQ_DEBUG 0` (CM4 EXTI debug would use `&huart6` if enabled — `CM4/Core/Inc/stm32h7xx_it.h`)
- `LWIP_DEBUG_ETH_IRQ 0` (`CM7/Core/Inc/lwip_debug_flags.h`; ETH handler hardcodes `&huart6` when on)

---

## UART7 — detail

### Active (intended)

- **`rc_sbus_hw_init()`**:
  - Same 100k 8E2 invert, **TX-only** mode
  - `UART_SetVoltage` @ 3.3 V (`RC_SBUS_TX_VOLTAGE`)
  - **No** `UART_Task_StartAfterInit` on UART7
  - **No** Phase 3 mirror send yet (`uart_send_ctrl` × 25 bytes — TBD)

### Active (unintended — fix recommended)

- **CM7 `StartUartTestTask`**:
  - Every **5 s**: `"UART7 CM7 cnt N\r\n"` on `&huart7` (ICC → CM4 → UART7 TX @ 100k)

### Disabled

- CM4 monitor (`CM4_MONITOR_TASK_ENABLED 0`; would use UART7 via `CM4_MON_SEND`)
- `ICC_CM4_TRACE 0` (would print `[ICC4][…]` on UART7 on CM4 if enabled)

---

## UART1 vs UART6/7 (what you see on the debug cable)

On **UART1 @ 115200** (confirmed on bench):

```text
[CM4] rc_sbus_hw_init OK — UART6 RX / UART7 TX @ 100k SBUS
[CM4] CustomerTask_Init OK — all example text on UART1
[CM7] CustomerTask_Init OK — all example text on UART1
```

Plus Customer examples every ~25 s (both cores, UART1). CM7 text reaches UART1 via **ICC → CM4** when CM7 calls `uart_send_ctrl(CM7_INIT_DEBUG_UART, …)` with `&huart1`.

---

## CM7 UART test fix — applied 2026-07-06

CM4 already had this pattern; CM7 now matches.

### 1. Add macro in `CM7/Core/Inc/main.h`

Place next to `CM7_UART_TEST_STACK_SIZE` (after `CM7_INIT_DEBUG_UART`), mirror CM4:

```c
/* UART_Test hammers UART6/7 — disable while SBUS uses those ports (CM4 owns HAL). */
#ifndef CM7_UART_TEST_ENABLED
  #define CM7_UART_TEST_ENABLED 0
#endif
#ifndef CM7_UART_TEST_STACK_SIZE
  #define CM7_UART_TEST_STACK_SIZE (4u * 1024u)
#endif
```

Default **`CM7_UART_TEST_ENABLED 0`** while SBUS uses UART6/7. Set to **1** only for harness tests.

### 2. Gate task creation in `CM7/Core/Src/main.c`

In `StartInitTask`, wrap the existing UART_Test block (currently ~lines 377–384) like CM4:

```c
#if CM7_UART_TEST_ENABLED
    {
        osThreadAttr_t uartTask_attributes = {
            .name = "UART_Test",
            .stack_size = CM7_UART_TEST_STACK_SIZE,
            .priority = (osPriority_t)osPriorityHigh,
        };
        uartTestTaskHandle = osThreadNew(StartUartTestTask, NULL, &uartTask_attributes);
    }
#if CM7_INIT_DEBUG
    uart_send_ctrl(CM7_INIT_DEBUG_UART, UART_SEND_OP_STRING, 0u,
                   uartTestTaskHandle ? "[CM7 INIT] UART_Test task created\r\n"
                                      : "[CM7 INIT] UART_Test task create FAILED\r\n");
#endif
#endif
```

Optional: leave `StartUartTestTask()` in the file (same as CM4) so you can re-enable quickly for harness tests.

### 3. Rebuild and flash **CM7** (CM4 unchanged unless you also changed it)

After fix, UART6/7 TX should be quiet until Phase 3 mirror or an RC-driven path.

---

## OPS debug flags — off now, but default UART targets still 6/7

If you enable these **without** overriding `*_DEBUG_UART` to `&huart1`, text goes to SBUS ports:

| Flag | Default | UART if enabled (typical) |
|------|---------|---------------------------|
| `debugOutputSettings` | 0 | CM7 → UART6, CM4 → UART7 |
| `ICC_CM4_TRACE` | 0 | CM4 → UART7 |
| `ADC_TASK_DEBUG` / `ADC_DEBUG` | 0 | CM7 → UART6, CM4 → UART7 |
| `WEBSERVER_DEBUG` / `WEBSITE_DEBUG` | 0 | CM7 → UART6 |
| `NETWORK_DEBUG` | 0 | CM7 → UART7 |
| `debugOutputStmBootStatus` | 0 | CM4 → UART7 |
| `LWIP_DEBUG_ETH_IRQ` | 0 | hardcoded `&huart6` in CM7 `stm32h7xx_it.c` |

**Note:** Traces inside precompiled `libops.a` are fixed at library build time; toggling flags in `main.h` only affects **your** Core/Customer `.c` files unless you rebuild the library.

---

## Next steps (migration)

| Step | Status |
|------|--------|
| Phase 2 — `rc_sbus_hw_init` | Done (bench OK on UART1) |
| Disable CM7 UART test on 6/7 | **Done** — `CM7_UART_TEST_ENABLED 0` |
| Phase 3 — poll + UART7 mirror + stick decode | Not started |
| Scope UART6 RX with RC connected | Pending |
| 5 V SBUS later | `RC_SBUS_RX_VOLTAGE` / `RC_SBUS_TX_VOLTAGE` → `SUPPLY_VOLTAGE_5V` |

---

## Cross-references

- `.cursor/Logs/Log1-UART.md` — port map and dual-core UART policy
- `.cursor/Logs/Log2-SBUS-config-path-NewBoard.md` — Phase 1–4 plan
- `CM4/Core/Inc/main.h` — reference for `CM4_UART_TEST_ENABLED`
- `CM4/Customer/rc_sbus_config.h` — SBUS port macros
