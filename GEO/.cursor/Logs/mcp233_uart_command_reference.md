# MCP233 UART Packet Serial — Command Reference

Reference for controlling the Basicmicro MCP233 from the MFCB (or any UART master) via Packet Serial mode.

---

## 1. UART Setup

| Setting | Value |
|---|---|
| Mode | Packet Serial (set in Ion Studio: General Settings → I2C/TTL UART1 → Mode) |
| Baud rate | 115200 |
| Address | 0x80 (default, configurable via command 141) |
| Physical pins | S1 / S2 (DB15 pins 4 / 11) → MCU TX/RX |

**Note:** MCP233 ships with S1/S2 unconfigured. If Packet Serial mode isn't explicitly set in Ion Studio first, the board will not respond to UART commands and will raise a `PacketTimeoutError`.

---

## 2. Packet Structure

Every command follows the same envelope:

```
Send:    [Address, Command, Data..., CRC(2 bytes)]
Receive: [0xFF]                      (write commands — ACK)
     or  [Data..., CRC(2 bytes)]     (read commands)
```

- **Address** — target board address (0x80)
- **Command** — command number, 0–253
- **Data** — command-specific arguments; multi-byte values are sent high byte first
- **CRC** — CRC16 checksum appended to every packet (master must compute this — the `basicmicro` Python library handles it automatically; a custom MFCB firmware implementation will need to compute it directly)

32-bit and 16-bit values are split manually when building packets:

```c
unsigned char byte3 = value >> 24; // high byte
unsigned char byte2 = value >> 16;
unsigned char byte1 = value >> 8;
unsigned char byte0 = value;       // low byte
```

---

## 3. Open-Loop Commands (No Encoder Required)

These control motor duty cycle / direction directly — no speed feedback, no PID. This is the mode already validated end-to-end from the Linux laptop (`basicmicro` library, `ReadPWMs` confirms readback).

### Legacy compatibility commands (0–13)
Single-byte value, range 0–127.

| Cmd | Description |
|---|---|
| 0 | Drive Forward M1 |
| 1 | Drive Backward M1 |
| 4 | Drive Forward M2 |
| 5 | Drive Backward M2 |
| 6 | Drive M1 (7-bit, signed: 0=full reverse, 64=stop, 127=full forward) |
| 7 | Drive M2 (7-bit, same scheme) |
| 8 | Drive Forward — Mixed Mode |
| 9 | Drive Backward — Mixed Mode |
| 10 | Turn Right — Mixed Mode |
| 11 | Turn Left — Mixed Mode |
| 12 | Drive Forward/Backward (7-bit) — Mixed Mode |
| 13 | Turn Left/Right (7-bit) — Mixed Mode |

### Advanced duty-cycle commands (32–34, 52–54)
Signed 16-bit value, range **−32767 to +32767** (±100% duty). Finer resolution than the legacy commands above.

| Cmd | Description |
|---|---|
| 32 | Drive M1 with signed duty cycle |
| 33 | Drive M2 with signed duty cycle |
| 34 | Drive M1 & M2 together with signed duty cycle |
| 52 | Drive M1 with signed duty + acceleration |
| 53 | Drive M2 with signed duty + acceleration |
| 54 | Drive M1 & M2 with signed duty + acceleration |

**Recommended for MFCB open-loop control:** commands 32–34 (or 52–54 if acceleration ramping is needed).

---

## 4. Closed-Loop Commands (Encoder Required)

Require EN1A/EN1B (M1) and/or EN2A/EN2B (M2) quadrature encoder wiring. Not yet available until encoder wiring is completed — planned next step.

### PID configuration

| Cmd | Description |
|---|---|
| 28 | Set Velocity PID Constants — M1 |
| 29 | Set Velocity PID Constants — M2 |
| 55 | Read Velocity PID Constants — M1 |
| 56 | Read Velocity PID Constants — M2 |
| 61+ | Set/Read Position PID Constants |

> Ion Studio's Autotune feature has no UART command equivalent — PID autotuning must be done in software if you want to replicate it outside Ion Studio.

### Speed control (quad pulses/second, signed)

| Cmd | Description |
|---|---|
| 35 | Drive M1 with signed speed |
| 36 | Drive M2 with signed speed |
| 37 | Drive M1 & M2 with signed speed |
| 38 | Drive M1 with signed speed + acceleration |
| 39 | Drive M2 with signed speed + acceleration |
| 40 | Drive M1 & M2 with signed speed + acceleration |
| 50 | Drive M1 & M2 with individual signed speed + acceleration |

### Speed + distance (buffered moves)

| Cmd | Description |
|---|---|
| 41 | Drive M1 with signed speed + distance (buffered) |
| 42 | Drive M2 with signed speed + distance (buffered) |
| 43 | Drive M1 & M2 with signed speed + distance (buffered) |
| 44 | Drive M1 with signed speed, acceleration + distance (buffered) |
| 45 | Drive M2 with signed speed, acceleration + distance (buffered) |
| 46 | Drive M1 & M2 with signed speed, acceleration + distance (buffered) |
| 51 | Drive M1 & M2 with individual signed speed, accel + distance |
| 47 | Read Buffer Length |

> Buffered commands accept a `Buffer` flag: `0` = queue and execute in order sent; `1` = stop current motion, clear queue, execute immediately.

---

## 5. Telemetry / Status Commands (Either Mode)

Useful for verifying commanded values actually reached the motor — the same role `ReadPWMs` played in the laptop validation.

| Cmd | Description |
|---|---|
| 48 | Read Motor PWMs |
| 49 | Read Motor Currents |
| 78 | Read Encoder Counters (M1 & M2) |
| 79 | Read Instantaneous Speeds (last 1/300s) |
| 31 | Read raw/unfiltered speed |
| 90 | Read Status |
| 24 | Read Main Battery Voltage |
| 25 | Read Logic Battery Voltage |
| 82 / 83 | Read Temperature / Temperature 2 |
| 21 | Read Firmware Version |

---

## 6. One-Time Configuration Commands

Typically set once via Ion Studio during bring-up rather than sent repeatedly at runtime from the MFCB.

| Cmd | Description |
|---|---|
| 2 / 3 | Set Min/Max Main Voltage (legacy — command 57 preferred) |
| 57 / 58 | Set Main/Logic Battery Voltages |
| 92 / 93 | Set Encoder Mode — M1 / M2 |
| 133 / 134 | Set Max Current Limit — M1 / M2 |
| 141 | Set Address & Mixed Flag |
| 94 | Write Settings to EEPROM |
| 95 | Read Settings from EEPROM |
| 80 | Restore Defaults |

---

## 7. Suggested MFCB Implementation Path

1. **Phase 1 (current capability):** commands 32–34 for open-loop duty control, command 48 to verify PWM readback — direct equivalent of what's already validated via the laptop + `basicmicro` library.
2. **Phase 2 (after encoder wiring):** commands 28/29 to set velocity PID gains, 35–37 for closed-loop speed commands, 78/79/55/56 for feedback and gain verification.
3. **CRC16:** confirm the CRC16 polynomial/implementation used by Basicmicro (matches the `basicmicro` library's internal calculation) before writing MFCB firmware — this is currently handled transparently by the Python library and will need to be reimplemented in C/embedded code.
