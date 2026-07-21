# Log6 — OPS libops.a full function inventory (CM4 + CM7)

**Date:** 2026-07-08
**Source:** `NewBoard/Rewrite/MFCB_BASE/{CM4,CM7}/OPS_Lib/` — CURRENT build (the one linked today).
**Method:** all 174 public headers parsed for prototypes + `@brief`, then cross-checked against the
function symbols actually exported by both `libops.a` archives (`nm`, type `T`).
**Counts:** 832 public functions in headers; 816 present in the libraries (821 CM4 / 826 CM7 symbols total).

---

## ⚠️ THE RULE (why this file exists)

> **Before designing ANY workaround for OPS behaviour, search this inventory first.
> OPS almost certainly already has a function for it.**

Canonical example (2026-07-08, cost ~a full day): UART6 SBUS reception kept freezing because the OPS
UART RX task owns every UART and perpetually re-arms a 1-byte `HAL_UART_Receive_IT`. Every attempted
workaround (re-init timing, moving init location) lost the port again at the next frame boundary.
The actual fix was **one call that was in the library all along**: `UART_Task_StopPort(6)`.
Search here first; think second.

How to search: this file (Ctrl-F function-ish words: "stop", "listen", "fetch", "voltage", …),
then read the full doxygen in the header named above each table.

---

## CM4 vs CM7 — how the split works

- The 174 headers are **byte-identical** on both cores; `libops.a` differs (compiled with
  `CORE_CM4` / `CORE_CM7`).
- **Most functions exist in both binaries** — but symbol presence ≠ permission to call.
  The doc comments carry the ownership rule, e.g. `UART_Task_StartPort` exists on CM7 too, but the
  header says CM7 must **not** call `UART_Task_Start*` (hardware owned by CM4). When a brief says
  "(CM4)" or "(CM7)", that is the core that may call it; the other core typically gets a stub or
  must use the shared-memory/ICC path instead.
- General ownership: **CM4 = hardware** (UART/ADC/PWM/timers/I2C-bus-lock RX tasks, IRQ handlers),
  **CM7 = network + website** (LwIP, webserver, auth, pages). Readers on the "other" core go through
  SRAM4 shared snapshots (`*_shared_memory.h`, `uart_rx_shared.h`) or ICC (`*_icc.h`, `intercore_comm.h`).
- Authoritative doc: `how_to_use_core_assignment.txt` (wins over this file on conflict).

**Functions only in the CM4 binary** (22): HAL TIM/UART Msp+callbacks (`HAL_UART_RxCpltCallback`,
`HAL_UART_ErrorCallback`, `HAL_TIM_IC_CaptureCallback`, …), `TIM2/3/5/7/8_CC_IRQHandler`,
`I2C2_BusLock*` (4 fns), `Timer_PWM_OutGetFrequencyHz/GetHandle`, `pwm_output_voltage_apply_gpio`,
`pwm_output_voltage_gpio_hold_3v3_at_boot`, `pwm_in_capture_log_init_status`, `ops_init_platform_cm4_impl`.

**Functions only in the CM7 binary** (27): `auth_web_users_*` (13 fns), `auth_session_update_identity`,
web-users/watchdog page handlers (`handle_web_users_manage_post`, `handle_watchdog_post`,
`send_*_stream`, `generate_watchdog_content`, `generate_pwm_out_embed_content`, …),
`ip_channels_apply_config`, `pwm_web_mirror_invalidate_primary`, `web_page_scratch(_size)`,
`ops_init_platform_cm7_impl`.

---

## Hard-won facts (bench-proven 2026-07-08, UART6/SBUS saga)

1. **OPS UART RX task owns every UART port.** At boot it arms a perpetual 1-byte
   `HAL_UART_Receive_IT` per RX-capable port; its IRQ post-processing **re-arms whenever it sees the
   port listening-but-unarmed** — i.e. the instant any customer HAL receive completes. Symptom:
   `HAL_UART_Receive_IT` returns `HAL_BUSY` forever, `RxXferCount` pinned at 1.
2. **Release a port with `UART_Task_StopPort(id)`** (disables listen + aborts RX). After that,
   plain HAL reception on that port works. This is THE way to take a UART away from OPS.
   (`UART_Task_SetListen(id,false)` is the softer variant; `UART_Task_StartPort` gives it back.)
3. **`UART_Task_HAL_IRQHandler` forwards to `HAL_UART_IRQHandler` internally** (verified via
   relocations in `uart_task.o`), so `stm32h7xx_it.c` routing all UART IRQs to it does NOT break
   customer HAL IT-mode reception — no IRQ rerouting needed.
4. **A customer `HAL_UART_Init` silently kicks OPS off the port** (resets `RxState` to READY without
   OPS noticing) — you win exactly one receive, then OPS steals the port back at the first
   completion. Don't rely on it; use `UART_Task_StopPort`.
5. **OPS boot init already enables the USART6 NVIC line** — customer `HAL_NVIC_EnableIRQ(USART6_IRQn)`
   proved unnecessary (works with it commented out).
6. `HAL_UART_RxCpltCallback` / `HAL_UART_ErrorCallback` are **defined inside CM4 libops.a** — customer
   code cannot define its own without a linker collision. Work via the task API instead.
7. Web "Save & Apply" writes **EEPROM only**; live peripheral registers are untouched until reboot.

---

## Legend

| Core column | Meaning |
|---|---|
| CM4+CM7 | symbol in both `libops.a` — check brief for which core may call it |
| **CM4 only** / **CM7 only** | symbol exists only in that core's binary |
| inline (both) | `static inline` in header — compiles into caller on either core |
| hook/weak — no lib body | declared in header, absent from both binaries — customer provides/overrides it |

---

## UART (peripherals/uart/)


### `peripherals/uart/uart_function.h` — High-level UART transmit — one entry point, same API on CM4 and CM7.

| Function | Core | Purpose |
|---|---|---|
| `uart_send_ctrl` | CM4+CM7 | Master UART transmit — same on CM4 and CM7. |
| `UART_SendString` | CM4+CM7 | Send null-terminated ASCII string. |
| `UART_SendInt` | CM4+CM7 | Send 32-bit value as four raw bytes (MSB first). |
| `UART_SendIntToASCII` | CM4+CM7 | Send 32-bit value as decimal ASCII. |
| `UART_SendBool` | CM4+CM7 | Send `"TRUE"` or `"FALSE"` . |
| `UART_SendHex` | CM4+CM7 | Send 16-bit value as 4-digit hex ASCII. |
| `UART_SendChar` | CM4+CM7 | Send one ASCII character. |

### `peripherals/uart/uart_rx_parse.h` — Incremental UART frame assembly from `uart_config_t` end_mode settings.

| Function | Core | Purpose |
|---|---|---|
| `uart_rx_parser_reset` | CM4+CM7 | Reset parser and copy framing fields from `cfg` . |
| `uart_rx_parser_feed` | CM4+CM7 | Process one received byte. |
| `uart_rx_parser_poll_idle` | CM4+CM7 | Check silence/idle end modes after ring is empty. |

### `peripherals/uart/uart_rx_shared.h` — Last completed UART RX frame per port in SRAM4 (CM4 producer, CM7 reader).

| Function | Core | Purpose |
|---|---|---|
| `uart_rx_shared_uart_id_to_index` | CM4+CM7 | Map logical `uart_id` to index 0..6. |
| `uart_rx_shared_init` | CM4+CM7 | Initialise SRAM4 store (safe on CM4 and CM7). |
| `uart_rx_shared_publish` | CM4+CM7 | Publish one completed frame (CM4 producer only). |
| `uart_rx_shared_fetch` | CM4+CM7 | Copy last published frame for `uart_id` . |

### `peripherals/uart/uart_task.h` — CM4 UART RX task: IRQ ring, framing, SRAM4 publish for CM7.

| Function | Core | Purpose |
|---|---|---|
| `UART_Task_UartIdFromHandle` | CM4+CM7 | Map HAL handle to logical uart_id (1,2,3,4,6,7,8). |
| `UART_Task_HandleFromUartId` | CM4+CM7 | Reverse map uart_id to HAL handle. |
| `UART_Task_Init` | CM4+CM7 | Create RX task and sync primitives (CM4); SRAM4 init on both cores. |
| `UART_Task_StartAfterInit` | CM4+CM7 | Register port after `UART_Init` (CM4): copy cfg, enable listen if RX capable. |
| `UART_Task_StartPort` | CM4+CM7 | Enable listen + arm RX for `uart_id` (CM4). |
| `UART_Task_StopPort` | CM4+CM7 | Disable listen and abort RX (CM4). |
| `UART_Task_RestartPort` | CM4+CM7 | Stop then start `uart_id` (CM4). |
| `UART_Task_SetListen` | CM4+CM7 | Software enable/disable RX processing without de-init (CM4). |
| `UART_Task_SetConfig` | CM4+CM7 | Update in-RAM config; re-arms RX when listen is on (CM4). |
| `UART_Task_IsListening` | CM4+CM7 | Query listen flag (CM4). |
| `UART_Task_IsServiceRunning` | CM4+CM7 | True if RX task thread exists (CM4). |
| `UART_Task_HAL_IRQHandler` | CM4+CM7 | Dispatch from USART/UART IRQ — call from `HAL_UART_IRQHandler` path (CM4). |
| `UART_RxShared_FetchLast` | CM4+CM7 | Copy last completed frame from SRAM4 (CM7 or CM4 reader). |
| `UART_Task_OnFrame` | hook/weak — no lib body | Optional weak hook when a frame completes (CM4 task context). |

### `peripherals/uart/usart.h` — UART1/2/3/4/6/7/8 HAL init, voltage select, and core-access helpers.

| Function | Core | Purpose |
|---|---|---|
| `UART_Init` | CM4+CM7 | Initialise UART with settings from `config` . |
| `UART_DeInit` | CM4+CM7 | De-initialise UART (peripheral + IRQ; GPIO unchanged). |
| `HAL_UART_MspInit` | CM4+CM7 | De-initialise UART (peripheral + IRQ; GPIO unchanged). |
| `HAL_UART_MspDeInit` | CM4+CM7 | De-initialise UART (peripheral + IRQ; GPIO unchanged). |
| `UART_Voltage_Init` | CM4+CM7 | Configure TX voltage selector GPIO for UART6 or UART7. |
| `UART_SetVoltage` | CM4+CM7 | Select TX supply (`SUPPLY_VOLTAGE_3V3` or `SUPPLY_VOLTAGE_5V` ). |
| `UART_IsCoreAllowed` | CM4+CM7 | Select TX supply (`SUPPLY_VOLTAGE_3V3` or `SUPPLY_VOLTAGE_5V` ). |
| `UART_HasAnyCoreAccess` | CM4+CM7 | Select TX supply (`SUPPLY_VOLTAGE_3V3` or `SUPPLY_VOLTAGE_5V` ). |

## ADC (peripherals/ADC/)


### `peripherals/ADC/adc.h` — Low-level ADC HAL init and channel GPIO mapping (CM4 ownership).

| Function | Core | Purpose |
|---|---|---|
| `ADC_Init` | CM4+CM7 | Initialise one ADC peripheral instance (CM4 when allowed). |
| `ADC_DeInit` | CM4+CM7 | De-initialise one ADC instance. |
| `ADC_Channel_Init` | CM4+CM7 | Initialise HAL channel + analog GPIO for `alias` . |
| `ADC_Channel_ApplyAinMuxGpio` | CM4+CM7 | Drive AIN1..6 current/voltage mux GPIO from `ain_cfg->input_type` . |
| `ADC_Channel_InvalidateAinMuxGpio` | CM4+CM7 | Forget cached mux state so next `ADC_Channel_ApplyAinMuxGpio` forces GPIO update. |
| `ADC_Channel_DeInit` | CM4+CM7 | De-initialise channel and reset GPIO to default. |
| `adc_get_os_ratio` | CM4+CM7 | Oversampling ratio for `hadc` (1 when disabled). |

### `peripherals/ADC/adc_functions.h`

| Function | Core | Purpose |
|---|---|---|
| `adc_ctrl` | CM4+CM7 | Run one ADC operation (same call on CM4 and CM7). Internally chooses local HAL vs ICC. Returns |
| `quantity_to_str` | CM4+CM7 | Run one ADC operation (same call on CM4 and CM7). Internally chooses local HAL vs ICC. Returns |
| `scale_to_str` | CM4+CM7 | Run one ADC operation (same call on CM4 and CM7). Internally chooses local HAL vs ICC. Returns |
| `adc_cal_stats_format_json` | CM4+CM7 | Run one ADC operation (same call on CM4 and CM7). Internally chooses local HAL vs ICC. Returns |

### `peripherals/ADC/adc_functions_icc.h` — ICC server bridge for ADC — include only from `intercore_comm.c` and `adc_functions.c` .

| Function | Core | Purpose |
|---|---|---|
| `ADC_ICC_HandlePacket` | CM4+CM7 | ICC server entry for `IC_CH_ADC` (CM4 build with ADC HAL ownership). |

### `peripherals/ADC/adc_shared_memory.h` — CM4↔CM7 shared ADC snapshot in SRAM4 with hardware-semaphore–gated reader/writer exclusion.

| Function | Core | Purpose |
|---|---|---|
| `ADC_Shared_Init` | CM4+CM7 | Initialise magic/version in SRAM4 (safe on CM4 and CM7). |
| `ADC_Shared_AliasToIndex` | CM4+CM7 | Map `alias` to shared-store index 0..N-1. |
| `ADC_Shared_PublishChannel` | CM4+CM7 | CM4 producer: publish one channel snapshot + rail stats + sample counter. |
| `ADC_Shared_ReadChannel` | CM4+CM7 | CM4 or CM7 consumer: copy last published data for one channel index. |
| `ADC_Shared_ReadByAlias` | CM4+CM7 | Same as `ADC_Shared_ReadChannel` but resolves @a alias to the internal channel index. |
| `ADC_Shared_ClearPublishedChannel` | CM4+CM7 | CM4: publish an all-zero sample and rail block (e.g. channel stop / inactive). |

### `peripherals/ADC/adc_task.h` — CM4 FreeRTOS sampler tasks — filter, rail stats, publish to SRAM4.

| Function | Core | Purpose |
|---|---|---|
| `ADC_Task_IsVoltageRailStatsAlias` | CM4+CM7 | True when `alias` has a dedicated sampler task slot. |
| `ADC_Task_GetVoltageRailStats` | CM4+CM7 | Read min/max rail stats from CM4 task RAM. |
| `ADC_Task_ResetVoltageRailStatsForAlias` | CM4+CM7 | Clear min/max trackers for one channel. |
| `ADC_Task_ResetAllVoltageRailStats` | CM4+CM7 | Clear min/max on all sampler channels. |
| `adc_task_sample_to_wire` | CM4+CM7 | Pack CM4 sample into wire layout for ICC. |
| `adc_task_sample_from_wire` | CM4+CM7 | Unpack wire layout into `adc_task_channel_data_t` . |
| `ADC_Task_Init` | CM4+CM7 | Create task infrastructure (CM4); no-op on CM7. |
| `ADC_Task_StartAll` | CM4+CM7 | Start all configured sampler threads (CM4). @return true on success. |
| `ADC_Task_StopAll` | CM4+CM7 | Stop all sampler threads (CM4). |
| `ADC_Task_RestartAll` | CM4+CM7 | Stop then start all sampler threads (CM4). |
| `ADC_Task_StartChannel` | CM4+CM7 | Start sampler for `alias` if not running (CM4). |
| `ADC_Task_StopChannel` | CM4+CM7 | Stop sampler for `alias` (CM4). |
| `ADC_Task_RestartChannel` | CM4+CM7 | Stop and restart sampler for `alias` (CM4). |
| `ADC_Task_GetChannelData` | CM4+CM7 | Last filtered sample by task index 0..`ADC_TASK_CHANNEL_COUNT-1` (CM4 RAM). |
| `ADC_Task_GetChannelDataByAlias` | CM4+CM7 | Last filtered sample by alias (CM4 RAM). |
| `ADC_Task_GetChannelPartialByAlias` | CM4+CM7 | Copy subset of last sample fields. |
| `ADC_Task_GetChannelDebugByAlias` | CM4+CM7 | Debug snapshot including Kalman state when applicable. |
| `ADC_Task_IsChannelRunning` | CM4+CM7 | Query whether sampler thread is running (CM4). |
| `ADC_Task_SetChannelConfig` | CM4+CM7 | Update runtime cfg for one channel (web apply path on CM4). |
| `ADC_Task_IsSamplerChannelAlias` | CM4+CM7 | True if `alias` is driven by the ADC sampler task. |

## PWM (peripherals/PWM/)


### `peripherals/PWM/pwm.h` — PWM OUT timers (CM4) and PWM IN hardware capture (TIM2/3/5/8, CM4).

