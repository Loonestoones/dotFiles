# Reference — OPS-MFCB Hardware Manual rev2.01

**Source PDF:** `NewBoard/OPS-MFCB Hardware manual rev2.01.pdf`  
**Board:** Multi-Function Control Board (MFCB) **HW rev2.0**  
**Manual rev:** 2.01 · **Creation date:** 7 Dec 2024 · **Pages:** 11  
**Status:** Supplier marks doc as *“Preliminary information still under construction!”*

> On-demand reference only — not loaded every session. `@`-mention this file or the PDF when connector/power questions come up.

---

## 1. Introduction (summary)

- MFCB = **stack**: Multi-Function **Power board** (bottom) + **control board** (top).
- Can run **standalone powered over USB-C** (power only — see § USB-C below).
- Use cases: motor/rudder control for drones / ROV / ROTV; or **remote control station** joysticks over **Ethernet** to a second MFCB on the vehicle (VPN via external firewall/router).
- Aligns with firmware: CM7 network/web, IP channels, future SBUS + ROC path.

---

## 2. Specifications

### 2.1 Power input

| Source | Notes |
|--------|--------|
| **2× redundant DC** | **22–56 V** via power connector (J12). Optional 9–36 V DC/DC (MOQ 10, 6–8 weeks lead) — **disables PoE+ input** on that variant |
| **PoE+ in** | IEEE **802.3at** |
| **USB-C** | **Power input** port |

**PoE passthrough rules:**

- **48–56 V** needed on PoE in **or** DC input to enable **PoE out**.
- 9–36 V variant: PoE+ input disconnected from board; PoE out only when 48–56 V on PoE in.

### 2.2 Power output

| Output | Fuse (auto-recover) |
|--------|---------------------|
| PoE+ out | 802.3at |
| Unregulated (max of 3 DC inputs) | 750 mA |
| 3× **15 V** | 125 mA each |
| 3× **5 V** | 250 mA each |
| 1× **3.3 V** | 1100 mA |

### 2.3 Communication ports

| Port | Count | Notes |
|------|-------|--------|
| RS232/RS485 | 3 | Tx & Rx only |
| CAN | 2 | |
| Gigabit Ethernet | 2 | PoE+ **in** and **out**, RJ45 |
| 100 Mbit LAN | 3 | **SM04B-GHS-TB** (bottom: J9, J10, J11) |
| WiFi | 2× U.FL | AP + client simultaneous |
| Bluetooth | 1 | |
| **UART** | **3** | **2×** output level **3.3 V or 5 V** (for **SBUS**); **all inputs** 3.3/5 V tolerant |
| I²C | 1 | External sensors |

### 2.4 Peripheral ports

| Type | Count |
|------|-------|
| Analog in 0–10 V | 4 (16-bit) |
| Analog in 4–20 mA | 2 (16-bit) |
| Analog out 0–10 V | 4 (16-bit) — maps to DAC/motor path in firmware |
| PWM in | 4 |
| PWM out | 4 (jumper **3.3 V / 5 V**) |
| GPIO | 2 (relays etc.) |
| Audio | 2 (line in/out; mic + headphones) — **VHF/Line drivers not yet made** per manual |

### 2.5 Processor / software / dimensions

**Pages 5–6 in PDF are diagram-only** — no extractable processor or software text in rev2.01.  
(Firmware in repo: STM32H757 dual-core CM4+CM7.)

---

## 3. IO connectors (physical map)

