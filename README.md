# Pennylane API Toolkit

PowerShell library, Claude skills and a hard-won pitfalls catalogue for the
**Pennylane Company API v2** — built for **multi-company** setups where several
people work on the same books.

> **🇫🇷 En français** — Bibliothèque PowerShell, skills Claude et catalogue de
> pièges pour l'**API Company v2 de Pennylane**, pensés pour les groupes
> **multi-entreprises** où plusieurs personnes travaillent sur la même compta.
> Le code et la documentation sont en anglais ; les termes comptables français
> (lettrage, avoir, exercice, FEC) sont conservés entre parenthèses là où ils
> comptent. Le catalogue des pièges (`docs/PITFALLS.md`) est la partie la plus
> utile : chaque entrée vient d'une erreur payée en production.

Not affiliated with Pennylane. Built by [Xileades](https://github.com/Xileades)
while automating supplier-invoice intake and bank reconciliation across four
legal entities.

## Why this exists

The Pennylane API v2 is good, but a handful of its behaviours cost real money to
discover:

- amounts are **strings with a dot** — `'{0:0.00}' -f` in a French locale yields
  `1077,79` and silently corrupts your imports;
- the pagination cursor **does not remember your filters** — omit `filter` on
  page 2 and you get *unfiltered* results from that position, with no error;
- `reconciled` **does not exist** on a transaction, so any code reading it gets
  `$null` and looks correct;
- the VAT code for 5.5 % is `FR_55` — the tutorial pages that say `FR_055` are
  wrong;
- there is **no idempotency**: two identical POSTs create two records.

Every one of those is documented in [`docs/PITFALLS.md`](docs/PITFALLS.md) with
the symptom, the cause and the fix.

## What's in here

| Path | What it is |
|---|---|
| `lib/pl-api.ps1` | API layer: auth, cursor pagination, suppliers, uploads, invoice import, payment matching |
| `lib/journal.ps1` | Shared deduplication journal with a lock, for teams of 2+ |
| `lib/outlook-extract.ps1` | Pull PDF attachments out of Outlook by message-id (Windows, COM) |
| `lib/outlook-classer.ps1` | File processed mails into a folder — move only, never delete |
| `config/tokens.example.json` | Multi-company token template |
| `docs/ARCHITECTURE.md` | Token model, why one token per company, shared-journal design |
| `docs/PITFALLS.md` | The catalogue. Read this one. |
| `examples/import-supplier-invoice.ps1` | End-to-end: PDF → supplier → attachment → invoice |
| `skills/` | Six [Claude skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) covering the workflows |

## Requirements

- **PowerShell 5.1** (Windows, shipped by default) or PowerShell 7+
- A Pennylane **Company API token per company** — Settings → Connectivity →
  Developers → Generate an API Token
- The Outlook scripts additionally need Outlook desktop installed (COM)

PowerShell 5.1 is the baseline on purpose: it is what you find on an accountant's
Windows workstation. Two consequences worth knowing about are in
[`docs/PITFALLS.md`](docs/PITFALLS.md) (script encoding, execution policy on
network shares).

## Quick start

```powershell
# 1. Put your tokens where the library looks for them
New-Item -ItemType Directory -Path "$env:USERPROFILE\.pennylane" -Force
Copy-Item .\config\tokens.example.json "$env:USERPROFILE\.pennylane\tokens.json"
notepad "$env:USERPROFILE\.pennylane\tokens.json"   # paste one token per company

# 2. Load the library
. .\lib\pl-api.ps1

# 3. Check what the token can actually do, before anything else
$me = PLMe 'company-a'
$me.company.name        # is this the company you think it is?
$me.scopes              # is the scope you need in there?

# 4. Sanity-check amount formatting in your locale
PLNum 1077.79           # MUST print 1077.79 with a dot
```

If step 4 prints a comma, stop and read the amounts section of the pitfalls doc
before touching anything that writes.

## The multi-company model

**A Pennylane Company API token is bound to exactly one company.** Groups
therefore need one token per entity, and a way to pick the right one per call.
This toolkit keeps them in a single per-user file keyed by a short slug:

```powershell
PLHdr 'company-a'       # Authorization header for that company
PLEntites               # every slug the file declares
```

Tokens live in `%USERPROFILE%\.pennylane\tokens.json`, **one file per person**,
never on a shared drive and never in git. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for why per-person tokens rather
than one service token: individual traceability of who imported what, and
individual revocation when someone leaves.

A company with no API access (a small SCI, an entity whose plan does not include
the API) is declared with `"token": null`. `PLHdr` then throws an explicit error
instead of failing obscurely mid-batch — that entity is handled manually and the
scripts say so out loud.

## Rate limits and safety

The API allows **25 requests per 5 seconds per token**. `PLThrottle` paces calls
at roughly 4.5 req/s, which leaves margin. Only `429`, `500` and `503` are worth
retrying — `400`, `401`, `403`, `404` and `422` mean the request must change.

Everything that writes to a ledger is worth a second look before it runs. The
skills in `skills/` are written to summarise a batch and wait for a human before
the first write, to test one case before the batch, and to re-read after any
`204 No Content` response — because a 204 confirms nothing.

## Contributing

Corrections to `docs/PITFALLS.md` are the most valuable contribution. If the API
behaves differently from what is written here, please open an issue with the
endpoint, the payload and the response — including the status code.

Entries marked **unverified** are behaviours the official documentation does not
specify and that were inferred; confirming or refuting one is genuinely useful.

## Licence

MIT — see [LICENSE](LICENSE).