| Function | Core | Purpose |
|---|---|---|
| `pwm_out_init` | CM4+CM7 | Initialise PWM OUT timers/GPIO on CM4. |
| `pwm_out_deinit` | CM4+CM7 | Stop PWM OUT and release timer resources (CM4). |
| `pwm_out_is_initialized` | CM4+CM7 | True after successful `pwm_out_init` on CM4. |
| `pwm_out_update_frequency_hz` | CM4+CM7 | Set base frequency for PWM OUT `channel_id` (1..4). |
| `pwm_out_get_period_ticks` | CM4+CM7 | Period ticks for `channel_id` . |
| `pwm_in_init` | CM4+CM7 | Prepare capture driver state (CM4). No-op on CM7. |
| `pwm_in_deinit` | CM4+CM7 | Stop all capture timers (CM4). |
| `pwm_in_capture_apply` | CM4+CM7 | Apply `cfg` to one channel: stop previous capture, start if active. |
| `pwm_in_capture_read` | CM4+CM7 | Read latest captured period/duty (non-blocking). |
| `pwm_in_capture_log_init_status` | **CM4 only** | One-line capture status on `CM4_INIT_DEBUG_UART` (when `CM4_INIT_DEBUG` ). |

### `peripherals/PWM/pwm_functions.h` — PWM OUT/IN runtime — one function per direction, same on CM4 and CM7.

| Function | Core | Purpose |
|---|---|---|
| `pwm_out_is_on_this_core` | inline (both) | True when this core may drive PWM OUT GPIO/timers locally. |
| `pwm_out_exists_on_device` | inline (both) | True when PWM OUT exists on the device (always CM4 on this board). |
| `pwm_in_is_on_this_core` | inline (both) | True when this core runs PWM IN capture tasks locally. |
| `pwm_out_ctrl` | CM4+CM7 | Run one PWM OUT operation (same call on CM4 and CM7). |
| `pwm_in_ctrl` | CM4+CM7 | Run one PWM IN operation (same call on CM4 and CM7). |

### `peripherals/PWM/pwm_functions_icc.h` — ICC server bridge for PWM — include only from `intercore_comm.c` and `pwm_functions.c` .

| Function | Core | Purpose |
|---|---|---|
| `PWM_OUT_ICC_HandlePacket` | CM4+CM7 | ICC server for `IC_CH_PWM` (CM4 with `IS_PWM_OUT_ALLOWED()` ). |
| `PWM_IN_ICC_HandlePacket` | CM4+CM7 | ICC server for `IC_CH_PWM_IN` (CM4 only). |

### `peripherals/PWM/pwm_shared_memory.h` — CM4↔CM7 PWM IN snapshots in SRAM4 (HSEM `HSEM_PWM_IN_SHARED_MASTER_LOCK` ).

| Function | Core | Purpose |
|---|---|---|
| `pwm_shared_in_init` | CM4+CM7 | Initialise magic/version in SRAM4 (safe on CM4 and CM7). |
| `pwm_shared_in_channel_to_index` | CM4+CM7 | Map connector `channel_id` (1..4) to store index 0..3. |
| `pwm_shared_in_publish_channel` | CM4+CM7 | CM4 producer: publish sample + rail + metadata. |
| `pwm_shared_in_read_channel` | CM4+CM7 | Reader: copy last published data by store index. |
| `pwm_shared_in_read_by_channel_id` | CM4+CM7 | Same as `pwm_shared_in_read_channel` but uses connector id 1..4. |
| `pwm_shared_in_clear_published_channel` | CM4+CM7 | CM4: publish zeroed sample (channel stop / inactive). |

### `peripherals/PWM/pwm_task.h` — PWM IN sampler tasks (CM4) and live samples in SRAM4 for CM7/web.

| Function | Core | Purpose |
|---|---|---|
| `PWM_Task_InInit` | CM4+CM7 | Create mutexes and shared-store hooks; calls `pwm_in_init` on CM4. |
| `PWM_Task_InStartAll` | CM4+CM7 | Start sampler tasks for channels active in primary EEPROM (CM4). |
| `PWM_Task_InStopAll` | CM4+CM7 | Stop all PWM IN sampler tasks (CM4). |
| `PWM_Task_InRestartAll` | CM4+CM7 | Stop then start all channels (CM4). |
| `PWM_Task_InStartChannel` | CM4+CM7 | Start sampler for `channel_id` (1..4) if not running (CM4). |
| `PWM_Task_InStopChannel` | CM4+CM7 | Stop sampler for `channel_id` (1..4) (CM4). |
| `PWM_Task_InRestartChannel` | CM4+CM7 | Stop and restart sampler for `channel_id` (1..4) (CM4). |
| `PWM_Task_InSetChannelConfig` | CM4+CM7 | Update in-RAM config used by sampler (does not write EEPROM). |
| `PWM_Task_InGetChannelConfig` | CM4+CM7 | Copy in-RAM sampler config (CM4 only). |
| `PWM_Task_InIsChannelRunning` | CM4+CM7 | Query whether sampler thread is running (CM4). |
| `PWM_Task_InIsChannelActive` | CM4+CM7 | Active flag from in-RAM config (CM4; no EEPROM read). |
| `PWM_Task_InResetRailStats` | CM4+CM7 | Reset min/max rail stats (CM4). |
| `PWM_Task_InResetAlarm` | CM4+CM7 | Clear latched alarm flags (CM4). |

## GPIO (peripherals/GPIO/)


### `peripherals/GPIO/gpio.h` — Drive the MCU GPIO hardware from `gpio_config_t` (settings/EEPROM image).

| Function | Core | Purpose |
|---|---|---|
| `GPIO_ConfigFromBoardPin` | CM4+CM7 | Set `cfg.port` and `cfg.pin` from a board name (`board_gpio_pin_t` ). |
| `GPIO_WriteLevelFromConfig` | CM4+CM7 | Drive high/low using `cfg.port` and `cfg.pin` (after `GPIO_Init` ). |
| `GPIO_BoardPinLookup` | CM4+CM7 | Resolve board pin to HAL port pointer and pin mask (for `gpio_functions.c` ). |
| `GPIO_Init` | CM4+CM7 | Resolve board pin to HAL port pointer and pin mask (for `gpio_functions.c` ). |
| `GPIO_DeInit` | CM4+CM7 | Release HAL configuration for one pin. |

### `peripherals/GPIO/gpio_functions.h` — GPIO level control only (high / low / read / toggle) by board pin name.

| Function | Core | Purpose |
|---|---|---|
| `gpio_set_pin_by_port_pin` | CM4+CM7 | Drive board pin high or low. |
| `gpio_read_pin_by_port_pin` | CM4+CM7 | Read board pin; true = high. |
| `gpio_toggle_pin_by_port_pin` | CM4+CM7 | Toggle board pin. |

## I2C (peripherals/I2C/)


### `peripherals/I2C/i2c.h` — I2C2/3/4 HAL init and core-access helpers (CM4 ownership on MFCB).

| Function | Core | Purpose |
|---|---|---|
| `I2C_Init` | CM4+CM7 | Initialise one I2C peripheral (CM4 when allowed). |
| `I2C_DeInit` | CM4+CM7 | De-initialise the given I2C peripheral. |
| `HAL_I2C_MspInit` | CM4+CM7 | De-initialise the given I2C peripheral. |
| `HAL_I2C_MspDeInit` | CM4+CM7 | De-initialise the given I2C peripheral. |
| `is_i2c_allowed` | CM4+CM7 | Internal — this core may touch `hi2c` HAL directly. |
| `i2c_has_any_core_access` | CM4+CM7 | Internal — any core owns `hi2c` per `peripherals_access.h` . |

### `peripherals/I2C/i2c_bus_lock.h` — Serialize CM4 access to I2C2 (M24M01 EEPROM) vs CM7 ICC forwards.

| Function | Core | Purpose |
|---|---|---|
| `I2C2_BusLockInit` | **CM4 only** | Create FreeRTOS mutex for I2C2 (call once from `I2C_Init` on `hi2c2` ). |
| `I2C2_BusLockTimeout` | **CM4 only** | Block until I2C2 is free or `timeout_ms` elapses. |
| `I2C2_BusLock` | **CM4 only** | Block until I2C2 is free (indefinite — prefer `I2C2_BusLockTimeout` in new code). |
| `I2C2_BusUnlock` | **CM4 only** | Release I2C2 mutex. |

### `peripherals/I2C/i2c_function.h` — I2C read/write/scan — same API on CM4 and CM7 (HAL or ICC inside).

| Function | Core | Purpose |
|---|---|---|
| `I2C_Scanner` | CM4+CM7 | Scan a given I2C bus for connected devices. |
| `Scan_I2C_Buses` | CM4+CM7 | Scan all defined I2C buses (hi2c2, hi2c3, hi2c4) |
| `I2C_DeviceExists` | CM4+CM7 | Check if a specific device exists on a given I2C bus. |
| `I2C_CheckDeviceReady` | CM4+CM7 | Checks if a specific device is ready on the I2C bus |
| `I2C_WriteByte` | CM4+CM7 | Writes a single byte to a device register. |
| `I2C_ReadByte` | CM4+CM7 | Reads a single byte from a device register. |
| `I2C_BurstWrite` | CM4+CM7 | Writes multiple bytes starting at `reg_addr` . |
| `I2C_BurstRead` | CM4+CM7 | Reads multiple bytes starting at `reg_addr` . |
| `I2C_SemiBurstWrite` | CM4+CM7 | Writes multiple bytes one register write at a time (semi-burst). |
| `I2C_SemiBurstRead` | CM4+CM7 | Reads multiple bytes one register read at a time (semi-burst). |
| `I2C_DummyWrite` | CM4+CM7 | Performs a "dummy write" to an I2C device (sends 1 byte without register) |

## SPI (peripherals/SPI/)


### `peripherals/SPI/spi.h` — SPI2/SPI4/SPI5 HAL handles and CubeMX init entry points.

| Function | Core | Purpose |
|---|---|---|
| `MX_SPI2_Init` | CM4+CM7 | CubeMX-generated init for SPI2 (CM4 external SPI). |
| `MX_SPI4_Init` | CM4+CM7 | CubeMX-generated init for SPI4 (CM4). |
| `MX_SPI5_Init` | CM4+CM7 | CubeMX-generated init for SPI5 (typically CM7). |

### `peripherals/SPI/spi_functions.h` — High-level SPI transfers and chip-select — same calls on CM4 and CM7.

| Function | Core | Purpose |
|---|---|---|
| `SPI_DeactivateAllChipSelects` | CM4+CM7 | Deactivate all chip selects on `spi_bus` . |
| `SPI_DeactivateChipSelect` | CM4+CM7 | Deactivate one chip select. |
| `SPI_ActivateChipSelect` | CM4+CM7 | Activate `chip_select` ; deactivates siblings on same bus first. |
| `SPI_SetChipSelect` | CM4+CM7 | Set CS line state explicitly. |
| `SPI_GetBusAndCSFromPin` | CM4+CM7 | Map a GPIO pin to SPI bus + CS index. |
| `SPI_Transmit_No_CS` | CM4+CM7 | Transmit without automatic CS handling. |
| `SPI_Transmit_With_CS` | CM4+CM7 | Transmit with CS assert/deassert around transfer. |
| `SPI_Receive_No_CS` | CM4+CM7 | Receive without CS handling. |
| `SPI_Receive_With_CS` | CM4+CM7 | Receive with CS handling. |
| `SPI_TransmitReceive_No_CS` | CM4+CM7 | Full-duplex transfer without CS handling. |
| `SPI_TransmitReceive_With_CS` | CM4+CM7 | Full-duplex transfer with CS handling. |
| `SPI_ICC_HandlePacket` | CM4+CM7 | ICC server entry for one SPI bus — internal only ( `intercore_comm.c` ). |

## Timer (peripherals/Timer/)


### `peripherals/Timer/timer.h` — Timer allocation and PWM OUT drivers on CM4 (STM32H757 MFCB board).

| Function | Core | Purpose |
|---|---|---|
| `Timer_PWM_OutChannelValid` | CM4+CM7 | < Enum bound for tables. |
| `Timer_PWM_OutGetInstance` | CM4+CM7 | < Enum bound for tables. |
| `Timer_PWM_OutGetHalChannel` | CM4+CM7 |  |
| `Timer_PWM_OutGetHandle` | **CM4 only** |  |
| `Timer_PWM_OutInit` | CM4+CM7 | Initialise TIM7 sw-PWM (CM4). @return true on success. |
| `Timer_PWM_OutDeInit` | CM4+CM7 | Stop OUT PWM and release TIM7 (CM4). |
| `Timer_PWM_OutIsReady` | CM4+CM7 | True after `Timer_PWM_OutInit` succeeded. |
| `Timer_PWM_OutReconfigurePinAf` | CM4+CM7 | Re-apply AF mapping for one OUT pin (CM4). @param channel 1..4. |
| `Timer_PWM_OutSetFrequencyHz` | CM4+CM7 | Set frequency for OUT `channel` (1..4, independent per channel). |
| `Timer_PWM_OutGetPeriodTicks` | CM4+CM7 | Period ticks for `channel` ; 0 if invalid. |
| `Timer_PWM_OutGetFrequencyHz` | **CM4 only** | Frequency in Hz for `channel` (after clamp). |
| `Timer_PWM_OutSetPulseTicks` | CM4+CM7 | Set high-time in timer ticks. @return false if out of range. |
| `Timer_PWM_OutSetChannelEnabled` | CM4+CM7 | Enable/disable output waveform. |
| `Timer_PWM_OutSetPolarityInverted` | CM4+CM7 | Active-low vs active-high polarity. |
| `Timer_PWM_OutBeginBatchUpdate` | CM4+CM7 | Begin atomic multi-channel update (CM4). |
| `Timer_PWM_OutEndBatchUpdate` | CM4+CM7 | Commit batched updates. @return false if not in batch mode. |
| `Timer_PWM_OutBatchUpdateActive` | CM4+CM7 | True between Begin and End batch calls. |
| `Timer_PWM_OutSharesTimebase` | CM4+CM7 | True when `channel_a` and `channel_b` share the same frequency (phase-aligned). |

## Inter-core communication ICC (peripherals/inter_core_communication/)


### `peripherals/inter_core_communication/intercore_comm.h` — Dual-core ICC: HSEM + ring buffers in SRAM4 (STM32H757).

| Function | Core | Purpose |
|---|---|---|
| `ICC_Init` | CM4+CM7 | Initialize the inter-core comm subsystem. What it does: - Places ringbuffer head/tail = 0 for all 4 buffers in shared SRAM4. - Enables HSEM clock and configures the correct HSEM IRQ for the current core. - Creates two Fr |
| `icc_diag_ring_fill_cm4` | CM4+CM7 | CM4 only: ring buffer fill 0..100 % (CM7→CM4 = what starves CM4 during web/EEPROM). |
| `ICC_SendPacket_NO_ID` | CM4+CM7 | Send packet without ID. |
| `ICC_SendPacket_WITH_ID` | CM4+CM7 | Send packet with ID. |
| `ICC_PacketReceivedHook_NO_ID` | hook/weak — no lib body | Hook called when a NO_ID packet arrives. |
| `ICC_PacketReceivedHook_WITH_ID` | hook/weak — no lib body | Hook called when a WITH_ID packet arrives. |
| `ICC_HSEM_IRQHandler` | CM4+CM7 | Lightweight wrapper called from HSEM IRQ handler. Behavior: - Clears the incoming HSEM flags (the ones the remote core sets). - Wakes the ICC tasks via osThreadFlagsSet(...). IMPORTANT: - This function is safe to call fr |
| `ICC_GetNextPacketID` | CM4+CM7 | Generate the next available packet ID for this core |
| `ICC_ShouldHandleResponse` | CM4+CM7 | Check if this core should handle a response based on packet ID |
| `ICC_AllocResponseSlot` | CM4+CM7 | Allocate a new response slot for tracking pending responses |
| `ICC_FindResponseSlot` | CM4+CM7 | Find a response slot by packet ID |
| `ICC_FreeResponseSlot` | CM4+CM7 | Free a response slot |
| `ICC_WaitForResponse` | CM4+CM7 | Wait for response with timeout |
| `ICC_SendResponse` | CM4+CM7 | Send response back to requesting core |
| `ICC_HandleResponsePacket` | CM4+CM7 | Handle incoming response packets |

## STM info (peripherals/STM_info/)


### `peripherals/STM_info/STM_info.h` — STM32 device ID, revision, 96-bit UID, and clock frequency helpers.

| Function | Core | Purpose |
|---|---|---|
| `STM_GetExactTypeString` | CM4+CM7 | Returns the exact STM32H7 type as a human-readable string. This function uses build-time device defines (e.g. STM32H757xx) to return the commercial STM32 type (STM32H757, STM32H745, ...). It complements the DBGMCU-based  |
| `STM_GetSerialNumber` | CM4+CM7 | Reads the 96-bit unique serial number from STM32H7 chip This function reads the three 32-bit registers that contain the device's unique serial number (96 bits total). The result is returned in three parts with part1 bein |
| `STM_GetDeviceInfo` | CM4+CM7 | Retrieves device information including device number and name This function reads the device identifier from DBGMCU_IDCODE register and matches it against known STM32H7 devices to return both the numeric identifier and h |
| `STM_GetClockInfo` | CM4+CM7 | Retrieves clock frequency information for the current core This function reads various clock frequencies from the RCC registers. For dual-core devices, it detects dual-core capability and can provide per-core clock infor |

## Boot status (peripherals/stm_boot_status/)


### `peripherals/stm_boot_status/stm_boot_status.h` — Last boot / reset cause (STM32H757) — SRAM4 snapshot latched by CM7 at reset.

