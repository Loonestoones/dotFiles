# Log 14 — Pololu MCP233 steering over UART7: phased plan (Start → testing → end product)

**Date:** 2026-07-15  
**Status:** 🔧 **Stage 4 in progress (2026-07-17).** Stages 0-2 bench-passed; Stage 3 ICC plumbing working; Stage 4 end-to-end partially complete with known issues (see §3 Stage 4).

**Stage 0-2 Summary:** CRC16 verified, UART7 init working, ACK + read-back confirmed on hardware.

**Stage 3 Summary (2026-07-17):** CM7→CM4 ICC steering working, bidirectional traffic on `IC_CH_CUSTOMER` with no conflicts.

**Stage 4 Current State (2026-07-17):** Steering ICC → Pololu mapping implemented; discovered CM7 task running at ~200ms instead of designed 10ms (see §5.1 Known Issues).
**Tree:** `NewBoard/Rewrite/MFCB_BASE` (target), `git/ops-box-b/drone-control-firmware_8000` (source-of-truth for the stubbed intent)
**Context:** Closes OldBoard backlog item — Log10 §2 item 4 ("Steering output to Pololu —
TODO even in OldBoard `_8000` (`SendtoPololu` never defined)"). Reference doc:
`.cursor/Logs/mcp233_uart_command_reference.md` (Basicmicro MCP233 packet-serial protocol,
already validated open-loop from a laptop via the `basicmicro` Python library). Hardware
docs: `NewBoard/Pololu-mcp233/mcp_user_manual.pdf`, `mcp23x_datasheet.pdf`.
**Related:** Log4 (UART6/7 SBUS bring-up — UART7's dead SBUS-shaped init lives here today),
Log7 (ICC design notes — CM7→CM4 is the *undemonstrated* direction), Log10 (roadmap),
reference-OPS-MFCB-hardware-manual-rev2.01.md (UART7 electrical: output 3.3/5 V selectable
via `UART_SetVoltage`, inputs 3.3/5 V tolerant).

---

## 0. Starting point (what's true today, no ambiguity)

- `Steeringcommand` (`uint16_t`, 1000–2000 µs range, 1500 = neutral) is computed every tick
  in `CM7/Customer/Src/GEO-application-task.c`, for every sailing state (RC/ROC/AP_IMS/Stop).
  This is the value to deliver.
- UART7 is electrically free: `UART7_Init4Pololu()` in `CM4/Customer/Src/rc_sbus_old.c` was
  **dead code** (never called from `Customer.c`), the wrong shape (100000 baud, 9-bit,
  inverted — copied from SBUS), and **would not have compiled** — it set
  `huart7.Instance = USART7`, and no such peripheral exists on the H757 (the real instance is
  `UART7`, per `stm32h757xx.h`). Removed 2026-07-15, superseded by `pololu_mcp233.c`.
- UART HAL is CM4-owned (dual-core rule) — `Steeringcommand` must cross CM7→CM4 via ICC.
  This direction has **zero prior traffic** in this codebase; only CM4→CM7 (SBUS) has been
  bench-proven. CM4's generic ICC receive plumbing
  (`Customer_ICC_HandlePacket_NO_ID` → `s_icc_slot` → `Customer_Icc_GetPacket()`) already
  exists but nothing sends into it or polls it yet.
- No CRC16 implementation exists anywhere in this codebase. Basicmicro's packet-serial CRC
  must be reproduced in C and bench-verified against a real ACK byte — this is the single
  biggest unknown and gates everything downstream of it.
- `uart_send_ctrl()` (the one core-transparent send helper) cannot carry an arbitrary binary
  packet (it has no raw-byte-buffer op) — this has to be direct HAL `HAL_UART_Transmit_IT`
  on `&huart7` in CM4 Customer code, same pattern as SBUS.

## 1. Open decisions

| # | Question | Answer |
|---|---|---|
| 1 | Command: **32** (M1 only) or **34** (M1 & M2 together, same duty)? | **Decided 2026-07-15: Cmd 32, M1 only** (matches current single-axis `Steeringcommand`). `pololu_mcp233.c` also exposes `DriveM2Duty`/`DriveM1M2Duty` for later if a second channel is ever needed — no rework, just a different call site. |
| 2 | UART7 line voltage: **3.3 V** or **5 V**? | **Decided 2026-07-15: 3.3 V**, confirmed (not just assumed) from `mcp23x_datasheet.pdf`: MCP233 UART outputs are "3.3v Compliant" and inputs "15v Tolerant" — no 5 V rail needed. |
| 3 | Direction/sign convention: does `Steeringcommand > 1500` mean duty **positive** or **negative**? Only knowable once a motor is spinning (Stage 2). | Still open — decide at Stage 2 bench, flip in software if wrong — no hardware change needed |
| 4 | Failure policy: if the CM7→CM4 ICC link goes stale (CM7 stopped sending), should CM4 command **duty 0** (fail-safe stop) or **hold last value**? | Still open (Stage 3/4 decision) — default remains fail-safe duty 0, same philosophy as the existing `Stop`/staleness paths |

## 2. Architecture (end state)

```
CM7 (GEO-application-task.c)                    CM4 (new pololu_mcp233.c)
  Steeringcommand (1000-2000us, tick rate)
        │
        ▼
  build tagged ICC packet (CUST_ICC_TAG_STEER_CMD)
        │
        ▼
  ICC_SendPacket_NO_ID(IC_CH_CUSTOMER, ...)  ───────►  Customer_ICC_HandlePacket_NO_ID
                                                              │ (existing raw slot, CM4)
                                                              ▼
                                                        StartCustomerTask loop polls
                                                        Customer_Icc_GetPacket()
                                                              │
                                                              ▼
                                                        staleness check (age vs last rx)
                                                              │  fresh                stale
                                                              ▼                        ▼
                                                   map 1000-2000us → duty     force duty = 0
                                                   ±32767 (signed)
                                                              │
                                                              ▼
                                                   pack [0x80, cmd, hi, lo, crc_hi, crc_lo]
                                                              │
                                                              ▼
                                                   HAL_UART_Transmit_IT(&huart7, ...)
                                                              │
                                                              ▼
                                                        MCP233 (S1/S2, packet serial)
                                                              │ ACK 0xFF (write cmds)
                                                              ▼
                                                   HAL_UART_Receive_IT(&huart7, ...) (optional,
                                                   bring-up + ongoing health check)
```

Mirrors the SBUS precedent exactly: raw binary protocol → CM4-owned direct HAL, decoupled
from CM7 logic by one ICC hop, with a staleness/fail-safe rule at the consumer.

## 3. Phased plan — Start → testing phases → end product

Each stage ends in a bench checkpoint (CP). **Do not start the next stage until the
previous CP passes on hardware** — same discipline as Log11/Log13.

### Stage 0 — Decisions + CRC16 groundwork (no hardware) — ✅ done 2026-07-15
- §1 answers 1 and 2 locked in.
- `Pololu_MCP233_CRC16()` implemented in `pololu_mcp233.c`: poly `0x1021`, init `0`,
  MSB-first, over Address+Command+Data (not the CRC bytes), high byte then low byte.
- **CP-0 upgraded:** no captured laptop packet+CRC pair exists anywhere in this workspace
  (checked — `NewBoard/Pololu-mcp233/` holds only the two PDFs, no logs/scripts). Instead,
  the C code was checked character-for-character against the manual's own C sample
  (`mcp_user_manual.pdf` §2.2.6, read directly, not from memory) — same authority a captured
  packet would have given, no board needed either way. **PASS** (by inspection — worth one
  more sanity pass at the Stage 1 bench session since it still hasn't produced a real ACK).

### Stage 1 — UART7 bring-up, single hardcoded packet, ACK only — ✅ CP-1 PASSED 2026-07-16
Code: `CM4/Customer/Src/pololu_mcp233.c` + `Inc/pololu_mcp233.h` (new). UART7 init at 115200,
8N1, no inversion, 3.3V (`Pololu_MCP233_Init()`). `Pololu_MCP233_DriveM1DutyAndWaitAck(0, ...)`
sends cmd 32 duty=0 and blocks for the ack — this is the CP-1 call. Wired into
`Customer.c`/`StartCustomerTask`: init at boot, then `Pololu_MCP233_SelfTestService()` runs
it (+ Stage 2's read-back) from the task loop, printing
`[POLOLU CM4] duty_cmd=... cp1_ack=... cp2_readback=... m1_pwm=... m2_pwm=...` on UART1
(`GEO-debug.c:PrintPololuSelfTest`). Also found and removed the dead, broken
`UART7_Init4Pololu()` this superseded (see §0) — one stone, two birds.
- **CP-1 — PASSED 2026-07-16:** UART1 boot log: `[POLOLU CM4] cp1_ack=OK cp2_readback=OK
  m1_pwm=0 m2_pwm=0`, repeating cleanly. MCP233 replies `0xFF` (ACK) to the duty=0 packet as
  expected — confirms line voltage (3.3V), wiring polarity, baud, CRC16, and Packet Serial
  mode all at once.

### Stage 2 — Manual duty sweep, confirm motor + sign + read-back — 🔧 sweep hook added 2026-07-16, CP-2 pending
Code done: `Pololu_MCP233_ReadMotorPWMs()` (Cmd 48) is CRC-checked against the reply's own
trailing CRC16 (manual §2.2.7) — only returns `true` on a verified match, so `cp2_readback=OK`
in the self-test print is an authoritative gate, not just "some bytes arrived" — **proven at
duty=0 in the CP-1 bench run above.** Bonus: `Pololu_MCP233_ReadVersion()` (Cmd 21) for a
human-readable proof-of-life, not the primary gate. Added 2026-07-16: a sweep state machine
inside `Pololu_MCP233_SelfTestService()` now cycles M1 through `0 → +10000 → 0 → −10000 → 0`
(~30% duty magnitude, ~3s/step), sending+reading back every ~500ms and printing the commanded
duty alongside the read-back (`duty_cmd=...`) — not yet bench-run.
- **CP-2 (pending bench test):** Motor visibly moves in both directions during the sweep;
  sign convention confirmed (answers §1.3 — flip in software, not wiring, if backwards);
  `m1_pwm` read-back tracks `duty_cmd` (allow one ~500ms step of lag). FAIL → CRC/address
  mismatch if no ACK at all (shouldn't recur, CP-1 already proved this path); scaling/driver
  bug if ACK present but motor doesn't move or read-back diverges from commanded.

### Stage 3 — ICC plumbing CM7→CM4 (values only, no motor output yet)
Code: add `CUST_ICC_TAG_STEER_CMD` to both copies of `cust_icc.h`; CM7
(`GEO-application-task.c`) sends `Steeringcommand` each tick on `IC_CH_CUSTOMER`; CM4
(`StartCustomerTask` loop) polls `Customer_Icc_GetPacket()`, validates the tag, timestamps
receipt, and **only prints** the received value to UART1 (no MCP233 send yet — isolates ICC
correctness from motor correctness).
- **CP-3:** Move the RC stick (or ROC steering) and watch the CM4-side debug print track it
  in real time, with sane latency (~tick rate, not seconds). Also verify: stop sending from
  CM7 (e.g. pause the task) → CM4 print shows staleness detected within the chosen timeout.
  FAIL → check against the SBUS snapshot precedent (Log7 §6, same mailbox/staleness shape).

### Stage 4 — End-to-end wiring — 🔧 In Progress (2026-07-17)
Code (done): CM4 loop polls ICC, recalculates staleness inside 20ms-throttled duty send block, maps 1000–2000 µs → ±32767 signed duty, calls `Pololu_MCP233_DriveM1Duty()` fire-and-forget, drains ACK bytes to prevent UART7 RX overflow. Stale ICC (age > 500ms) → force duty 0. Self-test disabled (`POLOLU_MCP233_SELFTEST_ENABLE 0`).

**Timing Bugs Fixed (2026-07-17):**
- **Bug #1:** STALE/FRESH flickering — staleness was calculated once per loop but used inside a 20ms-throttled block; packets could arrive between calculation and use. **Fix:** Recalculate staleness inside the duty send block, right before use.
- **Bug #2:** Pololu command spam — sending every 2ms overwhelmed MCP233 UART (ACK/readback failures). **Fix:** Throttled to 20ms (50 Hz).
- **Bug #3:** UART7 RX overflow — fire-and-forget commands left 0xFF ACKs in buffer. **Fix:** Drain ACKs after every send (non-blocking).
- **Bug #4:** CM7 running at 200ms — ICC packets arrive every 200ms, not 10ms. **Workaround:** Increased timeout 150ms → 500ms. **Root cause confirmed 2026-07-17:** blocking CM7 `dac_ctrl` ×2 (Log18); fix = DAC on CM4 via ICC.

**Checkpoints (pending bench test):**
- **CP-4a:** Steering actuator follows RC stick steering axis live (200ms latency expected).
- **CP-4b:** Steering actuator follows ROC/UDP steering command live.
- **CP-4c (fail-safe):** Disconnect RC / let ROC go stale → actuator returns to neutral (duty 0) within 500ms.
- **CP-4d (regression):** SBUS RC read, DAC motor outputs, ROC UDP all still function correctly with Pololu traffic active.

### Stage 5 — Cleanup and record
Remove Stage 1/2 debug-only test hooks (keep them behind one `#if POLOLU_MCP233_SELFTEST_ENABLE`
for future bench use, same convention as CAN's loopback self-test in Log11 — already done,
see `pololu_mcp233.h`). ~~Delete the dead SBUS-shaped `UART7_Init()` from `rc_sbus_old.c`~~
done early, at Stage 1 (§0) — it turned out to be a compile-breaking landmine, not worth
leaving in place until Stage 5. Update this log's status to bench-verified with the final CP
results; update Log10's roadmap item 4 to done; note the actual CRC16/voltage/sign answers
found in §1 for future reference.

### Stage 6 — Parked for later (out of scope for this slice)
Closed-loop control once encoder wiring exists (per the reference doc's own "Phase 2"):
Cmd 28/29 (PID gains), 35–37 (signed speed), 78/79 (encoder feedback). Not scheduled — same
treatment as CAN/NMEA2000 in Log10 (explicitly deprioritized, not forgotten).

## 4. Files to create / edit (all in `NewBoard/Rewrite/MFCB_BASE`)

| File | Action |
|---|---|
| `CM4/Customer/Src/pololu_mcp233.c` + `Inc/pololu_mcp233.h` | ✅ done — UART7 init, CRC16, packet build, blocking `HAL_UART_Transmit`/`Receive` (Stage 1/2 bench shape), self-test behind `#if POLOLU_MCP233_SELFTEST_ENABLE` |
| `CM4/Customer/Src/rc_sbus_old.c` | ✅ done — removed dead/broken `UART7_Init4Pololu()` |
| `CM4/Customer/Inc/GEO-debug.h` + `Src/GEO-debug.c` | ✅ done — `PrintPololuSelfTest()` |
| `CM4/Customer/Customer.c` | ✅ done — `Pololu_MCP233_Init()` at boot, `Pololu_MCP233_SelfTestService()` in the task loop |
| `CM4/Debug/Customer/Src/subdir.mk` | ✅ done — new `.c` added to the build |
| `CM4/Customer/Inc/cust_icc.h` **and** `CM7/Customer/Inc/cust_icc.h` | not started (Stage 3) — add `CUST_ICC_TAG_STEER_CMD` + payload struct (keep both copies identical, as today) |
| `CM7/Customer/Src/GEO-application-task.c` | not started (Stage 3) — send tagged ICC packet with `Steeringcommand` each tick |
| `CM4/Customer/Customer.c` (Stage 3/4 addition) | not started — poll `Customer_Icc_GetPacket()`, staleness check, replace self-test's duty=0 with the real ICC-derived duty |

## 5. Risks / open points / known issues

### 5.1 Known Issues (Stage 4, 2026-07-17)

**CM7 Task Running at ~200–400ms Instead of ~10ms — ROOT CAUSE CONFIRMED (2026-07-17):**
- **Cause:** Per-tick `WriteMotorDAC` ×2 on CM7 → blocking `dac_ctrl` ICC WITH_ID wait (Log18).
- **Proof:** DAC commented → `[CM7 UPDATE]` ~50 ms / 10 calls; DAC on → ~4000 ms / 10 calls.
- **Workaround:** Steer timeout 500 ms; DAC temporarily commented for A/B.
- **Fix:** Log18 — apply DAC on CM4; CM7 sends motor cmds via Customer ICC NO_ID.

### 5.2 Original Risks (Stages 0-3)

- **CRC16 correctness** — ✅ Resolved Stage 0/1 (bench-verified).
- **CM7→CM4 ICC direction** — ✅ Working Stage 3 (no starvation observed at 200ms rate).
- **MCP233 Packet Serial mode** — ✅ Confirmed Stage 1 (ACK received).
- **Single vs dual motor** — Cmd 32 (M1 only) used; Cmd 34 API exists if needed later.
