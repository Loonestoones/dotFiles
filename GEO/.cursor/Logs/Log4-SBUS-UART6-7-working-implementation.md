# Log 4 — SBUS on UART6/7: working implementation (full explanation)

**Date:** 2026-07-07
**Status:** ✅ **Bench-confirmed working** — RC frames received and decoded on UART6
**Tree:** `NewBoard/Rewrite/MFCB_BASE/`
**Context:** Phase 3 of the OPS_ZF → NewBoard port. UART6 = SBUS RX, UART7 = SBUS TX mirror (line configured; mirror send still TBD). All debug text on UART1.
**Related:** Log1-UART.md, Log2-SBUS-config-path-NewBoard.md, Log3-UART6-7-traffic-current-state.md

---

## 1. The problem in one paragraph

Futaba SBUS is a 25-byte serial protocol at **100000 baud, 9-bit even parity, 2 stop bits, inverted line** (idles low). The CURRENT precompiled `libops.a` cannot produce that line format: its baud-enum table has no 100000 entry (`UART_Init` falls back to 115200), the web app / EEPROM config cannot express it, and — the last bug found — the library's `HAL_UART_MspInit` enables the NVIC interrupt line for only **one** port while every DeInit path disables it for **all** ports. The Customer code in `CM4/Customer/rc_sbus*.{c,h}` works around all three limitations without touching the library, and is written so most of it can be deleted when the NEWER library (with native SBUS preset) arrives.

---

## 2. File map

| File | Role |
|------|------|
| `CM4/Customer/rc_sbus_config.h` | All tunables: ports, baud, framing, voltages, debug flags |
| `CM4/Customer/rc_sbus_config.c` | Builds `uart_config_t` for RX (UART6) and TX (UART7) in NEWER-preset shape |
| `CM4/Customer/rc_sbus.c` | Init pipeline, NVIC fix, BRR/RXINV patch, poll + frame decode, debug |
| `CM4/Core/Src/stm32h7xx_it.c:425` | `USART6_IRQHandler` → IRQ counter + `UART_Task_HAL_IRQHandler(&huart6)` |

Key config values (`rc_sbus_config.h`):

```c
#define RC_SBUS_UART_RX_ID   6u          /* &huart6 — RX from RC receiver   */
#define RC_SBUS_UART_TX_ID   7u          /* &huart7 — TX mirror (Phase 3)   */
#define RC_SBUS_BAUD_ENUM    16u         /* NEWER UART_BAUD_ENUM_100000     */
#define RC_SBUS_BAUD_HZ      100000u     /* real line rate                  */
#define RC_SBUS_FRAME_LEN    25u         /* 0x0F + 22 data + flags + 0x00   */
#define RC_SBUS_RX_VOLTAGE   SUPPLY_VOLTAGE_3V3   /* 5 V possible later     */
#define RC_SBUS_FRAMING_SIMPLE 1         /* length-25 end; 0 = NEWER preset */
```

---

## 3. Init pipeline — `rc_sbus_hw_init()` (called from CM4 `CustomerTask_Init`)

Runs **after** `ops_init_platform()`, so it deliberately overrides whatever the EEPROM configured UART6/7 to at boot.

```text
rc_sbus_hw_init()
 ├─ rc_sbus_config_build_rx/tx(&cfg)          — SBUS uart_config_t in code (not EEPROM)
 ├─ rc_sbus_uart_apply_ops_cfg(&huart6, rx)   — per port:
 │   ├─ UART_DeInit / UART_Init(huart, cfg)   — OPS path: GPIO, clocks, framing fields
 │   ├─ rc_sbus_uart_apply_baud_hz(...)       — HAL DeInit+Init @ 100000 + RXINV/TXINV
 │   └─ rc_sbus_uart_enable_irq(huart)        — NVIC enable (the final missing piece)
 ├─ rc_sbus_uart_apply_voltage(...)           — UART_Voltage_Init + 3V3 rail
 ├─ (same three steps for &huart7 TX mirror)
 └─ rc_sbus_uart6_arm_rx_task(&rx_cfg)        — OPS RX task arm + register-level patch
     ├─ UART_Task_StartAfterInit(&huart6,cfg) — registers port with OPS UART task
     ├─ UART_Task_RestartPort(6)              — AbortReceive + Receive_IT → BUSY_RX
     └─ rc_sbus_uart6_patch_line_after_arm()  — BRR rescale + CR2.RXINV, UE cycled
```

