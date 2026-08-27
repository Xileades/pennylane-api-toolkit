---
name: pennylane-access
description: >-
  Foundation for the Pennylane Company API v2 in a multi-company setup: where
  tokens live, how to call the API, cursor pagination, filters, VAT codes,
  amount formatting, rate limits, and the behaviours that silently corrupt data.
  Use whenever a task touches Pennylane — invoice, transaction, reconciliation,
  export, ledger entry — and always before any other pennylane-* skill.
---

# Pennylane — access foundation

Every Pennylane task starts here. The skills `pennylane-supplier-invoices`,
`pennylane-customer-invoices`, `pennylane-reconciliation`,
`pennylane-accounting-exports` and `pennylane-analysis` assume this one is loaded.

Toolkit: <https://github.com/Xileades/pennylane-api-toolkit>

## 1. Load the library

```powershell
. <toolkit>\lib\pl-api.ps1
. <toolkit>\lib\journal.ps1     # only when a shared journal is in use
```

If the library sits on a network share, PowerShell's `RemoteSigned` policy will
refuse it ("is not digitally signed"). Copy it to a local cache and dot-source
the copy, refreshed at every run so it cannot drift:

```powershell
$c = "$env:USERPROFILE\.pennylane\scripts"
New-Item -ItemType Directory -Path $c -Force | Out-Null
Copy-Item '<share>\lib\*.ps1' $c -Force
. "$c\pl-api.ps1"
```

Do **not** work around this by setting the policy to `Bypass`: that disables the
protection machine-wide.

If `pl-api.ps1` throws "tokens.json not found", send the user to set it up from
`config/tokens.example.json`. Never guess a token, never reuse someone else's.

## 2. Companies and tokens

**A Pennylane Company API token is bound to exactly one company.** A group needs
one token per entity, kept in one file per person:

```
%USERPROFILE%\.pennylane\tokens.json        (override with PENNYLANE_HOME)
```

`PLEntites` lists the declared slugs. An entity with `"token": null` has no API
access — `PLHdr` throws an explicit error for it on purpose. Handle that entity
manually and **say so in the report**: a group total that silently drops an
entity is a wrong total.

Tokens are never displayed, never logged, never copied into a shared file or a
message.

Pre-flight before anything unusual — `GET /me` needs no scope:

```powershell
$m = PLMe 'company-a'
$m.company.name      # is this the company you think it is?
$m.scopes            # is the scope you need present?
```

A missing scope gives **403**, not 401. It cannot be retried: the token has to be
regenerated with the right scope.

## 3. Available helpers

| Function | Purpose |
|---|---|
| `PLHdr $c` | auth header for a company slug |
| `PLNum $v` | amount as a string with an invariant decimal point |
| `PLGetAll $c $path $filter $sort $limit` | fully paginated GET |
| `PLThrottle` | pause that respects the rate limit |
| `PLFindSup` / `PLNewSup` | find / create a supplier |
| `PLUpload $c $path` | file attachment → `file_attachment_id` |
| `PLImport $c $payload` | supplier invoice import |
| `PLMatchSupplier` / `PLMatchCustomer` | payment matching |
| `PLMatchesSupplier` / `PLMatchesCustomer` | re-read the matches |
| `PLUnmatchSupplier` / `PLUnmatchCustomer` | unmatch |
| `PLSetCategories` | analytical categories |
| `PLMe $c` | company + token scopes |

## 4. Six rules that prevent most failures

**a. Amounts are STRINGS with a DOT.** A JSON number gives 400. Both
`'{0:0.00}' -f` and `'{0:N2}'` follow the current culture: in `fr-FR` they yield
`1077,79` and `1 077,79`. **Always `PLNum`**, which forces `InvariantCulture`.
Never emit a thousands separator. The one exception: `quantity` on an invoice
line is a number.

**b. The pagination cursor does not remember filters.** `filter` and `sort` must
be re-sent **on every page**, otherwise you get **unfiltered** results from that
cursor position — with no error. `PLGetAll` handles it; hand-rolled pagination
must too. This is the most dangerous behaviour of this API: you believe you
processed one account's transactions, you processed all of them.

