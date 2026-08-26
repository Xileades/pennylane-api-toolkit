---
name: pennylane-accounting-exports
description: >-
  Produce Pennylane accounting exports for an accountant or an audit: FEC
  (French fiscal export), general ledger, analytical general ledger, trial
  balance, and reading fiscal years. Use when the user asks for a FEC, a general
  ledger, a trial balance, an export for the accountant, closing a fiscal year,
  or "get me the accounts for that period".
  Load the pennylane-access skill first.
---

# Accounting exports

**Prerequisite: `pennylane-access`.**
Scopes: `exports:fec`, `exports:gl`, `exports:agl`, `trial_balance:readonly`,
`fiscal_years:readonly`.

## 1. Always start with the fiscal year

Exports take **a date range, never a fiscal year id**. So read the year first:

```powershell
$fy = PLGetAll 'company-a' 'fiscal_years' $null '-start'
$fy | Select-Object id, start, finish, status
```

`status`: `open`, `reopen`, `closed`, `frozen`. There is **no "current fiscal
year" endpoint and no server-side filter on status**: the selection happens in
memory. **Several years can be open at once** (`open` + `reopen`) — do not assume
uniqueness, and confirm with the user when it is ambiguous.

## 2. The three exports

Same model for all three: **create a job, poll, then download**. Not a
synchronous download.

| Export | Create | Poll | Scope | Format |
|---|---|---|---|---|
| FEC | `POST /exports/fecs` | `GET /exports/fecs/{id}` | `exports:fec` | undocumented |
| General ledger | `POST /exports/general_ledgers` | `GET /exports/general_ledgers/{id}` | `exports:gl` | xlsx |
| Analytical general ledger | `POST /exports/analytical_general_ledgers` | `GET /.../{id}` | `exports:agl` | xlsx |

```powershell
$base = 'https://app.pennylane.com/api/external/v2'
$hd   = PLHdr 'company-a'
$b    = @{ period_start = '2026-01-01'; period_end = '2026-12-31' } | ConvertTo-Json

$job = Invoke-RestMethod -Uri "$base/exports/fecs" -Headers $hd `
         -Method Post -ContentType 'application/json' -Body $b

do {
  Start-Sleep -Seconds 5
  $st = Invoke-RestMethod -Uri "$base/exports/fecs/$($job.id)" -Headers $hd -Method Get
} while ($st.status -eq 'pending')

if ($st.status -eq 'error') { throw "Export failed" }
Invoke-WebRequest -Uri $st.file_url -OutFile $out   # IMMEDIATELY
```

- `period_start` and `period_end` are **required** everywhere, `YYYY-MM-DD`. No
  other field is accepted (`additionalProperties: false`).
- `status` is `pending` | `ready` | `error`. `file_url` stays `null` until ready.
- **`file_url` expires after 30 minutes.** Download at once; never store the URL.
- The analytical general ledger also accepts `mode`: `in_line` (default) or
  `in_column`. Ask which if the use is not obvious — the column form reads better
  in a spreadsheet.
- Neither the FEC format, nor generation time, nor a recommended polling interval
  is documented. Poll under the rate limit (25 req / 5 s); 5 seconds is prudent.

## 3. Trial balance

```powershell
$tb = PLGetAll 'company-a' 'trial_balance' $null $null 1000
```

**Required**: `period_start`, `period_end`. Optional: `is_auxiliary`. `limit` up
to **1000**. No `filter`, no `sort`.

Per line: `number`, `formatted_number`, `label`, `debits`, `credits`.

- **No net balance**: `debits` and `credits` are gross, the subtraction is yours.
- **No account id** in the response — only numbers. `formatted_number` is the
  padded number (`512` → `51200000`), useful to reconcile a short number against
  a formatted account.

## 4. Chart of accounts and journals

```powershell
$accounts = PLGetAll 'company-a' 'ledger_accounts' @(
  @{ field = 'number'; operator = 'start_with'; value = '401' }
) $null 1000
$journals = PLGetAll 'company-a' 'journals'
```

**The same account number exists under several ids**, one per VAT rate (`706000`
at 20 %, 10 %, 5.5 %, exempt). Always work with ids, never numbers, and resolve
them dynamically: they are per-company.

**Watch out**: creating an account starting with `401` or `411` also creates a
supplier or a customer record. Not undoable through the API.

## 5. Delivering

Exports are files destined for a third party (accountant, audit). So:

- name them explicitly: `FEC_CompanyA_2026-01-01_2026-12-31.txt`;
- write them where the user actually keeps their work, not into a temp folder;
- **one entity per file** — never merge two companies into one export, that is an
  accounting error;
- state the period and the entity when handing it over, so the user can check
  before forwarding it.

## 6. Entities without API access

An entity on a plan without API access has no token. Its exports are retrieved
**manually** from the web interface. Never attempt an API call on it: `PLHdr`
raises an explicit error on purpose. Say clearly, in any consolidated delivery,
that this entity is not covered.

## 7. Pitfalls

- **Exports by date range, not by fiscal year** — read `fiscal_years` first.
- **`file_url`: 30 minutes.**
- **`exports:gl`** appears on the general-ledger endpoint pages but is absent
  from the scopes documentation page. If a 403 lands there, that is the likely
  cause: check with `PLMe` before looking elsewhere.
- The trial balance gives no net balance and no account id.
- **No duplicate protection**: re-running an export creates a new job. Harmless
  for the books, but it consumes rate limit.
- Since the 2026 API changes, filtering and sorting on `created_at` /
  `updated_at` were **removed** from accounting endpoints: sort on `id` or
  `date`. Default sort is now **descending** on journals, accounts and lines.
