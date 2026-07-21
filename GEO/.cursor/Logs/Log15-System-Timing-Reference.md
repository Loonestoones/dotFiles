# Log 15 — System Timing Reference: Rates, Intervals, Timeouts

**Date:** 2026-07-17  
**Status:** 📋 Living reference — update whenever timing-sensitive code changes  
**Purpose:** Single source of truth for all timing constraints, rates, and intervals across the NewBoard firmware to prevent timing bugs and conflicts.

---

## 0. How to Use This Log

**MANDATORY:** Before adding/changing any timing-sensitive code (loops, throttles, timeouts, periodic sends):

1. **Read this entire log first**
2. Check for conflicts with existing rates
3. Add your new timing here
4. Cross-reference related systems (e.g., if changing ICC send rate, check receiver staleness timeout)

**Timing bug symptoms:**
- STALE/FRESH flickering
- Missed packets
- UART overflow
- Task starvation
- Inconsistent behavior between runs

---

## 1. Core Task Loop Rates

| Core | Task | Loop Period (Design) | Actual Rate (Measured) | Rate | File | Notes |
|------|------|----------------------|------------------------|------|------|-------|
| CM4 | `StartCustomerTask` | 2 ms | ~2 ms ✅ | 500 Hz | `CM4/Customer/Customer.c` | Main loop `osDelay(2)` — processes ICC, SBUS, Pololu |
| CM7 | `StartCustomerTask` | 10 ms | **~5 ms ✅ without CM7 `dac_ctrl`; ~240–400 ms ⚠️ with it** | see §1.1 | `CM7/Customer/Customer.c` | Wakes on SBUS ICC or `CUSTOMER_TASK_LOOP_DELAY_MS` |

**Critical:** 
- CM4 loops at design rate (2ms)
- **Never call blocking `dac_ctrl` / `WriteMotorDAC` from CM7 every tick** — see §1.1 / Log18
- Any CM4→CM7 traffic must not assume synchronous timing

### 1.1 CONFIRMED: CM7 tick blocked by `dac_ctrl` ICC wait (2026-07-17)

**Symptom:** ICC steering / app tick ran at ~200–400 ms, not ~10 ms.

**Root cause (bench-proven):** Each tick called `WriteMotorDAC` twice on CM7. On CM7,
`dac_ctrl(DAC_OP_OUTPUT_VOLTAGE)` → `ICC_SendPacket_WITH_ID` + `ICC_WaitForResponse`
(`osSemaphoreAcquire`, timeout 1000 ms). Two round-trips dominated the tick.

**Evidence:**
```
DAC on:  [CM7 UPDATE #20] delta=4000 ms  (10 calls → ~400 ms/tick)
DAC off: [CM7 UPDATE #20] delta=50 ms    (10 calls → ~5 ms/tick)
```
(Steer `last_rx` ~200 ms steps were the same effect observed from CM4.)

**Not the cause:** dashboard `network_send`, HB GPIO, steer NO_ID, task priority alone.

**Workaround (temporary):** `WriteMotorDAC` commented in `GEO-application-task.c` for A/B —
motors not driven until Log18 Stage 1.

**Fix plan:** Log18 — apply DAC on **CM4**; CM7 sends right/left via Customer ICC NO_ID.

**Steering timeout:** 500 ms remains until tick is healthy with motors restored; then tighten.

---

## 2. Inter-Core Communication (ICC)

### 2.1 Send Rates

| Direction | Channel | Payload | Send Rate | Sender File | Staleness Timeout |
|-----------|---------|---------|-----------|-------------|-------------------|
| CM4→CM7 | `IC_CH_CUSTOMER` | SBUS snapshot (tag 0x01) | ~7–14 ms (SBUS frame rate) | `CM4/Customer/Src/rc_sbus_old.c:ProcessRC()` | 100 ms (`CUST_ICC_SBUS_MAX_AGE_MS`) |
| CM7→CM4 | `IC_CH_CUSTOMER` | Steering command (tag 0x02) | ~CM7 tick (~5–10 ms after Log18) | `GEO-application-task.c` | 500 ms (`CUST_ICC_STEER_MAX_AGE_MS`) — tighten after CP-1a |
| CM7→CM4 | `IC_CH_CUSTOMER` | Motor DAC cmd (tag 0x03) | ~CM7 tick | `GEO-application-task.c` | **300 ms** (`CUST_ICC_MOTOR_DAC_MAX_AGE_MS`) — peek/RX age (Log18 B+A) |

