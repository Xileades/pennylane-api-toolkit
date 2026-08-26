---
name: pennylane-customer-invoices
description: >-
  Issue and manage sales invoices in Pennylane: create a draft or a finalised
  invoice, manage customers, quotes and products, send by email, raise a credit
  note, track unpaid invoices. Use when the user talks about invoicing a
  customer, a quote, a credit note, a sales invoice, chasing an unpaid invoice,
  or issuing an invoice.
  Load the pennylane-access skill first.
---

# Customer invoices (sales)

**Prerequisite: `pennylane-access`.**
Scopes: `customer_invoices:all`, `customers:all`, `quotes:all`, `products:all`.

Here you **issue** documents in the company's name. A finalised invoice goes to
the customer and enters the books. The rule is therefore: **create as a draft
whenever there is the slightest doubt**, have it validated, finalise after.

## 1. The customer first

In v2, **each object is created through its own endpoint**: a customer cannot be
created inline in an invoice payload.

```powershell
$base = 'https://app.pennylane.com/api/external/v2'
$hd = PLHdr 'company-a'
$customers = PLGetAll 'company-a' 'customers' @(
  @{ field = 'name'; operator = 'start_with'; value = 'ACME' }
)
```

**Major trap — company vs individual.** Two sets of endpoints:

| | Company | Individual |
|---|---|---|
| Create | `POST /company_customers` | `POST /individual_customers` |
| Update | `PUT /company_customers/{id}` | `PUT /individual_customers/{id}` |
| Own fields | `name`, `vat_number`, `reg_no` | `first_name`, `last_name` |

Calling the **wrong** endpoint **returns no error**: the request succeeds and
corrupts the record (permanent type conversion in the UI, empty display name in
accounting). The documentation's words are "could result in data corruption". So
**always read the type before an update** — the dedicated endpoints do not
return it:

```powershell
$c = Invoke-RestMethod -Uri "$base/customers/$id" -Headers $hd -Method Get
$c.customer_type    # "company" | "individual"
```

Creation — `billing_address` is **required**, with all four fields:

```powershell
$b = @{
  name = 'ACME Ltd'
  billing_address = @{
    address = '12 Paix Street'; postal_code = '75002'
    city = 'Paris'; country_alpha2 = 'FR'      # country_alpha2, NOT country
  }
} | ConvertTo-Json -Depth 4
Invoke-RestMethod -Uri "$base/company_customers" -Headers $hd -Method Post `
  -ContentType 'application/json' -Body $b
