# Log 9 — ROC UDP: `network_send()` deadlocks when called from the network RX task

**Date:** 2026-07-10
**Status:** ✅ Fix bench-confirmed — freeze gone, `network_send()` reply path works from
`roc_udp_service()`, ROC state (`state=4`) reached and driving mapped motor values from real
UDP input. One follow-up issue found during this same test, not yet fixed — see §7.
**Tree:** `NewBoard/Rewrite/MFCB_BASE/CM7/Customer/{Src/roc_udp.c,Inc/roc_udp.h,GEO-application-task.c}`
**Context:** Phase 3 ROC/UDP control-channel slice (OldBoard `OPS_ZF/Core/Src/ops-ethernet.c`
→ NewBoard `network_functions.h`). First hardware test of the ROC UDP path froze the whole
CM7 Customer task and stopped all UART1 output shortly after the first valid ROC packet.
**Related:** Log6-OPS-function-inventory.md, Log7-ICC-design-notes.md, Log8-DAC-CM7-bench-verified.md

---

## 1. Symptom

Running a PC-side Python test script against the board's ROC UDP listener (port 8888):

- Board's periodic `[CM7 RC] state=...` debug heartbeat (from `MotorControl_DebugPrint`,
  a completely separate task) printed normally while only RC was exercised.
- As soon as the ROC UDP test script ran and a valid handshake packet was processed, **all
  UART1 output stopped permanently** — including the unrelated app-task heartbeat, which
  shares no code path with the ROC handler beyond one mutex.
- Python client reported "no reply" on every send.

A single stuck FreeRTOS task blocked on a mutex/queue does not stop unrelated tasks
(FreeRTOS is preemptive) — the fact that a *totally separate* task's periodic output also
went silent forever was the key clue that ruled out "just this one task is stuck" as being
sufficient explanation on its own, and pointed at something the stuck call itself was doing
that had broader impact (or at minimum, something worth isolating precisely before
theorizing further).

## 2. Method — print bisection inside `roc_udp_on_packet()`

No debugger was available. Diagnosed by adding one `customer_task_uart()` print at a time at
successively deeper points inside the RX callback (`roc_udp_on_packet()`, registered via
`network_rx_register_handler()`), re-flashing, and re-running the same test each time to see
which was the *last* checkpoint to print before the freeze:

1. Top of function (before the `packet == NULL || res_port != ROC_UDP_PORT` filter) — **fired**.
2. After `memcpy(rx_buf, ...)` / before `sscanf()` — **fired**.
3. Right after the `sscanf(...) != 8` check (i.e. parse succeeded) — **fired**.
4. Right after `osMutexRelease(s_roc_mutex)` (end of the latch/handshake critical section) — **fired**.
5. Right before `network_send(&tx)` — **fired**.
6. Right after `network_send(&tx)` returns — **never fired**.

Every step of the handler's own logic (port filter, buffer copy, `sscanf` parsing, the
handshake/latch conditional, the mutex acquire/release) completed correctly and quickly.
The **only** step that never returned was the call into `network_send()` itself.

## 3. Root cause (best available explanation — `libops.a` is closed-source)

`network_rx_register_handler()`'s own doc comment states the callback is "called from RX
task." Calling `network_send()` — documented as "queue an outbound packet for transmission,"
implying a fast, non-blocking enqueue — **synchronously from inside that same RX task's own
callback** deadlocks every time.

Most likely explanation: the RX task's internal dispatch loop holds some internal lock or
queue slot while invoking the registered callback, and `network_send()` (called from that
same task) needs that same resource to complete — which can't happen until the callback
(itself blocked inside `network_send()`) returns. A classic self-deadlock via a non-recursive
mutex/queue, not a bug in the caller's logic.

This is **not** how OldBoard did it: `OPS_ZF/Core/Src/ops-ethernet.c`'s
`udp_control_recv_callback` calls raw LwIP's `udp_sendto()` directly inside the recv
callback, which is a standard, explicitly-supported pattern for raw LwIP (the callback runs
in the `tcpip` thread, and `udp_sendto()` is designed to be called from there). NewBoard's
`network_functions.h` wraps LwIP in its own queued abstraction with different, undocumented
threading assumptions — nothing in the header warns against this specific call pattern.

