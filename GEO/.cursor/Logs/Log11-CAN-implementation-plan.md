# Log 11 — CAN slice plan: OldBoard(_8000) CAN/NMEA2000/Yanmar → NewBoard, CM4-owned + ICC

**Date:** 2026-07-14
**Status:** 📋 Plan approved by user — implementation not started. Each stage ends in a bench
checkpoint; do not start the next stage until the previous checkpoint PASSes on hardware.
**Tree:** `NewBoard/Rewrite/MFCB_BASE` (target), `git/ops-box-b/drone-control-firmware_8000` (source)
**Context:** Next slice after ROC UDP (Log9/Log10). Ports OldBoard's CAN receive path:
`CAN_Init`/`CAN_SetBitrate` (Dekimo `can.c`) + `YanmarFB_Process()` (`Yanmar.c`) +
`NMEA2000_ProcessFrame()` (`nmea2000.c`) → `VPEngine[]`/`VPFaultLog`.
**Related:** Log10 (roadmap, §3 superseded by this log), Log7 (ICC), Log9 (RX-context rule),
Log6 (OPS inventory), reference-OPS-MFCB-hardware-manual-rev2.01.md,
**Log12 (Stage-1 retrospective: full struggle timeline + OldBoard comparison + bring-up checklist)**

---

## 0. Decisions and corrections locked in (2026-07-14 session)

1. **Current `libops.a` only.** OPS confirmed by mail their CAN software is not ready and
   (per the standing decision) will likely never arrive. **No `Newer_build_includes/`
   header may be included** — that tree is design inspiration only.
2. **Correction to Log10 §3.2: FDCAN IS initialized in the current firmware — on CM4.**
   `nm` on `CM4/OPS_Lib/libops.a`: `ops_init_platform_cm4.o` has undefined refs to
   `MX_FDCAN1_Init`/`MX_FDCAN2_Init`, and `CM4/Core/Src/main.c:195` calls
   `ops_init_platform()` at boot. What that leaves: clocks on, PH13/PH14 muxed AF9 (CM4
   `HAL_FDCAN_MspInit`), `HAL_FDCAN_Init` run with **CubeMX placeholder values** (junk
   timing: prescaler 16 / Seg1 1 / Seg2 1; **zero** RxFifo0/TxFifoQueue elements), never
   `HAL_FDCAN_Start`ed, never touched again (web `fdcan_config` save is EEPROM-only, like
   UART). So: placeholder-initted, stopped, unused — but CM4 boot code *does* touch it.
3. **Also corrected:** the `.ioc` `:I` suffix marks the *initializing* context —
   `FDCAN1:I, FDCAN2:I` is in the **CM4** list (earlier Log10 text said "active on CM7";
   wrong). Matches `how_to_use_core_assignment.txt` line "FDCAN1,2 → CM4".
4. **Therefore: CAN is owned by CM4 Customer code, frames forwarded to CM7 over ICC**
   (user preference — CM4 is under-utilized — plus ownership correctness: our CM4 code
   runs downstream of `ops_init_platform()` in the same boot flow and may re-init
   `hfdcan1` safely; re-initting from CM7 would be a cross-core stomp on a peripheral
   CM4's libops boot touches — the UART_Init lesson). High-level logic (NMEA2000 decode,
   Yanmar, app state machine) stays on CM7.
5. Bench hardware: user has a PC USB-CAN adapter → stage-4 real-bus tests from the PC.
   (Adapter model TBD — determines python-can backend.)

## 1. Architecture and OldBoard alignment

```
            CM4 (transport)                    │              CM7 (logic)
                                               │
 FDCAN1 ──IRQ──► rx ring ──customer task──► ICC WITH_ID ──► handler ──► CM7 ring
 (PH13/14,        (copy-only,   {id,len,data[8]} ≈13B      │
  J16 CAN1 P/N)    Log9 rule)                              ▼
                                               CAN_Receive() facade (Dekimo signature)
                                               ▼
                                     YanmarFB_Process()  [Yanmar.c, ~verbatim _8000]
                                               ▼
                                     NMEA2000_ProcessFrame()  [nmea2000.c, verbatim]
                                               ▼
                                     VPEngine[] / VPFaultLog globals
```

