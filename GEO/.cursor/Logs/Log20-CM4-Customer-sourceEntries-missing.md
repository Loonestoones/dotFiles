# Log20 — CM4 Customer not in CubeIDE sourceEntries

**Date:** 2026-07-17  
**Tree:** `NewBoard/Rewrite/MFCB_BASE/CM4`  
**Status:** Fixed (will recur if `.cproject` is regenerated / copied without Customer)

## Symptom

Linker errors when building CM4 Debug:

```
undefined reference to `CustomerTask_Init'
undefined reference to `Customer_ICC_HandlePacket_NO_ID'
undefined reference to `Customer_ICC_HandlePacket_WITH_ID'
… Unknown destination type (ARM/Thumb) … dangerous relocation …
```

Sources existed under `CM4/Customer/` (including the three symbols in `Customer.c`). Include path already had `${workspace_loc:/${ProjName}/Customer}`. There was **no** `Debug/Customer/` build output.

## Root cause

`CM4/.cproject` `sourceEntries` listed Common, Core, Drivers, FATFS, LWIP, Middlewares — **not** `Customer`.

CM7 Rewrite and non-Rewrite `NewBoard/MFCB_BASE/CM4` already had `Customer` in `sourceEntries`.

## Fix applied

Added to Debug and Release `sourceEntries`:

```xml
<entry flags="VALUE_WORKSPACE_PATH|RESOLVED" kind="sourcePath" name="Customer"/>
```

User: Clean + Build in CubeIDE so makefiles regenerate.

## Recurrence notes

- CubeMX / project re-import / copying `.cproject` from a template without Customer can drop the entry again.
- Include path alone does not compile the folder.
- Agent memory: `.cursor/rules/cm4-customer-sourceentries.mdc`
