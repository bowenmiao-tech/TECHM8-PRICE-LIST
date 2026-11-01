# Crazy Parts Monthly Repair Price Monitor

This tool logs into Crazy Parts, reads the account's member prices, and creates an internal Excel repair price list for the supported phone, Samsung tablet, iMac, and MacBook families.

## Pricing rule

```text
raw repair price = part price excluding GST × 1.10 + the repair-category labour charge
internal repair price = round the raw repair price up to the nearest $5
```

For every model and repair type, the workbook uses the lowest and highest eligible in-stock or low-stock part price. All genuine camera modules are combined into one camera range. Camera glass, lenses, frames, covers and protectors are excluded.

iMac keeps every available repair part, adds GST and $130 labour, then rounds up to the nearest $5. MacBook combines Macbook Pro, Macbook Air and Macbook under the `Apple MacBook` Admin brand; iMac uses `Apple iMac`. It keeps screens, speakers, batteries, charging ports, back covers and fans; keyboards are excluded. AMPLUS/AMP screens are `Aftermarket Screen`, BQ7 screens are `Premium Aftermarket Screen`, and PULL-A screens are `Original Screen`. MacBook screens add $150 labour and the other MacBook repairs add $120.

## Files

- `crazyparts-price-monitor.config.json` contains non-secret pricing and runtime settings.
- `scripts/crazyparts-price-monitor.mjs` performs the login, model discovery, scraping, classification and workbook build.
- `scripts/setup-crazyparts-credential.ps1` stores the login using Windows user encryption.
- `scripts/run-crazyparts-price-monitor.ps1` safely loads the encrypted login and starts the monitor.
- `scripts/sync-crazyparts-to-supabase.mjs` backs up the old values and verifies every write. A Series keeps its variant-aware matching; the supported replacement brands are rebuilt from a complete supplier run so stale models are removed.
- `scripts/install-crazyparts-daily-brand-tasks.ps1` creates the monthly Windows tasks. On day 3, HUAWEI finishes first and Apple Mac runs immediately afterward.
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

Supported scope: Samsung A Series and Tab A/Tab S, OPPO, HUAWEI, XIAOMI, REDMI, MOTOROLA, NOKIA, ONEPLUS, REALME, VIVO, SONY, iMac and MacBook. SONY game-console and generic category pages are excluded.

## Full manual update

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -All
```

The full run intentionally waits between pages and may take 30–60 minutes depending on the number of models on Crazy Parts.

## Install the monthly brand sequence

The default schedule starts the assigned work at 5:00 AM on each day from the 1st through the 11th:

```powershell
.\scripts\install-crazyparts-daily-brand-tasks.ps1
```

To choose a different start time for every brand:

```powershell
.\scripts\install-crazyparts-daily-brand-tasks.ps1 -StartTime '04:30'
```

The order is Samsung A Series, OPPO, HUAWEI followed by Apple Mac on day 3, XIAOMI, REDMI, MOTOROLA, NOKIA, ONEPLUS, REALME, VIVO and SONY. Each run publishes live progress to the Admin Portal, then backs up, replaces and verifies that brand before marking it complete. It runs under the same Windows user that owns the encrypted credential. If the computer is off or that user is signed out at the scheduled time, Windows is asked to run it as soon as possible after that user signs in again.

## Safety behaviour

Cloudflare verification pages (including Chinese `正在进行安全验证` / `请稍候`), HTTP errors and generic `www.crazyparts.com.au` model headings stop the run immediately. A page with product links but no readable member prices is an error. Empty catalogues must explicitly report no products. An all-empty run cannot replace either the workbook or live prices; publishing independently checks these conditions again.

If Crazy Parts requests human verification, run the updater in visible-browser mode:

```powershell
.\scripts\run-crazyparts-price-monitor.ps1 -Family 'A Series' -Headful -SyncSupabase
```

Complete verification in the browser window opened by this updater. It waits up to three minutes per verification page and then continues in the same session. Completing verification in an unrelated browser does not update the scraper's session. Verification is performed manually; scheduled background runs stop with an error while it is required.

`browserHeadless` defaults to `false` because Crazy Parts currently challenges windowless Chrome while standard Chrome completes the same requests. Admin requests and scheduled tasks therefore open a standard browser controlled entirely by the script. No manual product lookup is required. If the website presents a human verification, the script waits up to three minutes and fails safely if it remains unresolved. The computer must have an active signed-in Windows desktop. Setting `browserHeadless` to `true` restores windowless mode; `-Headful` always explicitly opens a browser.

Run the validation regression checks with `node scripts/test-crazyparts-page-validation.mjs`.

Product cards are identified by their product link, stock information and member tier, including out-of-stock cards that have no Add To Cart button. Out-of-stock products are read for completeness but remain excluded from repair price calculations. The loader waits for stable member prices and accepts the site's RRP, Retail Price (Ex. Tax), and Was reference-price labels. Available repair parts must have a verified member discount before they can be quoted; the initial retail-price placeholder is rejected. Temporary unreadable prices are retried before a model is marked failed. Captures record `priceValidationVersion: 2` and the sync step independently checks the member-price flags.

Verified model captures are checkpointed locally under `.runtime/checkpoints` for up to six hours. A failed capture can resume only with the same account, script version, settings and model selection. Completed captures clear their checkpoint after the workbook is saved. This requires no AI calls or tokens. Checkpoints contain supplier product information, not passwords.

Additional checks: `node scripts/test-crazyparts-product-cards.mjs` and `node scripts/test-crazyparts-checkpoint.mjs`.

- The script refuses to run unless `-All` or at least one `-Model` is provided.
- It verifies that the expected Diamond member tier is present after login.
- It never places orders or changes the Crazy Parts account.
- Products are eligible only when Sydney or Melbourne is `In Stock` or `Low Stock`.
- A run with more than 10% failed model pages does not replace the current workbook.
- A non-Samsung brand is never replaced unless every selected model page completed, the run was not model-limited, and at least one eligible repair price was produced for that brand.
- Source product names, prices, stock and URLs are retained in the workbook and raw history.
- Formula errors are scanned before the workbook is saved.