| OldBoard `_8000` | NewBoard | Alignment |
|---|---|---|
| `Dekimo_HAL/can/can.c` | CM4 `Customer/Src/can_input.c` + CM7 facade in `Customer/Src/can.c` | Same public API on CM7, new internals split across cores |
| `Yanmar.c` | CM7 `Customer/Src/Yanmar.c` | Verbatim minus `DAC_Init` (covered by dac_ctrl) ; `if`→`while` drain |
| `nmea2000.c/.h` | CM7 `Customer/Src/nmea2000.c` + `Inc/nmea2000.h` | Verbatim |
| `CAN_Init` + `CAN_SetBitrate(g_phcan1,250)` call sites | same two calls in `GEO_ApplicationTask_Init` (facade → ICC command to CM4, or CM4 auto-inits; decide in Stage 2) | Identical call sites |
| `YanmarFB_Process()` in app tick | same call in `GEO_ApplicationTask_Update` ZF branch | Identical call site |

**Documented deviations vs `_8000`** (each gets a `/* deviation vs _8000 */` comment):
- RX is IRQ→ring→ICC→ring, not a bare FIFO poll (fixes _8000's one-frame-per-tick loss risk
  and its dead/dangerous debug `RxFifo0Callback` — do NOT port that callback).
- Proper extended-ID filter (_8000 used a std-ID filter + accept-all global backdoor).
- `CAN_Send` supports extended IDs (_8000 hardcodes `FDCAN_STANDARD_ID`).
- Bit timing computed for MFCB clocks (§2), not _8000's prescaler table (H743-specific).
- `YanmarFB_Process` drains with `while`, not `if`.

## 2. Bit timing — rev.3 after two CP-1a bench iterations (2026-07-14)

**Bench history — CP-1a did its job twice:**
- rev.1 predicted PLL2 = 156.25 MHz (from CM7 `PeriphCommonClock_Config` math
  with HSE 25 MHz) → **measured 400 MHz**. Loopback frames still passed
  (loopback is bitrate-independent), so only the print caught it.
- rev.2 pinned the mux to HSE 25 MHz → **measured kernel_clk = 0, no frames**:
  the HAL reports 0 for a non-ready oscillator — **this board has no running
  HSE crystal**. The PLLs run from **HSI 64 MHz**, which explains rev.1
  exactly: PLL2Q = 64/4 ×50 /2 = **400 MHz**. (`HSE_VALUE=25M` in hal_conf is
  boilerplate, not hardware truth.)

**rev.3 (implemented): trust no clock assumption.** `CAN_Input_Init` selects
HSE only if `HSERDY` is actually set, else PLL2 (proven alive — it feeds the
ADC), reads the resulting frequency back, and **derives the timing at runtime**
(`can_pick_timing`): smallest prescaler giving an exact integer division to
250 kbit/s with 40–200 tq/bit, Seg2 ≈ 13% (sample point ≈ 87%), SJW = Seg2.
On this board: 400 MHz → **prescaler 8, 200 tq, Seg1 173 / Seg2 26, SP 87.0%**,
zero bitrate error. Init fails loudly (no silent wrong bitrate) if no exact
divide exists. CP-1a expected print:
`kernel_clk=400000000 src=P presc=8 tq=200 (bitrate=250000)`.

**rev.5 (user-approved, implemented):** rev.4 bench showed PLL1Q = **800 MHz**
(worse) and corruption persisting (~1/60 frames word-swapped, __DMB() made no
difference — as predicted, it's not a ring race: identical test frames cannot
word-swap by racing). No in-spec mux source exists → `can_lower_pll2q()` in
`can_input.c` drops PLL2's **Q divider only** (direct RCC register write, all
other PLL2 settings and the ADC's PLL2P output untouched): VCO 800 MHz /16 =
**50 MHz kernel**, ≤ APB1 with margin, exact 250k (presc 1, tq 200, SP 87%).
Cost: PLL2 offline sub-ms once at customer-task start (brief ADC kernel gap,
user-accepted). Watch ADC/web behavior after flash. Expected CP-1a:
`kernel_clk=50000000 (pll1q=800000000 pll2q=400000000) src=2 presc=1 tq=200 (bitrate=250000)`.

