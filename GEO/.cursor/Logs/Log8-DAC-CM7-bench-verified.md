# Log 8 — DAC from CM7: `dac_ctrl` bench-verified, `voltage_uv` is output-referred

**Date:** 2026-07-09
**Status:** ✅ Verified on hardware — safe to build the real DAC-prep port on this result.
**Tree:** `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Customer.c`
**Context:** Phase 3 of the OPS_ZF → NewBoard port. Next slice after SBUS-to-CM7 (Log7) is
turning SBUS/PWM channel values into DAC output on the MFCB — porting OldBoard's
`prepareDACValue()` + `DAC_SetCHANNELValueAndUpdateOutputs()` (`OldBoard/Core/Src/ops-tools.c`,
`ops-application-task.c`) to NewBoard's `dac_ctrl()`. Before porting the real math, ran a
one-shot bench test to settle two unknowns: does `dac_ctrl` work from CM7 at all, and what
domain is `voltage_uv` in (pre- or post- onboard op-amp gain)?
**Related:** Log7-ICC-design-notes.md, Log6-OPS-function-inventory.md,
`reference-OPS-MFCB-hardware-manual-rev2.01.md`

---

## 1. Goal

1. Confirm `dac_ctrl()` (`devices/onboard/DAC/DAC084S085_104S085_124S085/dac.h`) actually
   drives the physical DAC when called from **CM7** (it's SPI2/CM4-owned; CM7 call should
   route via `IC_CH_DAC_MAINPRINT` ICC automatically — never proven on this board before).
2. Determine what `voltage_uv` in `dac_output_voltage_t` actually means at the physical
   `AO1..AO4` pins (connector J8), since the header only documents it as "desired output
   in µV" with no stated reference point.
3. Rough-check `dac_ctrl` call latency from CM7 (open question from Log7: does the ICC
   round-trip block toward `ICC_RESPONSE_TIMEOUT_MS = 1000ms`, which would be unacceptable
   in a ~50ms motor control loop).

## 2. Method

One-shot bench call added to `CM7/Customer/Customer.c` (`customer_dac_bench_test`),
fired once right before `StartCustomerTask`'s main loop so the voltage holds indefinitely
for multimeter probing:

```c
dac_req_t req = DAC_REQ(DAC_OP_OUTPUT_VOLTAGE);
req.output_voltage = (dac_output_voltage_t){
    .channel = DAC_CH_A,
    .voltage_uv = 1000000u,        /* requested 1.000 V */
    .op_code = DAC_OP_WRITE_UPDATE,
    .power_down_mode = DAC_POWER_HIZ_00,
};
uint32_t t0 = HAL_GetTick();
bool ok = dac_ctrl(&req);
uint32_t dt = HAL_GetTick() - t0;   /* printed over UART1 alongside ok */
```

User measured `AO1` (vs `GND`) on connector J8 with a multimeter.

## 3. Result

**`dac_ctrl` works from CM7** — `ok == true`, call succeeded via ICC to CM4's SPI2 server.

**Measured 0.981V at AO1 for a 1.000V request.** This is the important finding: initial
hypothesis (based on `DAC_FACTORY_VREF_UV = 3,000,000` µV and `DAC_FACTORY_OPAMP_GAIN = 340`
i.e. ×3.4, plus the hardware manual labeling `AO1..AO4` as 0–10V) was that `voltage_uv` is
the **pre-gain**, DAC-chip-side voltage — predicting ~3.4V measured for a 1.0V request.
**Wrong.** The 1:1 result (0.981 ≈ 1.000, well within 8-bit DAC quantization + gain-stage
component tolerance) proves `voltage_uv` is **output-referred** — the voltage you actually
get at the physical AO pin. `dac_ctrl` handles the `Vref`/`opamp_gain`/calibration
conversion internally; the caller never needs to know the gain stage exists.

**Implication for the real port:** OldBoard's `prepareDACValue()` (clamps to 0.4V–3.0V,
fed straight into Dekimo HAL's `DAC_SetCHANNELValueAndUpdateOutputs`) was almost certainly
*also* output-referred, same physical DAC084S085 + op-amp front-end. Porting to `dac_ctrl`
is therefore a straight unit conversion, no gain math anywhere:

```
voltage_uv = (uint32_t)(prepareDACValue(motorcommand) * 1e6f)
```

**Channel mapping:** `DAC_CH_A` physically confirmed to land on `AO1`. `DAC_CH_B → AO2`
not yet bench-tested, but same ordinal convention expected (OldBoard: DAC channel 0 =
right motor, channel 1 = left motor — see Log7 cross-reference; hardware manual only
labels pins generically `AO1..AO4`, no left/right semantics at the connector level).

**Doc-drift caught along the way:** `Settings/dac_config.h` doc comments and
`current-build-porting-strategy.mdc`'s DAC row both reference a `DAC_OutputVoltage()`
function. Checked the linked `libops.a` with `nm`:

```
t DAC_OutputVoltage      <- local/static, NOT exported, cannot be called from Customer code
T dac_ctrl                <- the real, only public entry point
```

`dac_ctrl` is confirmed as the sole callable API by Log6's inventory too. The
`DAC_OutputVoltage` references are stale (likely a pre-finalization name) —
`current-build-porting-strategy.mdc`'s "DAC / motors" row should eventually be corrected
to `dac_ctrl`.

## 4. Open item — RESOLVED 2026-07-17 (see Log18)

`dac_ctrl` from CM7 **blocks** on WITH_ID + `ICC_WaitForResponse` (timeout 1000 ms). Two
per-tick calls in `GEO_ApplicationTask_Update` made the CM7 Customer loop ~240–400 ms
(DAC on) vs ~5 ms (DAC commented). Do **not** use CM7 `dac_ctrl` in the hot path — apply
DAC on CM4; plan in Log18.

## Cross-references

- `.cursor/Logs/Log7-ICC-design-notes.md` — CM4→CM7 SBUS/PWM bridge design, the data source
  this DAC path will consume (`cust_icc_mailbox_read_sbus()`)
- `.cursor/Logs/Log6-OPS-function-inventory.md` — confirms `dac_ctrl` as the only DAC entry
- `OldBoard/Core/Src/ops-tools.c` (`prepareDACValue`, line ~313), `ops-application-task.c`
  (DAC write call site, line ~123) — source of truth for the motor-command → DAC math
- `NewBoard/Rewrite/MFCB_BASE/CM7/OPS_Lib/include/devices/onboard/DAC/DAC084S085_104S085_124S085/dac.h`
- `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/Customer.c` — `customer_dac_bench_test`
- `OldBoard/OPS-MFCB Hardware manual rev0.01.pdf` — connector J8 `AO1..AO4` (0–10V) pinout
