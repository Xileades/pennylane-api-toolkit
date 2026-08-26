---
name: pennylane-reconciliation
description: >-
  Match bank transactions to invoices in Pennylane: find transactions lacking a
  justification and invoices left unpaid, propose pairings, apply the matching,
  and letter ledger entry lines. Use when the user talks about reconciliation,
  bank matching, transactions without an invoice, unmatched invoices, orphans,
  or "what is left to reconcile".
  Load the pennylane-access skill first.
---

# Reconciliation and lettering

**Prerequisite: `pennylane-access`.**
Scopes: `transactions:all`, `supplier_invoices:all`, `customer_invoices:all`,
plus `ledger_entries:all` for accounting lettering.

Two **distinct** mechanisms, routinely confused:

1. **Payment matching** — links a bank transaction to an invoice. This is what
   you want in 95 % of cases.
2. **Lettering** — groups ledger entry lines on a counterparty account. A lower,
   accounting-level operation.

## 1. Establish the picture

**There is no server-side filter on reconciliation state, amount or label of a
transaction.** The only filters are `id`, `bank_account_id`, `journal_id`,
`date`. Everything else happens in memory.

```powershell
$tx = PLGetAll 'company-a' 'transactions' @(
  @{ field = 'date'; operator = 'gteq'; value = '2026-01-01' }
)
$needsJustifying = $tx | Where-Object { $_.attachment_required }
```

On supplier invoices, `payment_status` **is** filterable:

```powershell
PLGetAll 'company-a' 'supplier_invoices' @(
  @{ field = 'payment_status'; operator = 'in'; value = @('to_be_paid','partially_paid') }
)
```

### Which field tells the truth

The documentation declares none authoritative. In practice:

| Question | Source |
|---|---|
| Which links exist? | `PLMatchesSupplier` / `PLMatchesCustomer` — the real list |
| How much is left to pay? | `remaining_amount_with_tax` on the invoice |
| Transaction balance? | `outstanding_balance` |
| Convenience flag | `reconciled` (**supplier invoice only**), `paid` |

**`reconciled` does NOT exist on a transaction**, nor on a customer invoice. Code
reading `$transaction.reconciled` gets `$null` — silently wrong. Rely on
`outstanding_balance` and on re-reading the links.

## 2. Propose the pairings

Do the matching **locally, writing nothing**: exact amount first, then a few
cents of tolerance, then date proximity, then label matching on the supplier
name.

Produce three buckets:
- **certain** — exact amount, coherent counterparty, plausible date;
- **to confirm** — one weak criterion (amount gap, ambiguous label);
- **orphans** — nothing facing them, to investigate another way.

**Submit the buckets before writing.** A wrong match is awkward to undo (§4).

## 3. Apply

```powershell
PLMatchSupplier 'company-a' $invoiceId $transactionId
PLThrottle
$check = PLMatchesSupplier 'company-a' $invoiceId   # mandatory re-read
```

Rules:
- **One link per request.** No batch, no rollback if the loop breaks — journal as
  you go.
- The response is **204 with no body**: no confirmation, no identifier.
  **Re-reading is the only proof.**
- 1 transaction ↔ N invoices and 1 invoice ↔ N transactions are both supported,
  one call at a time. **No partial amount can be declared** — Pennylane infers
  the allocation. A partial shows up afterwards in `remaining_amount_with_tax`
  and `payment_status: partially_paid`.
- **Forbidden on a draft** → 422. Check `draft` (customer) /
  `accounting_status` (supplier) first.
- An empty list on re-read does not prove failure: on a draft or archived
  invoice the read returns empty **with no error**.
- **404 can mean "not the same company"**, not only "does not exist". On a
  multi-entity batch, verify the company before concluding it is an error.
- Rate: ~4.5 req/s. A one-invoice-at-a-time batch saturates fast.

## 4. Undo a match

```powershell
PLUnmatchSupplier 'company-a' $invoiceId $matchId
```

**The documentation does not say whether `{id}` is the transaction id or a
distinct link id.** So: read `PLMatchesSupplier` first, test on **one** case,
confirm by re-reading that the link is gone, and only then run the batch. A wrong
`{id}` gives a 404 — or worse, silently unlinks nothing.

## 5. Auto-matching by reference (a separate mechanism)

`transaction_reference` set on an invoice triggers **asynchronous** matching on
Pennylane's side — not an API call, and not immediate.

```powershell
transaction_reference = @{
  banking_provider     = 'bank'    # bank | stripe | gocardless | budgetinsight
  provider_field_name  = 'label'   # label | payment_id | charge_id | report_id | webid
  provider_field_value = 'INV-2026-042'
}
```

For `bank` + `label`, the transaction matches if its label **contains** the
value. Leaving the fields empty disables the mechanism. Do not confuse it with
`matched_transactions`.

## 6. Accounting lettering

On counterparty accounts (`401xxx`, `411xxx`) whose `letterable` is true:

```powershell
$b = @{
  unbalanced_lettering_strategy = 'none'          # REQUIRED, no default
  ledger_entry_lines = @(@{id=3455}, @{id=3456})  # minimum 2
} | ConvertTo-Json -Depth 4
Invoke-RestMethod -Uri "https://app.pennylane.com/api/external/v2/ledger_entry_lines/lettering" `
  -Headers (PLHdr 'company-a') -Method Post -ContentType 'application/json' -Body $b
```

- `unbalanced_lettering_strategy`: `none` refuses an unbalanced lettering
  (422 "Entry lines are not balanced"); `partial` accepts it. **Choose
  explicitly** — there is no default value.
- **Lettering a line that is already lettered merges the groups.** The response
  contains every line of the new group, including ones you never sent. Check the
  return before concluding.
- **There is no lettering code (A/B/C) in v2.** Read group membership from
  `lettered_ledger_entry_lines.ids`, or
  `GET /ledger_entry_lines/{id}/lettered_ledger_entry_lines`. Build no logic on a
  letter.
- Unlettering: `DELETE /ledger_entry_lines/lettering`, with a **JSON body on a
  DELETE** (minimum 1 line, versus 2 for lettering). Some HTTP clients drop a
  DELETE body — verify the request goes out complete. The documentation is
  inconsistent about whether this endpoint exists: **test one case before
  relying on it.**

## 7. What not to do

- **Never archive a reconciled invoice** in the Pennylane UI: the reconciliation
  is lost and does not come back.
- Do not sweep all `ledger_entry_lines` regularly — timeout risk on large
  volumes. Initial export, then `GET /changelogs/ledger_entry_lines`
  differentially (**4-week retention**: beyond that, full resync).
- Do not forget to re-send `filter` on every page. Here the omission is
  especially costly: you believe you are processing one account's transactions,
  you are processing the whole company's.
