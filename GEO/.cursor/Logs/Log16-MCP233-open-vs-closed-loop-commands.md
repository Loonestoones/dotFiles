# Log 16 — MCP233 Open-Loop vs Closed-Loop Command Comparison

**Date:** 2026-07-17  
**Status:** 📚 Reference log — command mapping for future encoder upgrade  
**Source:** `NewBoard/Pololu-mcp233/mcp_user_manual.pdf` + `mcp23x_datasheet.pdf` + `.cursor/Logs/mcp233_uart_command_reference.md`  
**Context:** Documents the transition path from current open-loop duty control (Stage 4, working) to future closed-loop speed/position control (Stage 6, parked pending encoder wiring).

---

## 0. Current Implementation Status (2026-07-17)

**Working now (open-loop):**
- Cmd 32: `DriveM1Duty(±32767)` — direct duty cycle control
- Map: 1000-2000µs steering → ±32767 duty (±100%)
- No encoder required
- No PID involved
- Stage 4 bench testing in progress (RC/ROC steering working)

**Future upgrade (closed-loop):**
- Cmd 35: `DriveM1Speed(±QPPS)` — velocity control with internal PID
- Requires: Encoder wired to MCP233 EN1A/EN1B pins
- Requires: PID gains configured (via Motion Studio or Cmd 28)
- Benefits: Accurate speed/position, load compensation, fault detection

---

## 1. Command Reference (from MCP User Manual)

### 1.1 Open-Loop Commands (No Encoder)

**Duty Cycle Control — No Feedback**

| Cmd | Name | Data Format | Range | Description |
|-----|------|-------------|-------|-------------|
| 32 | Drive M1 Duty | int16 (2 bytes) | ±32767 | M1 signed duty cycle (±100%) |
| 33 | Drive M2 Duty | int16 (2 bytes) | ±32767 | M2 signed duty cycle (±100%) |
| 34 | Drive M1M2 Duty | int16 (2 bytes) | ±32767 | Both motors, same duty |
| 52 | Drive M1 Duty + Accel | int32, int16 | ±32767 | M1 duty with acceleration ramp |
| 53 | Drive M2 Duty + Accel | int32, int16 | ±32767 | M2 duty with acceleration ramp |
| 54 | Drive M1M2 Duty + Accel | int32, int16 | ±32767 | Both motors with accel ramp |

**Packet Format (Cmd 32 example):**
```
Send: [0x80, 0x20, duty_hi, duty_lo, crc_hi, crc_lo]
Reply: [0xFF]  (ACK)
```

**Current firmware usage:**
```c
// Customer.c line 195:
Pololu_MCP233_DriveM1Duty(duty);  // duty = ±32767

// Mapping (line 190-193):
int32_t us = clamp(s_last_steering_us, 1000, 2000);
int32_t duty_scaled = ((us - 1500) * 32767) / 500;
duty = (int16_t)duty_scaled;
```

---

### 1.2 Closed-Loop Commands (Encoder Required)

**Speed Control — PID Feedback**

| Cmd | Name | Data Format | Units | Description |
|-----|------|-------------|-------|-------------|
| 35 | Drive M1 Speed | int32 (4 bytes) | QPPS | M1 signed speed (quadrature pulses/sec) |
| 36 | Drive M2 Speed | int32 (4 bytes) | QPPS | M2 signed speed |
| 37 | Drive M1M2 Speed | int32 (4 bytes) | QPPS | Both motors, same speed |
| 38 | Drive M1 Speed + Accel | int32, int32 | QPPS | M1 speed with accel limit |
| 39 | Drive M2 Speed + Accel | int32, int32 | QPPS | M2 speed with accel limit |
| 40 | Drive M1M2 Speed + Accel | int32, int32 | QPPS | Both motors with accel limit |

**QPPS = Quadrature Pulses Per Second** (encoder counts/sec at shaft)

**Packet Format (Cmd 35 example):**
```
Send: [0x80, 0x23, speed_b3, speed_b2, speed_b1, speed_b0, crc_hi, crc_lo]
Reply: [0xFF]  (ACK)
```

**Future firmware usage (Stage 6):**
```c
// NEW mapping:
int32_t us = clamp(s_last_steering_us, 1000, 2000);
int32_t speed_qpps = ((us - 1500) * MAX_SPEED_QPPS) / 500;

// NEW command:
Pololu_MCP233_DriveM1Speed(speed_qpps);  // speed in QPPS
```

---

### 1.3 PID Configuration Commands

**Set/Read Velocity PID Gains**

