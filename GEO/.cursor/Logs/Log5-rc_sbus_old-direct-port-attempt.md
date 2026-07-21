# Log 5 — rc_sbus_old.c: direct OPS_ZF port attempt (UNSOLVED)

**Date:** 2026-07-07
**Goal:** Minimal exact-copy port of OPS_ZF SBUS code (`UART6_Init4SBUS()` + `ProcessRC()`)
into `CM4/Customer/rc_sbus_old.c`, printing decoded PWM channel values on UART1.
**Status:** ❌ Not working. Polling read on UART6 gets essentially zero bytes, while
`rc_sbus.c` (OPS UART_Task path) receives SBUS frames perfectly on the same hardware,
same session, same wiring. Root cause not yet identified.

---

## 1. What was built

`rc_sbus_old.c` (state at end of day):

- `UART6_Init4SBUS()` — verbatim OPS_ZF HAL init (100000 baud, 9B, even parity,
  2 stop, RXINV via AdvancedInit) plus NewBoard additions:
  - `UART_Task_StopPort(6u)` — release the port from OPS's UART task (result stored,
    printed as `stop=`)
  - `UART_Voltage_Init(&huart6)` + `UART_SetVoltage(&huart6, SUPPLY_VOLTAGE_3V3)` —
    enable the UART6 connector transceiver rail
- `ReadSBUSFrameBlocking()` — polling read (blocking `HAL_UART_Receive`), scans up to
  30 bytes for start byte 0x0F, then reads remaining 24. No interrupt dependency.
- `PrintPWMValuesUart1()` — throttled 500 ms diagnostic print via `uart_send_ctrl`.
- `uint8_t requestRCcontrol = 0;` defined here (in OPS_ZF it lives in `ops-tools.c`,
  which was not ported — linker error otherwise).
- `Customer.c` calls `UART6_Init4SBUS()` in `CustomerTask_Init()` and `ProcessRC()`
  in the task loop (`RC_SBUS_ENABLE` guard).

## 2. Final diagnostic output (the mystery)

```
[SBUS_OLD] ok=0 fail=378 st=3 raw0=0x0F stop=1 listen=0 RxSt=0x20 rxneie=0 | ch0=0 ...
```

Decoded:
- `st=3` (HAL_TIMEOUT): blocking read waits 20 ms for one byte — RXNE never sets.
- `stop=1`: `UART_Task_StopPort(6)` succeeded.
- `listen=0`: OPS UART task is NOT listening on port 6.
- `RxSt=0x20` (READY): no interrupt receive armed by anyone.
- `rxneie=0`: RXNE interrupt disabled in CR1 — no ISR is consuming bytes.
- `raw0=0x0F`: at least one real byte DID arrive early in the boot (sbusFrame is
  .bss-zeroed, so 0x0F was written this run) — then the line went permanently silent.
- Meanwhile `rc_sbus.c` flashed onto the same board immediately after: `ok=` climbing,
  all 16 channels valid. Signal, wiring, receiver all proven good.

**Open question:** what makes USART6 receive bytes in the rc_sbus init sequence but
not in the direct-HAL sequence, given that GPIO, kernel clock, line config (CR1/CR2
verified vs working log: CR2=0x00012000, BRR=0x3E8) and transceiver rail all appear
identical, the port is idle, and nothing else owns it?

## 3. Theories tested and ELIMINATED (with evidence)

1. **Missing NVIC enable for USART6_IRQn** — real gap for interrupt mode (OldBoard/
   OPS_ZF CubeMX enabled per-port NVIC in their own `HAL_UART_MspInit`; OPS_ZF
   `stm32h7xx_hal_msp.c:1532` has it, OldBoard `usart.c:885` has it; NewBoard's linked
   MspInit only enables NVIC in its USART1 branch, IRQ 37, prio 0). **But irrelevant to
   the final polling approach**, which uses no interrupts at all.
2. **`USART6_IRQHandler` owned by OPS (`UART_Task_HAL_IRQHandler`), so
   `HAL_UART_Receive_IT` completion never runs** — WRONG as stated. Disassembly of
   `uart_task.o` proves `UART_Task_HAL_IRQHandler` calls `HAL_UART_IRQHandler(huart)`
   unconditionally first, then adds IDLE-flag handling for its own framing. It is a
   wrapper, not a replacement. HAL IT-receives WOULD be serviced.
3. **OPS UART task holds RxState BUSY_RX so our receive calls return HAL_BUSY** —
   disproven by diagnostics: `RxSt=0x20`, `listen=0`, `stop=1`.
4. **OPS ISR steals bytes (RXNEIE armed by boot config)** — disproven: `rxneie=0`,
   and `st=3` not `st=2`.