```

`payment_conditions` defaults to `30_days`. Others: `upon_receipt`, `7_days`,
`15_days`, `30_days_end_of_month`, `45_days`, `45_days_end_of_month`, `60_days`,
`custom`.

## 2. Create the invoice

```powershell
$b = @{
  customer_id = 123
  date        = '2026-09-01'
  deadline    = '2026-10-01'
  draft       = $true                   # draft: the default reflex
  invoice_lines = @(
    @{ label = 'Design services - phase 1'
       quantity = 1                     # a NUMBER, not a string
       unit = 'piece'
       raw_currency_unit_price = (PLNum 8500)
       vat_rate = 'FR_200' }
  )
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "$base/customer_invoices" -Headers $hd -Method Post `
  -ContentType 'application/json' -Body $b
```

Required: `date`, `deadline`, `customer_id`, `invoice_lines` (at least one).

**You send NO totals.** Pennylane computes net, VAT and gross from the lines. Do
not transpose the supplier-invoice import schema, which requires totals and
insists the lines sum to them.

Two line shapes:
- **on a product** — `product_id` + `quantity` suffice; label, price, unit, VAT
  and ledger account are inherited from the product and can be overridden per
  line;
- **free** — `label`, `quantity`, `raw_currency_unit_price`, `unit`, `vat_rate`.

`quantity` is a **number**: the only exception to the strings-for-amounts rule.
`raw_currency_unit_price` accepts up to 6 decimals.

`invoice_number` **cannot be set at creation** — numbering belongs to Pennylane.
It is settable only when importing an existing PDF.

`transaction_reference` and `imputation_dates` are **forbidden on a draft**:
sending them with `draft: true` fails validation.

Discount: `@{ type = 'absolute'|'relative'; value = (PLNum 10) }`, both fields
required, applied on the net.

Sections: `invoice_line_sections` with a unique integer `rank` **starting at 1,
incrementing by 1**; a line attaches through `section_rank`, not through an id.

## 3. Finalise, send, collect

```powershell
Invoke-RestMethod -Uri "$base/customer_invoices/$id/finalize" -Headers $hd -Method Put
```

**Finalisation is irreversible.** After it, only `label`,
`transaction_reference`, `external_reference` and the lines' `imputation_dates`
remain editable. `DELETE` works on **drafts only**: a finalised invoice is
cancelled with a credit note, not deleted.

```powershell
$b = @{ recipients = @('billing@acme.example') } | ConvertTo-Json   # optional
Invoke-RestMethod -Uri "$base/customer_invoices/$id/send_by_email" -Headers $hd `
  -Method Post -ContentType 'application/json' -Body $b
```

**409 means the PDF is still being generated** — common right after creation.
Not a failure: retry in a few minutes. Without `recipients`, the mail goes to the
customer's default addresses.

`PUT /customer_invoices/{id}/mark_as_paid` marks it paid **without reconciling
anything** — for a real match, see `pennylane-reconciliation`.

`public_file_url` **expires after 30 minutes**.

## 4. Credit notes

There is **no `/credit_notes` endpoint** in v2 — those sections were deprecated
in May 2025. A credit note is a customer invoice with `status = "credit_note"`,
created through `POST /customer_invoices` with negative amounts, then attached:

```powershell
$b = @{ credit_note_id = 42 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/customer_invoices/$invoiceId/link_credit_note" `
  -Headers $hd -Method Post -ContentType 'application/json' -Body $b
```

`credited_invoice_id` at creation appears in the changelog but is **absent from
the current schema**: use `link_credit_note`, which is verified.

## 5. Quotes

`POST /quotes` has the **same line schema** as invoices: required `date`,
`deadline`, `customer_id`, `invoice_lines`. No accounting `label`, no
`transaction_reference`.

`PUT /quotes/{id}/update_status` with `{status}`: `pending`, `accepted`,
`denied`, `expired`, `invoiced`. **The documentation lists no allowed or
forbidden transitions** — do not assume restrictions.

Conversion to an invoice: `POST /customer_invoices/create_from_quote`, with
`quote_id` **and `draft`** (boolean, required).

## 6. Modify a draft

`PUT /customer_invoices/{id}` — on a draft, `invoice_lines` becomes an
**object** `{create, update, delete}`, not an array. `update` and `delete`
require the line's `id`. A deletion fails if an associated cutoff has already
generated accounting events.

## 7. Tracking unpaid invoices

Useful fields: `status` (`paid`, `partially_paid`, `late`, `upcoming`, `draft`,
`credit_note`, `cancelled`…), `paid`, `remaining_amount_with_tax`.

**Neither `paid` nor `status` is filterable** server-side. Available filters:
`id`, `date`, `customer_id`, `invoice_number`, `draft`, `credit_note`,
`external_reference`, `quote_id`. Sorting unpaid invoices therefore happens in
memory.

## 8. Pitfalls

- **Company / individual endpoint swapped: no error, corrupted record.** Read
  `customer_type` before any update.
- **`country_alpha2`**, not `country` (the official example is wrong).
- **No totals at creation** — unlike the import.
- **Finalisation irreversible**; `DELETE` for drafts only.
- `PUT .../categories` **does not work on a draft**, and the weights within one
  group must sum to exactly 1 (7 decimals max).
- **409 on `send_by_email` means the PDF is not ready**, not a definitive error.
- `quantity` is a number, every other amount is a string.
- **No idempotency**: deduplicate on `external_reference` (unique — a duplicate
  returns 409).
- Down-payment invoices and delivery notes: **not supported by the API**.
