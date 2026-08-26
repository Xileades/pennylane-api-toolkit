---
name: pennylane-analysis
description: >-
  Query Pennylane read-only and produce work lists: uncategorised transactions,
  invoices without a justification, supplier and customer outstandings,
  consistency checks, comparisons across the group's entities, analytical
  categories. Use when the user wants to know "what is missing", "what does not
  add up", a status report, a work list, an accounting situation, or a
  spreadsheet extract.
  Load the pennylane-access skill first.
---

# Analysis and work lists

**Prerequisite: `pennylane-access`.**
Read scopes: `transactions:readonly`, `supplier_invoices:readonly`,
`customer_invoices:readonly`, `ledger_entries:readonly`, `categories:readonly`,
`trial_balance:readonly`.

**This skill writes nothing.** It produces findings and work lists. As soon as
action is needed, hand over to `pennylane-reconciliation`,
`pennylane-supplier-invoices` or `pennylane-customer-invoices`.

## 1. The structural constraint

**The API filters very little.** On transactions, only `id`, `bank_account_id`,
`journal_id` and `date` are filterable server-side — **not** amount, label,
counterparty, nor reconciliation state. On customer invoices, neither `paid` nor
`status`. On bank accounts, no filter at all.

Consequence: **fetch a date range, analyse in memory.** Hence:

- always bound by `date` — the only filter that meaningfully reduces volume;
- `limit` at 100 (1000 on `ledger_accounts`, `trial_balance`, changelogs);
- re-send `filter` on **every** page — `PLGetAll` does; by hand, the omission
  returns unfiltered results **with no error**;
- do not sweep all `ledger_entry_lines`: timeout risk. Initial export, then
  `GET /changelogs/ledger_entry_lines` differentially (**4-week retention**).

## 2. The reports most often needed

### Transactions to justify

```powershell
$tx = PLGetAll 'company-a' 'transactions' @(
  @{ field = 'date'; operator = 'gteq'; value = '2026-01-01' }
)
$tx | Where-Object { $_.attachment_required } |
  Select-Object date, label, currency_amount, outstanding_balance
```

`attachment_required = true` means "must be justified and matched to an
invoice". That is the right starting point for a work list.

### Unpaid purchase invoices

```powershell
PLGetAll 'company-a' 'supplier_invoices' @(
  @{ field = 'payment_status'; operator = 'in'; value = @('to_be_paid','partially_paid') }
)
```

`payment_status` **is** filterable on the supplier side (values:
`to_be_processed`, `to_be_paid`, `partially_paid`, `payment_error`,
`payment_scheduled`, `payment_in_progress`, `payment_emitted`, `payment_found`,
`paid_offline`, `fully_paid`). `reconciled` is not.

### Customer outstandings

Fetch the period, then sort in memory on `status` in `late`, `partially_paid`,
and on `remaining_amount_with_tax`.

### Consolidated group view

Loop over the entities that have API access, and **always label the entity in
the output**:

```powershell
$all = foreach ($c in @('company-a','company-b','holding')) {
  PLGetAll $c 'supplier_invoices' @(@{field='date';operator='gteq';value='2026-01-01'}) |
    ForEach-Object { $_ | Add-Member entity $c -PassThru }
}
```

An entity without API access must be named **explicitly as not covered** in any
consolidated report, rather than quietly disappearing. A group total that forgets
one is a wrong total.

## 3. Analytical categories

```powershell
$groups = PLGetAll 'company-a' 'category_groups'
$cats   = PLGetAll 'company-a' 'categories' @(
  @{ field = 'category_group_id'; operator = 'eq'; value = $gid }
)
```

Filters on `categories`: `id`, `label` (`start_with`, `eq`, `in`),
`category_group_id`, `analytical_code`. **`direction` (`cash_in`/`cash_out`) is
not filterable**, and there is no "type" filter. `category_groups` accepts no
filter at all.

An uncategorised resource shows an empty `categories` array.

## 4. Trial balance for a consistency check

For a coherence check, the trial balance is far cheaper than sweeping entries:

```powershell
$tb = PLGetAll 'company-a' 'trial_balance' $null $null 1000
```

Required: `period_start`, `period_end`. Note that `debits` and `credits` are
**gross, with no net balance**, and there is **no account id** — only `number`
and `formatted_number` (`512` → `51200000`).

For a full export destined to a third party, hand over to
`pennylane-accounting-exports`.

## 5. Reporting back

A report is judged on legibility, not exhaustiveness:

- **group by the action required**, not by API order: "to justify", "to match",
  "to investigate", "nothing to do";
- give counts and total amounts per bucket, so the user knows where the stake is
  before reading the lines;
- past thirty or so rows, produce a **spreadsheet** where the user actually keeps
  their work, rather than a table in the chat — it is a working file people tick
  off;
- **say what was not covered**: an entity without API access, a truncated period,
  a changelog beyond four weeks, records skipped for lack of a criterion. Silence
  about a gap reads as full coverage.

## 6. Pitfalls

- **`reconciled` does not exist on a transaction**, nor on a customer invoice.
  Reading `$tx.reconciled` returns `$null` — a report built on it is wrong and
  looks right.
- **`filter` not re-sent while paginating returns unfiltered results**, with no
  error. The leading cause of confidently wrong reports on this API.
- **404 means "does not exist" OR "belongs to another company".** On a
  multi-entity loop, do not conclude too fast.
- **Rate: 25 req / 5 s per token.** A multi-entity report over a year is a lot of
  pages: `PLThrottle` between calls, and warn the user if the extraction will
  take a while.
- **Changelogs: exactly 4 weeks of retention.** `start_date` together with
  `cursor` returns 400; a `start_date` older than four weeks returns 422.
- An unresolved case is reported on the Pennylane forum: lines present in
  `/changelogs/ledger_entry_lines` as `insert`, with no later `delete`, that
  cannot be found through `GET /ledger_entry_lines`. Handle the read failure
  rather than assuming consistency.