**Per the mandatory workspace check** (`Log6-OPS-function-inventory.md`, "check the OPS
function inventory first before designing any workaround"): confirmed no existing documented
alternative send path or safe-context caveat for `network_send()` / `network_rx_register_handler()`
beyond what's already in `network_functions.h` — this isn't a known, already-solved quirk on
record, so a workaround (not a different existing OPS call) is the correct next step.

## 4. Fix applied

`network_send()` must not be called from the RX task. `roc_udp_on_packet()` now only
**latches** the handshake-reply fields (dest IP, dest port, `sendpackettime`) under the
existing `s_roc_mutex`, in the same critical section that already updates `s_latest` —
no `network_send()` call in the RX-task path at all anymore.

A new function, `roc_udp_service()`, checks that latch under the same mutex and performs
the actual `network_send()` call — called once per tick from `GEO_ApplicationTask_Update()`
(the Customer app task, a different task from the network RX task). This is the same pattern
the supplier's own doc demonstrates for `network_send()` usage (called from Customer task
context, e.g. `Customer_Example_IpChannelNetworkTest`), so it's consistent with the
documented-safe calling context, just deferred by one tick (a few ms) instead of sent inline.

Protocol-visible behavior is unchanged from OldBoard: every syntactically valid packet still
gets exactly one handshake reply, with the same payload format and timing semantics — the
only difference is *which task* performs the send, invisible on the wire.

Chosen over the alternative (a dedicated CMSIS-RTOS2 message queue + new worker thread
purely for sending replies): the mutex-latch-and-poll approach reuses existing state/mutex,
adds no new RTOS objects, and keeps the change contained to `roc_udp.c`/`roc_udp.h` plus one
call site in `GEO-application-task.c` — smaller diff, per this project's stated preference
for the smallest testable diff over a more "textbook" producer/consumer design.

## 5. Files changed

- `CM7/Customer/Src/roc_udp.c` — removed `network_send()` call from `roc_udp_on_packet()`;
  added `s_reply_pending`/`s_reply_ip`/`s_reply_port`/`s_reply_send_time` latch fields and
  `roc_udp_service()`.
- `CM7/Customer/Inc/roc_udp.h` — declared `roc_udp_service()`.
- `CM7/Customer/GEO-application-task.c` — calls `roc_udp_service()` once per
  `GEO_ApplicationTask_Update()` tick, right after `roc_udp_get_latest()`.

## 6. Bench result (2026-07-10, same session)

Re-ran the same PC-side Python ROC test against the fixed firmware:

- No freeze. UART1 output continued throughout.
- `state=4` (ROC) reached and sustained — confirms `network_send()` from `roc_udp_service()`
  (Customer app task context) works, unlike from the RX task.
- Motor commands tracked real ROC input (`right=1646 left=1335`, mapped from the raw
  joystick values sent by the script), not stuck at neutral.

Fix confirmed working for the deadlock this log covers.

## 7. New follow-up issue found in this same test (not fixed yet)

The bench run also showed `" RC sailing mode"` / `" ROC sailing mode"` printing in rapid
alternating pairs, every ~10ms tick, for as long as both RC and ROC were simultaneously
asserting control (RC channel 8/`request_control` held high on the bench transmitter, at the
same time as a granted ROC session). Root cause: in `GEO_ApplicationTask_Update()`
(`GEO-application-task.c`), the RC-arbitration `if` block runs first and unconditionally
takes `currentSailingState` away from `ROC` back to `RC` (printing the transition) whenever
`rc_ok && rc.request_control`; the very next `if` block then unconditionally takes it back to
`ROC` (printing that transition too) whenever `roc_ok`. With both conditions true every tick,
the state — and both transition prints — flip-flop every single iteration instead of settling.
Final motor output each tick still lands on `ROC` (since that check runs last), so control
itself was stable in this run; the flip-flopping is currently only visible as print spam, but
is the same "same priority, to be discussed" ambiguity OldBoard itself flagged, now made
visible as a concrete bug rather than a comment. Deferred to the next session per user
request ("next prompt we will clean it up") — not fixed in this entry.

