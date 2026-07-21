# Log 10 — Remaining conversion roadmap: what's done, what's left, CAN slice findings

**Date:** 2026-07-14
**Status:** 📋 Planning log — analysis only, no code changed. Basis for the post-ROC slices.
**Tree:** `NewBoard/Rewrite/MFCB_BASE` (port target), `git/ops-box-b/drone-control-firmware_8000` (source-of-truth)
**Context:** Phase 3 of the OldBoard(_8000) → NewBoard port. ROC UDP + dashboard feedback
slice bench-completed 2026-07-13 (Log9 + memory). This log records the full remaining
backlog and the findings from sizing the next big slice (CAN / NMEA2000 / Yanmar).
**Decision 2026-07-14 (supersedes the old dual-target rule):** the NEWER libops build will
probably never be delivered. All remaining slices target the CURRENT `libops.a` only —
raw STM32 HAL is acceptable wherever the current library has no API. `Newer_build_includes/`
headers are pattern reference only, never a compatibility target.
**Related:** Log6-OPS-function-inventory.md, Log8-DAC-CM7-bench-verified.md,
Log9-ROC-UDP-network_send-RX-task-deadlock.md

---

## 1. Status snapshot — done and bench-verified

All on the `Rewrite/MFCB_BASE` build, all confirmed on hardware:

| Slice | Where | Log |
|---|---|---|
| SBUS RC input (UART6, frame re-align/recovery) | `CM4/Customer/Src/rc_sbus_old.c` | Log1–5 |
| CM4↔CM7 ICC mailbox | `CM7/Customer/Src/cust_icc_mailbox.c` | Log7 |
| DAC motor outputs for ZF (both channels vs `prepareDACValue`) | `CM7/Customer/Src/tools.c` | Log8 |
| ROC UDP control (handshake/grant, 3s staleness→Stop, re-grant) | `CM7/Customer/Src/roc_udp.c` | Log9 |
| Dashboard UDP feedback (end-of-tick; key/value swap bug fixed vs OldBoard) | `roc_udp.c` / app task | Log9 era |
| Sailing state machine core (RC / ROC / Stop) | `CM7/Customer/Src/GEO-application-task.c` | — |
| SBUS pass-through to autopilot (UART6 TX mirror) | `CM4/Customer/Src/rc_sbus_old.c` | Log13 |
| AP_IMS mode (PWM IN1/IN2 throttle/steer capture, Rising edge) | `CM7/Customer/Src/tools.c` | Log13 |

Assessment: by feature count roughly halfway; by **risk** well past it. The platform
unknowns (ICC, libops network quirks, UART ownership, DAC semantics) are all solved and
documented. Remaining work is mostly "port feature X onto proven infrastructure" — the one
genuinely new peripheral domain left is CAN.

## 2. Remaining backlog (ordered by size/importance)

**Update 2026-07-15:** items below have moved since this section was first written same-day
2026-07-14. (1) SBUS pass-through and (2) AP_IMS PWM input turned out to already be coded
(likely added later the same session, undocumented until now — see file timestamps), and
both are now **bench-verified on hardware** (see Log13 — fixed a `fetch_uart_fast` bug that
froze `PWMVALUE1/2`, and selected Rising-edge PWM IN capture after comparing all three modes
on the real AP signal). (3) CAN/NMEA2000/Yanmar is explicitly **deprioritized to the bottom**
per user decision 2026-07-15 (see `memory/project_can_nmea2000_deprioritized.md`) — Stage 1
(CM4 FDCAN loopback, Log11/Log12) stays bench-passed, but Stage 2+ is parked, not "next."

