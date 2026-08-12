# Crazy Parts Monthly Repair Price Monitor

This tool logs into Crazy Parts, reads the account's member prices, keeps only screens, batteries, charging ports and camera modules, and creates an internal Excel repair price list.

## Pricing rule

```text
raw repair price = part price excluding GST × 1.10 + 110
internal repair price = round the raw repair price up to the nearest $5
```

For every model and repair type, the workbook uses the lowest and highest eligible in-stock or low-stock part price. All genuine camera modules are combined into one camera range. Camera glass, lenses, frames, covers and protectors are excluded.

## Files

- `crazyparts-price-monitor.config.json` contains non-secret pricing and runtime settings.
- `scripts/crazyparts-price-monitor.mjs` performs the login, model discovery, scraping, classification and workbook build.
- `scripts/setup-crazyparts-credential.ps1` stores the login using Windows user encryption.
- `scripts/run-crazyparts-price-monitor.ps1` safely loads the encrypted login and starts the monitor.
- `scripts/sync-crazyparts-to-supabase.mjs` backs up the old values, updates only the four approved repair categories, and verifies every write. A Series keeps its variant-aware matching; the supported non-Samsung brands are fully replaced from a complete supplier run so stale models are removed.
- `scripts/install-crazyparts-daily-brand-tasks.ps1` creates eleven monthly Windows tasks: one brand per day from the 1st to the 11th.
- `outputs/crazyparts-price-monitor/TECHM8_CrazyParts_Repair_Prices.xlsx` is the current internal workbook.
- `outputs/crazyparts-price-monitor/history/` keeps raw JSON history for auditing and recovery.

Credentials and generated price outputs are ignored by Git.

## First-time credential setup

From PowerShell in the project directory:

```powershell
.\scripts\setup-crazyparts-credential.ps1
```

The password is requested as a hidden secure input and is never stored in source code. The encrypted credential can only be decrypted by the same Windows user on the same computer.

## Controlled model test

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -Model 'a17-5g-(a176)'
```

## Run one model family

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -Family 'A Series'
```

Run the A Series update and sync matched prices to the website Admin database:

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -Family 'A Series' -SyncSupabase
```

Run every supported phone brand and sync the verified result:

```powershell
.\scripts\run-crazyparts-supported-brands.ps1 -Concurrency 1
```

Supported scope: Samsung A Series, OPPO, HUAWEI, XIAOMI, REDMI, MOTOROLA, NOKIA, ONEPLUS, REALME, VIVO and SONY. SONY game-console and generic category pages are excluded.

## Full manual update

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -All
```

The full run intentionally waits between pages and may take 30–60 minutes depending on the number of models on Crazy Parts.

## Install the monthly brand sequence

The default schedule runs one brand at 5:00 AM on each day from the 1st through the 11th:

```powershell
.\scripts\install-crazyparts-daily-brand-tasks.ps1
```

To choose a different start time for every brand:

```powershell
.\scripts\install-crazyparts-daily-brand-tasks.ps1 -StartTime '04:30'
```

The order is Samsung A Series, OPPO, HUAWEI, XIAOMI, REDMI, MOTOROLA, NOKIA, ONEPLUS, REALME, VIVO and SONY. Each run publishes live progress to the Admin Portal, then backs up, replaces and verifies that brand before marking it complete. It runs under the same Windows user that owns the encrypted credential. If the computer is off or that user is signed out at the scheduled time, Windows is asked to run it as soon as possible after that user signs in again.

## Safety behaviour

- The script refuses to run unless `-All` or at least one `-Model` is provided.
- It verifies that the expected Diamond member tier is present after login.
- It never places orders or changes the Crazy Parts account.
- Products are eligible only when Sydney or Melbourne is `In Stock` or `Low Stock`.
- A run with more than 10% failed model pages does not replace the current workbook.
- A non-Samsung brand is never replaced unless every selected model page completed, the run was not model-limited, and at least one eligible repair price was produced for that brand.
- Source product names, prices, stock and URLs are retained in the workbook and raw history.
- Formula errors are scanned before the workbook is saved.