**rev.4 — the 400 MHz open point CONFIRMED as a real fault (bench, same day):**
with kernel = PLL2Q 400 MHz vs APB1 = 100 MHz, ~20% of loopback frames arrived
corrupted at **32-bit-word granularity** (patterns word1|word1 and word1|word0
instead of word0|word1) — the message-RAM clock-domain hazard: the FDCAN
kernel clock must not exceed the APB bus clock. Counters/IDs fine, data words
mis-read. Fix: init now reads PLL1Q and PLL2Q at runtime and picks HSE (if
running) → else the lowest PLLQ that divides exactly to 250k — expecting
PLL1Q < 400 MHz on this board (value unknown until next flash; boot print now
reports both candidates). If PLL1Q is also ≥400 MHz, remaining options:
reconfigure PLL2 DIVQ2 (needs PLL2 stop — glitches libops ADC, ask user) or
OPS question re: HSE crystal. Ring got __DMB() barriers same round
(belt-and-braces; corruption signature was clock-domain, not ring race).
RxFifo0: 32 elements × 8 bytes; TxFifoQueue: 8 elements. Classic frames only.

## 3. Implementation stages with bench checkpoints

### Stage 1 — CM4 FDCAN bring-up, internal loopback (no wiring, no bus)
> ✅ **PASSED 2026-07-14 (rev.5 build):** CP-1a `kernel_clk=50000000 src=2
> presc=1 tq=200 (bitrate=250000)`, CP-1b 34/34 frames byte-perfect, drop=0,
> SBUS unaffected. (34 frames alone isn't statistically conclusive vs the old
> ~1.6% corruption rate — user soaking longer; fix is causal so expectation is
> clean.) Took 5 revisions — full clock saga in §2. Separate pre-existing
> observation, NOT CAN-related: occasional garbage `[CM7 RC]` line
> (ch11-16 = 35548,35337,… style) appeared in runs before CAN existed too —
> likely a torn read between the CM7 ICC snapshot write and the RC debug
> print. Park for a later fix; do not conflate with CAN work.
Code: `CM4/Customer/Src/can_input.c` — after `ops_init_platform()`: re-init `hfdcan1`
(§2 values, `FDCAN_MODE_INTERNAL_LOOPBACK` behind a test flag, ext-ID range filter
0x0–0x1FFFFFFF → FIFO0, reject remote + non-matching), `HAL_FDCAN_Start`,
`FDCAN1_IT0_IRQn` in CM4 NVIC + `FDCAN1_IT0_IRQHandler` defined **in can_input.c
itself** (strong override of the startup file's weak alias — Core/ generated
files are never edited, Customer-only rule), IRQ drains FIFO0
(while fill>0) into static ring — copy only.
- **CP-1a:** boot print on CM4 debug UART: FDCAN kernel clock (expect 156 250 000),
  init OK, started OK. FAIL→ clock/RCC problem, fix before anything else.
- **CP-1b (RX+TX in one):** CM4 self-test sends one synthetic PGN 127488 frame
  (ext ID 0x09F20100, 8 bytes, RPM field = 6000 raw = 1500.0 RPM) via TX FIFO; loopback
  returns it; IRQ fires; ring holds 1 frame; print id/len/data — must match sent bytes.
  **This is the "CM4 can receive AND transmit CAN configured by us" gate.**
  FAIL→ message-RAM sizing, filter, or NVIC (bitrate immune in loopback).

### Stage 2 — ICC transport CM4→CM7
Code: CM4 customer task drains ring → `ICC_SendPacket` WITH_ID (`CUST_ICC_CAN_FRAME`,
new packet ID in `cust_icc.h`, payload `{u32 id, u8 len, u8 data[8]}` packed); CM7 ICC
handler pushes into CM7 ring; CM7 `CAN_Receive()` facade pops it (Dekimo signature,
`e_RETURNVALUE_Failure` when empty). Decide + implement how init is triggered (CM4
auto-init at boot vs CM7 `CAN_Init` facade sending an ICC command — prefer CM4 auto-init,
simpler, matches rc_sbus_old).
- **CP-2:** still loopback: CM4 self-test frame arrives on CM7 — temporary CM7 debug
  print of `CAN_Receive()` output matches CP-1b bytes. Also: burst 10 frames fast →
  all 10 arrive in order (ICC/ring capacity sanity). FAIL→ mailbox/packing, check
  against SBUS snapshot path (Log7).