### Why each step exists (the three library workarounds)

**Workaround 1 — 100000 baud (`rc_sbus_uart_apply_baud_hz`)**
CURRENT `UART_Init` maps `cfg->baud` through the library enum table (300…3 000 000 — no 100000; enum 16 lands at **115200**). So after the OPS init, the Customer code re-runs `HAL_UART_DeInit` + `HAL_UART_Init` with `Init.BaudRate = 100000` and sets the advanced features:
- RX port: `UART_ADVFEATURE_RXINVERT_INIT` (SBUS inverted input)
- TX port: `UART_ADVFEATURE_TXINVERT_INIT` (inverted output for the mirror)

This is the NewBoard equivalent of OPS_ZF's `UART6_Init4SBUS()` (`OPS_ZF/Core/Src/ops-tools.c`).

**Workaround 2 — belt-and-braces register patch (`rc_sbus_uart6_patch_line_after_arm`)**
Runs after the OPS RX task has armed the receiver. It rescales `BRR` to 100 kBd from the (BRR, `Init.BaudRate`) pair left by the last `HAL_UART_Init` — so the kernel clock never needs to be known — and ORs `CR2.RXINV`, with `CR1.UE` cleared briefly around the writes (those bits are only writable with UE=0). No HAL DeInit, so the `BUSY_RX` arming and CR1 interrupt enables survive. If the line was already correct (as it is today: patch prints `baud 100000->100000 BRR 0x3E8->0x3E8`), it is a self-correcting no-op; it becomes real protection if a future lib/task path silently re-inits the port at 115200.

**Workaround 3 — NVIC enable (`rc_sbus_uart_enable_irq`) — the bug that kept RX dead**
Found by relocation analysis of `usart.o` inside `libops.a`:
- `HAL_UART_MspInit` = 7 per-port branches; **only the first branch** (one port, not USART6) calls `HAL_NVIC_SetPriority` + `HAL_NVIC_EnableIRQ`. USART6/UART7 branches do RCC clock + GPIO only.
- `HAL_UART_MspDeInit` **and** `UART_DeInit` disable the IRQ in **all 7** branches.

Consequence: every DeInit/Init cycle on UART6/7 leaves the NVIC line permanently disabled — the USART receives bytes and asserts its interrupt request, but the CPU never takes it. Fix:

```c
HAL_NVIC_SetPriority(irqn, 5u, 0u);  /* 5 = configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY */
HAL_NVIC_EnableIRQ(irqn);            /* USART6_IRQn or UART7_IRQn */
```

Priority 5 equals the FreeRTOS max-syscall priority, so `UART_Task_HAL_IRQHandler` may safely use RTOS calls from the ISR. Handlers for both ports exist in `stm32h7xx_it.c` (lines 425/432).

---

## 4. How the bug was diagnosed (for future reference)

Symptom: `RX-ARMED OK … RxState=0x22` but `irq=0` forever, `fetch_miss` climbing.

The decisive bench line (after adding the `[SBUS] regs:` print):

```text
[SBUS] regs: RxState=0x22 err=0x00 ISR=0x004200E2 CR1=0x00001535 CR2=0x00012000 BRR=0x3E8
```

Decode:
- `ISR`: **RXNE=1** (byte waiting in RDR), **FE=1**, **CMF=1** (char match on 0x00 = SBUS end byte), REACK=1 → **data reached PG9; pin/wiring fine**
- `CR1`: UE, RE, IDLEIE, **RXNEIE=1**, PEIE, PCE (even), M0 (9-bit) → peripheral actively requesting the interrupt
- `CR2 = 0x00012000`: STOP=2 bits, **RXINV=1** → line format correct
- `BRR = 0x3E8` (1000) with 100 MHz kernel clock → exactly 100000 baud

RXNE=1 + RXNEIE=1 + irq=0 has exactly one explanation: NVIC line disabled. `nm`/`readelf -r` on the extracted `usart.o` then showed the MspInit/MspDeInit asymmetry above. After the fix, frames decode and channel prints appear (`[SBUS] ok=… ch0=…`).

