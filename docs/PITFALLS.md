# Pitfalls — Pennylane Company API v2

Every entry below was paid for, either in production or in a long debugging
session. Ordered roughly by how much damage it does.

Entries tagged **UNVERIFIED** are behaviours the official documentation does not
specify and that were inferred. Confirming or refuting one is a genuinely useful
contribution.

---

## 1. Amounts silently corrupted by locale

**Symptom.** Imports are rejected with `400`, or worse, accepted with wrong
values. `1077.79` becomes `1077,79` or `1 077,79`.

**Cause.** Monetary values must be **strings with a dot**. Both
`'{0:0.00}' -f $v` and `'{0:N2}' -f $v` follow the *current culture*. In `fr-FR`
that means a comma, and `N2` adds a non-breaking space as thousands separator.
Strip the comma to "fix" it and `1077,79` becomes `107779` — a hundredfold error
that looks like a plausible number.

**Fix.** Force the invariant culture, always:

```powershell
([double]$v).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
```

`PLNum` in `lib/pl-api.ps1` does exactly this. Print one sample before any
batch import. Never emit a thousands separator.

**Exception.** `quantity` on an invoice line is a **number**, not a string. It
is the only one.

---

## 2. The pagination cursor forgets your filters

**Symptom.** A query returns the right rows on page 1 and the whole table from
page 2 onwards. No error, no warning. You believe you processed one bank
account's transactions; you processed every transaction in the company.

**Cause.** The cursor encodes a position, not a query. `filter` and `sort` must
be re-sent **on every request**.

**Fix.** Re-send them each page, or use `PLGetAll`, which does. This is the most
dangerous behaviour of this API precisely because it fails silently.

---

## 3. `reconciled` does not exist on a transaction

**Symptom.** Reconciliation reports look correct and are wrong.
`$transaction.reconciled` evaluates to `$null`, which is falsy, so everything
appears unreconciled — or, with inverted logic, everything appears fine.

**Cause.** `reconciled` exists on a **supplier invoice** only. Neither the
transaction object nor the customer invoice has it.

**Fix.** Decide what you actually need:

| Question | Field to read |
|---|---|
| Which links exist? | `GET /{supplier,customer}_invoices/{id}/matched_transactions` |
| How much is left to pay? | `remaining_amount_with_tax` on the invoice |
| Transaction balance? | `outstanding_balance` |
| Payment state (supplier) | `payment_status`, `reconciled`, `paid` |

The documentation never declares any field authoritative. The list of links is
the only ground truth for "is it matched".

---

## 4. The VAT code for 5.5 % is `FR_55`, not `FR_055`

**Symptom.** `422` on an otherwise valid invoice line.

**Cause.** The tutorial pages of the official documentation print `FR_055`. The
OpenAPI schemas — which carry the actual enum — only know `FR_55`. The tutorials
are wrong.

**Reference.** French rates: `FR_1_05`, `FR_1_75`, `FR_09`, `FR_21`, `FR_40`,
`FR_50`, `FR_55`, `FR_60`, `FR_65`, `FR_85`, `FR_92`, `FR_100`, `FR_130`,
`FR_15_385`, `FR_160`, `FR_196`, `FR_200`. Construction variants exist
(`FR_85_construction`, `FR_100_construction`, `FR_200_construction`). Non-country
values: `exempt`, `intracom_21`, `intracom_55`, `intracom_85`, `intracom_100`,
`crossborder`, `extracom`, `mixed`. Country codes follow `XX_<rate>`
(`DE_190`, `NL_210`, `GB_200`, `CH_77`, …). `any` exists **only** on ledger
accounts, never on an invoice line.

The integers are tenths of a percentage point: `FR_200` = 20 %, `FR_85` = 8.5 %,
`FR_21` = 2.1 %. The `X_YYY` form is a decimal: `FR_1_05` = 1.05 %,
`FR_15_385` = 15.385 %.

---

## 5. No idempotency anywhere

**Symptom.** A retried script creates duplicate invoices or duplicate ledger
entries.

**Cause.** The API enforces no idempotency on creation endpoints and offers no
idempotency key. Two identical POSTs create two records.

**Fix.** Deduplicate client-side. Options, best first:

- `external_reference` — unique per resource; a duplicate returns `409`;
- a stable triple (party, document number, date);
- for imports, the `file_attachment_id`.

**The one server-side guard** is the PDF: re-importing an invoice whose
`file_attachment_id` is already present in the workspace is refused. The status
code differs by documentation page — `409 Conflict` on the error-handling page,
`422` on the supplier-invoicing page. **Treat both as "already there", not as a
failure, and do not retry.**

