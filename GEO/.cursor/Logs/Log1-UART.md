# Log 1 — UART1 / UART6 / UART7 (NewBoard, CURRENT build)

**Date started:** 2026-07-01  
**Last updated:** 2026-07-06 (port map: UART1 debug, UART6 SBUS RX, UART7 SBUS TX)  
**Status:** Debug bring-up next; SBUS hardcode planned; hardware verification pending  
**Related:** OPS_ZF → NewBoard migration, SBUS RC input, dual-core debug

**Rule cross-refs:** `.cursor/Logs/Log2-SBUS-config-path-NewBoard.md` (phased path), `.cursor/rules/current-build-porting-strategy.mdc`, `.cursor/rules/newboard-knowledge-graph.mdc`  
**Supplier docs:** `how_to_use_core_assignment.txt`, `how_to_use_debug_mechanism.txt`

---

## Goal

Port OPS_ZF RC input (SBUS on UART6) to NewBoard **CURRENT** firmware without blocking on the newer OPS library, while keeping a clean swap path to NEWER (`uart_config_apply_preset_sbus`, `sbus_shared_read`).

---

## UART1 / UART6 / UART7 — roles (decisions 2026-07-06, revised)

**Target port map** — frees UART6/7 for SBUS (both have OPS `UART_SetVoltage`); debug on UART1 (3.3 V serial is enough).

| Port | Role (porting) | Voltage now | **→ 5 V later (OPS API)** |
|------|----------------|-------------|---------------------------|
| **UART1** | **Debug / customer console** (CM4 + CM7 traces → one cable, ICC for CM7) | 3.3 V | *Not applicable* — no `UART_SetVoltage` on UART1; debug stays 3.3 V |
| **UART6** | **SBUS RC receive** (OPS_ZF `UART6_Init4SBUS`; NEWER translator **inst1**) | 3.3 V | `uart_config_t::tx_voltage` on RX cfg + `UART_SetVoltage(&huart6, SUPPLY_VOLTAGE_5V)` in `rc_sbus_hw_init` (connector TX rail / SBUS front-end) |
| **UART7** | **SBUS TX mirror** (same 100k 8E2 invert; outbound raw frames) | 3.3 V | `uart_config_t::tx_voltage` on TX cfg + `UART_SetVoltage(&huart7, SUPPLY_VOLTAGE_5V)` in `rc_sbus_hw_init` |

**Supplier defaults (override in `main.h` + Customer):** CM4 debug was UART7, CM7 debug was UART6 — move **both** to **`&huart1`** so UART6/7 are free for SBUS.

**Hardware (J16):** 3× external UART; **2×** ports with selectable **3.3/5 V TX output** (OPS: UART6 & UART7 only); **all** inputs 3.3/5 V tolerant. Verify silkscreen ↔ UART1/6/7 on bench. See `.cursor/Logs/reference-OPS-MFCB-hardware-manual-rev2.01.md`.

**Do not** use UART7 for CM4 debug once SBUS TX mirror is active. **Do not** use UART6 for CM7 debug once SBUS RX is active.

---

## Dual-core: API vs HAL (important)

Both cores call the **same OPS API names** (`uart_send_ctrl`, `settings_load_raw`, …) but **CM4 owns UART HAL**.

- CM4 → UART1/6/7: direct HAL.
- CM7 → any UART: **ICC → CM4** (debug on UART1 uses same path).

**SBUS for “both cores”** = **one physical UART**, init on **CM4**, both cores **read** sticks:

| Build | Read path |
|-------|-----------|
| **CURRENT** | CM4 UART RX task → `uart_rx_shared` / `UART_RxShared_FetchLast` on CM7 |
| **NEWER** | `sbus_translator_ctrl` + `sbus_shared_read()` on either core |

Do **not** `UART_Init` the same SBUS port from CM7 Customer code.

---

## Debug UART — bring-up

| Core | Flag | UART | Terminal |
|------|------|------|----------|
| CM4 | `CM4_INIT_DEBUG` in `CM4/Core/Inc/main.h` | **UART1** (`CM4_INIT_DEBUG_UART` → `&huart1`) | 115200 8N1 |
| CM7 | `CM7_INIT_DEBUG` in `CM7/Core/Inc/main.h` | **UART1** (`CM7_INIT_DEBUG_UART` → `&huart1`) | 115200 8N1 |

Also set `CUSTOMER_TASK_UART` / example UART to **`&huart1`** on both cores. Expect `[CM4 INIT]` / `[CM7 INIT]` on **one** UART1 cable (interleaved). Flash **both** cores.

**Helpers while probing:**

- `CM4_UART_TEST_ENABLED 1` — may still print on UART6/UART7 from CM4 test task; ignore or disable when SBUS owns 6/7.
- If UART1 silent → check EEPROM `BLOCK_UART1` active; `CM4_MAIN_DEBUG_LOOP` only forces UART6/7, not UART1.

**SBUS bench:** UART6 RX + UART7 TX must not share ports with debug. Supplier default debug on UART6/7 must be **redirected to UART1** before SBUS init.

---

