<#
    End-to-end: a PDF on disk becomes a supplier invoice in Pennylane.

        .\import-supplier-invoice.ps1 -Company company-a -Pdf .\acme-2026-042.pdf `
            -Supplier 'ACME Corp' -Number 'INV-2026-042' -Date 2026-06-01 `
            -Due 2026-06-30 -NetAmount 100 -Vat 20 -VatCode FR_200 -WhatIf

    Run it with -WhatIf first: it does every read and every check, prints the
    payload it would send, and writes nothing.

    Pure ASCII on purpose -- see docs/PITFALLS.md.
#>
param(
    [Parameter(Mandatory=$true)][string]$Company,
    [Parameter(Mandatory=$true)][string]$Pdf,
    [Parameter(Mandatory=$true)][string]$Supplier,
    [string]$Number,
    [Parameter(Mandatory=$true)][string]$Date,
    [Parameter(Mandatory=$true)][string]$Due,
    [Parameter(Mandatory=$true)][double]$NetAmount,
    [Parameter(Mandatory=$true)][double]$Vat,
    [string]$VatCode = 'FR_200',
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot
. (Join-Path $here 'lib\pl-api.ps1')

if (-not (Test-Path -LiteralPath $Pdf)) { throw "PDF not found: $Pdf" }
$gross = $NetAmount + $Vat

# --- 0. Pre-flight: is this the company you think it is, with the right scopes?
$me = PLMe $Company
Write-Host "Company : $($me.company.name)"
$needed = @('supplier_invoices:all','suppliers:all','file_attachments:all')
$missing = $needed | Where-Object { $_ -notin $me.scopes }
if ($missing) { throw "Token is missing scope(s): $($missing -join ', ')" }

# --- 1. Amount formatting. If this line shows a comma, stop.
Write-Host "Net / VAT / Gross : $(PLNum $NetAmount) / $(PLNum $Vat) / $(PLNum $gross)"
if ((PLNum $gross) -match ',') { throw "Locale problem: amounts are being formatted with a comma." }

# --- 2. Does Pennylane already have it?
# It often creates invoices on its own from email extraction and bank feeds.
# A duplicate is a reconciliation problem, not an import problem.
$sup = PLFindSup $Company $Supplier
if ($sup) {
    Write-Host "Supplier found : $($sup[1]) (id $($sup[0]))"
    $existing = PLGetAll $Company 'supplier_invoices' @(
        @{ field = 'supplier_id'; operator = 'eq'; value = $sup[0] }
    )
    $dupe = $existing | Where-Object {
        ($Number -and $_.invoice_number -eq $Number) -or
        ($_.date -eq $Date -and [math]::Abs([double]$_.currency_amount - $gross) -lt 0.01)
    }
    if ($dupe) {
        Write-Warning "Already in Pennylane (id $($dupe[0].id)). Nothing to import -- this is a matching question."
        return
    }
} else {
    Write-Host "Supplier not found -- it will be created."
}

# --- 3. Build the payload.
# Amounts as strings via PLNum. The sum of the lines MUST equal the total.
$payload = @{
    date                       = $Date
    deadline                   = $Due
    currency_amount_before_tax = (PLNum $NetAmount)
    currency_tax               = (PLNum $Vat)
    currency_amount            = (PLNum $gross)
    invoice_lines = @(
        @{ currency_amount = (PLNum $gross); currency_tax = (PLNum $Vat); vat_rate = $VatCode }
    )
}
if ($Number) { $payload.invoice_number = $Number }

$lineSum = ($payload.invoice_lines | ForEach-Object { [double]$_.currency_amount } | Measure-Object -Sum).Sum
if ([math]::Abs($lineSum - $gross) -ge 0.01) { throw "Line sum $lineSum does not equal total $gross -- the API would return 422." }

if ($WhatIf) {
    Write-Host "`n-- WhatIf: payload that would be sent --"
    ($payload | ConvertTo-Json -Depth 6)
    Write-Host "`n-- nothing was written --"
    return
}

# --- 4. Create the supplier if needed. Minimal payload: adding vat_number or
# country returns 400.
$supId = if ($sup) { $sup[0] } else { PLNewSup $Company $Supplier }
PLThrottle

# --- 5. Upload the PDF, then import.
$payload.file_attachment_id = PLUpload $Company (Resolve-Path $Pdf).Path
$payload.supplier_id        = $supId
PLThrottle

try {
    $r = PLImport $Company $payload
    Write-Host "Imported. Pennylane id : $($r.id)"
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 409 -or $code -eq 422) {
        # The PDF is already in the workspace. This is the duplicate guard,
        # not a failure. Do not retry.
        Write-Warning "Document already present in Pennylane ($code). Treated as a duplicate."
    }
    else { throw }
}