---

## 6. Only `429`, `500` and `503` are worth retrying

**Symptom.** A retry loop hammers the API on a `422` that will never succeed,
and burns the rate limit.

**Cause.** `400`, `401`, `403`, `404` and `422` mean the request itself must
change.

**Fix.** Rate limit is **25 requests / 5 seconds, per token**, on all endpoints,
in production and sandbox alike. On `429`, honour `retry-after`. The headers
`ratelimit-limit`, `ratelimit-remaining` and `ratelimit-reset` are returned on
successful responses too, so you can throttle proactively. A "one invoice at a
time" batch saturates the limit quickly.

---

## 7. `403` means a missing scope, not a bad token

**Symptom.** `403 Forbidden` on an endpoint that works elsewhere.

**Cause.** The token is valid but lacks the scope. `401` is the bad-token case.

**Fix.** `GET /me` requires no scope and returns the token's company and its
scope list. Check it before diagnosing anything else:

```powershell
$me = PLMe 'company-a'
$me.company.name
$me.scopes
```

Scopes follow `<resource>:readonly` or `<resource>:all`. Note that `exports:gl`
appears on the General Ledger endpoint pages but is **absent from the scopes
documentation page** — if a `403` lands there, that is the likely reason.
The monolithic `ledger` scope is deprecated.

---

## 8. `404` can mean "another company"

**Symptom.** A matching call fails with `404` on ids you just read successfully.

**Cause.** The documentation is explicit: `404` covers both "does not exist" and
"not accessible to this token". With one token per company, an id from company A
used against company B's token returns `404`.

**Fix.** On multi-entity batches, label every object with its company and assert
the pair before writing.

---

## 9. `204 No Content` confirms nothing

**Symptom.** A matching loop reports success; nothing is matched.

**Cause.** `POST .../matched_transactions` and its `DELETE` return `204` with no
body and no link identifier.

**Fix.** Re-read `GET .../matched_transactions` after writing. And beware the
inverse trap: on a **draft or archived** invoice that read returns an **empty
list with no error**, so an empty list does not prove the write failed. Check
`draft` / `accounting_status` / `archived_at` first. Matching a draft invoice
returns `422`.

---

## 10. Customer type: the wrong endpoint corrupts the record silently

**Symptom.** A customer record shows an empty display name in accounting, or a
company appears as an individual.

**Cause.** Companies and individuals have separate endpoints
(`/company_customers` vs `/individual_customers`) with mutually exclusive fields
(`name`, `vat_number`, `reg_no` vs `first_name`, `last_name`). Calling the wrong
one **returns no error**: the request succeeds and writes inappropriate fields.
The documentation's own words are "could result in data corruption". Saving in
the UI afterwards forces a permanent type conversion.

**Fix.** Read the type before any update — the dedicated endpoints do not return
it:

```powershell
$c = Invoke-RestMethod -Uri "$base/customers/$id" -Headers $hd -Method Get
$c.customer_type    # "company" | "individual"
```

Also: addresses use `country_alpha2`, not `country`. The example in the official
guide is wrong.

---

## 11. Create and import have different contracts

**Symptom.** `422` with a totals mismatch, or totals that come out at zero.

**Cause.** Two different schemas that look alike:

- `POST /customer_invoices` — you send **no totals at all**. Pennylane computes
  them from the lines.
- `POST /{customer,supplier}_invoices/import` — totals are **required**, and the
  sum of the lines' `currency_amount` **must equal** the total, else `422`.

**Fix.** Do not transpose one payload shape onto the other.

Related asymmetry: on `PUT`, `invoice_lines` becomes an **object**
`{create, update, delete}`, not an array. Same for `ledger_entry_lines`. Classic
serialisation trap.

---

## 12. Finalisation is irreversible

**Symptom.** A wrong customer invoice cannot be corrected.

**Cause.** After `PUT /customer_invoices/{id}/finalize`, only `label`,
`transaction_reference`, `external_reference` and the lines' `imputation_dates`
remain editable. `DELETE` works on **drafts only**.

**Fix.** Create as draft whenever there is any doubt, have it validated, finalise
after. A finalised invoice is cancelled with a credit note, not a delete.

There is no `/credit_notes` endpoint in v2 — those sections were deprecated in
May 2025. A credit note is a customer invoice with negative amounts, attached
afterwards via `POST /customer_invoices/{id}/link_credit_note`.
(`credited_invoice_id` at creation appears in the changelog but is **absent from
the current schema** — **UNVERIFIED**.)