| Function | Core | Purpose |
|---|---|---|
| `STM_BootStatus_CaptureFromHardware` | CM4+CM7 | CM7 only: latch RCC reset flags into SRAM4, then clear hardware RSR. |
| `STM_BootStatus_ProcessBootEarly` | CM4+CM7 | CM4 only: process this boot immediately (counter + latch + clear snapshot). Call once from |
| `STM_BootStatus_GetResetCause` | CM4+CM7 | Returns classified reset cause for this boot. |
| `STM_BootStatus_Report` | CM4+CM7 | UART dump of latched RCC flags and classified cause (when `debugOutputStmBootStatus` is 1). |
| `STM_BootStatus_ResetCauseToString` | CM4+CM7 | Short English label for a reset cause (UART / logs / web). |
| `STM_BootStatus_AcknowledgeEvent` | CM4+CM7 | After handling: clear SRAM4 snapshot (RSR, flags, cause, pending) and RCC RSR. |
| `STM_BootStatus_ApplyFactoryResetIfNeeded` | CM4+CM7 | CM4 only: write EEPROM factory defaults if `STM_BootStatus_ProcessBootEarly` reached |
| `STM_BootStatus_ApplyResetButtonFactoryPolicy` | CM4+CM7 | Same as `STM_BootStatus_ApplyFactoryResetIfNeeded` (legacy name). |
| `STM_BootStatus_GetResetButtonPressCount` | CM4+CM7 | Warm reset-button count after `STM_BootStatus_ProcessBootEarly` on this boot. |
| `STM_BootStatus_WasFactoryResetTriggeredThisBoot` | CM4+CM7 | True if `STM_BootStatus_ApplyFactoryResetIfNeeded` wrote factory defaults this boot. |

## Peripherals umbrella / access / pins (peripherals/)


### `peripherals/stm32h757_pins.h` — MFCB board signal names and pin accessors (physical map in stm32h757_pins.c).

| Function | Core | Purpose |
|---|---|---|
| `board_pins_detect_hardware_version` | CM4+CM7 | Detect PCB pin-map revision (AT24MAC402 EEPROM on I2C2, CM4 only). |
| `board_pins_select_hardware` | CM4+CM7 | Switch active pin/ADC map for this boot. |
| `board_pins_init` | CM4+CM7 | Init pin map: autodetect via `board_pins_detect_hardware_version()` then select map. |
| `board_pins_init_with` | CM4+CM7 | Init pin map with explicit revision (skips autodetect). |
| `board_pins_get_active_hardware` | CM4+CM7 | Map currently selected by `board_pins_select_hardware()` . |
| `board_pin_port` | CM4+CM7 | Map currently selected by `board_pins_select_hardware()` . |
| `board_pin_pin_mask` | CM4+CM7 |  |
| `board_pin_af` | CM4+CM7 |  |
| `board_pin_adc_hal` | CM4+CM7 |  |
| `board_pin_adc_channel` | CM4+CM7 |  |

## Settings supporting types (Settings/supporting_types_functions/)


### `Settings/supporting_types_functions/communication_channels.h` — Communication channel enum and string labels for `device_info_t` and settings/UI.

| Function | Core | Purpose |
|---|---|---|
| `comm_channel_to_string` | CM4+CM7 | Human-readable label for `channel` (e.g. `"UART1"` , `"IP3"` ). |

### `Settings/supporting_types_functions/date_type.h` — 7-byte EEPROM date type and pack/unpack helpers.

| Function | Core | Purpose |
|---|---|---|
| `date_pack` | CM4+CM7 | Pack `dt` into 7-byte array for EEPROM storage. |
| `date_unpack` | CM4+CM7 | Unpack 7-byte EEPROM representation into `dt` . |

### `Settings/supporting_types_functions/ip_address.h` — IPv4 address struct and parse/format helpers for network and IP-channel settings.

| Function | Core | Purpose |
|---|---|---|
| `parse_ipv4` | CM4+CM7 | Parse dotted-decimal IPv4 (e.g. `"192.168.1.10"` ) into four bytes. |
| `ipv4_to_string` | CM4+CM7 | Format `ip` into `buffer` as dotted-decimal (no trailing newline). |

### `Settings/supporting_types_functions/sample_rate.h` — Sample rate enumerations: `SampleRate` (integer Hz) and `ain_sample_freq_t` (0.1 Hz..400 Hz).

| Function | Core | Purpose |
|---|---|---|
| `ain_sample_freq_to_str` | CM4+CM7 | Human-readable string for AIN sample frequency (e.g. "0.1 Hz (every 10 s)", "10 Hz"). |
| `ain_sample_freq_to_hz` | CM4+CM7 | Frequency in Hz (0.1f .. 400.0f) for timer/period use. |
| `sample_rate_to_string` | CM4+CM7 | Converts a SampleRate enum value to its string representation |
| `dump_debug_sample_rate` | CM4+CM7 | Outputs debug info of the sample rate via a user-defined output function |

### `Settings/supporting_types_functions/save_load_settings.h` — Low-level EEPROM read/write for settings slots and individual `settings_block_t` regions.