**c. No idempotency.** Two identical POSTs create two records. Deduplicate
client-side: a shared journal, `external_reference`, or the triple (party,
number, date). The one exception: re-importing a PDF already in the workspace is
refused — **409 or 422 depending on the doc page, both meaning "already there",
not a failure. Do not retry.**

**d. Rate limit: 25 requests / 5 s, per token.** Exceeding it gives 429 with
`retry-after`, `ratelimit-remaining` and `ratelimit-reset` (these headers also
come back on 2xx, so you can anticipate). `PLThrottle` holds ~4.5 req/s. A "one
invoice at a time" batch saturates quickly.

**e. Retry only 429, 500, 503.** 400, 401, 403, 404 and 422 mean the request must
change.

**f. `ledger_account_id`, never the account number.** The same number (`706000`)
exists under several ids depending on the VAT rate. Journal and account ids are
per-company: resolve them dynamically, never hard-code them.

## 5. VAT codes

`FR_200` (20 %), `FR_100` (10 %), **`FR_55`** (5.5 %), `FR_21` (2.1 %),
`FR_85` (8.5 %), `exempt` (0 % — reverse charge, intra-EU).

**`FR_055` does not exist.** The tutorial pages of the official documentation
print it; the OpenAPI schemas only know `FR_55`. The tutorials are wrong.

Also available: `FR_1_05`, `FR_1_75`, `FR_15_385`, `FR_196` (historic),
`*_construction` variants, `intracom_*`, `crossborder`, `extracom`, `mixed`, and
country codes (`DE_190`, `NL_210`, `GB_200`, `CH_77`…). `any` exists only on
ledger accounts, never on an invoice line.

## 6. Filters and pagination

`filter` — **singular** — is a URL-encoded JSON array of
`{field, operator, value}` objects, combined with AND. Operators: `eq`, `not_eq`,
`lt`, `lteq`, `gt`, `gteq`, `in`, `not_in` (array required), `start_with` (ILIKE).
Dates as `YYYY-MM-DD`.

**PS 5.1:** no `-AsArray`, and `ConvertTo-Json` unwraps a single-element array
(a bare hashtable serialises as an object). `PLGetAll` re-wraps the JSON when
needed; if you build `filter` by hand, check the string starts with `[` before
URL-encoding it.

Filterable fields **vary per endpoint** — check before assuming. Paginated
response: `{ items, has_more, next_cursor }`. `limit` defaults to 20, max 100
(1000 on `ledger_accounts`, `trial_balance`, changelogs).

## 7. File attachments

`POST /file_attachments`, multipart, field **`file`**, `filename` optional.
Accepted: PDF, PNG, JPEG, TIFF, BMP, GIF. Max **100 MB**. Scope
`file_attachments:all`. Returns the `id` to pass as `file_attachment_id`.
`POST /ledger_attachments` is **deprecated**.

## 8. Errors

Generic body `{error, message, details}` — but some pages return
`{status, error}` where `error` carries the text. Tolerate both.

| Code | Meaning | Reflex |
|---|---|---|
| 400 | invalid payload | fix it (often: a number where a string was required) |
| 401 | token missing or expired | regenerate |
| 403 | missing scope | regenerate with the right scope |
| 404 | not found **or belongs to another company** | check the company before concluding |
| 409 | conflict — PDF already imported | duplicate, not an error |
| 422 | business rule violated | totals mismatch, unbalanced lines, draft not allowed |
| 429 | rate limited | honour `retry-after` |

## 9. What the API cannot do

- **No DELETE or PATCH on a supplier invoice.** Deduplication and archiving
  happen in the Pennylane UI. **Never archive a reconciled invoice** — the
  reconciliation is lost and does not come back.
- No deletion of a ledger entry (line by line only).
- No creation or modification of a fiscal year.
- No down-payment invoices, no delivery notes.
- Webhooks: three events only, none on transactions. To track changes use the
  `changelogs/*` endpoints — **4-week retention**.

## 10. Discipline

Every write touches a real company's books. So: summarise and **wait for
validation before the first write of a batch**; test **one** case before the
batch; re-read after writing whenever the response is a `204` with no body; and
when in doubt about the company, the counterparty or an amount, **ask**.
