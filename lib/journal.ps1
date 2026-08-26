<#
    journal.ps1 -- shared deduplication journal with a lock.

    Dot-source it after pl-api.ps1:
        . .\lib\pl-api.ps1
        . .\lib\journal.ps1

    Why this exists: the API enforces no idempotency, so two people importing
    invoices cannot see what the other already processed. The journal is the
    common memory. See docs/ARCHITECTURE.md.

    Location: $env:PENNYLANE_SHARE\invoice-journal.json, falling back to the
    per-user home, so a single operator needs no configuration.

    Operating rule: ONE operator at a time. The lock makes that visible rather
    than pretending to solve distributed locking.

    Pure ASCII on purpose -- see docs/PITFALLS.md.
#>
$ErrorActionPreference = 'Stop'

function PLJournalPath { return (Join-Path (PLShare) 'invoice-journal.json') }
function PLLockPath    { return (Join-Path (PLShare) 'invoice-journal.lock') }

# A lock older than this is considered orphaned (crashed session).
$script:PLLockStaleMin = 45

function PLJournalLock {
    param([switch]$Force)
    $lk = PLLockPath
    if (Test-Path -LiteralPath $lk) {
        $info = $null
        try { $info = Get-Content -LiteralPath $lk -Raw | ConvertFrom-Json } catch {}
        $age = [math]::Round(((Get-Date) - (Get-Item -LiteralPath $lk).LastWriteTime).TotalMinutes, 0)
        $who = if ($info) { "$($info.user) on $($info.machine) since $($info.since)" } else { 'unknown' }
        if ($age -lt $script:PLLockStaleMin -and -not $Force) {
            throw "Journal locked by $who ($age min). Wait, or use -Force if you are certain that session is dead."
        }
        Write-Warning "Orphaned lock ($age min, $who) -- taking over."
    }
    @{ user = $env:USERNAME; machine = $env:COMPUTERNAME; since = (Get-Date -Format 'yyyy-MM-dd HH:mm') } |
        ConvertTo-Json | Set-Content -LiteralPath $lk -Encoding UTF8
}

# Call this at the end of every run, on success AND on failure.
function PLJournalRelease {
    $lk = PLLockPath
    if (Test-Path -LiteralPath $lk) { Remove-Item -LiteralPath $lk -Force }
}

function PLJournalRead {
    $p = PLJournalPath
    if (-not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ lastProcessed = $null; invoices = @() }
    }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}

<#
    Has this document already been processed, by anyone, for any company?
    Two routes: the document number, or the triple (party, date, amount) when the
    number could not be extracted from the PDF.
#>
function PLSeen($journal, $party, $number, $date, $amount) {
    $np = ($party -replace '[^A-Za-z0-9]','').ToLower()
    foreach ($i in $journal.invoices) {
        if ($number -and $i.number -and $i.number -eq $number) { return $true }
        $jp = ($i.party -replace '[^A-Za-z0-9]','').ToLower()
        if ($jp -and $np -and $jp -eq $np -and $date -and $i.date -eq $date -and
            $null -ne $amount -and $null -ne $i.amount -and
            [math]::Abs([double]$i.amount - [double]$amount) -lt 0.01) { return $true }
    }
    return $false
}

<#
    Atomic write: temp file then move, so a network hiccup mid-write cannot leave
    truncated JSON on the share. Keeps the last 20 backups.
#>
function PLJournalWrite($journal) {
    $p = PLJournalPath
    $bdir = Join-Path (PLShare) '_backups'
    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir | Out-Null }
    if (Test-Path -LiteralPath $p) {
        Copy-Item -LiteralPath $p (Join-Path $bdir ("invoice-journal.{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
    }
    $journal.lastProcessed = (Get-Date -Format 'yyyy-MM-dd')
    $tmp = "$p.tmp"
    $journal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp $p -Force
    Get-ChildItem $bdir -Filter 'invoice-journal.*.json' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
}

<#
    Append one record. Status is one of:
      imported            -- created in Pennylane by us
      already_in_pennylane -- 409/422 on the file, or found by a pre-check
      identified_not_imported -- recognised but the PDF could not be obtained
      failed              -- an actual error, with a reason
    Never store a token here, and never store one in a report either.
#>
function PLJournalAdd($journal, $record) {
    $journal.invoices += [pscustomobject]$record
    return $journal
}