## 8. Fault attribution

Asked directly during this session: is this on us or on OPS? Answer: **OPS, not the
Customer code.**

- Our code used the documented API exactly as documented — `network_send()` is described as
  "queue an outbound packet for transmission" (implying fast/non-blocking), and
  `network_rx_register_handler()`'s doc states the callback runs on the RX task as a plain
  fact, with **no warning anywhere** that calling `network_send()` from inside that callback
  is unsafe.
- Print bisection (§2) proved every line of *our* logic — port filter, buffer copy, `sscanf`,
  the mutex-protected latch — executed correctly and returned promptly. Only the library's
  own `network_send()` call ever hung.
- Porting OldBoard's exact pattern (reply inline inside the recv callback) was a reasonable
  assumption, not negligence: that pattern is explicitly correct and standard for raw LwIP,
  which is what OldBoard used. Nothing in NewBoard's docs flagged this OPS wrapper as
  behaving differently under the same pattern.

So the real defect is in `libops.a` — either a genuine reentrancy self-deadlock (leading
theory: the RX task needs to service something internally to let `network_send()` complete,
and can't while blocked inside the very callback that's waiting on it), or at minimum an
undocumented "must not call from this context" constraint that should have been in the
header. Either way, that's a library/documentation failure, not a Customer-code bug.

The one thing worth calling out on our side, and a minor one: assuming OldBoard's calling
pattern would carry over unchanged to a different, closed-source middleware without
verifying that assumption first. A reasonable, unverified port assumption — not a coding
error — and exactly the kind of gap this bench-test slice existed to catch.

## 9. How similar is the fix to OldBoard? — behaviorally yes, mechanically no

Asked directly: functionally identical, mechanically different.

**Same as OldBoard (intentionally preserved):**
- Every syntactically valid packet still gets exactly one handshake reply, same payload
  format (`sendpackettime,ip.ip.ip.ip,`), same fields echoed.
- Same handshake logic (`requestcontrol==1` + both throttles at neutral latches the sender's
  IP), same stale-timeout behavior, same raw-to-PWM mapping math, same "only steering
  clamped" quirk.
- From the PC client's point of view the protocol is indistinguishable from OldBoard — same
  requests get the same replies, just up to ~10ms later (§ latency discussion above).

**Different from OldBoard (forced by the fix, not a design choice):**
- OldBoard's `udp_control_recv_callback` runs inline, single step: parse packet, then
  immediately call `udp_sendto()`, same function, same thread — supported because raw LwIP
  explicitly allows sending from inside a recv callback.
- NewBoard now: two steps, two different tasks. `roc_udp_on_packet()` (still on OPS's RX
  task, still does the same parsing/handshake logic as before) only *latches* what reply is
  owed, under `s_roc_mutex`. `roc_udp_service()`, running on the Customer app task, picks
  that latch up on its next ~10ms tick and is the one that actually calls `network_send()`.

The behavior is a faithful port; the mechanism had to become a producer/consumer hand-off
across two tasks instead of a single inline call — not because OldBoard's design was wrong,
but because NewBoard's `network_send()` doesn't tolerate being called from the same task
that invokes the RX callback, unlike raw LwIP's `udp_sendto()`. This is the one place this
slice could not stay structurally identical to OldBoard, only behaviorally identical.

## Cross-references

- `.cursor/Logs/Log6-OPS-function-inventory.md` — mandatory first check for OPS library
  behavior before designing workarounds; confirmed no existing documented alternative here.
- `.cursor/Logs/Log7-ICC-design-notes.md` — CM4/CM7 split context for this control loop.
- `OPS_ZF/Core/Src/ops-ethernet.c` — OldBoard's `udp_control_recv_callback`, source of truth
  for the protocol/handshake behavior being preserved.
- `NewBoard/Rewrite/MFCB_BASE/CM7/OPS_Lib/include/Middleware/Network/network_functions.h` —
  `network_rx_register_handler` / `network_send` docs (no caveat documented for this case).
