# Log 7 — Customer ICC design notes (CM4 → CM7 bridge for SBUS and beyond)

**Date:** 2026-07-09
**Status:** 📝 Design discussion — no code written yet
**Tree:** `NewBoard/Rewrite/MFCB_BASE/`
**Context:** Phase 3 of the OPS_ZF → NewBoard port. Main application state machine
(`ops_application_task_impl` from `OPS_ZF/Core/Src/ops-application-task.c`) is being
moved to **CM7**; SBUS RX/decode stays on **CM4** (`CM4/Customer/rc_sbus_old.c` — see
Log4/Log5). This log captures the reasoning for how decoded SBUS data — and future
Customer data — crosses from CM4 to CM7.
**Related:** Log4-SBUS-UART6-7-working-implementation.md, Log6-OPS-function-inventory.md

---

## 1. Why the main app moves to CM7, not CM4

Per `how_to_use_core_assignment.txt`: CM4 = real-time I/O (UART, DAC chip, PWM, CAN),
CM7 = network stack + higher-level logic. The deciding factor is the next slice after
SBUS: OPS_ZF's ROC path (`init_udp_control_channel()`, `EthrottleSB/BB`, `ESteering`,
`GetEControl`) is LwIP/UDP, which on NewBoard exists **only on CM7**. Putting the state
machine on CM7 now avoids relocating it once ROC is ported. SBUS RX cannot move to CM7:
UART HAL is CM4-owned, and `rc_sbus_old.c` does direct `HAL_UART_Receive_IT` on `huart6`
plus an NVIC fix — illegal/impossible from CM7 (design rule: "never bit-bang HAL on CM7").

| OPS_ZF piece | NewBoard home |
|---|---|
| `UART6_Init4SBUS()` + `ProcessRC()` | CM4 (unchanged) |
| `pwmValues[]`, `requestRCcontrol` | CM4 → CM7 via ICC |
| Sailing state machine, DAC output | CM7 |
| ROC/UDP, heartbeat/redundancy, AP_IMS | later slices |

---

## 2. ICC vs SRAM4 snapshot — same physical transport, different protocol

Both live in the **same SRAM4 region** (D3 domain, `0x38000000`–`0x3800FFFF`, 64 KB),
reached at bus speed by both cores. No physical speed difference. The difference is
purely semantic:

| | ICC (`intercore_comm.h`) | SRAM4 snapshot (`uart_rx_shared.h`, `*_shared_memory.h`) |
|---|---|---|
| Shape | Queue: 4 rings (CM4→CM7 / CM7→CM4 × NO_ID / WITH_ID), 8 KB each, HSEM IRQ wakes a receiver task | Blackboard: one fixed slot per resource, writer overwrites, HSEM-guarded copy, no wakeup |
| Delivery | Pushed — receiver task woken per packet | Pulled — reader polls, freshness = poll interval |
| Failure mode | Ring full → send waits ≤5 ms, then drops | Reader gets stale value or "no frame yet" — graceful |
| Extensibility (Customer code) | First-class: `IC_CH_CUSTOMER` exists, scaffolding already wired | Not viable on CURRENT lib — SRAM4 layout + HSEM lines owned by `libops.a`; DIY slot = real risk, no gain at these data rates |

**Rule of thumb:** does every message matter, or only the newest one?
- Events/commands/transactions → ICC (queue semantics are correct here).
- Continuously refreshed state (sensor/stick values) → snapshot semantics — but see §3,
  because on CURRENT this still means "ICC, wearing snapshot behavior."

**Decision:** SBUS → ICC on `IC_CH_CUSTOMER` today (only sanctioned extensible path on
CURRENT; existing receive code already gives latest-value behavior — see §3). NEWER lib's
`sbus_shared_read()` is the natural snapshot replacement once available — same shape as
`UART_RxShared_FetchLast`, just for SBUS specifically.

---

## 3. Ring capacity vs bitrate — not the same axis

`ICC_BUFFER_SIZE = 8192` (8 KB) is a **backlog capacity**, not a throughput limit. The
transfer itself (memcpy into SRAM4 + HSEM signal) is effectively instant relative to any
Customer traffic. SBUS: ~40 B payload + 3 B NO_ID header ≈ 43 B/frame × ~70 Hz ≈ 3 KB/s —
the ring could hold ~190 such packets (~2.7 s) of backlog before refusing sends. Not a
constraint at this rate.