Supplier invoices have no `DELETE` or `PATCH` at all: deduplication and
archiving happen in the Pennylane UI. **Never archive a reconciled invoice** —
the reconciliation is lost and does not come back.

---

## 13. `409` on send-by-email is a timing issue

**Symptom.** `409 Conflict` when emailing an invoice created seconds earlier.

**Cause.** The PDF is still being generated.

**Fix.** Retry after a few minutes. Not a definitive error. Relatedly,
`public_file_url` **expires after 30 minutes**, as do the download URLs of the
FEC, general ledger and analytical general ledger exports — download immediately,
never store the URL.

---

## 14. Ledger account numbers are not unique

**Symptom.** An entry lands on the wrong account even though the number is right.

**Cause.** The same `number` (say `706000`) exists under **several ids**,
one per VAT configuration (20 %, 10 %, 5.5 %, exempt).

**Fix.** Always work with `ledger_account_id`, resolved dynamically. Journal and
account ids are per-company: never hard-code them.

**Side effect worth knowing.** Creating an account whose number starts with `401`
or `411` also creates a supplier or a customer record. Not undoable through the
API.

---

## 15. Ledger entries must balance; lettering has no letter

**Symptom.** `422 "Entry lines are not balanced"`.

**Cause.** Debits must equal credits, including after the combined
`create`/`update`/`delete` of a `PUT`.

**Also.** `POST /ledger_entry_lines/lettering` requires
`unbalanced_lettering_strategy` — there is **no default**. `none` refuses an
unbalanced lettering; `partial` accepts it. Lettering a line that is already
lettered **merges the groups**, and the response contains lines you never sent.

**There is no lettering code (A/B/C…) in v2.** Group membership is read from
`lettered_ledger_entry_lines.ids`. Build no logic on a letter.

Unlettering (`DELETE /ledger_entry_lines/lettering`) requires a **JSON body on a
DELETE**, which some HTTP clients drop silently. Documentation is inconsistent
about whether this endpoint exists — **UNVERIFIED**, test on one case first.

The order of returned lines is **not guaranteed** to match the request. Pair by
content, never by index.

---

## 16. Exports are jobs, not downloads

**Symptom.** The response contains no file.

**Cause.** FEC, general ledger and analytical general ledger are asynchronous:
`POST` creates a job, you poll `GET .../{id}` until `status` is `ready`, then
fetch `file_url`.

**Also.** Exports take a **date range**, never a fiscal year id. Read
`GET /fiscal_years` first — and note there is no "current fiscal year" endpoint
and no server-side filter on `status`, so the selection happens client-side.
**Several fiscal years can be open at once** (`open` + `reopen`): do not assume
uniqueness.

The trial balance returns `debits` and `credits` **gross, with no net balance**,
and **no account id** — only `number` and `formatted_number` (`512` →
`51200000`).

---

## 17. Change tracking has a hard 4-week window

**Symptom.** An integration stopped for a month can never catch up.

**Cause.** `GET /changelogs/*` retains events for **4 weeks exactly**. Passing
`start_date` and `cursor` together returns `400`; a `start_date` older than four
weeks returns `422`.

**Fix.** Initial full export, then differential polling. Beyond four weeks of
downtime, re-export fully.

Webhooks are not a substitute: only three events exist
(`customer_invoice.e_invoicing_status_updated`, `dms_file.created`,
`supplier_invoice.e_invoicing_received`) and **none covers transactions**.

**Open issue.** Lines reported as `insert` in
`/changelogs/ledger_entry_lines`, with no later `delete`, have been observed to
be unreachable via `GET /ledger_entry_lines`. Reported on the Pennylane forum,
no official answer. Handle the read failure rather than assuming consistency.

---

## 18. The API filters much less than you expect

**Symptom.** You cannot query what you need, so you write a filter that is
silently ignored.

**Cause.** Filterable fields vary per endpoint and are often minimal:

| Resource | Filterable |
|---|---|
| `transactions` | `id`, `bank_account_id`, `journal_id`, `date` — **not** amount, label, party, or reconciliation state |
| `customer_invoices` | `id`, `date`, `customer_id`, `invoice_number`, `draft`, `credit_note`, `external_reference`, `quote_id` — **not** `paid`, **not** `status` |
| `supplier_invoices` | `payment_status` **is** filterable; `reconciled` is not |
| `bank_accounts` | no `filter` parameter at all |
| `categories` | `id`, `label`, `category_group_id`, `analytical_code` — **not** `direction` |
| `ledger_entries` | `id`, `date`, `journal_id` only |

