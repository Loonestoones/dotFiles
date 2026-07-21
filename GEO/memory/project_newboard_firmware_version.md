---
name: project-newboard-firmware-version
description: User is running OLD firmware on the NewBoard/MFCB board — Newer_build_includes tree is not relevant to current debugging
metadata:
  type: project
---

The board Kevin is currently working with (NewBoard/MFCB_BASE, STM32H757 CM4/CM7) is running the **old firmware** — the actual deployed build under `MFCB_BASE/CM4` and `MFCB_BASE/CM7`.

The `Newer_build_includes/` directory in the same repo contains headers for a newer/future firmware version (e.g. SBUS translator support: `Page_sbus_translator.h`, `sbus_translator_config.h`, etc.) that is **not what's currently flashed/running** on his board.

**Why:** Kevin explicitly said "Remember i am on the old firmware, the newer build includes is not relevant atm" — this was said after discovering the SBUS Translator web UI page appears to be missing from his actual board's menu, while research had found SBUS-related headers partly under `Newer_build_includes`.

**How to apply:** When researching what features/pages/settings exist on his actual running board, scope searches to `MFCB_BASE/CM4/OPS_Lib` and `MFCB_BASE/CM7/OPS_Lib` only (and their web `Middleware/Website` trees) — exclude `Newer_build_includes` unless he says he's asking about the newer/future firmware specifically. A feature only present in `Newer_build_includes` does not exist on his current board's web UI, even if header files reference it elsewhere in the repo.

**Confirmed example (2026-07-02):** SBUS Translator (`Page_sbus_translator.h`, `sbus_translator_config.h`) exists ONLY in `Newer_build_includes` — zero SBUS-related files under `MFCB_BASE/CM4` or `MFCB_BASE/CM7`, and the old firmware's page registry (`pages_include.h`) doesn't reference it. Old firmware's `uart_config_t` has no protocol-preset concept at all (no SBUS/protocol enum) — only raw direction/word-length/framing/flags. `Newer_build_includes` also adds `Page_i2c.h`, `Page_spi.h`, and Drone application pages not present in old firmware — worth assuming other features found only in that tree are similarly absent from the deployed board unless verified against `MFCB_BASE` directly.
