# Log 19 — Customer ICC traffic inventory (`IC_CH_CUSTOMER`)

**Date:** 2026-07-17  
**Status:** 📋 Living reference — **update this log whenever a Customer ICC tag/payload/direction changes**  
**Tree:** `NewBoard/Rewrite/MFCB_BASE`  
**Wire header:** `CM4/Customer/Inc/cust_icc.h` **and** `CM7/Customer/Inc/cust_icc.h` (must stay identical)  
**Related:** Log7 (ICC design), Log14 (steer), Log18 (motor DAC move)

---

## 0. Mandatory before any new Customer ICC send

1. Read **this entire log**
2. Read both `cust_icc.h` copies (tags + packed structs)
3. Check receiver storage: CM7 `cust_icc_mailbox_*` and/or CM4 per-tag slots in `Customer.c`
4. Check Log15 for send rate vs staleness timeout
5. Prefer **NO_ID + tag + latest-value slot** for cyclic commands; **WITH_ID** only for one-shot ack-needed events (Log7 §7)
6. **Never** put per-tick `dac_ctrl` / other WITH_ID device ops on the CM7 control loop (Log18)

Platform ICC (UART proxy, DAC internal, ADC, watchdog, …) is **not** listed here — only **Customer** `IC_CH_CUSTOMER` app traffic.

---

## 1. Common envelope (all tags)

```
Offset  Size  Field
0       1     tag          (cust_icc_tag_t)
1       1     version      (per-tag)
2       2     payload_len  (bytes after header)
4       4     sender_tick  (HAL_GetTick of sender; debug only)
8       N     payload      (tag-specific, packed)
```

Struct: `cust_icc_hdr_t` + payload. Total size must equal `CUST_ICC_HDR_SIZE + payload_len`.

Transport: `ICC_SendPacket_NO_ID(IC_CH_CUSTOMER, packet, total_len)` unless noted.

---

## 2. Tag registry

| Tag | Name | Dir | Sender | Receiver | Rate (typical) | Max age | Payload |
|-----|------|-----|--------|----------|----------------|---------|---------|
| `0x01` | `CUST_ICC_TAG_SBUS_SNAPSHOT` | CM4→CM7 | `rc_sbus_old.c` `ProcessRC` | CM7 `cust_icc_mailbox` → `rc_input.c` | ~7–14 ms (SBUS) | 100 ms | §3.1 |
| `0x02` | `CUST_ICC_TAG_STEER_CMD` | CM7→CM4 | `GEO-application-task.c` | CM4 per-tag slot → Pololu | ~CM7 tick (~5–10 ms) | 500 ms* | §3.2 |
| `0x03` | `CUST_ICC_TAG_MOTOR_DAC` | CM7→CM4 | `GEO-application-task.c` | CM4 peek → clamp → `dac_ctrl` | ~CM7 tick | **300 ms** | §3.3 (v2 µV) |

\*Steer age was raised 150→500 ms while CM7 was blocked by DAC (Log18); tighten after Stage 1 CPs pass.

**Reserved:** `0x10+` for future WITH_ID opcodes (do not use for NO_ID cyclic data).

---

## 3. Payloads

### 3.1 SBUS snapshot (`0x01`) — CM4→CM7

| Field | Type | Meaning |
|---|---|---|
| `flags` | `uint8_t` | bit0 = `CUST_ICC_SBUS_FLAG_REQUEST_RC` |
| `reserved` | `uint8_t` | 0 |
| `channels[16]` | `uint16_t` | Decoded SBUS µs-style channel values |

- Packet size: `CUST_ICC_SBUS_PACKET_SIZE`
- CM7 storage: dedicated mailbox slot (latest value + `rx_tick`)
- Consumer: `rc_input_update()` / sailing state

### 3.2 Steer command (`0x02`) — CM7→CM4

| Field | Type | Meaning |
|---|---|---|
| `steering_us` | `uint16_t` | 1000–2000, 1500 = neutral |
| `reserved` | `uint16_t` | 0 |

- Packet size: `CUST_ICC_STEER_PACKET_SIZE`
- CM4: Pololu MCP233 Cmd 32 duty (throttled 20 ms)
- Stale → duty 0

### 3.3 Motor DAC command (`0x03`) — CM7→CM4  *(v2 µV, Log18)*

| Field | Type | Meaning |
|---|---|---|
| `right_uv` | `uint32_t` | Right AO output-referred microvolts → `DAC_CH_A` |
| `left_uv` | `uint32_t` | Left AO output-referred microvolts → `DAC_CH_B` |

- Version: **2** (v1 µs payloads rejected)
- Range constants: `CUST_ICC_MOTOR_DAC_UV_MIN/MAX/MID` (0.4 / 3.0 / 1.7 V)
- CM7: `motor_command_to_voltage_uv()` / `prepareDACValue` (µs clamped signed)
- CM4: peek + RX age 300 ms; `MotorDac_ClampVoltageUv` + local `dac_ctrl`; stale → `UV_MID`
- Guideline: CM7 scale / CM4 IO+clamp — **not a hard rule** (`cm7-process-cm4-io-guideline.mdc`)

---

## 4. Receiver storage rules (collision avoidance)

| Core | Storage | Rule |
|---|---|---|
| CM7 | `cust_icc_mailbox` | **One slot per tag** (today: SBUS only). Incoming NO_ID routed by `hdr->tag`. |
| CM4 | Per-tag latest slots | **Must not** use a single overwrite slot for steer + motor — both arrive every tick; last-writer-wins drops one. Route `0x02` / `0x03` into separate slots. |

`Customer_Icc_GetPacket` single-slot API is only for WITH_ID / legacy; cyclic NO_ID tags use per-tag slots.

---

## 5. What must stay identical across cores

When changing wire format:

1. Edit **both** `CM4/.../cust_icc.h` and `CM7/.../cust_icc.h` the same way
2. Update **this log** (§2–3)
3. Update Log15 rates/timeouts
4. Flash **both** cores

---

## 6. Explicitly not on `IC_CH_CUSTOMER`

| Traffic | Channel / API |
|---|---|
| DAC SPI from CM7 (old hot path) | `IC_CH_DAC_MAINPRINT` inside `dac_ctrl` — **do not use per-tick from CM7** |
| Debug UART from CM7 | UART proxy ICC inside `uart_send_ctrl` |
| Dual-core watchdog | `IC_CH_WATCHDOG` |
| Board-to-board heartbeat GPIO | Not ICC (Log17) |

---

## 7. Changelog

| Date | Change |
|---|---|
| 2026-07-20 | Motor DAC v2: payload `right_uv`/`left_uv`; CM7 prepareDACValue; CM4 ClampVoltageUv |
| 2026-07-20 | Motor DAC: peek+RX age (B) + max age 100→300 ms (A); UART prints age/stale |
| 2026-07-20 | Stage 1b: CM4 `motor_dac_output.c` local `dac_ctrl` apply (change-only, stale→mid) |
| 2026-07-20 | Stage 1a live on `MFCB_BASE`: tag `0x03` send + CM4 per-tag print-only (no DAC apply) |
| 2026-07-17 | Initial inventory: `0x01` SBUS, `0x02` steer; add `0x03` motor DAC (Log18 Stage 1) |