| Cmd | Name | Data Format | Description |
|-----|------|-------------|-------------|
| 28 | Set M1 Velocity PID | 4× uint32 (16 bytes) | Kp_fp, Ki_fp, Kd_fp, QPPS_max |
| 29 | Set M2 Velocity PID | 4× uint32 (16 bytes) | Kp_fp, Ki_fp, Kd_fp, QPPS_max |
| 55 | Read M1 Velocity PID | none | Returns: P_fp, I_fp, D_fp, QPPS_max (16 bytes + CRC) |
| 56 | Read M2 Velocity PID | none | Returns: P_fp, I_fp, D_fp, QPPS_max (16 bytes + CRC) |

**Gain Format:** Fixed-point, scaled by 65536  
- Kp = 1.5 → send `1.5 * 65536 = 98304`
- Ki = 0.1 → send `0.1 * 65536 = 6554`
- Kd = 0.05 → send `0.05 * 65536 = 3277`

**QPPS_max:** Encoder counts/sec at 100% motor power (from motor/encoder specs or measurement)

**Packet Format (Cmd 28 example):**
```
Send: [0x80, 0x1C, 
       Kp_b3, Kp_b2, Kp_b1, Kp_b0,
       Ki_b3, Ki_b2, Ki_b1, Ki_b0,
       Kd_b3, Kd_b2, Kd_b1, Kd_b0,
       QPPS_b3, QPPS_b2, QPPS_b1, QPPS_b0,
       crc_hi, crc_lo]
Reply: [0xFF]  (ACK)
```

