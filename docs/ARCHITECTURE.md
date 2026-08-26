# Architecture

The design decisions behind this toolkit, and why they are what they are. Most of
them exist because a group of companies is not the same problem as one company,
and because more than one person touches the books.

---

## 1. One token per company, one file per person

**A Pennylane Company API token is bound to exactly one company.** That is a
property of the API, not a choice. A group of four legal entities therefore needs
four tokens, and every call has to pick the right one.

The toolkit keeps them in a single file, keyed by a short slug:

```
%USERPROFILE%\.pennylane\tokens.json
```

```json
{
  "entites": {
    "company-a": { "label": "Company A Ltd", "token": "..." },
    "holding":   { "label": "Group Holding", "token": "..." }
  }
}
```

`PLHdr 'company-a'` returns the right `Authorization` header; `PLEntites` lists
every slug declared. Override the location with `PENNYLANE_HOME`.

### Why per-person tokens rather than one service token

A token grants write access to the ledgers of a real company. With one shared
service token, an import cannot be attributed to anyone, and a departure means
rotating a secret that everybody has copied. With one token per person:

- **traceability** — Pennylane records who created what;
- **individual revocation** — one person leaves, one set of tokens dies;
- **least surprise** — nobody wonders whether the token in their file is the same
  one their colleague is using.

The cost is a five-minute setup per person. It is worth it.

### Why never on the shared drive

A token file on a network share gives write access to the company's supplier
invoices to anyone who can read that share — and to anything that compromises
any workstation with the share mapped. The `.gitignore` blocks `tokens.json`, and
the token file lives under the user profile, which is not shared.

### Entities without API access

Small entities often sit on a plan without API access. Declare them anyway, with
`"token": null`:

```json
"small-sci": { "label": "Small SCI", "token": null, "note": "no API plan" }
```

`PLHdr` then throws an explicit, readable error for that slug. This is deliberate:
a batch that hits it stops with a clear message instead of failing obscurely, and
consolidated reports can state that the entity is **not covered** rather than
silently omitting it. A group total that quietly drops an entity is a wrong total.

---

## 2. The shared deduplication journal

One person importing invoices needs no journal: the API's duplicate guard on the
PDF is enough. Two people do, because neither can see what the other already
processed, and the API has no idempotency (see `PITFALLS.md` §5).

`lib/journal.ps1` keeps a single JSON file on a location shared by the team:

```
$env:PENNYLANE_SHARE\invoice-journal.json
```

Defaults to `PLHome` when unset, so a single operator gets working behaviour with
no configuration.

Each record carries what is needed to recognise a document later — date, party,
document number, entity, amount, status, source, and the Pennylane id when the
import succeeded. `PLSeen` matches on the document number, falling back to the
triple (party, date, amount) when the number could not be extracted from the PDF.

### One operator at a time, made visible

The journal is a single file on a share: concurrent writes would lose records.
Rather than pretend to solve distributed locking, the design makes the constraint
explicit.

`PLJournalLock` writes a lock file naming who holds it, on which machine, since
when. A second operator gets a refusal that says who to go and talk to. A lock
older than 45 minutes is treated as orphaned — a crashed session — and taken over
with a warning.

This is the right amount of machinery for a team of two or three people who do
not import invoices simultaneously. It is not a substitute for a real queue, and
it does not pretend to be.

### Atomic writes and backups

The journal is written to a temporary file and then moved into place, so a network
hiccup mid-write cannot leave truncated JSON on the share. Every write first
copies the current file into `_backups/`, keeping the last twenty.

### Why the journal is not in git

It is mutable operational state that changes on every import, and its `source`
field routinely names individuals ("registered letter for Mrs X"). Sharing it
through a network share is appropriate; keeping its history in a git repository is
not. The `.gitignore` excludes it.

---

## 3. Source of truth on the share, execution from a local cache

PowerShell's `RemoteSigned` policy refuses an unsigned `.ps1` located on a mapped
drive or UNC path (see `PITFALLS.md` §20). Signing scripts or reconfiguring zones
requires administrative work that a small team may not want to take on.

The pattern that needs no privileges:

```powershell
$cache = "$env:USERPROFILE\.pennylane\scripts"
New-Item -ItemType Directory -Path $cache -Force | Out-Null
Copy-Item '\\share\pennylane\lib\*.ps1' $cache -Force
. "$cache\pl-api.ps1"
```

The share stays the source of truth; the local copy is a cache overwritten at the
start of every run, so it cannot drift. If you prefer the clean fix, add the
server to the Local intranet zone, or sign the scripts, and dot-source directly
from the share.

---

## 4. Read a lot, write carefully

The API filters very little (see `PITFALLS.md` §18), so the working shape of
almost every task is: **fetch a date range, analyse in memory, propose, then
write one record at a time.**

That shape drives three habits baked into the library and the skills:

- **`PLGetAll` re-sends `filter` and `sort` on every page.** Forgetting them
  returns unfiltered rows with no error — the failure mode that produces
  confident, wrong reports.
- **`PLThrottle` between calls.** 25 requests / 5 seconds is easy to exceed when
  you are matching invoices one at a time.
- **Re-read after writing** whenever the response is `204 No Content` — which is
  every payment-matching call. A `204` confirms nothing.

---

## 5. Skills as the interface

`skills/` holds six [Claude skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview),
one foundation plus five workflows:

| Skill | Scope |
|---|---|
| `pennylane-access` | tokens, entities, amounts, pagination, VAT codes, error handling — loaded first by all the others |
| `pennylane-supplier-invoices` | mail → PDF → import, and filing the processed mail |
| `pennylane-customer-invoices` | issuing invoices, quotes, credit notes, unpaid tracking |
| `pennylane-reconciliation` | matching transactions to invoices, accounting lettering |
| `pennylane-accounting-exports` | FEC, general ledger, trial balance, fiscal years |
| `pennylane-analysis` | read-only work lists and consistency checks |

The split is by **use case, not by API surface**, for two reasons. A skill loaded
for an export should not carry the invoice-import instructions — the description
is what makes it trigger correctly, and a single large skill triggers on
everything. And the shared foundation exists once, so a correction to the amount
formatting rule or a VAT code is made in one place instead of five.

The foundation skill is the only one that repeats itself: every workflow skill
declares it as a prerequisite rather than restating the rules.
