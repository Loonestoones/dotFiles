# Log 21 — Customer ICC can deliver bad payloads; clamps are mandatory

**Date:** 2026-07-20  
**Tree:** `NewBoard/Rewrite/MFCB_BASE`  
**Status:** CRITICAL — bench-confirmed OOR + libops ring-wrap hypothesis  
**Related:** Log7 (ICC design), Log18 (motor DAC on CM4), Log19 (traffic inventory),  
`icc-freshness-motor-dac.mdc`, `icc-bad-packets-need-clamps.mdc`

---

## Goal

Explain random AO spikes to motor plant min/max after motor DAC moved to CM4
(Customer ICC µV + local `dac_ctrl`).

---

## CRITICAL finding (keep)

### Scaler is fine

`prepareDACValue` → `motor_command_to_voltage_uv` for **any** `uint16_t` stick
command stays in **`[400000, 3000000]` µV** (float `* 1e6f` is not the junk source).

At **RC idle**, CM7 should send steady **~1700000 µV (1700 mV / mid)**.

### CM4 still receives OOR

Clamp-fire UART1 prints inside `MotorDac_ClampVoltageUv` (rate-limited), including
**while RC was idle**:

| Print | Approx raw µV | Notes |
|-------|---------------|--------|
| `HI raw=25827 mV -> MID` | ~25 827 000 | ~25.8 V — far above 3.0 V max (print would be 3000 mV) |
| `HI raw=25821 mV -> MID` | ~25 821 000 | same band, slight drift |
| `LO raw=0 mV -> MID` | 0 | below min; classic zero/torn dword |

### Verdict

**CM7 → CM4 sometimes delivers garbage.** Not stick endpoints; not CM7 plant math.
Customer validation is header-only (tag / version / length) — **no CRC on
`right_uv` / `left_uv`**. CM4 OOR→MID clamps are mandatory defense in depth.

---

## Likely root cause — libops ring wrap + linear pointer (2026-07-20)

**Source inspected:** `NewBoard/Rewrite/MFCB_BASE/CM4/OPS_Lib/libops.a` →
`intercore_comm.o` (arm-none-eabi-objdump `-dr`).

### What `process_rx_buffer` does

| Step | Behaviour |
|------|-----------|
| Parse ICC NO_ID header | Length + channel via wrap-safe `next_index` (`ubfx` 13 bits → 8 KB) |
| Payload pointer | **Linear:** `ring_base + index + 4` (into SRAM4 ring data) |
| Dispatch | `ICC_PacketReceivedHook_NO_ID` → jump table → `Customer_ICC_HandlePacket_NO_ID` for `IC_CH_CUSTOMER` |
| Advance read index | **After** hook returns, then `osThreadYield` |

Ring object: `buf_CM7_to_CM4_NO_ID` in `.shared_sram4`, size **`0x2004`** = 4-byte
head/tail + **8192** data (`ICC_BUFFER_SIZE`). Header docs already say hook `data`
is a **pointer into shared SRAM4** (zero-copy).

### Why that breaks

Header/channel bytes are consumed with wrap-aware indexing. The payload is **not**
copied into a contiguous scratch buffer. If a packet **straddles the end** of the
8 KB data region, `Customer_ICC_HandlePacket_NO_ID` → `memcpy` into the motor slot
reads **past the ring** into neighboring SRAM4 → garbage µV while tag/version/len
can still look valid.

Matches bench: intermittent; fires at **idle**; impossible magnitudes (0 / ~25 V);
CM7 scaler cannot emit them. Motor (~16 B customer) + steer every CM7 tick → more
ring traffic → more wrap opportunities.

### Contributing (Customer code — not the root)

`how_to_use` / `Customer.h`: handlers must stay **short**. CM4 store path may
`osMutexAcquire(s_icc_mutex, 5 ms)` then `memcpy` **before the hook returns**, so
the ICC NO_ID task holds the current ring slot longer → higher fill → **more wraps**.
Mitigate later (copy out under no wait / defer work); does not replace a libops fix.

### What will not fix it from Customer alone

Cannot implement wrap-safe gather without ring layout ownership. **Real fix:** new
`libops` that linearizes payload before the hook (or wrap-safe copy API). Until then:
**keep clamps.**

### Optional confirm later

Log `icc_diag_ring_fill_cm4()` next to `[CM4 MOTOR CLAMP]` — expect correlation when
CM7→CM4 NO_ID ring has been cycling near wrap.

### Ranked alternatives (weaker)

| Rank | Hypothesis | Notes |
|------|------------|--------|
| 1 | Ring wrap + linear hook pointer | Best fit; seen in disassembly |
| 2 | Mutex delay inside hook | Worsens fill/wraps |
| 3 | SPSC head/tail race | Possible; less direct than wrap |
| — | Scaler / float / stick endpoints | Ruled out |

---

## Earlier clamp experiment

CM4 `MotorDac_ClampVoltageUv`:

```c
/* Out-of-range → MID (was saturate to MIN/MAX) */
if (voltage_uv < CUST_ICC_MOTOR_DAC_UV_MIN) return CUST_ICC_MOTOR_DAC_UV_MID;
if (voltage_uv > CUST_ICC_MOTOR_DAC_UV_MAX) return CUST_ICC_MOTOR_DAC_UV_MID;
return voltage_uv;
```

Range: `UV_MIN=400000`, `UV_MAX=3000000`, `UV_MID=1700000` (`cust_icc.h`).

| Clamp OOR behaviour | Observed on AO |
|---------------------|----------------|
| Saturate to min/max | Random spikes to ~0.4 V / ~3.0 V |
| Map OOR → mid       | Rail spikes gone; **bursts to ~1.7 V** instead |

---

## Do not confuse with stale→mid

`MotorDac_Service(..., stale=true)` also forces mid when age >
`CUST_ICC_MOTOR_DAC_MAX_AGE_MS`. That path does **not** print `[CM4 MOTOR CLAMP]`.
Clamp prints = OOR at clamp input only.

---

## Rule going forward

1. Keep CM4 plant clamps — **OOR → MID**, never rail saturate.
2. Never assume ICC motor µV is good because CM7 already clamped.
3. Keep/restore clamp-fire UART1 prints when diagnosing AO glitches.
4. Escalate wrap-safe RX to supplier / next `libops.a`; Customer workarounds are
   clamps + shorter ICC hooks + less NO_ID traffic if needed.
5. Optional bisect: CM7 TX µV vs CM4 latch; ring fill % vs clamp fire.