| Ref | Location | Purpose |
|-----|----------|---------|
| **J12** | Bottom board | Power input |
| **J3** | Top, **left** | Analog in, PWM in (see pin text below) |
| **J16** | Top, **right upper** | **Data** — UART / CAN / RS485 (pinout = **PDF diagram p.8**, not text) |
| **J14** | Top, **right lower** | **Motor** (pinout = **PDF diagram p.9**) |
| **J4** | — | **JTAG programming** (ST-Link/debug probe — not USB-C serial) |
| **J9, J10, J11** | Bottom | 100 Mbit Ethernet (same wiring; isolated transformers) |
| **PoE IN / OUT** | — | Gigabit, **802.3at**, wiring **code B** |
| **B2B extender** | Topside | Stack expansion (p.11 diagram only) |
| **USB-C** | — | **Power in** (per §2.1) |
| Audio jacks | — | VHF, Line (drivers N/Y in manual) |

### J3 pin text (extracted from manual p.7)

18-pin style layout (odd/even rows):

- **A IN 1** + **VCC 15V** (pins 1–2 area)
- **A IN 3** + **VCC 15V**
- **A IN 5** + **VCC 15V**
- **PWM IN 1, 2** + **GND**
- **A IN 2, 4, 6** each with **GND** (pairs 1&2, 3&4, 5&6)
- **PWM IN 3, 4**

*(Exact pin numbers — see PDF figure 4.3.)*

### J16 / J14 / layout / B2B

**No machine-readable pinout** in PDF — only images on pages 7–9 and 11. Open the PDF and zoom those figures for TX/RX/CAN assignments.

---

## 4. Ethernet detail (manual p.10)

**J9, J10, J11 (100 Mbit):** drone camera, drone RC, HDMI↔Ethernet converters; all three wired identically.

**PoE IN/OUT (GbE):**

- IEEE **802.3at-2009**, **25.5 W** in and out (when conditions met).
- PoE out requires PoE in powered **or** DC **44–56 V** on power connector.
- PoE-in-only power: out budget = 25.5 W − board + loads.
- Battery &lt; 44 V + need PoE out → external **≥ 30 W** DC/DC.

**Firmware tie-in:** CM7 LwIP + web UI; factory static IP often **10.0.1.30/24** (`how_to_use_network_mechanism.txt`).

---

## 5. Cross-reference — firmware vs hardware

| Topic | Hardware manual | MFCB firmware (repo) |
|-------|-----------------|----------------------|
| Debug / Customer UART text | 3× external UART (likely **J16**) | **CM7 → UART6**, **CM4 → UART7** @ **115200 8N1** |
| SBUS RC | 3× UART, 2× **5 V** capable for SBUS | Newer build: translator; UART preset; instance1→UART6 factory |
| USB-C | **Power only** | USB OTG **HS host** + USB **device audio** — **not** PC serial console |
| Program / debug | **J4 JTAG** | ST-Link + CubeIDE; not VCP on USB-C |
| Motor / rudder | **J14** analog outs | `DAC_OutputVoltage` / OPS devices |
| ROC / Ethernet | PoE GbE + 100M ports | `network_send`, web, IP channels |
| CAN | 2× CAN | FDCAN1/2 (newer build task API) |

---

## 6. Gaps and caveats

1. Manual is **preliminary**; processor/software sections empty in extractable text.
2. **J16/J14 pin tables** exist only as **graphics** — verify on bench + PDF zoom.
3. No explicit mapping **UART connector label ↔ STM32 UART6/7/1** in manual — infer from silkscreen + `stm32h757_pins.h` + web UART page.
4. Audio/VHF drivers **not yet made** (manual note).

---

## 7. Related repo docs

| Doc | Path |
|-----|------|
| This summary | `.cursor/Logs/reference-OPS-MFCB-hardware-manual-rev2.01.md` |
| Original PDF | `NewBoard/OPS-MFCB Hardware manual rev2.01.pdf` |
| UART / SBUS log | `.cursor/Logs/Log1-UART.md` |
| NewBoard knowledge graph | `.cursor/rules/newboard-knowledge-graph.mdc` |
| Core assignment | `NewBoard/MFCB_BASE/how_to_use_core_assignment.txt` |
| Debug UART | `NewBoard/MFCB_BASE/how_to_use_debug_mechanism.txt` |