### 2.2 Receive / Polling

| Core | Polling Rate | File | Method |
|------|--------------|------|--------|
| CM7 | 10 ms (every CM7 tick) | `CM7/Customer/Src/rc_input.c` | Reads SBUS ICC mailbox via `cust_icc_mailbox_read_sbus()` |
| CM4 | 2 ms (every CM4 tick) | `CM4/Customer/Customer.c` | Polls `Customer_Icc_GetPacket()` for steering ICC |

**Critical Rules:**
- **Staleness timeout must be > 2× send period** (allows 1 missed packet)
- CM4 SBUS send: ~10 ms avg → CM7 timeout: 100 ms ✅ (10× margin)
- CM7 steering send: **200 ms actual** → CM4 timeout: 500 ms ✅ (2.5× margin, increased 2026-07-17)
  - **Note:** Design intent was 10ms → 150ms, but CM7 runs at 200ms (§1.1 Known Issue)
- **Never calculate staleness BEFORE checking for new packets** (Bug #1 from Log14 Stage 4)
- **Recalculate staleness right before use** if use is inside a throttled block (Bug #1 complete fix)

---

## 3. UART Peripherals

### 3.1 UART Line Parameters

| Port | Role | Baud | Framing | Voltage | Owner | File |
|------|------|------|---------|---------|-------|------|
| UART1 | Debug console (both cores) | 115200 | 8N1, std | 3.3 V (fixed) | OPS lib | `main.h` CM4/CM7_INIT_DEBUG_UART |
| UART6 | SBUS RX + TX passthrough to AP | 100000 | 8E2, inverted | 3.3 V (5 V capable) | CM4 | `CM4/Customer/Src/rc_sbus_old.c` |
| UART7 | Pololu MCP233 motor controller | 115200 | 8N1, std | 3.3 V | CM4 | `CM4/Customer/Src/pololu_mcp233.c` |

### 3.2 UART Traffic Rates

| Port | Protocol | Frame/Packet Rate | Byte Rate | File | Notes |
|------|----------|-------------------|-----------|------|-------|
| UART6 RX | SBUS | ~7–14 ms (RC transmitter) | 25 bytes/frame | `rc_sbus_old.c` | Irregular; watchdog 120 ms |
| UART6 TX | SBUS mirror | Same as RX (passthrough) | 25 bytes/frame | `rc_sbus_old.c` | Sent on every valid RX frame |
| UART7 TX | Pololu Cmd 32 | **20 ms** (50 Hz, throttled 2026-07-17) | 6 bytes/cmd | `Customer.c` Stage 4 | **Was 2 ms (Bug #2)** — now throttled |
| UART1 | Debug prints | Throttled per print type | Variable | `GEO-debug.c` | See §4 |

**Critical:** UART7 was sending every 2 ms (500 Hz) → MCP233 couldn't keep up (ACK/readback failures). Now throttled to 20 ms.

---

## 4. Debug Print Throttles (UART1)

All debug prints use independent throttle timers to avoid UART1 spam. **Do not print unthrottled in loops.**

| Print Function | Throttle Period | File | Typical Call Site |
|----------------|-----------------|------|-------------------|
| `PrintPWMValuesUart1()` | 500 ms | `CM4/Customer/Src/GEO-debug.c` | `ProcessRC()` — 16 SBUS channels |
| `PrintUart6RawDebug()` | 500 ms | `GEO-debug.c` | SBUS raw frame debug |
| `PrintCanBootStatus()` | One-shot | `GEO-debug.c` | `Customer.c` init (CP-1a) |
| `PrintCanFrame()` | 500 ms | `GEO-debug.c` | `CAN_Input_Service()` loop |
| `PrintPololuSelfTest()` | 400 ms | `GEO-debug.c` | Self-test service (now disabled) |
| `PrintSteeringICC()` | 500 ms | `GEO-debug.c` | **Only when packet arrives** (not every loop) |
| `PrintSteeringDuty()` | 500 ms | `GEO-debug.c` | Every 20 ms duty send |

**Critical:** Independent throttles mean two prints can fire in the same loop iteration — they show the **same** system state (Bug #1 was calculating staleness at different times).

---

## 5. Peripheral Command Rates

### 5.1 Motor Control

| Peripheral | Command Rate | Owner | File | Notes |
|------------|--------------|-------|------|-------|
| DAC (ZF motors) | ICC ~CM7 tick; CM4 change-only SPI | CM7 µV / CM4 clamp+SPI | tag `0x03` v2 µV | peek/RX age 300 ms; stale→1.7 V mid (Log18) |
| Pololu MCP233 (steering) | **20 ms** (50 Hz) | CM4 | `CM4/Customer/Customer.c` | **Throttled 2026-07-17** (was 2 ms) |

### 5.2 Sensor Reads

| Peripheral | Read Rate | Owner | File | Notes |
|------------|-----------|-------|------|-------|
| PWM IN1/IN2 (AP_IMS) | 10 ms (every CM7 tick) | CM7 | `CM7/Customer/Src/tools.c:ProcessAP_IMS()` | Via OPS `pwm_in_ctrl(PWM_IN_OP_FETCH)` |
| ADC | On-demand | CM4 HAL / CM7 ICC | OPS lib | Not periodic in Customer code |

---

## 6. Network / UDP

| Operation | Rate / Timeout | File | Notes |
|-----------|----------------|------|-------|
| ROC UDP RX | Async (network task) | `CM7/Customer/Src/roc_udp.c` | Callback on packet arrival |
| ROC staleness | 3000 ms | `roc_udp.c` | `roc_udp_get_latest()` checks age; forces `Stop` state |
| Dashboard TX | 100 ms (`DashboardUpdate_MS`) | `roc_udp.c` | Throttled in `send_dashboard_feedback()` |

---

## 7. Staleness / Watchdog Timeouts

| Data Source | Timeout | Check Location | Fail-Safe Action |
|-------------|---------|----------------|------------------|
| SBUS ICC (CM4→CM7) | 100 ms | `CM7/Customer/Src/rc_input.c` | `rc_input_update()` returns `false` |
| Steering ICC (CM7→CM4) | 150 ms | `CM4/Customer/Customer.c` | Force Pololu duty = 0 |
| ROC UDP | 3000 ms | `CM7/Customer/Src/roc_udp.c` | State machine → `Stop`, motors neutral |
| SBUS UART6 RX | 120 ms | `CM4/Customer/Src/rc_sbus_old.c` | Enter `RC_SBUS_OLD_RX_HUNTING` (resync) |

**Pattern:** Timeouts are 10–15× the expected update rate to tolerate jitter and occasional packet loss.

---

## 8. State Machine / Application Logic

| Operation | Rate | File | Notes |
|-----------|------|------|-------|
| Sailing state machine | 10 ms | `CM7/Customer/Src/GEO-application-task.c` | Every CM7 tick: RC / ROC / AP_IMS / Stop decision |
| Dashboard feedback send | 100 ms (throttled) | `roc_udp.c` | End of CM7 tick |

---

## 9. Hardware Timing Constraints

### 9.1 Pololu MCP233 (UART7)

| Constraint | Value | Source | Impact |
|------------|-------|--------|--------|
| UART baud | 115200 bps | `pololu_mcp233.c` | ~0.5 ms per 6-byte command |
| ACK reply time | < 1 ms (real hw) | Bench observation | Fast; mock may be slower |
| Command spacing | **≥ 20 ms recommended** | Bug #2 finding | Too fast → ACK/readback FAIL |
| Blocking TX timeout | 50 ms | `POLOLU_MCP233_TX_TIMEOUT_MS` | HAL_UART_Transmit max wait |

**Lesson from Bug #2:** Even though MCP233 UART is fast (115200 baud), the controller needs processing time between commands. Sending every 2 ms overwhelmed it; 20 ms works reliably.

### 9.2 SBUS (UART6)

| Constraint | Value | Source | Impact |
|------------|-------|--------|--------|
| Frame period | 7–14 ms | RC transmitter | Irregular; depends on TX |
| Frame size | 25 bytes | SBUS spec | ~2.2 ms @ 100k baud |
| Watchdog | 120 ms | `RC_SBUS_OLD_RX_WATCHDOG_MS` | 10× nominal frame period |

---

## 10. FreeRTOS / Kernel

| Parameter | Value | Notes |
|-----------|-------|-------|
| Tick rate | 1 ms | `osKernelGetTickCount()` resolution |
| `osDelay(N)` | N ms | Minimum; actual may be N+1 if unlucky phase |

**Critical:** `osDelay(2)` in CM4 loop means "at least 2 ms" — actual could be 2–3 ms depending on kernel tick phase. Never assume exact timing; always use `>=` in staleness checks.

---

## 11. Timing Bug Checklist

Before committing timing-sensitive code, verify:

- [ ] Loop period documented in this log
- [ ] Send rate < (staleness timeout ÷ 10)
- [ ] Peripheral command rate doesn't exceed hardware limit
- [ ] Debug prints throttled (≥ 400 ms)
- [ ] Staleness calculated AFTER checking for new data
- [ ] **Staleness RE-calculated right before use** (if use is inside a throttled block)
- [ ] No assumption that sender/receiver are synchronous
- [ ] Independent throttle timers used for related prints
- [ ] UART not spammed faster than device can process
- [ ] Fire-and-forget UART commands drain ACKs (prevent RX buffer overflow)

---

## 12. Common Timing Bug Patterns (Lessons Learned)

### Pattern A: Staleness Calculation Timing (Bug #1 from Log14 Stage 4)

**Symptom:** STALE/FRESH status flickering even though packets arrive regularly.

**Root Cause:**
```c
// WRONG - calculate once at top of loop
age_ms = now - last_rx_time;
stale = (age_ms > timeout);

// ... later in loop, inside a throttled block ...
if (should_send_every_20ms) {
    if (stale) {  // Uses OLD stale value!
        duty = 0;
    }
}
```

Between calculating `stale` and using it, packets can arrive and update `last_rx_time`, but `stale` isn't recalculated. If the usage is inside a throttled block (e.g., every 20ms), it may use a stale value from a much earlier loop iteration.

**Fix:** Recalculate staleness RIGHT BEFORE use:
```c
if (should_send_every_20ms) {
    age_ms = now - last_rx_time;  // Fresh calculation
    stale = (age_ms > timeout);
    if (stale) {
        duty = 0;
    }
}
```

### Pattern B: UART Fire-and-Forget ACK Overflow

**Symptom:** Commands work initially but fail after a while; ACK/readback intermittent failures.

**Root Cause:**
- Write command sent (e.g., Pololu Cmd 32)
- Device replies with 0xFF ACK
- Firmware doesn't read ACK (fire-and-forget)
- After many commands, UART RX buffer fills with unread 0xFF bytes
- Buffer overflow or stale bytes interfere with later reads

**Fix:** Drain ACKs after every send:
```c
HAL_UART_Transmit(&huart7, cmd_packet, len, timeout);
// Drain any ACK bytes (non-blocking, 0ms timeout)
while (HAL_UART_Receive(&huart7, &ack_drain, 1, 0) == HAL_OK) {
    // Empty loop - just drain buffer
}
```

### Pattern C: Independent Throttle Timers Show Different States

**Symptom:** Two related debug prints (e.g., packet RX and command send) show inconsistent states even though they're in the same system.

**Root Cause:**
- Print A throttled to 500ms, last printed at T=0
- Print B throttled to 500ms, last printed at T=100ms
- At T=500ms, Print A fires (shows state at T=500ms)
- At T=600ms, Print B fires (shows state at T=600ms)
- System state may have changed between T=500 and T=600

**Fix:** Either:
1. Use the same throttle timer for related prints, OR
2. Accept that they show different snapshots (document this)

---

## 13. Cross-References

- **Log7** — ICC design notes (CM4↔CM7 mailbox/slot patterns)
- **Log9** — ROC UDP + network RX task rules (never call `network_send` from RX callback)
- **Log14** — Pololu MCP233 implementation (Stages 0–4, Bug #1 & #2 fixes)
- **Log4** — SBUS UART6 implementation (frame alignment, watchdog)

---

## 14. Update History

| Date | Change | By |
|------|--------|-----|
| 2026-07-17 | Initial version (Logs 0–14 consolidated) | Log15 creation |
| 2026-07-17 | Pololu command rate: 2 ms → 20 ms (Bug #2 fix) | Log14 Stage 4 |
| 2026-07-17 | Steering ICC debug: print only on packet arrival (Bug #1 first attempt) | Log14 Stage 4 |
| 2026-07-17 | **Critical fix:** Staleness recalculated INSIDE duty send block (Bug #1 complete fix) | Log14 Stage 4 retry |
| 2026-07-17 | MCP233 ACK drain added (fire-and-forget ACKs were filling UART7 RX buffer) | Log14 Stage 4 |
| 2026-07-17 | **Known issue documented:** CM7 task running at 200ms (not 10ms design); steering ICC timeout increased 150ms → 500ms | Log14 Stage 4 investigation |