### Stage 3 — Protocol port on CM7 (still no external hardware)
Code: copy `nmea2000.c/.h` verbatim; port `Yanmar.c` (drop `DAC_Init`, `while` drain);
call `YanmarFB_Process()` at the OldBoard position in `GEO_ApplicationTask_Update` ZF
branch; `initYanmar` equivalent in `GEO_ApplicationTask_Init`.
- **CP-3a:** CP-1b synthetic frame → `VPEngine[0].rpm == 1500.0` and `lastUpdate` fresh
  (debug print in app tick).
- **CP-3b (fast-packet):** CM4 self-test sends PGN 127489 (Engine Dynamic, 26 bytes) as
  a proper fast-packet sequence → oil pressure/temp fields populate. Proves FP
  reassembly survived the ICC hop intact. FAIL→ frame order/loss in transport.

### Stage 4 — Real bus with PC USB-CAN adapter
Wiring: adapter CAN-H→J16 CAN1 **P**, CAN-L→CAN1 **N**, common GND; termination such that
the two ends (adapter + MFCB) are terminated — measure ~60Ω across P/N powered-down.
Switch `can_input.c` test flag to `FDCAN_MODE_NORMAL`, disable self-test TX.
- **CP-4a (RX, real bitrate proof):** PC sends crafted PGN 127488 @ 250k (python-can
  script, backend per adapter model) → CM7 prints decoded RPM. First checkpoint that
  proves timing on real silicon+transceiver. FAIL→ §2 numbers vs measured kernel clock,
  or termination/wiring.
- **CP-4b (TX):** board sends one frame (facade `CAN_Send` → ICC → CM4, or CM4-local
  test) → PC monitor shows correct ext ID + payload. Verifies TX path for future VP use
  while the bench is set up.
- **CP-4c (soak):** PC script emits realistic traffic ≥10 min (127488 @10 Hz, 127489
  fast-packet @2 Hz, plus unrelated-PGN noise @20 Hz): zero ring/ICC overflow (add temp
  drop counters), stable decoded values, and staleness behaves (stop script →
  `lastUpdate` ages, no stale-data reuse). Meanwhile SBUS RC + ROC UDP + DAC must keep
  working (ICC contention check).

### Stage 5 — Cleanup and record
Remove temp debug prints + self-test flag (keep loopback self-test callable behind one
`#if`), remove drop counters or demote to debug page, update Log11 status per checkpoint,
update memory. Real-Yanmar test deferred until the engine bench is available — code
identical, only wiring changes.

## 4. Files to create/edit (all in `NewBoard/Rewrite/MFCB_BASE`)

| File | Action |
|---|---|
| `CM4/Customer/Src/can_input.c` + `Inc/can_input.h` | new — FDCAN re-init/start, `FDCAN1_IT0_IRQHandler` (weak-override, keeps Core/ untouched), IRQ→ring, self-test, ICC forward |
| `CM4/Customer/Inc/cust_icc.h` (+ CM7 copy) | add `CUST_ICC_CAN_FRAME` packet ID + payload struct |
| `CM7/Customer/Src/can.c` + `Inc/can.h` | new — Dekimo-signature facade over CM7 ring |
| `CM7/Customer/Src/nmea2000.c` + `Inc/nmea2000.h` | new — verbatim from `_8000` |
| `CM7/Customer/Src/Yanmar.c` + `Inc/Yanmar.h` | new — near-verbatim from `_8000` |
| `CM7/Customer/Src/GEO-application-task.c` | add init call + `YanmarFB_Process()` in ZF branch |
| CM4/CM7 `Customer.c` ICC dispatch | route `CUST_ICC_CAN_FRAME` |

## 5. Risks / open points

- **Kernel clock assumption** — closed at CP-1a (runtime readout).
- **Termination on MFCB side**: manual pinout is image-only (PDF p.7–9); `fdcan_config`
  EEPROM has a termination flag but nothing in the current lib applies it — if no on-board
  termination is switchable-by-us, rely on adapter-end termination + short leads for the
  bench, revisit for the boat install.
- **ICC contention with SBUS** (~70 pkt/s SBUS + CAN forwards): watched at CP-4c.
- **`ops_init_platform` ordering**: our re-init must run after it; hook `can_input` init
  from the CM4 Customer task start (same place rc_sbus_old inits), which already runs post-ops_init.
- Do **not** port `_8000`'s `HAL_FDCAN_RxFifo0Callback` (debug prints in IRQ) — its IRQ
  handler was commented out in `_8000` (`stm32h7xx_it.c:628`), i.e. OldBoard's CAN worked
  *because* that path was dead.