| Function | Core | Purpose |
|---|---|---|
| `get_settings_slot_address` | CM4+CM7 | Returns the start address of a settings slot |
| `validate_eeprom_address` | CM4+CM7 | Validates that a memory location and size are within EEPROM bounds |
| `save_settings_to_eeprom` | CM4+CM7 | Saves settings data to EEPROM |
| `load_settings_from_eeprom` | CM4+CM7 | Loads settings data from EEPROM |
| `save_settings_slot` | CM4+CM7 | Save a settings slot by enum |
| `load_settings_slot` | CM4+CM7 | Load a settings slot by enum |
| `save_settings_block` | CM4+CM7 | Save one logical `block` inside `slot` (address derived from `settings_location.h` layout). |
| `load_settings_block` | CM4+CM7 | Load one logical `block` from `slot` into `local_data` . |
| `load_settings_block_extended` | CM4+CM7 | Load one block at layout offset without `SETTINGS_BLOCK_SIZE` slot cap. For tail blocks (e.g. |
| `save_settings_block_extended` | CM4+CM7 | Save one block at layout offset without `SETTINGS_BLOCK_SIZE` slot cap. |

### `Settings/supporting_types_functions/separator.h` — CSV-style field separator: compact wire enum (lower 3 bits), parse/token helpers, wire-to-character mapping.

| Function | Core | Purpose |
|---|---|---|
| `text_sep_enum_token` | CM4+CM7 | Token string for `v` (e.g. `"comma"` ). |
| `text_sep_enum_parse` | CM4+CM7 | Parse user/config string to `text_sep_enum_t` ; returns `TEXT_SEP_COMMA` on unknown. |
| `text_sep_wire_char` | CM4+CM7 | Map separator wire (lower 3 bits) to a single UTF-8 byte for inline payloads. |

### `Settings/supporting_types_functions/settings_location.h` — Single source of truth for EEPROM settings layout: block ids, sizes, offsets, upgrade hooks.

| Function | Core | Purpose |
|---|---|---|
| `settings_get_offset` | CM4+CM7 | Compute absolute EEPROM byte offset for `block` within the layout (checks overflow). |
| `settings_get_size` | CM4+CM7 | Return wired size in bytes for `block` ( `valid` false if unknown enum). |
| `settings_get_name` | CM4+CM7 | Stable ASCII name for debug, web tables, and UART listings. |
| `settings_get_offset_layout_v212` | CM4+CM7 | Slot-relative offset as in layout v2.1.2 (UART blocks were 10 bytes). For EEPROM migration only. |
| `settings_pwm_out_voltage_offset_layout_v216` | CM4+CM7 | EEPROM byte offset of `BLOCK_PWM_OUT_VOLTAGE` in settings layout v2.1.6 (block was after GPIO). |
| `settings_get_offset_layout_v216` | CM4+CM7 | Byte offset of `block` in layout v2.1.6 (voltage after GPIO; PWM_IN..GPIO at -1 vs v2.1.8). |
| `settings_get_offset_layout_v217` | CM4+CM7 | Byte offset of `block` in layout v2.1.7 (2-byte voltage after PWM_OUT4; tail at +1 vs v2.1.8). |
| `settings_get_offset_for_stored_layout` | CM4+CM7 | Get the slot-relative offset for a block for a stored (legacy) layout version. Used by EEPROM migration to read preserved user blocks from their old positions, even if the current firmware moved blocks around. |
| `settings_needs_upgrade` | CM4+CM7 | True if `stored` version differs from the firmware’s expected settings version. |
| `settings_upgrade` | CM4+CM7 | Perform layout/version migration or factory init path for `stored_version` . |

### `Settings/supporting_types_functions/supply_voltage.h` — Shared supply level enum (3.3 V / 5 V / unused / reserved) for UART TX, PWM OUT rails, etc.

| Function | Core | Purpose |
|---|---|---|
| `supply_voltage_to_string` | CM4+CM7 | Human-readable label ("3.3V", "5V", …). |
| `supply_voltage_sanitize` | CM4+CM7 | Clamp invalid raw wire value to `SUPPLY_VOLTAGE_UNUSED` . |
| `supply_voltage_gpio_select_5v` | CM4+CM7 | True when GPIO / enable pin should select 5 V (not 3.3 V). |
| `supply_voltage_from_pwm_out_wire` | CM4+CM7 | Decode one rail from a PWM OUT voltage EEPROM byte (2-bit field). |
| `supply_voltage_to_pwm_out_wire` | CM4+CM7 | Encode one rail into a PWM OUT voltage byte (2-bit field). |
| `supply_voltage_from_legacy_pwm_bit` | CM4+CM7 | Legacy PWM EEPROM: single bit set = 5 V, clear = 3.3 V. |
| `supply_voltage_from_web_binary` | CM4+CM7 | Web/GPIO/PWM select: 0 = 3.3 V, 1 = 5 V (`supply_voltage_to_web_binary).` |
| `supply_voltage_to_web_binary` | CM4+CM7 | 0 = 3.3 V, 1 = 5 V for legacy web query params. |

### `Settings/supporting_types_functions/time_unit.h` — Time unit enumeration and string/debug helpers for settings UI.

| Function | Core | Purpose |
|---|---|---|
| `time_unit_to_string` | CM4+CM7 | Human-readable string for `unit` . |
| `dump_debug_time_unit` | CM4+CM7 | Emit debug line for `unit` via `output` . |

### `Settings/supporting_types_functions/version.h` — `version_t` structure and pack/unpack/parse helpers for EEPROM version rows.

| Function | Core | Purpose |
|---|---|---|
| `version_unpack` | CM4+CM7 | Unpack 3 version bytes into `ver` . |
| `version_pack` | CM4+CM7 | Pack `ver` into 3 bytes. |
| `version_factory` | CM4+CM7 | Set `ver` to factory default (see `VERSION_FACTORY_ ` ). |
| `version_to_string` | CM4+CM7 | Format `ver` as `"major.minor.patch"` . |
| `version_from_string` | CM4+CM7 | Parse `"major.minor.patch"` into `ver` . |

## Application settings (Settings/Applications/)


### `Settings/Applications/Cranesystem/app_cranesystem_application_settings_types.h` — Cranesystem main-application sub-wire selector: first byte of APPLICATION EEPROM tail after `app_settings_common` .

| Function | Core | Purpose |
|---|---|---|
| `cranesystem_application_setting_type_to_str` | CM4+CM7 | Human-readable name for typed enum `v` . |
| `cranesystem_application_setting_type_wire_to_str` | CM4+CM7 | Human-readable name for raw wire byte (EEPROM / API). |

### `Settings/Applications/Cranesystem/app_cranesystem_master_settings_location.h` — Cranesystem master sub-application: minimal APPLICATION-tail indexed rows (sub + settings version).

| Function | Core | Purpose |
|---|---|---|
| `app_cranesystem_master_tail_indexed_byte_count` | CM4+CM7 | Total byte length of indexed master tail rows (sub + version). |
| `app_cranesystem_master_tail_get_offset` | CM4+CM7 | Byte offset of @a block within the master APPLICATION tail. |
| `app_cranesystem_master_tail_get_size` | CM4+CM7 | Wire size of row @a block . |
| `app_cranesystem_master_tail_get_name` | CM4+CM7 | Human-readable row label for @a block . |

### `Settings/Applications/Cranesystem/app_cranesystem_slave_settings_location.h` — Cranesystem slave sub-application: minimal APPLICATION-tail indexed rows (sub + settings version).

| Function | Core | Purpose |
|---|---|---|
| `app_cranesystem_slave_tail_indexed_byte_count` | CM4+CM7 | Total byte length of indexed slave tail rows (sub + version). |
| `app_cranesystem_slave_tail_get_offset` | CM4+CM7 | Byte offset of @a block within the slave APPLICATION tail. |
| `app_cranesystem_slave_tail_get_size` | CM4+CM7 | Wire size of row @a block . |
| `app_cranesystem_slave_tail_get_name` | CM4+CM7 | Human-readable row label for @a block . |

### `Settings/Applications/Cranesystem/app_cranesystem_stand_alone_settings_location.h` — Cranesystem stand-alone APPLICATION tail: EEPROM row table, offsets, and mapping to global IP channel blocks.

| Function | Core | Purpose |
|---|---|---|
| `app_cranesystem_stand_alone_application_tail_prefix_pack` | CM4+CM7 | Write the stand-alone APPLICATION-tail prefix (sub wire + schema `version_t` ). |
| `app_cranesystem_stand_alone_payload_prefix_pack` | CM4+CM7 | Legacy alias for `app_cranesystem_stand_alone_application_tail_prefix_pack` . |
| `app_cranesystem_stand_alone_transmit_row_block` | inline (both) | Map transmit column index to the matching `APP_CRANESYSTEM_STAND_ALONE_BLOCK_TRANSMIT_ ` enumerator. |
| `app_cranesystem_stand_alone_get_offset` | CM4+CM7 | Byte offset of @a block within the stand-alone APPLICATION tail (after the 8-byte common prefix). |
| `app_cranesystem_stand_alone_get_size` | CM4+CM7 | Wire size in bytes of one logical row @a block . |
| `app_cranesystem_stand_alone_get_name` | CM4+CM7 | Human-readable row label for diagnostics. |
| `app_cranesystem_stand_alone_payload_byte_count` | CM4+CM7 | Total APPLICATION-tail byte count for stand-alone (prefix + matrix rows + packed transmit bundle wire bytes). |
| `app_cranesystem_stand_alone_transmit_bundle_offset_bytes` | CM4+CM7 | Byte offset from start of APPLICATION tail to the first byte of the packed transmit matrix blob. |
| `app_cranesystem_stand_alone_transmit_bundle_wire_bytes` | CM4+CM7 | Packed on-wire size of transmit bundle (`CRANE_TX_SETTINGS_PACKED_SIZE;` v6 compact wire). |
| `app_cranesystem_transmit_idx_to_ip_channel_block` | CM4+CM7 | Map transmit column @a transmit_idx_0based to the global settings block that holds its `ip_channel_config_t` . |

### `Settings/Applications/Cranesystem/app_cranesystem_stand_alone_settings_manager.h` — Cranesystem stand-alone sub-application: in-memory transmit matrix, pack/unpack, IP channel EEPROM helpers.

| Function | Core | Purpose |
|---|---|---|
| `crane_tx_cell_pack` | inline (both) | Pack enable, debug, and slot (0..15) into one matrix cell byte. |
| `crane_tx_cell_get_en` | inline (both) | True when the transmit-enable bit is set in `c` . |
| `crane_tx_cell_get_dbg` | inline (both) | True when the debug-enable bit is set in `c` . |
| `crane_tx_cell_get_slot` | inline (both) | Slot index `0` … 15 encoded in bits 2–5 of @a c . |
| `cranesystem_standalone_tx_settings_factory` | CM4+CM7 | Initialise `out` to stand-alone transmit defaults (`CRANE_TX_FACTORY_ ` ). |
| `cranesystem_standalone_tx_settings_stored_payload_valid` | CM4+CM7 | `true` if @a bytes carries a known stand-alone matrix tail (v6 `M6,` legacy v5 `M5,` or v4 `M4` ). |
| `cranesystem_standalone_tx_settings_unpack` | CM4+CM7 | Decode matrix tail from EEPROM wire @a bytes into @a out (v6 compact wire, or legacy v5/v4). |
| `cranesystem_standalone_tx_settings_pack` | CM4+CM7 | Encode @a in into @a bytes (v6 wire, `CRANE_TX_SETTINGS_PACKED_SIZE` bytes): sanitise then copy. |
| `cranesystem_standalone_tx_settings_to_str` | CM4+CM7 | Human-readable dump for UART or debug (returns written length, or `-1` on error). |
| `app_cranesystem_transmit_ip_channel_factory_for_transmit` | CM4+CM7 | Factory defaults for `BLOCK_IP_CHANNEL(1+transmit_idx)` : all transmit IP rows enabled; UDP send-only to |
| `app_cranesystem_save_factory_ip_channels_all_transmits` | CM4+CM7 | Writes factory IP rows for all eight transmit indices (see `app_cranesystem_transmit_ip_channel_factory_for_transmit` ). |
| `app_cranesystem_read_ip_channel_for_transmit` | CM4+CM7 | Load packed IP channel row for @a transmit_idx_0based from @a slot into @a out (factory on failure). |
| `app_cranesystem_save_ip_channel_for_transmit` | CM4+CM7 | Persist @a cfg to the IP channel block for @a transmit_idx_0based in @a slot . |

### `Settings/Applications/Cranesystem/app_cranesystem_undefined_settings_location.h` — Cranesystem undefined sub-application wire: APPLICATION-tail indexed rows (sub + settings version).

| Function | Core | Purpose |
|---|---|---|
| `app_cranesystem_undefined_tail_indexed_byte_count` | CM4+CM7 |  |
| `app_cranesystem_undefined_tail_get_offset` | CM4+CM7 |  |
| `app_cranesystem_undefined_tail_get_size` | CM4+CM7 |  |
| `app_cranesystem_undefined_tail_get_name` | CM4+CM7 |  |

### `Settings/Applications/Cranesystem/cranesystem_settings_gates.h` — EEPROM-backed checks: main app Cranesystem + APPLICATION sub stand-alone (`device_info` + APPLICATION tail).

| Function | Core | Purpose |
|---|---|---|
| `cranesystem_settings_gates_main_is_cranesystem` | CM4+CM7 | True when `device_info` in `slot` reports main application Cranesystem. |
| `cranesystem_settings_gates_sub_is_stand_alone` | CM4+CM7 | True when the APPLICATION sub-type wire in `slot` is stand-alone. |
| `cranesystem_settings_gates_stand_alone` | CM4+CM7 | True when both main is Cranesystem and sub is stand-alone. |

### `Settings/Applications/Cranesystem/current_cranesystem_master_settings_version.h` — Schema version for Cranesystem sub-application `CRANESYSTEM_APP_SETTING_MASTER` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_cranesystem_master_settings_version` | CM4+CM7 | Fill `ver` with master Cranesystem schema version. |
| `get_current_cranesystem_master_settings_version_string` | CM4+CM7 | ASCII schema string for master Cranesystem settings. |

### `Settings/Applications/Cranesystem/current_cranesystem_slave_settings_version.h` — Schema version for Cranesystem sub-application `CRANESYSTEM_APP_SETTING_SLAVE` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_cranesystem_slave_settings_version` | CM4+CM7 | Fill `ver` with slave Cranesystem schema version. |
| `get_current_cranesystem_slave_settings_version_string` | CM4+CM7 | ASCII schema string for slave Cranesystem settings. |

### `Settings/Applications/Cranesystem/current_cranesystem_stand_alone_settings_version.h` — Schema version for Cranesystem sub-application `CRANESYSTEM_APP_SETTING_STAND_ALONE` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_cranesystem_stand_alone_settings_version` | CM4+CM7 | Fill `ver` with stand-alone Cranesystem schema version. |
| `get_current_cranesystem_stand_alone_settings_version_string` | CM4+CM7 | ASCII schema string for stand-alone Cranesystem settings. |

### `Settings/Applications/Cranesystem/current_cranesystem_undefined_settings_version.h` — Schema version for Cranesystem sub-application `CRANESYSTEM_APP_SETTING_UNDEFINED` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_cranesystem_undefined_settings_version` | CM4+CM7 | Fill `ver` with Cranesystem undefined-sub schema version. |
| `get_current_cranesystem_undefined_settings_version_string` | CM4+CM7 | ASCII schema string for Cranesystem undefined-sub settings. |

### `Settings/Applications/Drone/app_drone_application_settings_types.h` — Drone main-application sub-wire selector: first byte of APPLICATION EEPROM tail after `app_settings_common` .

| Function | Core | Purpose |
|---|---|---|
| `drone_application_setting_type_to_str` | CM4+CM7 | Human-readable name for typed enum `v` . |
| `drone_application_setting_type_wire_to_str` | CM4+CM7 | Human-readable name for raw wire byte (EEPROM / API). |

### `Settings/Applications/Drone/app_drone_undefined_settings_location.h` — Drone (`APPLICATION_TYPE_DRONE):` sub-application wire undefined — APPLICATION-tail prefix rows only.

| Function | Core | Purpose |
|---|---|---|
| `app_drone_undefined_tail_indexed_byte_count` | CM4+CM7 | Total byte length of indexed tail rows (sub + version). |
| `app_drone_undefined_application_tail_prefix_pack` | CM4+CM7 | Write sub wire + `version_t` into first four bytes of APPLICATION tail. |
| `app_drone_undefined_tail_get_offset` | CM4+CM7 | Byte offset of `block` within Drone undefined APPLICATION tail. |
| `app_drone_undefined_tail_get_size` | CM4+CM7 | Wire size of row `block` . |
| `app_drone_undefined_tail_get_name` | CM4+CM7 | Human-readable row label for `block` . |

### `Settings/Applications/Drone/current_drone_undefined_settings_version.h` — Schema version for Drone sub-application `DRONE_APP_SETTING_UNDEFINED` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_drone_undefined_settings_version` | CM4+CM7 | Fill `ver` with Drone undefined schema version. |
| `get_current_drone_undefined_settings_version_string` | CM4+CM7 | ASCII schema string for Drone undefined settings. |

### `Settings/Applications/Rheotune/app_rheotune_application_settings_types.h` — Rheotune main-application sub-wire selector: first byte of APPLICATION EEPROM tail after `app_settings_common` .

| Function | Core | Purpose |
|---|---|---|
| `rheotune_application_setting_type_to_str` | CM4+CM7 | Human-readable name for typed enum `v` . |
| `rheotune_application_setting_type_wire_to_str` | CM4+CM7 | Human-readable name for raw wire byte. |

### `Settings/Applications/Rheotune/app_rheotune_undefined_settings_location.h` — Rheotune (`APPLICATION_TYPE_RHEOTUNE):` sub-application wire undefined — APPLICATION-tail prefix rows.

| Function | Core | Purpose |
|---|---|---|
| `app_rheotune_undefined_tail_indexed_byte_count` | CM4+CM7 |  |
| `app_rheotune_undefined_application_tail_prefix_pack` | CM4+CM7 |  |
| `app_rheotune_undefined_tail_get_offset` | CM4+CM7 |  |
| `app_rheotune_undefined_tail_get_size` | CM4+CM7 |  |
| `app_rheotune_undefined_tail_get_name` | CM4+CM7 |  |

### `Settings/Applications/Rheotune/current_rheotune_undefined_settings_version.h` — Schema version for Rheotune sub-application `RHEOTUNE_APP_SETTING_UNDEFINED` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_rheotune_undefined_settings_version` | CM4+CM7 | Fill `ver` with Rheotune undefined schema version. |
| `get_current_rheotune_undefined_settings_version_string` | CM4+CM7 | ASCII schema string for Rheotune undefined settings. |

### `Settings/Applications/Silas/app_silas_application_settings_types.h` — Silas main-application sub-wire selector: first byte of APPLICATION EEPROM tail after `app_settings_common` .

| Function | Core | Purpose |
|---|---|---|
| `silas_application_setting_type_to_str` | CM4+CM7 | Human-readable name for typed enum `v` . |
| `silas_application_setting_type_wire_to_str` | CM4+CM7 | Human-readable name for raw wire byte. |

### `Settings/Applications/Silas/app_silas_undefined_settings_location.h` — Silas (`APPLICATION_TYPE_SILAS):` sub-application wire undefined — APPLICATION-tail prefix rows.

| Function | Core | Purpose |
|---|---|---|
| `app_silas_undefined_tail_indexed_byte_count` | CM4+CM7 |  |
| `app_silas_undefined_application_tail_prefix_pack` | CM4+CM7 |  |
| `app_silas_undefined_tail_get_offset` | CM4+CM7 |  |
| `app_silas_undefined_tail_get_size` | CM4+CM7 |  |
| `app_silas_undefined_tail_get_name` | CM4+CM7 |  |

### `Settings/Applications/Silas/current_silas_undefined_settings_version.h` — Schema version for Silas sub-application `SILAS_APP_SETTING_UNDEFINED` .

| Function | Core | Purpose |
|---|---|---|
| `get_current_silas_undefined_settings_version` | CM4+CM7 | Fill `ver` with Silas undefined schema version. |
| `get_current_silas_undefined_settings_version_string` | CM4+CM7 | ASCII schema string for Silas undefined settings. |

### `Settings/Applications/app_settings_common.h` — Fixed-size prefix of every APPLICATION EEPROM blob (before the per-main APPLICATION tail).

| Function | Core | Purpose |
|---|---|---|
| `app_settings_common_unpack` | CM4+CM7 | Decode the 8-byte APPLICATION common prefix from raw EEPROM bytes. |
| `app_settings_common_pack` | CM4+CM7 | Encode @a in into the 8-byte wire prefix at @a bytes . |
| `app_settings_common_factory` | CM4+CM7 | Initialise @a out to product defaults (undefined main type + factory date). |

### `Settings/Applications/application_settings_regulator.h` — Validation and defaults for the APPLICATION sub-type wire byte.

| Function | Core | Purpose |
|---|---|---|
| `application_settings_default_setting_type_for_main` | CM4+CM7 | Default sub-application wire for @a main_type . |
| `application_settings_validate_setting_type_for_main` | CM4+CM7 | Returns whether @a wire_byte is legal for @a main_type . |
| `application_settings_setting_type_wire_to_str` | CM4+CM7 | English label for a stored sub-application wire under @a main_type . |

### `Settings/Applications/application_subapp_settings_versions.h` — Combined “current application settings” schema `version_t` (lexicographic max over sub-roles).

| Function | Core | Purpose |
|---|---|---|
| `get_current_application_settings_version` | CM4+CM7 | Highest schema version among all registered sub-application / role settings blobs. |
| `get_current_application_settings_version_string` | CM4+CM7 | ASCII `"major.minor.patch"` for `get_current_application_settings_version` . |

### `Settings/Applications/undefined/app_undefined_settings_location.h` — Main application type undefined (`APPLICATION_TYPE_UNDEFINED):` APPLICATION-tail block indices and helpers.

| Function | Core | Purpose |
|---|---|---|
| `app_role_undefined_tail_indexed_byte_count` | CM4+CM7 | Total byte length of indexed main-type-undefined tail rows (sub + version). |
| `app_role_undefined_application_tail_prefix_pack` | CM4+CM7 | Write sub wire + `version_t` into the first four bytes of the main-type-undefined APPLICATION tail. |
| `app_role_undefined_tail_get_offset` | CM4+CM7 | Byte offset of @a block within this APPLICATION tail. |
| `app_role_undefined_tail_get_size` | CM4+CM7 | Wire size of row @a block . |
| `app_role_undefined_tail_get_name` | CM4+CM7 | Human-readable row label for @a block . |

### `Settings/Applications/undefined/current_app_role_undefined_settings_version.h` — Schema version for main application `APPLICATION_TYPE_UNDEFINED` (no concrete product selected).

| Function | Core | Purpose |
|---|---|---|
| `get_current_app_role_undefined_settings_version` | CM4+CM7 | Fill `ver` with main-type-undefined schema version from macros in this header. |
| `get_current_app_role_undefined_settings_version_string` | CM4+CM7 | ASCII schema string for main-type undefined settings. |

## Settings blocks (Settings/)


### `Settings/adc_config.h` — Hardware configuration for ADC peripheral controllers (`BLOCK_ADC1..3` ).

| Function | Core | Purpose |
|---|---|---|
| `adc_config_factory` | CM4+CM7 | Set global ADC settings to factory defaults (`ADC_FACTORY_ ` ). |
| `adc_config_pack` | CM4+CM7 | Pack the configuration into a 4-byte buffer for storage. |
| `adc_config_unpack` | CM4+CM7 | Unpack a 4-byte buffer into `cfg` . |
| `adc_resolution_to_str` | CM4+CM7 | Label for `res` . |
| `adc_prescaler_to_str` | CM4+CM7 | Label for `pre` . |
| `adc_overrun_to_str` | CM4+CM7 | Label for `ovr` . |
| `adc_config_to_str` | CM4+CM7 | Debug string (static buffer; not re-entrant). |
| `adc_config_to_string` | CM4+CM7 | Write ADC config to a string buffer (for settings display). |

### `Settings/ain_config.h` — Analog input (AIN) channel settings — alias, sampling, filter, scaling, alarms (56 B EEPROM).

| Function | Core | Purpose |
|---|---|---|
| `ain_config_unpack` | CM4+CM7 | Deserialize EEPROM bytes into `cfg` . |
| `ain_config_pack` | CM4+CM7 | Serialize `cfg` to EEPROM bytes. |
| `ain_config_is_sane` | CM4+CM7 | Check unpacked config is within valid enum/range limits. |
| `ain_config_sanitize` | CM4+CM7 | Repair single fields using factory defaults for `factory_index` . |
| `ain_config_from_eeprom_bytes` | CM4+CM7 | Unpack + sanitize; fails on NULL, short buffer, or all 0xFF. |
| `ain_config_factory` | CM4+CM7 | Fill factory defaults for one logical row (`index` ). |
| `adc_sample_time_to_str` | CM4+CM7 | Fill factory defaults for one logical row (`index` ). |
| `analog_input_type_to_str` | CM4+CM7 | Fill factory defaults for one logical row (`index` ). |
| `filter_type_to_str` | CM4+CM7 | Fill factory defaults for one logical row (`index` ). |
| `ain_filter_source_to_str` | CM4+CM7 |  |
| `ain_config_to_str` | CM4+CM7 |  |
| `ain_get_hal_sample_time` | CM4+CM7 | Map `adc_sample_time_t` to STM32 HAL constant for `adc_functions` . |

### `Settings/current_firmware_version.h` — Central place for current firmware version (macros) and get/to_string helpers.

| Function | Core | Purpose |
|---|---|---|
| `get_current_firmware_version` | CM4+CM7 | Get the current firmware version as a `version_t` . |
| `get_current_firmware_version_string` | CM4+CM7 | Get the current firmware version as string (`"major.minor.patch"` ). |

### `Settings/current_settings_version.h` — Central place for current settings/layout version (macros) and get/to_string helpers.

| Function | Core | Purpose |
|---|---|---|
| `get_current_settings_version` | CM4+CM7 | Get the current settings/layout version as a `version_t` . |
| `get_current_settings_version_string` | CM4+CM7 | Get the current settings/layout version as string (`"major.minor.patch"` ). |

### `Settings/dac_config.h` — DAC global (1 byte) and per-channel EEPROM settings: limits, startup, names.

| Function | Core | Purpose |
|---|---|---|
| `dac_global_config_pack` | CM4+CM7 | Pack global DAC settings into one EEPROM byte. |
| `dac_global_config_unpack` | CM4+CM7 | Unpack one EEPROM byte into `cfg` . |
| `dac_global_config_factory` | CM4+CM7 | Factory defaults for global DAC block (`DAC_GLOBAL_FACTORY_ ` ). |
| `dac_channel_config_pack` | CM4+CM7 | Pack per-channel DAC settings to EEPROM wire bytes. |
| `dac_channel_config_unpack` | CM4+CM7 | Unpack EEPROM bytes into `cfg` . |
| `dac_channel_config_factory` | CM4+CM7 | Factory defaults for one DAC channel (`DAC_CHANNEL_FACTORY_ ` ). |
| `dac_power_mode_to_str` | CM4+CM7 | Human-readable power-down mode name. |
| `dac_rounding_to_str` | CM4+CM7 | Human-readable rounding mode name. |
| `dac_global_config_to_str` | CM4+CM7 | Debug string for global config (static buffer; not re-entrant). |
| `dac_channel_config_to_str` | CM4+CM7 | Debug string for channel config (static buffer; not re-entrant). |

### `Settings/device_info.h` — Device identity and role block (`BLOCK_DEVICE_INFO):` name, debug channel, application type.

| Function | Core | Purpose |
|---|---|---|
| `device_info_unpack` | CM4+CM7 | Deserialize EEPROM/raw bytes into `device` . |
| `device_info_pack` | CM4+CM7 | Serialize `device` into the packed EEPROM layout. |
| `device_info_factory` | CM4+CM7 | Fill `device` with factory defaults (`DEVICE_INFO_FACTORY_ ` ). |
| `device_info_name_stored_valid` | CM4+CM7 | True if EEPROM name field looks user-set (non-empty, not only whitespace). |
| `application_type_to_string` | CM4+CM7 | Short English label for `type` . |
| `device_info_to_string` | CM4+CM7 | Multi-field summary of `device` into `out` . |

### `Settings/fdcan_config.h` — FDCAN port settings (2-byte EEPROM block per controller).

| Function | Core | Purpose |
|---|---|---|
| `fdcan_config_unpack` | CM4+CM7 | Deserialize 2 EEPROM bytes into `cfg` . |
| `fdcan_config_pack` | CM4+CM7 | Serialize `cfg` to 2 EEPROM bytes. |
| `fdcan_config_factory` | CM4+CM7 | Factory defaults (`FDCAN_FACTORY_ ` : normal, CAN FD, termination on). |
| `fdcan_config_to_string` | CM4+CM7 | One-line debug string into `buffer` . |

### `Settings/forward_config.h` — GPIO/signal forwarding map (`BLOCK_ ` forward region, 2-byte EEPROM block).

| Function | Core | Purpose |
|---|---|---|
| `forward_config_unpack` | CM4+CM7 | Deserialize 2 bytes from EEPROM. |
| `forward_config_pack` | CM4+CM7 | Serialize to 2 EEPROM bytes. |
| `forward_config_factory` | CM4+CM7 | Factory defaults (`FORWARD_FACTORY_ ` : forwarding disabled). |

### `Settings/gpio_config.h` — GPIO pin settings for EEPROM — one logical pin per `BLOCK_GPIO ` (4 bytes on wire).

| Function | Core | Purpose |
|---|---|---|
| `gpio_config_unpack` | CM4+CM7 | Read 4 bytes from EEPROM into a struct you can edit or pass to `GPIO_Init` . |
| `gpio_config_pack` | CM4+CM7 | Write struct back to 4 bytes for `settings_save_raw` . |
| `gpio_config_factory` | CM4+CM7 | Fill `cfg` with product factory defaults (`GPIO_FACTORY_ ` in this file). |
| `gpio_mode_to_str` | CM4+CM7 | Text for `gpio_mode_t` (static storage). |
| `gpio_speed_to_str` | CM4+CM7 | Text for `gpio_speed_t` . |
| `gpio_interrupt_to_str` | CM4+CM7 | Text for `gpio_interrupt_t` . |
| `gpio_state_to_str` | CM4+CM7 | Text for `gpio_state_t` . |
| `gpio_config_to_str` | CM4+CM7 | One-line summary for logging. |

### `Settings/i2c_config.h` — I2C bus settings — role, speed, filters, IRQ/DMA (6-byte EEPROM per I2C2/3/4).

| Function | Core | Purpose |
|---|---|---|
| `i2c_config_unpack` | CM4+CM7 | Deserialize EEPROM bytes into `config` . |
| `i2c_config_pack` | CM4+CM7 | Serialize `config` to EEPROM wire bytes. |
| `i2c_config_factory` | CM4+CM7 | Factory defaults (`I2C_FACTORY_ ` : master, 100 kHz, DMA on). |
| `i2c_config_to_string` | CM4+CM7 | Format `cfg` as a debug string (UART/log). |

### `Settings/i2s_config.h` — I2S audio port settings (2-byte EEPROM block per I2S instance).

| Function | Core | Purpose |
|---|---|---|
| `i2s_config_unpack` | CM4+CM7 | Deserialize 2 EEPROM bytes into `cfg` . |
| `i2s_config_pack` | CM4+CM7 | Serialize `cfg` to 2 EEPROM bytes. |
| `i2s_config_factory` | CM4+CM7 | Factory defaults (`I2S_FACTORY_ ` : inactive port). |
| `i2s_config_to_string` | CM4+CM7 | Debug string into `buffer` . |

### `Settings/ip_channel_config.h` — One IP channel settings record: address, ports, protocol, direction, encryption, alias.

| Function | Core | Purpose |
|---|---|---|
| `ip_channel_config_unpack` | CM4+CM7 | Deserialize EEPROM bytes into `cfg` . |
| `ip_channel_config_pack` | CM4+CM7 | Serialize `cfg` to EEPROM wire format. |
| `ip_channel_config_factory_for_channel` | CM4+CM7 | Factory defaults for channel `channel_1based` (1..20). |
| `ip_channel_config_factory` | CM4+CM7 | Same as `ip_channel_config_factory_for_channel` with channel `1` . |
| `ip_channel_config_to_string` | CM4+CM7 | Format config as a debug string (UART/log). |

### `Settings/mcu_clock_config.h` — CM7 sysclk and CM4 prescaler settings (1-byte EEPROM block).

| Function | Core | Purpose |
|---|---|---|
| `mcu_clock_config_unpack` | CM4+CM7 | Deserialize 1 EEPROM byte into `config` . |
| `mcu_clock_config_pack` | CM4+CM7 | Serialize `config` to 1 EEPROM byte. |
| `mcu_clock_config_factory` | CM4+CM7 | Factory defaults (`MCU_CLOCK_FACTORY_ ` ). |

### `Settings/network_config.h` — Wire layout and helpers for the `BLOCK_NETWORK` EEPROM blob (IPv4 mode, static addresses, DNS).

| Function | Core | Purpose |
|---|---|---|
| `network_encryption_to_string` | CM4+CM7 | Human-readable label for `network_encryption_t` wire value (0–20). |
| `network_config_unpack` | CM4+CM7 | Deserialize fixed-layout `bytes` into `cfg` . |
| `network_config_pack` | CM4+CM7 | Serialize `cfg` into packed wire form. |
| `network_config_factory` | CM4+CM7 | Fill `cfg` with factory defaults (`NETWORK_FACTORY_ ` ). |
| `network_config_stored_valid` | CM4+CM7 | True if stored network block is coherent enough to keep after layout migration. |
| `network_config_to_string` | CM4+CM7 | One-line human summary of `cfg` into `buffer` . |

### `Settings/ntp_pps_config.h` — Network time (NTP) and pulse-per-second (PPS) routing — 19-byte EEPROM block.

| Function | Core | Purpose |
|---|---|---|
| `ntp_pps_config_unpack` | CM4+CM7 | Deserialize 19 EEPROM bytes into `cfg` . |
| `ntp_pps_config_pack` | CM4+CM7 | Serialize `cfg` to 19-byte wire image. |
| `ntp_pps_config_factory` | CM4+CM7 | Factory defaults (`NTP_PPS_FACTORY_ ` : NTP on, ports 123, PPS output off). |

### `Settings/pwm_input_config.h` — PWM IN channel settings stored in EEPROM (`BLOCK_PWM_IN1..4` , 70 bytes each).

| Function | Core | Purpose |
|---|---|---|
| `pwm_input_config_unpack` | CM4+CM7 | Deserialize wire bytes into `config` (no validation). |
| `pwm_input_config_pack` | CM4+CM7 | Serialize `config` to wire bytes. |
| `pwm_input_config_factory` | CM4+CM7 | Factory defaults for PWM IN `channel_index` (`PWM_INPUT_FACTORY_ ` ). |
| `pwm_input_config_is_sane` | CM4+CM7 | Basic validity check for unpacked config. |
| `pwm_input_config_sanitize` | CM4+CM7 | Clamp invalid EEPROM fields to factory defaults for that field only. |
| `pwm_input_config_from_eeprom_bytes` | CM4+CM7 | Unpack and repair minor EEPROM corruption. |
| `pwm_in_filter_source_to_str` | CM4+CM7 | Label for `source` . |
| `pwm_input_capture_edge_to_str` | CM4+CM7 | Label for capture edge wire value. |
| `pwm_input_config_to_string` | CM4+CM7 | Human-readable line into `buffer` (UART/log). |
| `pwm_input_config_get_active` | CM4+CM7 | Read active flag from `flags` . |
| `pwm_input_config_get_capture_edge` | CM4+CM7 | Read capture edge code from `flags` . |
| `pwm_input_config_set_active` | CM4+CM7 | Set active bit in `flags` . |
| `pwm_input_config_set_capture_edge` | CM4+CM7 | Set capture edge bits in `flags` . |

### `Settings/pwm_output_config.h` — PWM OUT settings — per channel (`BLOCK_PWM_OUT1..4` , 64 B) and shared voltage (`BLOCK_PWM_OUT_VOLTAGE` , 1 B).

| Function | Core | Purpose |
|---|---|---|
| `pwm_output_settings_block` | CM4+CM7 | EEPROM block id for PWM OUT `channel_id` (1..4). |
| `pwm_output_config_pack` | CM4+CM7 | Serialize `cfg` to `bytes` (`PWM_OUTPUT_CONFIG_SIZE` bytes). |
| `pwm_output_config_unpack` | CM4+CM7 | Deserialize EEPROM bytes into `cfg` ; validates `channel_id` and `nbytes` . |
| `pwm_output_config_factory` | CM4+CM7 | Factory defaults for one PWM OUT channel (`PWM_OUTPUT_FACTORY_ ` , 1..4). |
| `pwm_output_config_to_string` | CM4+CM7 | Human-readable line into `buffer` (UART/log). |
| `pwm_output_min_duty_permille_for_freq` | CM4+CM7 | Minimum allowed duty (permille) at `freq_hz` (hardware timing limit). |
| `pwm_output_effective_duty_permille` | CM4+CM7 | Convert up/down percent pair to effective duty permille (0..1000). |
| `pwm_output_config_get_duty_ratio` | CM4+CM7 | Read duty as percentages from `cfg` . |
| `pwm_output_config_set_duty_ratio` | CM4+CM7 | Set duty percentages and refresh `cfg->duty_permille` . |
| `pwm_output_config_set_duty_times_us` | CM4+CM7 | Set high/low times (µs); switches to `PWM_OUT_DUTY_MODE_TIME_US` and syncs permille. |
| `pwm_output_config_sync_down_time_from_period` | CM4+CM7 | In time mode, set low time from period(`cfg->frequency_hz)` − high time. |
| `pwm_output_period_us` | CM4+CM7 | Period length in µs for `freq_hz` (0 if invalid). |
| `pwm_output_config_effective_frequency_hz` | CM4+CM7 | Frequency for hardware: `cfg->frequency_hz` in ratio mode, else 1e6 / (up+down) us. |
| `pwm_output_config_sync_frequency_from_times` | CM4+CM7 | In time mode, store `cfg->frequency_hz` from high+low cycle time. |
| `pwm_output_config_resolve_duty` | CM4+CM7 | Resolve effective duty for hardware at `cfg->frequency_hz` . |
| `pwm_output_config_sync_duty_permille` | CM4+CM7 | Recompute `cfg->duty_permille` from active duty mode fields. |
| `pwm_output_config_sync_ratio_from_duty_permille` | CM4+CM7 | After clamp, set ratio % from `cfg->duty_permille` (RAM matches HW pulse). |
| `pwm_output_config_prepare_for_hw_apply` | CM4+CM7 | Fix invalid time-mode / zero effective Hz before `pwm_out_ctrl(PWM_OUT_OP_INIT_CHANNEL)` (no EEPROM write). |
| `pwm_output_clamp_duty_permille` | CM4+CM7 | Clamp requested duty to min/max/enforce rules in `cfg` . |
| `pwm_output_config_normalize_time_limits` | CM4+CM7 | Sort and cap time min/max limit fields in `cfg` . |
| `pwm_output_config_clamp_duty_times_us` | CM4+CM7 | Clamp `cfg` high/low times to time min/max when enforce flags are set (time mode). |
| `pwm_output_config_frequency_capture_supported` | CM4+CM7 | `true` when `freq_hz` is within capture-reliable range (see `PWM_FREQ_HZ_CAPTURE_RELIABLE_MIN` ). |
| `pwm_output_config_duty_ratio_capture_supported` | CM4+CM7 | `true` when both phases are long enough for PWM IN capture at `freq_hz` (ratio mode). |
| `pwm_output_config_duty_times_capture_supported` | CM4+CM7 | `true` when high/low times (µs) are long enough for PWM IN capture. |
| `pwm_output_voltage_factory` | CM4+CM7 | Factory defaults for shared 3.3 V / 5 V block (OUT 1–2 and 3–4). |
| `pwm_output_voltage_pack` | CM4+CM7 | Pack voltage block to one EEPROM byte (2-bit `supply_voltage_t` per rail). |
| `pwm_output_voltage_unpack` | CM4+CM7 | Unpack voltage block from EEPROM. |
| `pwm_output_voltage_to_string` | CM4+CM7 | Human-readable line (OUT 1–2 / OUT 3–4 supply level). |
| `pwm_output_voltage_load` | CM4+CM7 | Load `BLOCK_PWM_OUT_VOLTAGE` from EEPROM `slot` . |
| `pwm_output_voltage_save` | CM4+CM7 | Save `BLOCK_PWM_OUT_VOLTAGE` to EEPROM `slot` . |
| `pwm_output_voltage_get_for_channel` | CM4+CM7 | Supply level for OUT `channel_id` (1–2 share `out12` , 3–4 share `out34` ). |
| `pwm_output_voltage_set_for_channel` | CM4+CM7 | Update one rail in EEPROM (does not apply GPIO). |
| `pwm_output_voltage_gpio_hold_3v3_at_boot` | **CM4 only** | Force PB7/PK3 low (3.3 V rails) once early in CM4 boot — before long InitTask work. |
| `pwm_output_voltage_apply_gpio` | **CM4 only** | Drive PWM12_EN_5V / PWM34_EN_5V GPIO for `channel_id` . |

### `Settings/rs485_config.h` — RS-232/RS-485 transceiver options (1-byte EEPROM block, paired with UART settings).

| Function | Core | Purpose |
|---|---|---|
| `rs485_config_unpack` | CM4+CM7 | Deserialize one EEPROM byte into `config` . |
| `rs485_config_pack` | CM4+CM7 | Serialize `config` to one EEPROM byte. |
| `rs485_config_factory` | CM4+CM7 | Factory defaults (`RS485_FACTORY_ ` : RS-485, full duplex, DE on, termination on). |
| `rs485_config_to_string` | CM4+CM7 | Debug string into `buffer` . |

### `Settings/sdio_config.h` — SDIO/MMC host settings (2-byte EEPROM block).

| Function | Core | Purpose |
|---|---|---|
| `sdio_config_unpack` | CM4+CM7 | Deserialize 2 EEPROM bytes into `config` . |
| `sdio_config_pack` | CM4+CM7 | Serialize `config` to 2 EEPROM bytes. |
| `sdio_config_factory` | CM4+CM7 | Factory defaults (`SDIO_FACTORY_ ` : inactive host). |
| `sdio_config_to_string` | CM4+CM7 | Debug string into `buffer` . |

### `Settings/settings.h` — Settings master include for OPS — EEPROM/config modules, application type, and helpers.

| Function | Core | Purpose |
|---|---|---|
| `settings_save_defaults` | CM4+CM7 | Save default settings to a given slot (Primary or Backup) |
| `settings_show_uart` | CM4+CM7 | Show settings on UART |
| `settings_upgrade_eeprom_layout` | CM4+CM7 | EEPROM upgrade when the stored settings layout / version no longer matches firmware. Writes factory defaults for all normal blocks so offsets and sizes match the current image, then restores only the user device name ( |
| `settings_load_raw` | CM4+CM7 | Load one settings block (raw wire bytes) from EEPROM for `slot` . Buffer size: use |
| `settings_load_raw_fast` | CM4+CM7 | Same as `settings_load_raw` without compatibility check or UART hex dump (faster, trusted paths only). |
| `settings_save_raw` | CM4+CM7 | Save one block (raw wire bytes) to EEPROM for `slot` . |
| `settings_save_raw_fast` | CM4+CM7 | Same as `settings_save_raw` without layout check or debug dump (e.g. web fast-save paths). |
| `settings_print_block` | CM4+CM7 | UART hex/text dump of one EEPROM block for field debugging. |
| `settings_print_struct` | hook/weak — no lib body | Pretty-print a decoded struct for `type` to `huart` (expects `data` pointer matching type). |
| `settings_application_common_unpack` | CM4+CM7 | Deserialize the 8-byte APPLICATION common prefix from a blob start. |
| `settings_application_common_pack` | CM4+CM7 | Serialize `in` into 8 bytes at `bytes` . |
| `settings_application_common_factory` | CM4+CM7 | Default common header (undefined main type baseline). |
| `settings_application_common_factory_for_main` | CM4+CM7 | Fills header and default Setting Type for the given main application (e.g. Cranesystem → stand_alone). |
| `settings_application_read_main_type` | CM4+CM7 | Read `device_info` main application type from EEPROM for `slot` . |
| `settings_application_read_sub_wire` | CM4+CM7 | Read sub-application wire byte (first APPLICATION-tail byte after common header). |
| `settings_application_get_code_schema_version` | CM4+CM7 | Firmware schema `version_t` for `main_type` + `sub_wire` (not EEPROM max). |
| `settings_application_unpack_common_prefix` | CM4+CM7 | Extract APPLICATION common header from a tail blob if `blob_size` is large enough. |
| `settings_application_pack_common_prefix` | CM4+CM7 | Write common header to start of `blob` (capacity `blob_capacity` ). |
| `settings_application_validate_setting_type_for_main` | CM4+CM7 | Sub-type wire valid for main application (delegates to application_settings_regulator). |
| `settings_application_header_coherent_with_device_info` | CM4+CM7 | True if the common prefix matches device_info `application_type_t` and @a sub_application_wire_byte |
| `settings_upgrade_application_settings` | CM4+CM7 | APPLICATION EEPROM upgrade / repair for @a slot (primary or backup). Reads |

### `Settings/spi_qspi_config.h` — SPI/QSPI bus settings — one 3-byte EEPROM block per bus (`BLOCK_SPI2` , …).

| Function | Core | Purpose |
|---|---|---|
| `spi_qspi_config_unpack` | CM4+CM7 | Load 3 EEPROM bytes into `cfg` . |
| `spi_qspi_config_pack` | CM4+CM7 | Write `cfg` to 3 EEPROM bytes. |
| `spi_qspi_config_factory` | CM4+CM7 | Fill `cfg` from `SPI_QSPI_FACTORY_ ` (inactive bus, Mode 0, MSB first). |
| `spi_qspi_config_to_string` | CM4+CM7 | Human-readable one-line summary (UART / log). |

### `Settings/timer_config.h` — General-purpose timer settings (EEPROM block for timers configured via settings).

| Function | Core | Purpose |
|---|---|---|
| `timer_config_unpack` | CM4+CM7 | Deserialize EEPROM bytes into `config` . |
| `timer_config_pack` | CM4+CM7 | Serialize `config` to EEPROM wire bytes. |
| `timer_config_factory` | CM4+CM7 | Factory defaults (`TIMER_FACTORY_ ` : stopped, zero PSC/ARR). |

### `Settings/uart_config.h` — UART port settings — baud, mode, framing, DMA/IRQ, RX delimiters, alias (41 B wire).

| Function | Core | Purpose |
|---|---|---|
| `uart_config_unpack` | CM4+CM7 | Deserialize `UART_CONFIG_PACKED_SIZE` bytes from EEPROM into `config` . |
| `uart_config_pack` | CM4+CM7 | Serialize `config` to EEPROM wire bytes. |
| `uart_config_factory` | CM4+CM7 | Fill `config` with factory defaults (`UART_FACTORY_ ` , empty alias). |
| `uart_config_factory_for_port` | CM4+CM7 | Factory defaults plus alias `"UARTn"` for `uart_id` . |
| `uart_config_sanitize_alias` | CM4+CM7 | Trim alias to valid length and ensure NUL termination. |
| `uart_config_to_string` | CM4+CM7 | One-line debug string into `buffer` . |
| `uart_baud_enum_to_hz` | CM4+CM7 | Baud rate in Hz from EEPROM baud enum byte. |
| `uart_baud_enum_to_name` | CM4+CM7 | Human-readable baud name for enum `code` . |

### `Settings/usb_config.h` — USB device/host mode settings (2-byte EEPROM block per USB instance).

| Function | Core | Purpose |
|---|---|---|
| `usb_config_unpack` | CM4+CM7 | Deserialize 2 EEPROM bytes into `config` . |
| `usb_config_pack` | CM4+CM7 | Serialize `config` to 2 EEPROM bytes. |
| `usb_config_factory` | CM4+CM7 | Factory defaults (`USB_FACTORY_ ` : inactive, safe clock). |

### `Settings/watchdog_config.h` — Dual-core software watchdog — ICC ping/pong between CM4 and CM7 (`BLOCK_WATCHDOG` , 24 B).

| Function | Core | Purpose |
|---|---|---|
| `watchdog_config_unpack` | CM4+CM7 | Deserialize 24-byte wire image into `cfg` . |
| `watchdog_config_unpack_sized` | CM4+CM7 | Unpack using actual EEPROM byte count (22/23/24-byte layouts). |
| `watchdog_config_pack` | CM4+CM7 | Serialize `cfg` to 24-byte wire format. |
| `watchdog_config_factory` | CM4+CM7 | Factory defaults for both cores (`WATCHDOG_CORE_FACTORY_ ` ). |
| `watchdog_config_stored_valid` | CM4+CM7 | True if stored block looks coherent enough to keep after migration. |
| `watchdog_time_to_ms` | CM4+CM7 | Convert `value` in `unit` to milliseconds (approximate for µs). |
| `watchdog_config_to_string` | CM4+CM7 | Human-readable summary into `buffer` . |
| `watchdog_time_unit_to_string` | CM4+CM7 | Label for `unit` . |

### `Settings/web_users_config.h` — Website login accounts — meta block + up to 20 user slots in EEPROM.

| Function | Core | Purpose |
|---|---|---|
| `web_users_slot_index_from_block` | CM4+CM7 | Map `BLOCK_WEB_USER ` to slot index 0..19. |
| `web_users_block_from_slot_index` | CM4+CM7 | Map slot index to `BLOCK_WEB_USER ` . |
| `web_users_unpack_meta` | CM4+CM7 | Deserialize META block (does not change `slots[]` ). |
| `web_users_pack_meta` | CM4+CM7 | Serialize meta fields only. |
| `web_users_unpack_slot` | CM4+CM7 | Deserialize one slot into `cfg->slots[slot_index]` . |
| `web_users_pack_slot` | CM4+CM7 | Serialize one slot to wire bytes. |
| `web_users_config_factory` | CM4+CM7 | Factory: four default accounts (`WEB_USERS_FACTORY_ ` ), slots 4..19 disabled. |
| `web_users_config_valid` | CM4+CM7 | True if magic and layout version match expected values. |
| `web_users_validate` | CM4+CM7 | Business rules: unique names, at least one Admin and one Ops. |

### `Settings/website_config.h` — Embedded web server enable flags and HTTP/HTTPS ports (`BLOCK_WEBSITE` , 5-byte EEPROM block).

| Function | Core | Purpose |
|---|---|---|
| `website_config_unpack` | CM4+CM7 | Deserialize 5 EEPROM bytes (enable flags + ports). |
| `website_config_pack` | CM4+CM7 | Serialize `config` to EEPROM wire format. |
| `website_config_factory` | CM4+CM7 | Factory defaults (`WEBSITE_FACTORY_ ` : HTTP on port 80). |

## Network (Middleware/Network/)


### `Middleware/Network/network_functions.h` — TCP/UDP network middleware with LwIP, core-aware ICC forwarding, and encryption API preparation.

| Function | Core | Purpose |
|---|---|---|
| `network_protocol_to_string` | CM4+CM7 | Human-readable label for `network_protocol_t` . |
| `network_tx_packet_init_outbound` | CM4+CM7 | Clear `and` set protocol/encryption/len for a typical TX packet. |
| `network_debug_print` | CM4+CM7 | Low-level UART sink for `network_print` when `NETWORK_DEBUG` is 1. |
| `network_print` | inline (both) | Conditional debug print when `NETWORK_DEBUG` is enabled. |
| `network_init` | CM4+CM7 | Start network middleware (threads, queues, mutex) after LwIP and ETH are up. |
| `network_start_server` | CM4+CM7 | Open a TCP or UDP listener on `port` . |
| `network_stop_server` | CM4+CM7 | Remove a previously started listener on `port` / `proto` . |
| `network_send` | CM4+CM7 | Queue an outbound packet for transmission. |
| `network_rx_register_handler` | CM4+CM7 | Register callback invoked for every accepted RX packet (after filters). |
| `network_add_filter_rule` | CM4+CM7 | Append an IP/port/protocol allow or deny rule. |
| `network_remove_filter_rule` | CM4+CM7 | Remove the filter rule at `index` (0-based). |
| `network_clear_filter_rules` | CM4+CM7 | Clear all filter rules (allow-all until new rules added). |
| `network_enable_filter_check` | CM4+CM7 | Enable or disable RX filter evaluation. |
| `network_get_active_listeners` | CM4+CM7 | Fill `ports` and `protocols` with active listeners. |
| `network_join_udp_broadcast_group` | CM4+CM7 | Join an IPv4 multicast group for UDP (IGMP). |
| `network_run_self_test` | CM4+CM7 | Run built-in TCP/UDP/mcast self-test. |

## Website pages (Middleware/Website/Pages_Module/)


### `Middleware/Website/Pages_Module/Applications/Cranesystem/Page_cranesystem_stand_alone.h` — Crane system web UI: stand-alone transmit blocks (1..8) and application sub-type page.

| Function | Core | Purpose |
|---|---|---|
| `generate_cranesystem_standalone_content` | CM4+CM7 | Full stand-alone page HTML into `buf` (min ~24 KB). |
| `generate_cranesystem_standalone_block_content` | CM4+CM7 | HTML for one transmit block. |
| `send_cranesystem_standalone_stream` | CM4+CM7 | Stream stand-alone page to HTTP connection (lower peak RAM than full buffer). |
| `generate_cranesystem_application_content` | CM4+CM7 | Application sub-type selector page (master/slave/stand-alone wire values). |
| `handle_cranesystem_stand_alone_post` | CM4+CM7 | POST `/cranesystem_standalone/save` — save/apply queues `CraneTxApply` worker (ETH core only). |
| `get_cranesystem_stand_alone_profile_body` | CM4+CM7 | URL-encoded profile for stand-alone page. |
| `get_cranesystem_stand_alone_apply_status_body` | CM4+CM7 | JSON/text status after apply (for AJAX poll). |
| `get_cranesystem_application_profile_body` | CM4+CM7 | Profile body for application sub-type page. |
| `handle_cranesystem_application_post` | CM4+CM7 | POST handler for application sub-type save. |

### `Middleware/Website/Pages_Module/Page_GPIO.h` — GPIO settings web pages: GPIO 1, GPIO 2, and GPIO PWM IN 1–4.

| Function | Core | Purpose |
|---|---|---|
| `generate_gpio_content` | CM4+CM7 | Generate HTML for a GPIO tab. |
| `gpio_page_get_status` | CM4+CM7 | Get current pin state for GET `.../status` . |
| `gpio_page_do_action` | CM4+CM7 | Execute output action for POST `.../action` . |
| `get_gpio_profile_body` | CM4+CM7 | URL-encoded `gpio_config` for profile (GET `.../profile?name=...` ). |
| `handle_gpio_save` | CM4+CM7 | Handle POST `.../save` (save `gpio_config` from form body). |

### `Middleware/Website/Pages_Module/Page_IP_channels.h` — Web UI for IP channel settings (20 channels): EEPROM profiles, save/apply, test send.

| Function | Core | Purpose |
|---|---|---|
| `send_ip_channels_stream` | CM4+CM7 | Stream IP Channels settings HTML to `conn` . |
| `handle_ip_channels_post` | CM4+CM7 | POST `/ip_channels/save` — `action=apply\|save\|save_apply` . |
| `handle_ip_channels_test_post` | CM4+CM7 | POST `/ip_channels/test` — send test datagram on `channel=1..20` . |
| `ip_channels_apply_config` | **CM7 only** | Apply a channel table to the network stack (listeners/senders). |
| `website_reload_ip_channel_network_from_eeprom` | CM4+CM7 | Reload primary IP channel blocks from EEPROM and re-apply network listeners. |
| `ip_channel_send_test_message` | hook/weak — no lib body | Weak hook: send a test message on one channel (override in application code). |
| `get_ip_channels_profile_body` | CM4+CM7 | URL-encoded config for IP channels for one profile. |
| `ip_channels_debug_line` | CM4+CM7 | UART trace line when `IPCH_DEBUG` is enabled (CM7). |
| `ip_channels_tab_js_serve` | CM4+CM7 | GET `/ip_channels_tab.js` — tab UI script. |

### `Middleware/Website/Pages_Module/Page_adc_config.h` — Web UI for per-ADC instance settings (ADC1, ADC2, ADC3): profiles and POST save.

| Function | Core | Purpose |
|---|---|---|
| `generate_adc_config_content` | CM4+CM7 | Build ADC settings HTML for `adc_id` (static string in flash). |
| `get_adc_profile_body` | CM4+CM7 | URL-encoded ADC config for a profile. |
| `handle_adc_post` | CM4+CM7 | POST handler for ADC save/apply routes. |

### `Middleware/Website/Pages_Module/Page_analog_inputs.h` — Web UI for analog inputs: overview, per-channel settings, live values, calibration assistant.

| Function | Core | Purpose |
|---|---|---|
| `generate_analog_inputs_overview_content` | CM4+CM7 | Build HTML for the analog-inputs overview tab into `buf` . |
| `send_analog_inputs_overview_stream` | CM4+CM7 | Stream overview HTML to `conn` . |
| `send_analog_input_channel_stream` | CM4+CM7 | Stream per-channel analog-input settings HTML. |
| `get_analog_inputs_values_json` | CM4+CM7 | JSON snapshot of all analog input live values. |
| `get_analog_input_value_json` | CM4+CM7 | JSON snapshot for one analog input channel. |
| `get_ain_cal_dialog_html` | CM4+CM7 | Lazy-loaded HTML for scale/offset calibration dialog (one channel). |
| `get_ain_profile_body` | CM4+CM7 | URL-encoded `ain_config_t` fields for a profile. |
| `handle_ain_post` | CM4+CM7 | POST handler for analog-input save/apply routes. |
| `handle_ain_rail_stats_reset_post` | CM4+CM7 | POST handler to reset rail statistics counters. |
| `get_ain_cal_start` | CM4+CM7 | Start calibration sampling on CM4 (via ICC). |
| `get_ain_cal_stop` | CM4+CM7 | Stop calibration sampling and return statistics. |
| `get_ain_cal_status` | CM4+CM7 | Poll in-progress calibration statistics without stopping. |

### `Middleware/Website/Pages_Module/Page_application_overview.h` — Simple overview tabs for Drone, Silas, and Rheotune (loaded via `loadTab` ).

| Function | Core | Purpose |
|---|---|---|
| `generate_application_overview_content` | CM4+CM7 | Build HTML fragment for the selected application type (Drone, Silas, or Rheotune only). |

### `Middleware/Website/Pages_Module/Page_config_manager.h` — Web UI for settings slot management: load/save primary and backup, version info.

| Function | Core | Purpose |
|---|---|---|
| `generate_config_manager_content` | CM4+CM7 | Full Config Manager page HTML (static string in flash). |
| `get_config_manager_content_compact` | CM4+CM7 | Compact Config Manager HTML (~1.4 KB) when the full page fails to deliver. |
| `handle_config_manager_post` | CM4+CM7 | POST handler for config-manager actions (slot copy, reset, etc.). |

### `Middleware/Website/Pages_Module/Page_dac.h` — Web UI for DAC global and per-channel settings (channels 1–4).

| Function | Core | Purpose |
|---|---|---|
| `generate_dac_global_content` | CM4+CM7 | HTML fragment for DAC global settings tab. |
| `generate_dac_channel_content` | CM4+CM7 | HTML fragment for one DAC channel tab. |
| `handle_dac_global_post` | CM4+CM7 | POST `/dac_global/save` — parse form and write EEPROM. |
| `handle_dac_channel_post` | CM4+CM7 | POST `/dac1/save` .. `/dac4/save` for one channel. |
| `get_dac_global_profile_body` | CM4+CM7 | URL-encoded global DAC config for a profile. |
| `get_dac_channel_profile_body` | CM4+CM7 | URL-encoded per-channel DAC config for a profile. |

### `Middleware/Website/Pages_Module/Page_device_info.h` — Web UI for device information: firmware versions, identifiers, POST save.

| Function | Core | Purpose |
|---|---|---|
| `generate_device_info_content` | CM4+CM7 | Build Device Info HTML into `buf` (buffer-based send paths). |
| `get_device_info_profile_body` | CM4+CM7 | URL-encoded device-info fields for a profile (AJAX Load factory/normal/backup). |
| `handle_device_info_post` | CM4+CM7 | POST handler for device-info save routes. |
| `send_device_info_stream` | CM4+CM7 | Stream Device Info HTML to `conn` (reduces heap spikes on large pages). |

### `Middleware/Website/Pages_Module/Page_fdcan.h` — Web UI for FDCAN1 and FDCAN2 settings: HTML tab, profiles, POST save.

| Function | Core | Purpose |
|---|---|---|
| `generate_fdcan_content` | CM4+CM7 | Build FDCAN settings HTML for `can_id` into `buf` . |
| `generate_fdcan_embed_content` | CM4+CM7 | Tab embed body in static RAM_D2 (no 32 KiB heap alloc on HTTP task). |
| `get_fdcan_profile_body` | CM4+CM7 | URL-encoded `fdcan_config_t` for a profile. |
| `handle_fdcan_post` | CM4+CM7 | POST handler for FDCAN save/apply (dispatched from post_handler.c). |

### `Middleware/Website/Pages_Module/Page_hardware_info.h` — Hardware Information page layout (read-only — no EEPROM / no action buttons).

| Function | Core | Purpose |
|---|---|---|
| `generate_hardware_info_content` | CM4+CM7 | Build Hardware Information HTML into `buf` . |

### `Middleware/Website/Pages_Module/Page_login.h` — Login page: chunked HTML response for unauthenticated GET `/login` .

| Function | Core | Purpose |
|---|---|---|
| `send_login_page_response` | CM4+CM7 | Send login form HTML as chunked HTTP 200 (avoids large static buffer). |

### `Middleware/Website/Pages_Module/Page_network.h` — Web UI for the Network tab: HTML fragment, POST save/apply, profile export, streaming send.

| Function | Core | Purpose |
|---|---|---|
| `generate_network_content` | CM4+CM7 | Build HTML fragment for AJAX tab load into `buf` . |
| `handle_network_post` | CM4+CM7 | Handle POST `/network/save` from post_handler. |
| `network_apply_init` | CM4+CM7 | Create deferred network-apply queue and worker task. |
| `get_network_profile_body` | CM4+CM7 | URL-encoded network config for a profile (GET `/network/profile` ). |
| `send_network_stream` | CM4+CM7 | Stream Network settings HTML to `conn` . |

### `Middleware/Website/Pages_Module/Page_pwm_inputs.h` — Web UI for PWM IN: overview, per-channel settings, live values, save/apply.

| Function | Core | Purpose |
|---|---|---|
| `send_pwm_inputs_overview_stream` | CM4+CM7 | Stream overview HTML to `conn` (embed uses static RAM_D2, no heap). |
| `send_pwm_input_channel_stream` | CM4+CM7 | Stream per-channel settings + live panel. |
| `get_pwm_inputs_values_json` | CM4+CM7 | JSON snapshot of all four PWM IN channels. |
| `get_pwm_input_value_json` | CM4+CM7 | JSON snapshot for one PWM IN channel. |
| `get_pwm_in_profile_body` | CM4+CM7 | URL-encoded profile body for AJAX load. |
| `handle_pwm_in_post` | CM4+CM7 | POST handler for `/pwm_in/save` . |
| `handle_pwm_in_rail_stats_reset_post` | CM4+CM7 | POST `/pwm_in/rail_stats/reset` — body `channel=pwm_in1..4` or `all` . |
| `handle_pwm_in_alarm_reset_post` | CM4+CM7 | POST `/pwm_in/alarm/reset` — clear latched alarm (same `channel` body as rail reset). |
| `pwm_in_overview_tab_js_serve` | CM4+CM7 | Serve GET `/pwm_in_overview_tab.js` . |
| `pwm_in_channel_tab_js_serve` | CM4+CM7 | Serve GET `/pwm_in_channel_tab.js` . |
| `pwm_in_send_help_overview` | CM4+CM7 | Lazy-loaded help HTML (GET `/pwm_inputs/help` ). |
| `pwm_in_send_help_channel` | CM4+CM7 | Lazy-loaded per-channel help HTML (GET `/pwm_in/help?channel=` ). |

### `Middleware/Website/Pages_Module/Page_pwm_out.h` — Web UI for PWM OUT channels 1–4 (`/pwm_outN` ): HTML generation, POST save, profiles.

| Function | Core | Purpose |
|---|---|---|
| `generate_pwm_out_content` | CM4+CM7 | Build settings HTML for PWM OUT `channel_id` into `buf` . |
| `generate_pwm_out_embed_content` | **CM7 only** | Tab embed body in static RAM_D2 (diagnostics; normal tabs use `send_pwm_out_stream` ). |
| `send_pwm_out_stream` | CM4+CM7 | GET `/pwm_outN` — streamed blocks; embed shows primary EEPROM on tab open. |
| `pwm_out_tab_js_serve` | CM4+CM7 | GET `/pwm_out_tab.js` — shared UI script (tab HTML sets `window._pwmChId` ). |
| `handle_pwm_out_post` | CM4+CM7 | Handle POST `/pwm_outN/save` — parse form, write EEPROM, apply on CM4. |
| `get_pwm_out_profile_body` | CM4+CM7 | URL-encoded profile body for AJAX load. |
| `pwm_web_mirror_invalidate_primary` | **CM7 only** | Drop CM7 RAM mirror of PRIMARY PWM blocks (after save elsewhere). |

### `Middleware/Website/Pages_Module/Page_uart.h` — Per-UART settings web pages (UART1–4, 6–8).

| Function | Core | Purpose |
|---|---|---|
| `uart_web_port_display_name` | CM4+CM7 | Menu label and page title for a UART port. |
| `uart_web_menu_label` | CM4+CM7 | Menu label: alias + hardware suffix when set, else `uart_web_port_display_name` . |
| `generate_uart_content` | CM4+CM7 | Build UART settings HTML for `uart_id` into `buf` . |
| `generate_uart_embed_content` | CM4+CM7 | Tab embed body in static RAM_D2 (no 32 KiB heap alloc on HTTP task). |
| `get_uart_profile_body` | CM4+CM7 | URL-encoded UART config for a profile. |
| `handle_uart_post` | CM4+CM7 | POST `/uart/save` — parse form, save EEPROM, re-init UART where allowed. |

### `Middleware/Website/Pages_Module/Page_watchdog.h` — Web UI for dual-core watchdog settings (`BLOCK_WATCHDOG` ).

| Function | Core | Purpose |
|---|---|---|
| `generate_watchdog_content` | **CM7 only** | Build watchdog settings HTML into `buf` . |
| `handle_watchdog_post` | **CM7 only** | POST handler for watchdog save/apply. |
| `get_watchdog_profile_body` | **CM7 only** | URL-encoded watchdog config for a profile. |
| `send_watchdog_stream` | **CM7 only** | GET `/watchdog` — streamed delivery (factory HTML on tab open, profile on button). |

### `Middleware/Website/Pages_Module/Page_web_users.h` — CM7 web UI: My account and User management (Users menu).

| Function | Core | Purpose |
|---|---|---|
| `web_users_role_may_access_manage` | CM4+CM7 | True if `role` may see User management menu link. |
| `send_web_users_me_stream` | **CM7 only** | Stream My account HTML. |
| `send_web_users_manage_stream` | **CM7 only** | Stream User management HTML. |
| `handle_web_users_me_post` | **CM7 only** | POST `/web_users/me` — update own password/language. |
| `handle_web_users_manage_post` | **CM7 only** | POST `/web_users/manage` — add/edit/disable users. |

### `Middleware/Website/Pages_Module/Page_website.h` — Web UI for website settings (HTTP port, auth options): tab under Network → Website.

| Function | Core | Purpose |
|---|---|---|
| `generate_website_content` | CM4+CM7 | Build Website settings HTML into `buf` . |
| `handle_website_post` | CM4+CM7 | POST `/website/save` — parse form, write EEPROM, optional apply. |
| `get_website_profile_body` | CM4+CM7 | URL-encoded `website_config_t` for a profile. |
| `send_website_stream` | CM4+CM7 | Stream Website settings HTML to `conn` . |

### `Middleware/Website/Pages_Module/page_builder.h` — Shared HTML/HTTP shell for the MFCB web UI: menu, headers, full pages, and embed fragments.

| Function | Core | Purpose |
|---|---|---|
| `website_get_device_display_name` | CM4+CM7 | Device alias from settings (browser tab titles, device-info — not menu/topbar chrome). |
| `website_build_page_title` | CM4+CM7 | Build full browser title: brand + device name + optional suffix. |
| `page_builder_send` | CM4+CM7 | Send a complete HTML page (layout, menu, footer) with `content` in the main area. |
| `mfcb_shell_js_serve` | CM4+CM7 | Serve authenticated GET `/mfcb_shell.js` (tab switching, loadTab helpers). |
| `website_send_html_fragment_200` | CM4+CM7 | Send HTML fragment for shell `loadTab` XHR (`?mfcb_embed=1` ): Content-Length + session script. |
| `website_embed_stream_begin` | CM4+CM7 | Begin tab embed stream (HTTP/1.1 chunked encoding, no full-page RAM buffer). |
| `website_embed_stream_write` | CM4+CM7 | Write one chunk to an embed stream started with `website_embed_stream_begin` . |
| `website_embed_stream_end` | CM4+CM7 | End embed stream (final chunk, close `conn` ). |
| `website_send_html_snippet_200` | CM4+CM7 | Send small HTML snippet for lazy-loaded help (fetch from tab, not loadTab). |
| `build_HTML_MENU` | CM4+CM7 | Build the sidebar menu from the user's role and permissions. |
| `build_HTTP_HEADER` | CM4+CM7 | Build HTTP response header (optional Set-Cookie from session). |

### `Middleware/Website/Pages_Module/web_page_scratch.h` — CM7: one RAM_D1 HTML scratch buffer shared by GPIO/ADC/DAC/IP pages.

| Function | Core | Purpose |
|---|---|---|
| `web_page_scratch` | **CM7 only** | Pointer to the single CM7 HTML scratch buffer in RAM_D1. |
| `web_page_scratch_size` | **CM7 only** | Size in bytes of `web_page_scratch` . |

## Website core / auth / webserver (Middleware/Website/)


### `Middleware/Website/Authentication_Module/Authentication.h` — Login, roles, and session validation for the embedded website.

| Function | Core | Purpose |
|---|---|---|
| `authenticate_user` | CM4+CM7 | Authenticate `username` / `password` against stored credentials. |
| `validate_session` | CM4+CM7 | Look up an existing session by id (cookie or query-string form). |
| `auth_decode_post_password` | CM4+CM7 | Decode XOR+Base64 password from an HTML form POST field. |
| `auth_web_users_load_from_eeprom` | **CM7 only** | Load users from EEPROM into CM7 runtime (factory if invalid/missing). |
| `auth_web_users_get` | **CM7 only** | Copy current CM7 runtime users into `out` . |
| `auth_web_users_set` | **CM7 only** | Replace CM7 runtime users (validates); does not write EEPROM. |
| `auth_web_users_save_to_eeprom` | **CM7 only** | Persist CM7 runtime users to `PRIMARY_SETTINGS` EEPROM slot. |
| `auth_web_users_load_from_settings_slot` | **CM7 only** | Load users from a settings slot (primary/backup) into CM7 runtime. |
| `auth_web_users_save_to_settings_slot` | **CM7 only** | Save CM7 runtime users to a settings slot (primary/backup). |
| `auth_web_users_load_factory_runtime` | **CM7 only** | Load factory defaults into CM7 runtime (does not write EEPROM). |
| `auth_web_users_find_username` | **CM7 only** | Find user slot index by username. |
| `auth_web_users_verify_plain` | **CM7 only** | Verify plain credentials against CM7 runtime. |
| `auth_web_users_role_label` | **CM7 only** | Human readable role name for display (Admin/Ops/Operator/Viewer). |
| `auth_web_users_may_manage_user` | **CM7 only** | True if `actor_role` may edit an enabled `target` user (not self). |
| `auth_web_users_may_assign_role` | **CM7 only** | True if `actor_role` may assign `assign_role_wire` . |
| `auth_session_update_identity` | **CM7 only** | Update active session username/language after My account save (same session id). |

### `Middleware/Website/Core_Utilities/http_utils.h` — HTTP helpers: parse requests, detect client platform, send common responses.

| Function | Core | Purpose |
|---|---|---|
| `get_platform_from_request` | CM4+CM7 | Classify client from User-Agent in the raw HTTP request. |
| `http_request_uri_after_method` | CM4+CM7 | Pointer to request-target URI after the HTTP method. |
| `http_extract_host_header` | CM4+CM7 | Copy the Host header value (host[:port]) into `out` . |
| `http_send_response` | CM4+CM7 | Send HTML body with a standard status (adds Content-Type and closes connection). |
| `http_send_json` | CM4+CM7 | Send `application/json` body with HTTP 200. |
| `send_http_ok` | CM4+CM7 | Send minimal HTTP 200 with empty body. |
| `send_http_error` | CM4+CM7 | Send HTTP 400 with plain-text `message` in the body. |
| `send_simple_response` | CM4+CM7 | Send a custom status line and body. |
| `send_http_warning` | CM4+CM7 | Send HTTP 200 with a warning message (non-fatal feedback). |
| `send_redirect` | CM4+CM7 | Send HTTP 302 redirect to `location` (closes connection). |
| `send_in_chunks` | CM4+CM7 | Chunked `netconn_write` with ERR_MEM retry (shared by handlers and tab JS routes). |

### `Middleware/Website/Core_Utilities/session_helpers.h` — Parse session identifiers from HTTP requests (Cookie header or query string fallback).

| Function | Core | Purpose |
|---|---|---|
| `extract_session_id` | CM4+CM7 | Extract session ID from Cookie header in a raw HTTP GET/POST request. |
| `extract_session_id_from_uri` | CM4+CM7 | Extract session id from `?mfcb_sid=...` when Cookie is missing. |

### `Middleware/Website/Request_Handlers/request_handlers.h` — lwIP `netconn` -level HTTP method dispatch for the embedded website.

| Function | Core | Purpose |
|---|---|---|
| `handle_http_request` | CM4+CM7 | Entry point: parse `data` (length `len` ) and dispatch to the correct verb handler. |
| `handle_get_request` | CM4+CM7 | Handle HTTP GET; `platform` is derived for responsive HTML (mobile/tablet/desktop). |
| `handle_post_request` | CM4+CM7 | Handle HTTP POST (forms, JSON, file uploads per route implementation). |
| `handle_put_request` | CM4+CM7 | Handle HTTP PUT. |
| `handle_delete_request` | CM4+CM7 | Handle HTTP DELETE. |
| `handle_head_request` | CM4+CM7 | Handle HTTP HEAD (headers only, same URI rules as GET). |
| `handle_options_request` | CM4+CM7 | Handle HTTP OPTIONS (CORS / capability probes). |
| `handle_patch_request` | CM4+CM7 | Handle HTTP PATCH. |

### `Middleware/Website/Webserver/webserver.h` — HTTP/HTTPS web server init and compile-time tuning (CM7).

| Function | Core | Purpose |
|---|---|---|
| `WebServer_Init` | CM4+CM7 | Initialize the WebServer task and listeners. |

### `Middleware/Website/web_path_debug.h` — Optional `[WEB-PATH]` / `[WEB-EEPROM]` / `[WEB-TAB]` diagnostic UART lines.

| Function | Core | Purpose |
|---|---|---|
| `web_path_debug_line` | CM4+CM7 | Print one preformatted debug line when `WEB_PATH_DEBUG` is enabled. |
| `web_path_debugf` | CM4+CM7 | Printf-style debug line when `WEB_PATH_DEBUG` is enabled. |
| `web_tab_trace_get` | CM4+CM7 | One line per authenticated HTTP GET: TAB-OPEN / PREFETCH / POLL / PROFILE-EEPROM / etc. |
| `web_tab_trace_block` | CM4+CM7 | Log blocked prefetch or missing poll/profile query parameters. |
| `web_tab_trace_post_from_request` | CM4+CM7 | One line per authenticated POST (path only, no body dump). |

### `Middleware/Website/website.h` — Legacy single-entry HTTP dispatch (delegates to request_handlers).

| Function | Core | Purpose |
|---|---|---|
| `handle_http_request` | CM4+CM7 | Handle an incoming HTTP request (parse method, route, respond, free buffer). |

## Filters (Middleware/Filters/)


### `Middleware/Filters/filter_functions.h` — Modular filter dispatch: single entry point to apply any supported filter type.

| Function | Core | Purpose |
|---|---|---|
| `filter_apply` | CM4+CM7 | Apply the selected filter: updates circular buffer and returns filtered value. |
| `filter_requires_init` | CM4+CM7 | Check if the filter type requires one-time init (e.g. Kalman). |
| `filter_get_name` | CM4+CM7 | Get human-readable name for a filter type (debug/logging). |

### `Middleware/Filters/kalman_filter.h` — 1D Kalman filter for time-domain signals (per-sensor indexed).

| Function | Core | Purpose |
|---|---|---|
| `kalman_init_1d` | CM4+CM7 | Initialize a 1D Kalman filter for a sensor. |
| `kalman_predict_1d` | CM4+CM7 | Predict step: propagate covariance (p += q dt); state x unchanged in 1D constant model. |
| `kalman_update_1d` | CM4+CM7 | Update step: correct state using `measurement` . |
| `kalman_reset_1d` | CM4+CM7 | Reset filter state to `initial_value` . |
| `kalman_set_noise_1d` | CM4+CM7 | Adjust process and measurement noise dynamically. |
| `kalman_set_dt_1d` | CM4+CM7 | Set sample interval dt. |
| `kalman_get_estimate_1d` | CM4+CM7 | Get current state estimate x. |
| `kalman_get_covariance_1d` | CM4+CM7 | Get current error covariance p. |

### `Middleware/Filters/median_filters.h` — Median of a sample window for `uint32_t` and `float` arrays.

| Function | Core | Purpose |
|---|---|---|
| `calculate_median` | CM4+CM7 | Median of `values[]` (bubble sort; modifies array order). |
| `calculate_median_optimized` | CM4+CM7 | Median using partial selection (faster for larger `size` ; may reorder array). |
| `calculate_median_f` | CM4+CM7 | Float median (bubble sort; may reorder array). |
| `calculate_median_optimized_f` | CM4+CM7 | Float median (partial selection). |

### `Middleware/Filters/min_max_filters.h` — Min/max filters for integer and float arrays.

| Function | Core | Purpose |
|---|---|---|
| `filter_min` | CM4+CM7 | Minimum `uint32_t` in array. |
| `filter_max` | CM4+CM7 | Maximum `uint32_t` in array. |
| `filter_min_f` | CM4+CM7 | Minimum `float` in array. |
| `filter_max_f` | CM4+CM7 | Maximum `float` in array. |

### `Middleware/Filters/moving_average.h` — Simple and weighted moving average filters for integer and float arrays.

| Function | Core | Purpose |
|---|---|---|
| `calculate_moving_average` | CM4+CM7 | Simple moving average of `uint32_t` values. |
| `calculate_weighted_average` | CM4+CM7 | Weighted moving average of `uint32_t` values (newer samples weighted higher). |
| `calculate_moving_average_f` | CM4+CM7 | Simple moving average of `float` values. |
| `calculate_weighted_average_f` | CM4+CM7 | Weighted moving average of `float` values (newer samples weighted higher). |

### `Middleware/Filters/ops_filter.h` — OPS adaptive filter — spike-aware smoothing for analog inputs.

| Function | Core | Purpose |
|---|---|---|
| `filter_ops` | CM4+CM7 | OPS custom adaptive filter (single sample step). |

### `Middleware/Filters/trimmed_sorted_filters.h` — Outlier-resistant averages: trimmed (unsorted) and sorted trimmed mean.

| Function | Core | Purpose |
|---|---|---|
| `calculate_trimmed_average_f` | CM4+CM7 | Trimmed average of floats (no sort — assumes representative order). |
| `calculate_sorted_average_f` | CM4+CM7 | Sorted trimmed average of floats. |

## Watchdog (Middleware/Watchdog/)


### `Middleware/Watchdog/watchdog.h` — Dual-core software watchdog over ICC (FreeRTOS task + osDelay; no hardware TIM).

| Function | Core | Purpose |
|---|---|---|
| `watchdog_init` | CM4+CM7 | Load PRIMARY watchdog block from EEPROM and start or stop the local monitor task. |
| `watchdog_apply_from_eeprom` | CM4+CM7 | Reload config from EEPROM (e.g. after web Save & Apply on watchdog tab). |
| `watchdog_apply_config` | CM4+CM7 | Apply in-memory config on this core (web Apply / Save & Apply; no EEPROM read). |
| `Watchdog_ICC_HandlePacket` | CM4+CM7 | CM4/CM7 ICC handler for `IC_CH_WATCHDOG` (WITH_ID packets). |
| `watchdog_grace_ms` | CM4+CM7 | Suspend peer-recovery on this core for `ms` . |

## HW mutex (Middleware/Mutex/)


### `Middleware/Mutex/hw_mutex.h` — Hardware mutex management for STM32H757 dual-core shared peripherals.

| Function | Core | Purpose |
|---|---|---|
| `HW_Mutex_Init` | CM4+CM7 | Initialize all hardware mutexes. |
| `HW_Mutex_Lock` | CM4+CM7 | Try to acquire the mutex for the given hardware peripheral. |
| `HW_Mutex_Unlock` | CM4+CM7 | Release the mutex for the given hardware peripheral. |
| `HW_Mutex_IsAvailable` | CM4+CM7 | Check if the mutex is currently available (not taken). |

## Cranesystem app middleware (Middleware/Applicatons/)


### `Middleware/Applicatons/Cranesystem/cranesystem_transmit.h` — Cranesystem: per-slot network transmit workers (slots 0–7).

| Function | Core | Purpose |
|---|---|---|
| `cranesystem_network_tx_task_params_factory` | CM4+CM7 | Fill outbound packet factory defaults (slot 0 factory destination). |
| `cranesystem_network_tx_transmit_args_factory` | CM4+CM7 | Fill default full args: slot 0, `PRIMARY_SETTINGS` , factory packet + IP channel. |
| `cranesystem_network_tx_transmit_start` | CM4+CM7 | Start worker for `args->transmit_slot_index` (0 .. `CRANESYSTEM_TRANSMIT_SLOT_MAX` ). |
| `cranesystem_network_tx_transmit_stop` | CM4+CM7 | Stop worker for `transmit_slot_index` (no-op if none running). |
| `cranesystem_network_tx_transmit_restart` | CM4+CM7 | Stop then start worker for the resolved slot. |
| `cranesystem_network_tx_apply_restart` | CM4+CM7 | Web/ICC entry: restart transmit worker on ETH-owning core only. |
| `cranesystem_network_tx_apply_stop` | CM4+CM7 | Web/ICC entry: stop transmit worker on ETH-owning core only. |
| `cranesystem_network_tx_apply_get_task_handle` | CM4+CM7 | Task handle for apply-path worker (monitoring). |
| `cranesystem_network_tx_transmit_get_task_handle` | CM4+CM7 | Current worker task handle for `transmit_slot_index` . |
| `cranesystem_network_tx_transmit_get_stack_hw` | CM4+CM7 | Stack high-water mark for transmit worker (words remaining). |

## Devices — on/off-board chips (devices/)


### `devices/onboard/DAC/DAC084S085_104S085_124S085/dac.h` — DAC084S085 — one entry point, same on CM4 and CM7.

| Function | Core | Purpose |
|---|---|---|
| `dac_ctrl` | CM4+CM7 | Run one DAC operation (same call on CM4 and CM7). Internally chooses local SPI vs ICC. Returns |

### `devices/onboard/DAC/DAC084S085_104S085_124S085/dac_icc.h` — ICC bridge for DAC mainprint — CM7 client, CM4 SPI server (ICC-internal).

| Function | Core | Purpose |
|---|---|---|
| `DAC_Mainprint_ICC_HandlePacket` | CM4+CM7 | ICC server entry for DAC mainprint (CM4 build with DAC ownership only). Dispatches |

### `devices/onboard/Eeprom/m24m01/m24m01.h` — M24M01 1 Mbit (128 KiB) I2C EEPROM — byte and burst read/write.

| Function | Core | Purpose |
|---|---|---|
| `M24M01_Write` | CM4+CM7 | Write one byte to EEPROM at `address` . |
| `M24M01_Read` | CM4+CM7 | Read one byte from EEPROM. |
| `M24M01_Test` | CM4+CM7 | Run write/read/burst self-test and print results on `test_uart` . |
| `M24M01_WriteBurst` | CM4+CM7 | Program `size` bytes starting at `startAddress` . |
| `M24M01_ReadBurst` | CM4+CM7 | Read `size` bytes starting at `startAddress` . |

### `devices/onboard/MAC_prom/AT24MAC402/AT24MAC402.h` — AT24MAC402 — 2 Kbit EEPROM plus factory MAC/EUI and serial number devices.

| Function | Core | Purpose |
|---|---|---|
| `AT24MAC402_Write_EEPROM` | CM4+CM7 | Write one byte to the EEPROM array at `address` . |
| `AT24MAC402_Read_EEPROM` | CM4+CM7 | Read one byte from the EEPROM array. |
| `AT24MAC402_WritePage_EEPROM` | CM4+CM7 | Page program up to `AT24MAC402_PAGE_SIZE` bytes within one EEPROM page. |
| `AT24MAC402_ReadSequential_EEPROM` | CM4+CM7 | Sequential read `length` bytes starting at `address` . |
| `AT24MAC402_EnableWriteProtection` | CM4+CM7 | Enable hardware write protection on the EEPROM array. |
| `AT24MAC402_ReadMAC48` | CM4+CM7 | Read factory 48-bit EUI from the MAC device (`AT24MAC402_MAC_ADDR` ). |
| `AT24MAC402_ReadMAC64` | CM4+CM7 | Read 64-bit MAC/EUI from the MAC device. |
| `AT24MAC402_ReadSerial` | CM4+CM7 | Read 16-byte unique serial number from the MAC device. |
| `AT24MAC402_WriteBurst_EEPROM` | CM4+CM7 | Burst write across page boundaries (handles page delays internally). |
| `AT24MAC402_ReadBurst_EEPROM` | CM4+CM7 | Burst read from the EEPROM array. |
| `AT24MAC402_CheckEEPROMReady` | CM4+CM7 | Poll until EEPROM write cycle completes (ACK polling). |
| `AT24MAC402_CheckMACReady` | CM4+CM7 | Poll until MAC/serial device is ready. |
| `AT24MAC402_DummyWrite` | CM4+CM7 | Single-byte write used for bus recovery / presence check. |
| `AT24MAC402_Test` | CM4+CM7 | Run EEPROM and MAC read/write self-test; prints on `huart` when debug enabled. |

### `devices/onboard/RS485/ltc2870_rs485/ltc2870_rs485.h` — RS-485 driver for LTC2870 IC connected to onboard UARTs

| Function | Core | Purpose |
|---|---|---|
| `LTC2870_RS485_Init` | CM4+CM7 | Initialize RS-485 GPIOs for a given UART. |
| `LTC2870_RS485_ApplyConfig` | CM4+CM7 | Apply RS-485 configuration to a UART (update pin states). |
| `LTC2870_RS485_DeInit` | CM4+CM7 | Deinitialize RS-485 GPIOs for a UART. |
| `RS485_ICC_HandlePacket` | CM4+CM7 | ICC packet handler for RS-485 bridge (ICC-internal — not for application code). Handles NO_ID ( |
| `LTC2870_Transmitter_OnOff` | CM4+CM7 | Turn the transmitter ON or OFF. |

### `devices/onboard/netwerk_chip/KSZ9897/ksz9897_functions.h` — KSZ9897 seven-port Ethernet switch — init, port/global parameters, debug display.

| Function | Core | Purpose |
|---|---|---|
| `KSZ9897_InitializePins` | CM4+CM7 | Initialize all non-SPI pins used by the KSZ9897 |
| `KSZ9897_FullChipReset` | CM4+CM7 | Perform hardware reset using RSTN pin |
| `KSZ9897_VerifyChipID` | CM4+CM7 | Verify KSZ9897 chip identification (Debug only) |
| `KSZ9897_Init` | CM4+CM7 | Complete KSZ9897 initialization sequence |
| `KSZ9897_GetPortParam` | CM4+CM7 | Get a specific parameter from a port This function reads a specific parameter from the specified port. The parameter type is defined by the KSZ_PortParam_t enum. The result is stored at the location pointed to by 'output |
| `KSZ9897_SetPortParam` | CM4+CM7 | Set a specific parameter for a port This function writes a specific parameter to the specified port. The parameter type is defined by the KSZ_PortParam_t enum. The new value is read from the location pointed to by 'input |
| `KSZ9897_GetGlobalParam` | CM4+CM7 | Get a specific global parameter This function reads a specific parameter from the global switch configuration. The parameter type is defined by the KSZ_GlobalParam_t enum. The result is stored at the location pointed to  |
| `KSZ9897_SetGlobalParam` | CM4+CM7 | Set a specific global parameter This function writes a specific parameter to the global switch configuration. The parameter type is defined by the KSZ_GlobalParam_t enum. The new value is read from the location pointed t |
| `KSZ9897_DisplayPortInfo` | CM4+CM7 | Display port information to UART This function displays formatted information about a port parameter to the specified UART interface. It automatically formats the output based on the parameter type. |
| `KSZ9897_DisplayGlobalInfo` | CM4+CM7 | Display global information to UART This function displays formatted information about a global parameter to the specified UART interface. It automatically formats the output based on the parameter type. |
| `KSZ_PortToString` | CM4+CM7 | Convert port enum to human-readable string |
| `KSZ_SpeedToString` | CM4+CM7 | Convert speed enum to human-readable string |
| `KSZ_DuplexToString` | CM4+CM7 | Convert duplex enum to human-readable string |
| `KSZ_LinkStatusToString` | CM4+CM7 | Convert link status enum to human-readable string |
| `KSZ_LedModeToString` | CM4+CM7 | Convert LED mode enum to human-readable string |
| `KSZ_XmiiModeToString` | CM4+CM7 | Convert XMII mode enum to human-readable string |
| `KSZ_PortParamToString` | CM4+CM7 | Convert port parameter enum to human-readable string |
| `KSZ_GlobalParamToString` | CM4+CM7 | Convert global parameter enum to human-readable string |

## Boot / init (init/)


### `init/application/Cranesystem/ops_app_cranesystem_init.h` — Application init — Cranesystem runtime (stand-alone TX, gates, …).

| Function | Core | Purpose |
|---|---|---|
| `ops_app_cranesystem_init` | CM4+CM7 | Start Cranesystem application runtime for current EEPROM sub-role. |

### `init/application/Drone/ops_app_drone_init.h` — Application init — Drone runtime.

| Function | Core | Purpose |
|---|---|---|
| `ops_app_drone_init` | CM4+CM7 | Drone application runtime start (stub until implemented). |

### `init/application/Rheotune/ops_app_rheotune_init.h` — Application init — Rheotune runtime.

| Function | Core | Purpose |
|---|---|---|
| `ops_app_rheotune_init` | CM4+CM7 | Rheotune application runtime start (stub until implemented). |

### `init/application/Silas/ops_app_silas_init.h` — Application init — Silas runtime.

| Function | Core | Purpose |
|---|---|---|
| `ops_app_silas_init` | CM4+CM7 | Silas application runtime start (stub until implemented). |

### `init/application/undefined/ops_app_undefined_init.h` — Application init — undefined / invalid EEPROM role (no-op runtime).

| Function | Core | Purpose |
|---|---|---|
| `ops_app_undefined_init` | CM4+CM7 | No application-specific runtime start. |

### `init/ops_init.h` — MFCB OPS bring-up — public two-stage init API (platform, then application).

| Function | Core | Purpose |
|---|---|---|
| `ops_init_platform` | CM4+CM7 | Stage 1 — platform / board OPS runtime (core-specific inside `OPS/init/platform/).` Moves here from |
| `ops_init_application` | CM4+CM7 | Stage 2 — application role from EEPROM (main + sub), per-app runtime start. Dispatches to |

### `init/ops_init_internal.h` — OPS init — internal declarations (not for Core `main.c` or web code).

| Function | Core | Purpose |
|---|---|---|
| `ops_init_platform_run` | CM4+CM7 | Stage 1 body — selects CM4 or CM7 platform implementation. |
| `ops_init_application_run` | CM4+CM7 | Stage 2 body — read EEPROM main/sub and call per-app init. |
| `ops_init_platform_cm4_impl` | **CM4 only** | Stage 2 body — read EEPROM main/sub and call per-app init. |
| `ops_init_platform_cm7_impl` | **CM7 only** | Stage 2 body — read EEPROM main/sub and call per-app init. |
| `ops_app_undefined_init` | CM4+CM7 | Stage 2 body — read EEPROM main/sub and call per-app init. |
| `ops_app_cranesystem_init` | CM4+CM7 |  |
| `ops_app_drone_init` | CM4+CM7 |  |
| `ops_app_silas_init` | CM4+CM7 |  |
| `ops_app_rheotune_init` | CM4+CM7 |  |

## LwIP glue (LWIP/)


### `LWIP/App/lwip.h` — LwIP middleware init — bring up `gnetif` , DHCP or static IP, DNS.

| Function | Core | Purpose |
|---|---|---|
| `MX_LWIP_Init` | CM4+CM7 | Initialize LwIP stack, `gnetif` , and network addressing. Calls |
| `MX_LWIP_DeInit` | CM4+CM7 | Tear down `gnetif` , Ethernet driver, and LwIP threads. Stops RX/link threads, releases ETH HAL, removes netif. Called automatically at the start of |
| `MX_LWIP_Process` | CM4+CM7 | Bare-metal poll loop — process RX, timers, and link check. Call periodically from |

### `LWIP/Target/ethernetif.h` — STM32H7 RMII Ethernet port for LwIP — low-level netif driver API.

| Function | Core | Purpose |
|---|---|---|
| `ethernetif_init` | CM4+CM7 | LwIP netif init callback — wire `netif` to STM32 ETH low-level driver. Sets interface name, output callbacks ( |
| `ethernetif_input` | CM4+CM7 | FreeRTOS RX thread entry — drain ETH DMA and pass frames to LwIP. Blocks on |
| `ethernet_link_check_state` | CM4+CM7 | Assert link-up on `netif` when the driver reports connectivity. If |
| `Error_Handler` | hook/weak — no lib body | Fatal error hook for unrecoverable ETH init failures. Called from |
| `sys_jiffies` | hook/weak — no lib body | Millisecond tick counter for LwIP `sys_arch` timeouts. Required by LwIP when not overridden by |
| `sys_now` | CM4+CM7 | Current time in milliseconds for LwIP (`sys_now` , TCP RTO, ICMP throttle). |
| `HAL_ETH_MspInit` | CM4+CM7 | HAL weak override — enable ETH peripheral clocks, GPIO, and NVIC. |
| `HAL_ETH_MspDeInit` | CM4+CM7 | HAL weak override — disable ETH GPIO and clocks on deinit. |

---

## Appendix A — Customer-overridable hooks (declared in headers, no body in either libops.a)

| Function | Header | Notes |
|---|---|---|
| `Error_Handler` | (Cube `main.h`) | provided by Core/Src/main.c on each core |
| `UART_Task_OnFrame` | `peripherals/uart/uart_task.h` | weak hook — called on CM4 task context when a UART frame completes; ideal customer RX entry point |
| `ICC_PacketReceivedHook_NO_ID` / `_WITH_ID` | `peripherals/inter_core_communication/intercore_comm.h` | customer hooks for inter-core packets |
| `ip_channel_send_test_message` | `Settings/ip_channel_config.h` | declared but absent from CURRENT libs — do not call |
| `settings_print_struct` | `Settings/settings.h` | declared but absent from CURRENT libs — do not call |
| `sys_jiffies` | `LWIP/Target` | provided by LwIP port glue |

## Appendix B — Library-internal symbols (in libops.a but in no public header)

Do not call these directly; listed so link errors / disassembly make sense.

`HAL_ADC_MspInit/DeInit`, `HAL_SPI_MspInit/DeInit`, `HAL_TIM_Base_MspInit/DeInit`,
`HAL_TIM_IC_MspInit/DeInit`, `HAL_TIM_IC_CaptureCallback`, `HAL_UART_RxCpltCallback`,
`HAL_UART_ErrorCallback`, `HAL_ETH_*Callback` (6), `TIM2/3/5/7/8_CC_IRQHandler`,
`M24M01_Init`, `M24M01_TestDeviceReady`, `Network_ICC_HandlePacket_NO_ID/_WITH_ID`,
`check_dma_memory_overlap`, `check_memory_layout`, `ethernet_link_thread`, `ethernetif_deinit`,
`generate_device_info_simple`, `get_Filter_OPS_response_speed/spike_threshold/stability_threshold`,
`pbuf_free_custom`, `pwm_internal_test`, `secure_clear`, `uart_transmit_raw`.

## Appendix C — Regenerating this file

Scripts live in the session scratchpad (rewrite if lost):
1. `nm --defined-only libops.a | awk '$2=="T"{print $3}' | sort -u` per core → symbol sets.
2. Parse headers for prototypes + `@brief` (linear paren-matching scanner, not regex-only).
3. Cross-reference and emit tables. Re-run whenever the supplier ships a new `libops.a`
   (NEWER build: `NewBoard/Newer_build_includes/` — 205 headers, not linked yet, NOT covered here).