## SBUS on CURRENT build — web limitation + approved workaround

**Problem:** Web UART page on **CURRENT** build cannot set baud **100000** (no `UART_BAUD_ENUM_100000` in linked headers). UART1/6 SBUS preset buttons are **NEWER** only.

**Approved approach (2026-07-06):** Hardcode SBUS `uart_config_t` in Customer — **CM4 only**, in a thin adapter (e.g. `rc_input_init()`), not scattered in `Customer.c`.

1. Build `uart_config_t` in RAM (mirror NEWER `UART_PRESET_SBUS_*` in comments / Log below).
2. **CM4** `CustomerTask_Init`: `UART_DeInit` → `UART_Init` on **UART6 (RX)** + **UART7 (TX)** → `UART_Voltage_Init` / `UART_SetVoltage` (3.3 V now) → `UART_Task_StartAfterInit` on UART6 only.
3. Gate interim decode behind `RC_INPUT_USE_OPS_TRANSLATOR` (0 = interim, 1 = NEWER swap).
4. **Optional:** `uart_config_pack` + `settings_save_raw(BLOCK_UART6, …)` once so reboot matches RAM config.

Web/EEPROM may still show 115200 on UART6 — runtime Customer init **overrides** until saved or newer web preset exists.

**Do not** rely on long-term DIY SBUS decode in Customer; swap to `sbus_shared_read()` when NEWER `libops.a` arrives.

### SBUS line parameters (target)

Match OPS_ZF / NEWER `UART_PRESET_SBUS_*`:

| Parameter | Value |
|-----------|--------|
| Baud | 100000 |
| Word | 9-bit |
| Parity | Even |
| Stop | 2 |
| Mode | RX-only (or TX+RX if needed) |
| Invert | `invert_logic` / RX invert (OPS_ZF: `UART_ADVFEATURE_RXINV_ENABLE`) |
| Framing | Fixed **25-byte** payload (silence + length), **not** CR/LF ASCII |
| TX voltage (SBUS ports) | **3.3 V now** on UART6 + UART7 via `RC_SBUS_*_VOLTAGE` + `UART_SetVoltage` — **→ 5 V:** set macros to `SUPPLY_VOLTAGE_5V` (see Log2) |

NEWER reference: `NewBoard/Newer_build_includes/include/Settings/uart_config.h` → `uart_config_apply_preset_sbus()`, `UART_PRESET_SBUS_*`.

---

## NEWER build (defer until new `libops.a`)

1. EEPROM layout adds `BLOCK_SBUS_TRANSLATOR1/2/3`.
2. Factory UART map: **inst1 → UART6**, **inst2 → UART7**, **inst3 → UART1** (all can use SBUS UART preset on web).
3. `uart_config_apply_preset_sbus()` + `sbus_translator_ctrl` / `sbus_shared_read`.
4. Replace interim `rc_input_*` body; keep state machine in Customer.

---

## Result

*(Update when bench work completes.)*

| Item | Outcome |
|------|---------|
| CM4/CM7 init debug on **UART1** | _`main.h` → `&huart1`; probe @ 115200_ |
| UART6 RX / UART7 TX SBUS (`rc_sbus_*`) | _Phase 1–2 updated in Rewrite CM4_ |
| UART6 SBUS verified on wire | _Not verified yet_ |
| Translator configured | _Blocked — needs newer library_ |
| `sbus_shared_read` in Customer | _Blocked — needs newer library_ |

**Decisions recorded:**

- **UART1 = debug (3.3 V); UART6 = SBUS RX; UART7 = SBUS TX mirror (3.3 V now, 5 V via `UART_SetVoltage` on 6/7 when needed).**
- Web cannot set 100k on CURRENT → **hardcode SBUS UART config in CM4 Customer adapter** is OK.
- Pre-configuring UART6 (RAM or EEPROM) should survive NEWER upgrade (same 41-byte `uart_config_t` wire).
- Factory translator channel map ≠ OPS_ZF `pwmValues[]` indices — plan mapping pass after upgrade.

---

## OPS_ZF reference mapping

| OPS_ZF | CURRENT NewBoard | NEWER NewBoard |
|--------|------------------|----------------|
| `UART6_Init4SBUS()` | CM4 `rc_input_init()` hardcoded `uart_config_t` on **UART6** | `uart_config_apply_preset_sbus()` + `BLOCK_UART6` |
| `decodeSBUSData` / `pwmValues[]` | Interim adapter (`RC_INPUT_USE_OPS_TRANSLATOR=0`) | `sbus_shared_read()` |
| `ProcessRC()` | Customer state machine | Same + `snap.stream_live` |

---

## Next steps

- [ ] Point CM4/CM7 debug + Customer UART to **UART1**; probe @ 115200
- [ ] Align `rc_sbus_config.h` TX port to **UART7** (code may still say UART1 until updated)
- [ ] `rc_sbus_hw_init` on UART6 RX + UART7 TX @ 100k (Phase 2 explicit Hz)
- [ ] Receive newer `libops.a` → swap adapter to translator APIs
- [ ] Update **Result** table above
