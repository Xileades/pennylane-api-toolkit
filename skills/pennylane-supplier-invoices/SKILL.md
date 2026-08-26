---
name: pennylane-supplier-invoices
description: >-
  Collect supplier invoices from mailboxes, obtain the PDF (attachment, link or
  portal), identify which legal entity is billed, import them into Pennylane via
  the API, then file the processed mail. Use when the user says "pull the
  invoices", "get the invoices from my mail", "import these invoices into
  Pennylane", or talks about purchase invoices to enter.
  Load the pennylane-access skill first.
---

# Supplier invoices: mail → Pennylane

**Prerequisite: `pennylane-access`** (loading, companies, tokens, amounts, VAT).
Scopes: `supplier_invoices:all`, `suppliers:all`, `file_attachments:all`.

**Guiding rule: automatic when it is certain, ask when it is not.** Never import
an invoice whose entity, supplier or amounts are uncertain without validation.

## Step 0 — Shared journal and lock

```powershell
PLJournalLock                 # refuses if someone else is running a batch
$journal = PLJournalRead
```

The journal is **common to the team**, so an invoice already handled by someone
else does not go in twice. A refused lock means **wait** — do not force it
without confirming the other session is dead. `PLJournalRelease` at the end of
the run, on success and on failure.

Period to process: since `$journal.lastProcessed`, else the last 30 days.

## Step 1 — Find the invoice mails

Search the relevant mailboxes for: invoice, receipt, bill, subscription,
statement — bounded by date, and paginate.

Discard: mere mentions of invoices, sales issued *by* the entities, order
confirmations. Keep invoices, receipts and credit notes.

Deduplicate on the internet message-id **and** against the journal:

```powershell
PLSeen $journal $party $number $date $amount
```

## Step 2 — Obtain the PDF

- **PDF attachment** → the simple case.
- **Link** → check domain coherence first (anti-phishing). A direct PDF can be
  fetched; a portal behind a login means browser automation, or asking for the
  PDF.
- **Batch extraction** from Outlook:

```powershell
& <toolkit>\lib\outlook-extract.ps1 -Targets .\targets.json -Since 2026-08-01
```

The log reports `ITEMS SCANNED: n`. A **zero on an active mailbox is a date
format bug**, not an empty mailbox — see Lessons.

Name files `YYYY-MM-DD_supplier_entity.pdf`.

## Step 3 — Analyse and route

Extract: supplier (plus registration number), **the entity being billed**,
document number, date, due date, net / VAT / gross, currency, rate.

Route on the entity named **on the document**, not on the mailbox that received
it. An entity without API access is handled manually and listed separately.

**Any doubt about the entity is a question, never a guess.** An invoice imported
into the wrong company is hard to undo: there is no DELETE in the API, and
archiving is forbidden once it has been reconciled.

## Step 4 — Check what already exists BEFORE writing

Pennylane frequently creates the invoice itself, from email extraction and bank
feeds. Compare number, amount and date first:

```powershell
$sup = PLFindSup 'company-a' 'ACME Corp'
$existing = PLGetAll 'company-a' 'supplier_invoices' @(
  @{ field = 'supplier_id'; operator = 'eq'; value = $sup[0] }
)
```

If it is already there, do not re-import — that is a reconciliation question
(see `pennylane-reconciliation`), not an import.

Then summarise the batch (supplier, number, date, gross, entity, source) and
**wait for validation before the first import**. Group the certain cases; list
the doubtful ones separately.

## Step 5 — Import

```powershell
$sup = PLFindSup $c $name
$supId = if ($sup) { $sup[0] } else { PLNewSup $c $name }
$fa = PLUpload $c $pdf
$payload = @{
  file_attachment_id         = $fa
  supplier_id                = $supId
  date                       = '2026-06-01'
  deadline                   = '2026-06-30'
  currency_amount_before_tax = (PLNum 100)
  currency_tax               = (PLNum 20)
  currency_amount            = (PLNum 120)
  invoice_lines = @(@{
    currency_amount = (PLNum 120); currency_tax = (PLNum 20); vat_rate = 'FR_200'
  })
}
$r = PLImport $c $payload
PLThrottle
```

- Supplier creation takes a **minimal `{name}`** payload. Adding `vat_number` or
  `country` returns **400**.
- **The sum of the lines' `currency_amount` must equal the total**, else 422.
- Amounts always through `PLNum`. `FR_55` for 5.5 %, never `FR_055`.
- Mixed VAT splits into several lines (e.g. an exempt portion plus a 20 % portion
  → one `exempt` line and one `FR_200` line).

**409 or 422 on the file means the document is already there.** That is the
duplicate guard, not a failure: record it as `already_in_pennylane` and move on.
Do not retry.

## Step 6 — Journal and report

```powershell
$journal = PLJournalAdd $journal @{
  date = '2026-06-01'; party = 'ACME Corp'; number = 'INV-2026-042'
  entity = 'company-a'; amount = 120; status = 'imported'
  source = 'mail 2026-06-02'; pennylane_id = $r.id
}
PLJournalWrite $journal
PLJournalRelease
```

Status is one of `imported`, `already_in_pennylane`, `identified_not_imported`
(with a reason), `failed`. Final report: imported per entity, duplicates,
entities handled manually, pending, failures. **Never a token in the journal or
in the report.**

## Step 7 — File the source mail

After a **successful** import (or a confirmed duplicate), move the mail to the
accounting folder **of its own mailbox**. **Move only, never delete.** Never move
a mail that failed, is doubtful, or is not an invoice.

```powershell
& <toolkit>\lib\outlook-classer.ps1 -Targets .\to-file.json -Folder 'Accounting/Supplier invoices' -Test
& <toolkit>\lib\outlook-classer.ps1 -Targets .\to-file.json -Folder 'Accounting/Supplier invoices'
```

The script creates missing folders. **Always run `-Test` on one mail before the
batch.** Record the mail's entry id in the journal.

## Lessons

### Outlook COM locale trap (dates as DD/MM/YYYY)
`Items.Restrict("[ReceivedTime] >= '...'")` parses the date with the **system
locale**. In French that is `DD/MM/YYYY`: `'06/12/2026'` reads as 12 June — or as
a future date, matching nothing, **silently**. The provided script formats
explicitly and logs the number of items scanned. A count of zero on an active
mailbox is a format bug, never an absence of mail.

Reliable COM access: `New-Object -ComObject Outlook.Application` followed by
`$ns.Logon()`. `GetActiveObject` and `GetDefaultFolder` can return empty stores.

### Unreachable attachments
Seen in the field: a stale Outlook OST while a newer client holds the sync, and
no browser available in a non-interactive run. Record
`identified_not_imported` with the reason rather than inventing an amount.

### Script encoding
A `.ps1` saved as UTF-8 **without BOM** is read as ANSI by PowerShell 5.1 and
breaks on accented characters. Save with BOM, or keep scripts pure ASCII.