1. **SBUS pass-through to autopilot — ✅ DONE, bench-verified.** Resolved the
   `_8000` ambiguity by adopting the `GEO-tools.c` UART6 TX-passthrough variant (not
   UART7): `rc_sbus_old.c`'s `ProcessRC()` now does `HAL_UART_Transmit_IT(&huart6,
   sbusFrameOUT, SBUS_FRAME_SIZE)` for every frame that passes the start/end-byte check.
   UART7 is free (not repurposed for Pololu on this build yet either).
2. **AP_IMS mode — ✅ DONE, bench-verified (Log13, 2026-07-15).** `ProcessAP_IMS()` in
   `CM7/Customer/Src/tools.c` reads PWM IN1 (throttle) / IN2 (steering) via the **native
   OPS `pwm_in_ctrl(PWM_IN_OP_FETCH)`** API — not a hand-rolled TIM input-capture port like
   OldBoard's Dekimo `PWM_input.c`. Fixed a `fetch_uart_fast` bug that froze
   `PWMVALUE1/2` at defaults, and added `PWM_IN_ForceRisingEdge()` (RAM-only, re-applied
   every CM7 boot) after bench-comparing all three capture-edge modes on the real AP signal
   — factory "Both edges" was intermittently flaky on IN2, "Falling" was stable but measured
   the wrong half-cycle, "Rising" is stable and correct. See Log13 for full detail.
3. **Heartbeat master/slave redundancy** — `SendHeartbeat()` / `checkHeartbeat()` +
   `systemActive` takeover logic (`ModuleRole == master`).
4. **Steering output to Pololu** — TODO even in OldBoard `_8000` (`SendtoPololu` never
   defined). On the roadmap: `NewBoard/Pololu-mcp233/` docs exist.
5. **Other engine types** — VP (Volvo Penta CAN; commented out even in `_8000`) and BR
   (PWM out via `SetPWMoutDuty`). Structural seams already exist in the port's
   `DroneEngineType` switch. Low priority.
6. **Probably skippable** — Modbus TCP (`ProcessModbusTCP` commented out in the `_8000`
   main loop), `AP_DOcn` (empty stub in source), USB-CDC debug (`Send2USB` /
   `debugserial` — replaced by NewBoard debug mechanism).
7. **CAN / NMEA2000 + Yanmar engine feedback — lowest priority (parked 2026-07-15).**
   `CAN_Init`, `initYanmar()`, `YanmarFB_Process()`, `nmea2000.c`, `Yanmar.c`. Stage 1 (CM4
   FDCAN loopback) bench-passed 2026-07-14 (Log11/Log12); Stage 2 (ICC to CM7) onward not
   started and not scheduled. Detailed sizing still in §3 below for whenever it's picked
   back up.

## 3. CAN / NMEA2000 / Yanmar slice — sizing findings (2026-07-14)

> **⚠️ Superseded by Log11-CAN-implementation-plan.md (same day, later session).** Two
> corrections there: (1) FDCAN **is** placeholder-initialized at CM4 boot
> (`ops_init_platform_cm4` → `MX_FDCAN1/2_Init`, never Started); (2) the `.ioc` assigns
> FDCAN to **CM4**, not CM7 as §3.2 below says. Design changed accordingly: CAN owned by
> CM4 Customer code, frames to CM7 over ICC (SBUS pattern). §3.1 (protocol layer
> portability) still stands.

### 3.1 The protocol layer is nearly copy-paste

- **`nmea2000.c` (~550 lines) has zero CAN-driver coupling.** Only external dependency is
  `HAL_GetTick()`. Interface in: `NMEA2000_ProcessFrame(can_id, data, len)`. Output:
  `VPEngine[2]` / `VPFaultLog` globals. Fast-packet reassembly and all PGN/J1939 parsers
  are pure C. Ports unchanged.
- **`Yanmar.c` is 43 lines and mostly evaporates:**
  - `initYanmar()` = `DAC_Init()` (already covered by working `dac_ctrl` setup, Log8) +
    a Pololu TODO. Effectively already ported.
  - `YanmarFB_Process()` = one `CAN_Receive()` poll → PGN extraction from 29-bit ID →
    `NMEA2000_ProcessFrame()`. Only the `CAN_Receive` line needs replacing.

### 3.2 CURRENT libops.a has NO FDCAN driver → we write our own on HAL

Verified against the linked library (`nm` on `CM7/OPS_Lib/libops.a`) and Log6 inventory:
the current build exports only `fdcan_config_*` (EEPROM pack/unpack) and the web settings
page (`Page_fdcan.h`). No init, no send/receive, no task.

**Per the 2026-07-14 decision, this gap is ours to fill permanently** with the STM32 HAL
FDCAN driver (source is in the project; `.ioc` has FDCAN1/2 **active on CM7** — same core
as the app task, no ICC needed). No adapter/swap layering required.

The NEWER build's FDCAN headers (`Newer_build_includes/include/peripherals/FDCAN/`) remain
useful as a **design pattern to imitate** — `FDCAN_Rx_Subscribe`-style per-frame callback
feeding RX ring buffers, `fdcan_pick_nominal_timing(target_bps)` for bit timing — but are
not a compatibility target.

### 3.3 Design decisions for our FDCAN module

Write a `can_input`-style Customer module directly on HAL FDCAN. Two notes:

1. **Drain a ring, don't poll one frame:** OldBoard pulls one `CAN_Receive` per tick — a
   latent weakness that can drop frames at NMEA2000 bus loads. Use IRQ → RX ring, and
   drain the whole ring into `NMEA2000_ProcessFrame` each app tick.
2. **Log9 lesson applies:** the IRQ/callback context does "copy into ring" ONLY.
   `NMEA2000_ProcessFrame` and anything downstream runs in the app-task tick.

### 3.4 Bitrate

`.ioc` defaults FDCAN to ~1.11 Mbps. **NMEA2000 is 250 kbit/s.** OldBoard sets this via
`CAN_SetBitrate(g_phcan1, TQcanbitrate)`. Must be configured during bring-up in our own
HAL init; the NEWER headers' `fdcan_pick_nominal_timing(target_bps)` shows the bit-timing
math to crib from.

### 3.5 Honest sizing

CAN bring-up (HAL FDCAN init, filters, IRQ/poll, bench-verify real frames from the Yanmar
bus) is the real work. After frames flow, the Yanmar/NMEA2000 conversion is ~an hour of
mechanical porting plus bench time.

## 4. Suggested slice order

1. **SBUS-out to AP** (small, closes the RC loop to the AP — but resolve the UART7
   SBUS-vs-Pololu ambiguity with the user first), *or* start **CAN bring-up** directly
   since it gates Yanmar feedback and any future VP support.
2. CAN bring-up → Yanmar/NMEA2000 port (§3).
3. AP_IMS (PWM input capture).
4. Heartbeat redundancy.
5. Pololu steering (hardware/API groundwork may come free from the UART7 decision in 1).
6. VP / BR engine types only if/when hardware demands.