**Fix.** Bound by `date` — usually the only filter that meaningfully reduces
volume — and analyse in memory. Do not sweep all `ledger_entry_lines` regularly:
the documentation warns of timeouts on large volumes.

Since the 2026 API changes, filtering and sorting on `created_at` / `updated_at`
were **removed** from ledger endpoints, and default sort flipped to
**descending** on journals, accounts and lines.

---

## 19. PowerShell 5.1: script encoding

**Symptom.** `The string is missing the terminator: "` on a script that looks
perfectly fine.

**Cause.** A `.ps1` saved as **UTF-8 without BOM** is read as ANSI by
PowerShell 5.1. Accented characters and em dashes then break the parser.

**Fix.** Either save `.ps1` files as **UTF-8 with BOM**, or keep them **pure
ASCII**. The files in `lib/` are pure ASCII on purpose, so their encoding cannot
matter.

---

## 20. PowerShell 5.1: execution policy on network shares

**Symptom.** `File ... is not digitally signed. You cannot run this script on the
current system.` — for a script that runs fine from a local folder.

**Cause.** `RemoteSigned` treats an unsigned `.ps1` on a mapped network drive or
UNC path as remote, and refuses it.

**Fix, in order of preference:**

1. copy the library to a local cache and dot-source that copy — a share stays the
   source of truth, the local copy is a disposable cache refreshed with
   `Copy-Item -Force` at every run;
2. add the hosting server to the **Local intranet** zone (deployable by policy);
3. sign the scripts with an internal code-signing certificate.

**Do not** set the policy to `Bypass`: that disables the protection for the whole
machine, not for that folder.

---

## 21. PowerShell 5.1: single-element arrays in JSON

**Symptom.** A one-element `filter` is serialised as an object instead of an
array, and the API ignores or rejects it.

**Cause.** `ConvertTo-Json` unwraps single-element arrays and PowerShell 5.1 has
no `-AsArray`.

**Fix.** Test the serialised JSON itself and wrap when it does not start with
`[`, as `PLGetAll` does:

```powershell
$json = $filter | ConvertTo-Json -Depth 5 -Compress
if ($json -notmatch '^\s*\[') { $json = "[$json]" }
```

Testing `$filter.Count -eq 1` is **not** enough: on a bare hashtable, `Count`
returns the number of *keys*, so a single filter passed without `@(...)` slips
through unwrapped.

---

## 22. Outlook COM: the French date trap

**Symptom.** `Items.Restrict("[ReceivedTime] >= '...'")` returns **zero items**
from an obviously active mailbox. No error.

**Cause.** `Restrict` parses the date string with the **system locale**. In
French that is `DD/MM/YYYY`. Write `'06/12/2026'` meaning 6 December and it is
read as 12 June — or, worse, a future date, which matches nothing.

**Fix.** Format explicitly and **log the number of items scanned**:

```powershell
$flt = "[ReceivedTime] >= '" + ([datetime]$since).ToString('dd/MM/yyyy HH:mm') + "'"
```

A count of zero on an active mailbox is a date-format bug, never an absence of
mail. `lib/outlook-extract.ps1` logs the count for this reason.

Related: use `New-Object -ComObject Outlook.Application` followed by
`$ns.Logon()`. `GetActiveObject` and `GetDefaultFolder` can return empty stores.

Related too: with many delegated mailboxes, `$ns.Stores` is walked in an
arbitrary enumeration order — a run can spend its whole time budget on the
wrong mailboxes before reaching the one that matters. `lib/outlook-extract.ps1`
takes `-Store` (alias `-Boite`) to restrict the scan, and logs the scanned-item
count **per store** as well as the total.

---

## 23. Discipline that actually pays

Not API quirks, but the habits that prevented the remaining incidents:

- **Check the existing invoice before importing.** Pennylane creates invoices on
  its own from email extraction and bank feeds. Compare number, amount and date
  first; a duplicate is a reconciliation problem, not an import problem.
- **Summarise a batch and wait for a human before the first write.**
- **Test one case before the batch**, especially anything with a `DELETE`.
- **Move mail, never delete it.**
- **One entity per output file.** Never merge two companies into one export.
- **Say what was not covered** — an entity without API access, a truncated
  period, records skipped for lack of a criterion. Silence about a gap reads as
  full coverage.