Ring overflow only happens if the **receiving task stalls** (busy with other traffic on
the same pipe) long enough for backlog to exceed 8 KB. Critically: **all channels sharing
a direction+framing pair share one physical ring** — `ic_channel_t` is just a 1-byte
routing tag in the packet header (`length(2B) + channel(1B)` for NO_ID), not a separate
buffer. Channels don't have individual quotas; they compete for the same byte pool.

**Documented starvation direction:** CM7→CM4, during web/EEPROM activity (heavy I2C2
forwarding, UART proxy traffic) — see `ICC_CM4_DROP_UART_PROXY_WHEN_BUSY` and
`icc_diag_ring_fill_cm4()` in `intercore_comm.h`. Relevant for **future** CM7→CM4 Customer
traffic (e.g. CM7 telling CM4 to assert a safety-relevant GPIO), not for SBUS itself
(which flows CM4→CM7). Mitigation: staleness timeout on the CM4 receiver, same pattern as
§6 below — don't trust "I received a value" to mean "this value is current."

---

## 4. Channel limit: 1 usable Customer channel on CURRENT

Searched the whole `MFCB_BASE` tree for `intercore_comm.c` (source) and for any
implementation of `ICC_PacketReceivedHook_NO_ID` (the documented per-channel dispatch
hook) — **neither exists anywhere in this codebase**. Only the header and the precompiled
`libops.a` are present (consistent with `current-build-porting-strategy.mdc`: "Headers +
`libops.a` linked").

`Customer_ICC_HandlePacket_NO_ID(data, len)` takes **no channel parameter** — it is a
fixed, hardcoded entry point that the precompiled library already calls specifically for
`IC_CH_CUSTOMER`. That routing is baked into the compiled binary against the `ic_channel_t`
enum as it existed when the library was built.

Consequences:
- Cannot define a second function of that name (link collision).
- Extending `ic_channel_t` with a new value (e.g. `IC_CH_CUSTOMER_SBUS`) only changes the
  local header — the already-compiled library's internal dispatch has no case for an
  unknown value. **Not proven by disassembly** (unlike the Log4 NVIC finding) — treated as
  the working assumption given no dispatcher source exists to point a new channel at.
- `IC_CH_CUSTOMER` is shared with `customer_examples.c` demo traffic (`IccSendNoId`), which
  targets the same channel and the same single-slot `s_icc_slot` receive buffer.

**Decision:** disable `CUSTOMER_EXAMPLES_ENABLE` while `IC_CH_CUSTOMER` carries SBUS, to
avoid slot collisions with demo traffic (matches the supplier doc's own "minimal starting
point" guidance). Revisit a real second channel only if/when NEWER lib's dispatch is
verified to support it, or if CURRENT's dispatch is proven more permissive via disassembly
(same technique as the Log4/Log5 NVIC investigation).

**By contrast:** a payload-level message-type tag (§5) is *not* subject to this limit —
that switch lives entirely in `Customer_ICC_HandlePacket_NO_ID`, which is app-owned code.
No library recompilation involved; add as many message types as needed.

---

## 5. NO_ID vs WITH_ID, and the message-type tag

- `NO_ID` = enqueue only, no reply tracking. Still FIFO-ordered end to end.
- `WITH_ID` = request/response: allocates a tracking slot (`MAX_PENDING_RESPONSES = 16`),
  expects a reply, `ICC_RESPONSE_TIMEOUT_MS = 1000`. For things needing acknowledgment.
- `s_icc_slot` in the current `Customer.c` gives "latest value only" behavior **not**
  because of NO_ID itself, but because the receive hook overwrites a single slot on every
  arrival — that's an app-level design choice layered on top of a queue transport, not a
  transport property.

**Tagging** (a single leading byte in the payload identifying message type) works
identically for NO_ID and WITH_ID — `packet_id` (transaction identity) and the tag
(content identity) are orthogonal. A byte gives 256 possible types, more than enough
given `ICC_MAX_PACKET_SIZE = 2048` and actual payload sizes in the tens of bytes; bit-level
packing would be premature optimization at this scale.

**Tagging alone is not sufficient** — see §6 for why per-type storage is also required.

---

## 6. Timing / freshness — the axis tagging does not solve

Tagging answers "which slot does this belong to." It says nothing about "how old is what's
currently in that slot." Two independent problems, both required per message type:

- **Identity** → the tag, routes payload to the correct slot.
- **Freshness** → a timestamp (`HAL_GetTick()`) captured *at receive time* inside
  `Customer_ICC_HandlePacket_NO_ID`, checked *at consumption time* against a threshold
  sized to that specific source's own natural rate.

For multiple independently-timed CM4 producers (e.g. SBUS + a second UART-sourced
protocol) sharing `IC_CH_CUSTOMER`: each gets its own slot **and** its own timestamp.
Interleaving on the wire needs no special handling — the ring is FIFO, packets from
different producers land in send order, get drained one at a time, and are routed by tag.
Ordering *between* different tags doesn't matter for latest-value data (only per-slot
freshness matters); ordering *within* one tag is preserved by the ring, which is all
overwrite semantics need.

**Open item, not yet verified:** if two different CM4 tasks call `ICC_SendPacket_NO_ID`
concurrently (e.g. SBUS decode task + a second protocol task), whether the ring write is
internally locked against concurrent callers has not been confirmed by inspection —
reasonable to assume yes (ICC is meant for use by many platform subsystems at once) but
worth a quick check before relying on it with two independent CM4 producer tasks.

---

## 7. Heartbeat and RC-takeover — applying the state-vs-event distinction

**Heartbeat — two different things, don't conflate them:**

1. **CM4↔CM7 liveness** — already implemented by the platform: `IC_CH_WATCHDOG` /
   `Watchdog_ICC_HandlePacket`, WITH_ID ping/pong, `Middleware/Watchdog/watchdog.h`
   (dual-core software watchdog, FreeRTOS task + `osDelay`, no hardware TIM). Nothing to
   design here if this is the intent.
2. **OPS_ZF master/slave module heartbeat** (`SendHeartbeat()`/`checkHeartbeat()`,
   `HEARTBEAT_PIN` = GPIO E13, `HEARTBEAT_MS`/`HEARTBEAT_TIMOUT_MS` in `rc_sbus_old.h`) —
   a signal **between two physical MFCB boards** (master / hot-backup), GPIO/bus-level,
   not a CM4↔CM7 concern and not a candidate for `IC_CH_CUSTOMER` at all.

If a CM4-Customer-side feed of (2) up to the CM7 state machine is ever needed: it's a
periodic beacon where individual misses don't matter, only recency — NO_ID + timestamp
staleness (§6), same shape as SBUS. WITH_ID would be over-engineering something re-sent
every N ms regardless of ack.

**RC takeover — not actually a separate event in this codebase.** `requestRCcontrol` in
OPS_ZF is recomputed every loop iteration from one SBUS channel's value against a
threshold (`pwmValues[CH_Take_Control] < PWM_MID_VALUE - 3*PWM_DEAD_BAND`) — it is
state, not an event, at the same rate as the rest of the SBUS channels. Correct design:
it rides inside the SBUS snapshot as one more field (or CM7 derives it itself from
channel values already received), inheriting SBUS's staleness handling for free — if the
SBUS slot goes stale, `requestRCcontrol` fails safe to "no RC control" as part of that
same fallback, with no separate tag or WITH_ID needed.

**Contrast case — what *would* deserve WITH_ID/ack:** a genuine one-shot operator
instruction not derived from a continuous input stream — e.g. an E-stop, or an explicit
"hand control to ROC now" request issued once rather than recomputed every frame. Losing
that silently is a real bug with no "next frame" to self-correct, unlike RC takeover.

**Decision rule for any future message type:** is this a value that will be re-sent
anyway on the next cycle (→ NO_ID + tag + slot + timestamp), or a one-shot instruction
where a miss matters (→ WITH_ID + tag + ack)?

---

## Cross-references

- `.cursor/Logs/Log4-SBUS-UART6-7-working-implementation.md` — working CM4 SBUS RX path
- `.cursor/Logs/Log5-rc_sbus_old-direct-port-attempt.md` — polling-read dead end, OPS UART
  task is the only working RX route on this board
- `.cursor/Logs/Log6-OPS-function-inventory.md` — ICC/watchdog/shared-memory function list
- `NewBoard/Rewrite/MFCB_BASE/CM4/Customer/Customer.c`, `CM7/Customer/Customer.c` —
  current (unmodified) ICC scaffolding: `s_icc_slot`, `Customer_ICC_HandlePacket_NO_ID/WITH_ID`
- `NewBoard/Rewrite/MFCB_BASE/CM*/OPS_Lib/include/peripherals/inter_core_communication/intercore_comm.h`
- `OPS_ZF/Core/Src/ops-application-task.c` — source of truth for the state machine being ported