Rules of thumb this produced:
- An **armed** UART at wrong baud/polarity still fires interrupts (framing errors). `irq=0` is never a baud problem — it is NVIC, vector table, or genuinely no edges at the pin.
- The regs line now also prints `nvic=<en> pend=<pend>` so this class of failure is visible immediately.

---

## 5. Runtime path — RX frame to channel values

```text
RC receiver ──SBUS──▶ PG9 (USART6_RX, RXINV, 100k 9E2)
  USART6_IRQHandler (it.c) ─▶ rc_sbus_debug_uart6_irq()   (counter)
                           └▶ UART_Task_HAL_IRQHandler(&huart6)
  OPS UART task: byte assembly → 25-byte frame → SRAM4 shared RX store
  ── weak hook UART_Task_OnFrame(6, data, len) → ops_frames counter (debug)

rc_sbus_poll()  (Customer task loop)
  └─ UART_RxShared_FetchLast(6, frame, 25)     — CM4 fetch from shared store
      └─ rc_sbus_decode_frame()                — OPS_ZF decodeSBUSData port:
          · validate 0x0F … 0x00, len 25
          · unpack 16 × 11-bit channels (bit-shift chain)
          · RC_SBUS_MAP_TO_PWM_US: (ch − 992)·5/8 + 1500 → ~1000–2000 µs
          · store → rc_sbus_get_channels() for the application
```

Framing today is `RC_SBUS_FRAMING_SIMPLE 1` = fixed length-25 end condition; `0` switches to the NEWER-preset shape (5000 µs silence start + length end) once supported end-to-end.

---

## 6. Forward path — NEWER library swap

The NEWER lib (preview headers in `NewBoard/Newer_build_includes/`) makes most of this native:

| Today (CURRENT workaround) | NEWER replacement |
|---|---|
| `rc_sbus_config_build_rx/tx()` in code | `uart_config_apply_preset_sbus()` (factory default ports 1/6/7) |
| `rc_sbus_uart_apply_baud_hz` + BRR patch | `UART_BAUD_ENUM_100000 = 16` honored by `UART_Init` — **delete both** |
| Interim `rc_sbus_decode_frame` + poll | `sbus_shared_read()` translator (`RC_INPUT_USE_OPS_TRANSLATOR 1`) |
| NVIC enable in Customer code | **Keep until verified** — MspInit asymmetry may persist in NEWER |

The config already uses baud **enum 16** and NEWER field conventions, so a future EEPROM seed of `BLOCK_UART6/7` (via `uart_config_pack` + `settings_save_raw`) is wire-compatible with NEWER (41-byte packed format identical). Caveat from Log2 analysis: a web-app **Save** on the UART6/7 page would silently rewrite a seeded SBUS block, since the form cannot express these values on CURRENT.

---

## 7. Remaining Phase 3 work

| Step | Status |
|------|--------|
| UART6 SBUS RX + decode | **Done — bench-confirmed 2026-07-07** |
| UART7 line init (100k, TXINV, 3V3) | Done (no traffic yet) |
| UART7 mirror send (`uart_send_ctrl` × 25 bytes per frame) | TBD |
| Wire channels into application (stick decode / control) | TBD |
| Optional: one-time EEPROM seed of BLOCK_UART6/7 (enum 16) | Discussed, not implemented |
| 5 V SBUS rail if needed | `RC_SBUS_*_VOLTAGE → SUPPLY_VOLTAGE_5V` |

---

## Cross-references

- `.cursor/Logs/Log1-UART.md` — port map and dual-core UART policy
- `.cursor/Logs/Log2-SBUS-config-path-NewBoard.md` — Phase 1–4 plan, EEPROM/web analysis
- `.cursor/Logs/Log3-UART6-7-traffic-current-state.md` — who else touches UART6/7
- `OPS_ZF/Core/Src/ops-tools.c` — original `UART6_Init4SBUS()` + `decodeSBUSData()` reference
- `NewBoard/Newer_build_includes/include/Settings/uart_config.h` — NEWER SBUS preset macros