5. **Wrong/unconfigured GPIO pins in the linked MspInit** — disproven by disassembly
   of `Debug/TempOPS/peripherals/uart/usart.o` (see §4): USART6 branch configures
   `BRD_USART6_RX`/`BRD_USART6_TX` (pin-table IDs 151/152) with GPIOG clock enabled,
   AF from board table. Matches PG9/PG14 expectation.
6. **Transceiver rail off (`UART_Voltage_Init`/`UART_SetVoltage` missing)** — a real
   difference vs OPS_ZF (OldBoard has no such hardware), fix applied, but symptom
   unchanged. Possibly still necessary, demonstrably not sufficient.
7. **Frame misalignment of blind 25-byte reads** — real secondary issue, addressed by
   start-byte sync in the polling reader; irrelevant while zero bytes arrive.

## 4. Hard facts learned from binary analysis (reusable)

Toolchain trick: host `nm`/`objdump` can't disassemble ARM; use CubeIDE's bundled
`arm-none-eabi-objdump.exe` under
`C:/ST/STM32CubeIDE_2.1.1/.../tools/bin/` (works on WSL paths only after copying the
object to a Windows-accessible or /tmp cwd).

- The linked UART board-support is **NOT** `Core/Src/Backup/usart.c.bak` (that's stale
  CubeMX output: PG9/PG14 hardcoded, zero NVIC calls). The real code is OPS's
  `TempOPS/peripherals/uart/usart.c` (source not shipped; object at
  `CM4/Debug/TempOPS/peripherals/uart/usart.o` with full DWARF, comp dir
  `D:/github_folder/MFCB/MFCB_BASE/CM4/Debug`).
- Real `HAL_UART_MspInit`:
  - Gates on `UART_HasAnyCoreAccess` + `UART_IsCoreAllowed` before doing anything.
  - Resolves pins via **board pin table** (`board_pin_pin_mask/af/port`, table in
    `stm32h757_pins.o`, IDs in `include/peripherals/stm32h757_pins.h` enum).
  - Branch map (Instance → pin IDs): USART1 0x40011000 → 143/144 (+ the ONLY
    NVIC enable: IRQ 37, prio 0,0); USART2 → 145/146; USART3 → 149/150;
    UART4 → 131/132; UART7 0x40007800 → 135/136; UART8 → 141/142;
    USART6 0x40011400 → **151/152** = `BRD_USART6_RX`/`BRD_USART6_TX`, GPIOG clock,
    kernel clock D2PCLK2.
- `UART_Task_HAL_IRQHandler` = `HAL_UART_IRQHandler()` + IDLE-flag post-processing.
- `stm32h7xx_it.c:425` routes `USART6_IRQHandler` → `UART_Task_HAL_IRQHandler(&huart6)`
  (fine for both HAL-IT and OPS consumers, per fact above).
- Boot order (CM4 `main.c`): `ops_init_platform()` (EEPROM-driven UART setup) runs in
  InitTask **before** `CustomerTask_Init()`.

## 5. Where to continue next session

The one byte that arrives early and then permanent silence suggests something
**turns the RX path off after/around CustomerTask_Init** rather than it never being on.
Candidates, in order:

1. **Read the HAL source** `stm32h7xx_hal_uart.c` → `HAL_UART_Receive` /
   `UART_WaitOnFlagUntilTimeout`: check whether a latched error flag (ORE/NE/FE/PE)
   makes the wait abort or wedge, and whether error flags need explicit clearing
   (`__HAL_UART_CLEAR_FLAG`) before/between polling reads. Cheap test: print `ISR`
   register in the debug line; if ORE=1 latched while RXNE never sets, that's the tell.
2. **Dump `huart6.Instance->ISR` + `CR1/CR2/CR3/BRR` in the fail path** and diff against
   the known-good rc_sbus values live (CR2=0x00012000, BRR=0x3E8, CR1=0x1535 armed).
3. **Try the hybrid**: keep everything else identical to rc_sbus_hw_init (OPS
   `UART_DeInit`+`UART_Init(cfg)` first, then HAL 100k re-init) but read via polling —
   isolates whatever OPS `UART_Init` does beyond HAL (it's 0x270 bytes and imports
   GPIO + RCC beyond MspInit).
4. If polling still fails there, accept the OPS-task path as the only working RX route
   on this board and implement "old-style" semantics on top of
   `UART_Task_StartAfterInit` + `UART_RxShared_FetchLast` (i.e. what rc_sbus.c already
   does), keeping rc_sbus_old.c only as the decode/print layer.

## 6. Build/link notes hit along the way

- `requestRCcontrol` undefined at link: OPS_ZF defines it in `ops-tools.c` (not
  ported); defined locally in rc_sbus_old.c instead.
- `USART_CR1_RXNEIE` exists on H7 as alias of `USART_CR1_RXNEIE_RXFNEIE`
  (stm32h757xx.h:24783) — safe to use.
- WSL has no ARM toolchain; builds must run in STM32CubeIDE on Windows.