**IMPORTANT:** These gains can also be set via **Motion Studio** (Basicmicro's GUI tool) and saved to MCP233's non-volatile memory (Cmd 94: Write Settings to EEPROM). When saved, gains persist across power cycles and **firmware does not need to send Cmd 28/29 at boot**.

---

### 1.4 Encoder Telemetry Commands

**Read Encoder Position & Speed**

| Cmd | Name | Reply Format | Description |
|-----|------|--------------|-------------|
| 78 | Read Encoder Counters | 2× int32 (8 bytes + CRC) | M1 & M2 cumulative position (counts) |
| 79 | Read Instantaneous Speeds | 2× int32 (8 bytes + CRC) | M1 & M2 speed (QPPS, averaged over last 1/300s) |
| 48 | Read Motor PWMs | 2× int16 (4 bytes + CRC) | M1 & M2 **duty** (works in both modes) |

**Cmd 78 Packet Format:**
```
Send: [0x80, 0x4E]  (no CRC on read requests)
Reply: [enc1_b3, enc1_b2, enc1_b1, enc1_b0,
        enc2_b3, enc2_b2, enc2_b1, enc2_b0,
        crc_hi, crc_lo]
```

**Cmd 79 Packet Format:**
```
Send: [0x80, 0x4F]
Reply: [spd1_b3, spd1_b2, spd1_b1, spd1_b0,
        spd2_b3, spd2_b2, spd2_b1, spd2_b0,
        crc_hi, crc_lo]
```

**Use cases:**
- Monitor actual vs commanded speed (PID tracking error)
- Detect stall (speed = 0 but command ≠ 0)
- Position feedback for UI/dashboard
- Fault detection (encoder disconnected, out-of-range)

---

## 2. Code Comparison: Open-Loop vs Closed-Loop

### 2.1 Current Code (Open-Loop, Stage 4)

**pololu_mcp233.h (lines 60-65):**
```c
#define POLOLU_MCP233_CMD_DRIVE_M1_DUTY     32u
#define POLOLU_MCP233_CMD_DRIVE_M2_DUTY     33u
#define POLOLU_MCP233_CMD_DRIVE_M1M2_DUTY   34u
#define POLOLU_MCP233_CMD_READ_MOTOR_PWMS   48u
```

**pololu_mcp233.c (lines 141-145):**
```c
HAL_StatusTypeDef Pololu_MCP233_DriveM1Duty(int16_t duty)
{
    uint8_t payload[2] = { 
        (uint8_t)((uint16_t)duty >> 8), 
        (uint8_t)((uint16_t)duty & 0xFFu) 
    };
    return pololu_send_write(POLOLU_MCP233_CMD_DRIVE_M1_DUTY, payload, sizeof(payload));
}
```

**Customer.c (lines 187-195):**
```c
if (stale) {
    duty = 0;
} else {
    int32_t us = (int32_t)s_last_steering_us;
    us = (us < 1000) ? 1000 : (us > 2000) ? 2000 : us;
    int32_t duty_scaled = ((us - 1500) * 32767) / 500;
    duty = (int16_t)duty_scaled;
}
(void)Pololu_MCP233_DriveM1Duty(duty);
```

**Behavior:** Motor applies commanded duty → actual movement depends on load/friction/voltage.

---

### 2.2 Future Code (Closed-Loop, Stage 6)

**pololu_mcp233.h — ADD new command defines:**
```c
// Closed-loop speed commands
#define POLOLU_MCP233_CMD_SET_M1_PID        28u
#define POLOLU_MCP233_CMD_SET_M2_PID        29u
#define POLOLU_MCP233_CMD_DRIVE_M1_SPEED    35u
#define POLOLU_MCP233_CMD_DRIVE_M2_SPEED    36u
#define POLOLU_MCP233_CMD_DRIVE_M1M2_SPEED  37u
#define POLOLU_MCP233_CMD_READ_ENCODERS     78u
#define POLOLU_MCP233_CMD_READ_SPEEDS       79u
```

**pololu_mcp233.c — ADD new command functions:**
```c
HAL_StatusTypeDef Pololu_MCP233_DriveM1Speed(int32_t speed_qpps)
{
    uint8_t payload[4] = { 
        (uint8_t)(speed_qpps >> 24),
        (uint8_t)(speed_qpps >> 16),
        (uint8_t)(speed_qpps >> 8), 
        (uint8_t)(speed_qpps & 0xFFu) 
    };
    return pololu_send_write(POLOLU_MCP233_CMD_DRIVE_M1_SPEED, payload, sizeof(payload));
}

// OPTIONAL: Only if configuring PID from firmware instead of Motion Studio
HAL_StatusTypeDef Pololu_MCP233_SetM1PID(uint32_t kp_fp, uint32_t ki_fp, 
                                          uint32_t kd_fp, uint32_t qpps_max)
{
    uint8_t payload[16];
    payload[0]  = (uint8_t)(kp_fp >> 24);
    payload[1]  = (uint8_t)(kp_fp >> 16);
    payload[2]  = (uint8_t)(kp_fp >> 8);
    payload[3]  = (uint8_t)(kp_fp & 0xFFu);
    payload[4]  = (uint8_t)(ki_fp >> 24);
    payload[5]  = (uint8_t)(ki_fp >> 16);
    payload[6]  = (uint8_t)(ki_fp >> 8);
    payload[7]  = (uint8_t)(ki_fp & 0xFFu);
    payload[8]  = (uint8_t)(kd_fp >> 24);
    payload[9]  = (uint8_t)(kd_fp >> 16);
    payload[10] = (uint8_t)(kd_fp >> 8);
    payload[11] = (uint8_t)(kd_fp & 0xFFu);
    payload[12] = (uint8_t)(qpps_max >> 24);
    payload[13] = (uint8_t)(qpps_max >> 16);
    payload[14] = (uint8_t)(qpps_max >> 8);
    payload[15] = (uint8_t)(qpps_max & 0xFFu);
    return pololu_send_write(POLOLU_MCP233_CMD_SET_M1_PID, payload, sizeof(payload));
}

// OPTIONAL: Read encoder position for monitoring
bool Pololu_MCP233_ReadEncoders(int32_t *m1_enc, int32_t *m2_enc, uint32_t timeout_ms)
{
    uint8_t reply[10];  // 2× int32 + CRC(2)
    
    if (pololu_send_read(POLOLU_MCP233_CMD_READ_ENCODERS, reply, sizeof(reply), timeout_ms)) {
        // Verify reply CRC (same pattern as ReadMotorPWMs, line 249-255)
        uint8_t expect_packet[10];
        expect_packet[0] = POLOLU_MCP233_ADDRESS;
        expect_packet[1] = POLOLU_MCP233_CMD_READ_ENCODERS;
        memcpy(&expect_packet[2], reply, 8);
        uint16_t expect_crc = Pololu_MCP233_CRC16(expect_packet, 10);
        uint16_t got_crc = ((uint16_t)reply[8] << 8) | reply[9];
        
        if (expect_crc == got_crc) {
            if (m1_enc) {
                *m1_enc = (int32_t)((reply[0] << 24) | (reply[1] << 16) | 
                                    (reply[2] << 8) | reply[3]);
            }
            if (m2_enc) {
                *m2_enc = (int32_t)((reply[4] << 24) | (reply[5] << 16) | 
                                    (reply[6] << 8) | reply[7]);
            }
            return true;
        }
    }
    return false;
}
```

**pololu_mcp233.c — OPTIONAL: PID init (only if NOT using Motion Studio):**
```c
bool Pololu_MCP233_Init(void)
{
    // ... existing UART init (lines 46-85) ...
    
    // NEW: Set PID gains if not already configured via Motion Studio
    // Example gains (MUST be tuned on real hardware):
    //   Kp = 1.5 → 98304
    //   Ki = 0.1 → 6554
    //   Kd = 0.05 → 3277
    //   QPPS_max = 4000 (encoder counts/sec at full power - from motor spec or measurement)
    #ifdef POLOLU_PID_FROM_FIRMWARE
    if (Pololu_MCP233_SetM1PID(98304, 6554, 3277, 4000) != HAL_OK) {
        return false;
    }
    #endif
    
    s_boot.init_ok = true;
    return true;
}
```

**Customer.c — CHANGE main loop (only 3 lines!):**
```c
// Define max speed based on motor/encoder specs
// Example: 500 RPM × (encoder counts per revolution) / 60
//   If encoder = 2048 CPR (counts per rev) → 500 RPM = 17067 QPPS
#define POLOLU_MAX_SPEED_QPPS  17000

if (stale) {
    speed_qpps = 0;  // Stop
} else {
    int32_t us = (int32_t)s_last_steering_us;
    us = (us < 1000) ? 1000 : (us > 2000) ? 2000 : us;
    
    // NEW: Map to speed instead of duty
    int32_t speed_scaled = ((us - 1500) * POLOLU_MAX_SPEED_QPPS) / 500;
    speed_qpps = speed_scaled;
}

// CHANGE: Call speed command instead of duty command
(void)Pololu_MCP233_DriveM1Speed(speed_qpps);  // ← ONLY LINE CHANGED

// OPTIONAL: Read encoder position for monitoring/dashboard
#ifdef POLOLU_READ_ENCODER_FEEDBACK
static uint32_t s_last_enc_read_ms = 0;
if ((now_ms - s_last_enc_read_ms) >= 100u) {  // 10 Hz
    int32_t enc_position, enc_speed;
    if (Pololu_MCP233_ReadEncoders(&enc_position, NULL, 50u)) {
        // Could send to dashboard, log, check for faults, etc.
        s_last_enc_read_ms = now_ms;
    }
}
#endif

// Drain ACK bytes (same as before)
while (HAL_UART_Receive(&huart7, &ack_drain, 1u, 0u) == HAL_OK) {
}
```

**Behavior:** Motor PID maintains commanded speed → actual speed constant regardless of load.

---

## 3. Motion Studio vs Firmware PID Configuration

### 3.1 Method A: Motion Studio (RECOMMENDED)

**Workflow:**
1. Connect PC to MCP233 via USB or UART
2. Open Basicmicro Motion Studio
3. Configure:
   - **Velocity PID tab:** Set Kp, Ki, Kd gains
   - **Encoder tab:** Set encoder mode (quadrature), counts per rev, polarity
   - **Limits tab:** Set max current, voltage cutoffs
   - **Test/Tune:** Use Motion Studio's live graphing + autotune
4. **Save to EEPROM:** Settings → Write to Device (Cmd 94 internally)
5. **Done:** MCP233 remembers these settings forever (survives power cycles)

**Firmware changes:**
- None in init (no Cmd 28/29 needed)
- Only change command in main loop: `DriveM1Duty()` → `DriveM1Speed()`
- PID gains already in MCP233's non-volatile memory

**Advantages:**
- ✅ GUI-based tuning (live graphs, easier than recompiling firmware)
- ✅ Autotune feature (MCP233 measures motor response, calculates gains)
- ✅ Settings persist across power cycles
- ✅ No PID code in firmware (simpler, smaller binary)
- ✅ Faster iteration (tweak gains without reflashing STM32)

---

### 3.2 Method B: Firmware PID Configuration (OPTIONAL)

**Workflow:**
1. Add `Pololu_MCP233_SetM1PID()` function (see §2.2)
2. Call from `Pololu_MCP233_Init()` at boot
3. Manually tune gains via trial-and-error or Ziegler-Nichols
4. Recompile + reflash to test new gains
5. Optionally save to EEPROM via Cmd 94 after finding good gains

**Firmware changes:**
- Add PID command function (§2.2)
- Call at init with hardcoded gains
- Gains sent to MCP233 every boot (or once + Cmd 94 to persist)

**Advantages:**
- ✅ No PC/Motion Studio needed in production
- ✅ Gains version-controlled in firmware source
- ✅ Can be changed programmatically (e.g. different gains for different modes)

**Disadvantages:**
- ❌ Slower tuning (recompile + reflash for every gain tweak)
- ❌ No autotune (manual calculation required)
- ❌ More code in firmware

---

### 3.3 Hybrid Method (BEST PRACTICE)

**Tuning phase:**
- Use **Motion Studio** to find good PID gains (autotune + live graphs)
- Test on bench, iterate quickly

**Production deployment:**
- **Option 1:** Save final gains to MCP233 EEPROM via Motion Studio → firmware needs no PID code
- **Option 2:** Hardcode final gains in firmware `Init()` → independent of EEPROM state

**Recommended: Option 1** (save to EEPROM, no firmware PID code) unless you need to change gains dynamically at runtime.

---

## 4. Summary: What Changes for Stage 6

### 4.1 Hardware Prerequisites
- ✅ Encoder wired to MCP233 EN1A/EN1B (quadrature A/B channels)
- ✅ Encoder counts per revolution known (from encoder datasheet)
- ✅ Motor max speed known (RPM or measured QPPS at 100% duty)

### 4.2 Motion Studio Configuration (one-time)
- ✅ Set encoder mode (quadrature, CPR, polarity)
- ✅ Tune PID gains (autotune or manual)
- ✅ Set velocity limits, accel limits
- ✅ Write settings to EEPROM (Cmd 94)

### 4.3 Firmware Changes (minimal if using Motion Studio)

**pololu_mcp233.h:**
```c
// ADD:
#define POLOLU_MCP233_CMD_DRIVE_M1_SPEED    35u
```

**pololu_mcp233.c:**
```c
// ADD:
HAL_StatusTypeDef Pololu_MCP233_DriveM1Speed(int32_t speed_qpps) {
    // ... (see §2.2)
}
```

**Customer.c:**
```c
// CHANGE (line 195):
- (void)Pololu_MCP233_DriveM1Duty(duty);
+ (void)Pololu_MCP233_DriveM1Speed(speed_qpps);

// CHANGE (lines 190-193):
- int32_t duty_scaled = ((us - 1500) * 32767) / 500;
- duty = (int16_t)duty_scaled;
+ int32_t speed_scaled = ((us - 1500) * POLOLU_MAX_SPEED_QPPS) / 500;
+ speed_qpps = speed_scaled;
```

**That's it!** (If PID gains in EEPROM)

---

## 5. Benefits of Closed-Loop (Why Bother?)

| Scenario | Open-Loop (Now) | Closed-Loop (Stage 6) |
|----------|-----------------|----------------------|
| **Light load** | Motor fast, overshoots | Accurate speed maintained |
| **Heavy load** | Motor slow, undershoots | Accurate speed maintained |
| **Motor stall** | Keeps applying power, no alert | Encoder=0 → fault detection |
| **Wave forces** | Rudder pushed off-target | PID compensates automatically |
| **Autopilot "steer 10°"** | Apply power, hope for 10° | Command 10°, encoder confirms |
| **Dashboard feedback** | Show commanded duty (%) | Show actual position/speed |
| **Human RC control** | Works fine (pilot corrects visually) | Works fine (less pilot correction) |
| **Long-term accuracy** | Drift over time | Stays on target |

**Bottom line:** Open-loop is fine for **RC mode** (human in the loop). Closed-loop is needed for **true autopilot** (position/heading hold without constant human correction).

---

## 6. References

- **MCP User Manual:** `NewBoard/Pololu-mcp233/mcp_user_manual.pdf` sections 2.2 (Packet Serial), 2.3 (Commands), 2.4.9 (PID)
- **MCP Datasheet:** `NewBoard/Pololu-mcp233/mcp23x_datasheet.pdf` (electrical specs, encoder inputs)
- **Command Reference:** `.cursor/Logs/mcp233_uart_command_reference.md` (summary of all commands)
- **Current Implementation:** `.cursor/Logs/Log14-Pololu-MCP233-UART7-steering-plan.md` (Stage 0-4, open-loop)
- **Motion Studio:** Free download from Basicmicro website (Windows only, or use Wine on Linux)

---

## 7. Next Steps (Not Scheduled Yet)

Stage 6 (closed-loop) is **explicitly parked** (same as CAN/NMEA2000 in Log10) — not forgotten, but deprioritized until:
1. Encoder hardware available and wired
2. User explicitly requests closed-loop implementation
3. Open-loop proves insufficient for the application (e.g. autopilot drift, load variation issues)

For now, **Stage 4 (open-loop RC/ROC steering) is the target** — sufficient for human-in-the-loop control.
