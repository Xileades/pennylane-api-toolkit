<#
    outlook-extract.ps1 -- save PDF attachments from Outlook, selected by
    internet message-id. Windows + Outlook desktop (COM) only.

    .\outlook-extract.ps1 -Targets .\targets.json -Dest .\invoices-temp -Since 2026-08-01
    .\outlook-extract.ps1 -Targets .\targets.json -Since 2026-08-01 -Store 'MERCADO','Accounting'

    -Store (alias -Boite): only scan stores whose DisplayName contains one of
    the values (case-insensitive). Essential with many delegated mailboxes:
    without it, enumeration order can exhaust the run before the right store.

    targets.json maps message-id to a label used in the output filename:
        { "<message-id@example.com>": "acme-corp", ... }

    Output: <YYYYMMDD>_<label>_<n>.pdf

    THE EXPENSIVE TRAP (docs/PITFALLS.md #22): Items.Restrict parses the date
    string with the SYSTEM LOCALE. In French that is DD/MM/YYYY, so '06/12/2026'
    means 12 June, not 6 December -- and a future date matches nothing, silently.
    Hence the explicit dd/MM/yyyy format below AND the scanned-item count in the
    log: zero items on an active mailbox is a format bug, not an empty mailbox.

    Pure ASCII on purpose -- see docs/PITFALLS.md.
#>
param(
    [Parameter(Mandatory=$true)][string]$Targets,
    [string]$Dest,
    [string]$Since = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd'),
    [Alias('Boite')][string[]]$Store
)
$ErrorActionPreference = 'SilentlyContinue'

if (-not $Dest) { $Dest = Join-Path (Get-Location) 'invoices-temp' }
if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
$log = Join-Path $Dest ('_extract-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
"START $(Get-Date -Format 'HH:mm:ss') since=$Since dest=$Dest" | Set-Content $log

$targetMap = @{}
(Get-Content -LiteralPath $Targets -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $targetMap[$_.Name] = $_.Value }
if ($targetMap.Count -eq 0) { throw "No targets in $Targets" }

# Locale-proof date filter. Do not simplify this line.
$flt = "[ReceivedTime] >= '" + ([datetime]$Since).ToString('dd/MM/yyyy HH:mm') + "'"
$found = @{}; $saved = New-Object System.Collections.ArrayList; $script:scanned = 0

# PR_INTERNET_MESSAGE_ID
$MSGID = 'http://schemas.microsoft.com/mapi/proptag/0x1035001F'

function SaveItem($it) {
    $mid = $null
    try { $mid = $it.PropertyAccessor.GetProperty($MSGID) } catch {}
    if (-not $mid -or -not $targetMap.ContainsKey($mid) -or $found.ContainsKey($mid)) { return }
    $found[$mid] = $true
    $label = $targetMap[$mid]; $d = $it.ReceivedTime.ToString('yyyyMMdd'); $n = 0
    foreach ($att in $it.Attachments) {
        $fn = $att.FileName; $ok = $false
        if ($fn -match '\.pdf$') { $ok = $true }
        elseif ($fn -notmatch '\.(png|jpg|jpeg|gif|p7s|html?|ics|vcf|xml|zip|docx?|xlsx?)$') { $ok = $true }
        if ($ok) {
            $n++
            $out = Join-Path $Dest ('{0}_{1}_{2}.pdf' -f $d, $label, $n)
            try { $att.SaveAsFile($out); [void]$saved.Add("OK $label :: $fn") }
            catch { [void]$saved.Add("SAVE-ERROR $label $fn") }
        }
    }
    if ($n -eq 0) { [void]$saved.Add("NO-PDF $label -- link or portal, handle manually") }
}

function ScanFolder($folder) {
    if ($found.Count -ge $targetMap.Count) { return }
    $items = $folder.Items
    try { $items.Sort('[ReceivedTime]', $true) } catch {}
    $recent = $items.Restrict($flt)
    $script:scanned += $recent.Count
    foreach ($it in $recent) {
        if ($it.MessageClass -like 'IPM.Note*') { SaveItem $it }
        if ($found.Count -ge $targetMap.Count) { break }
    }
}

# New-Object + Logon() is the reliable path. GetActiveObject and
# GetDefaultFolder can hand back empty stores.
$ol = New-Object -ComObject Outlook.Application
$ns = $ol.GetNamespace('MAPI'); $ns.Logon() | Out-Null
$stores = @($ns.Stores)
if ($Store) {
    $stores = @($stores | Where-Object {
        $dn = $_.DisplayName
        @($Store | Where-Object { $dn -like ('*' + $_ + '*') }).Count -gt 0
    })
    "STORE FILTER: $($Store -join ', ') -> $($stores.Count) store(s) kept" | Add-Content $log
    if ($stores.Count -eq 0) {
        'WARNING: no store matches -Store. Available stores:' | Add-Content $log
        foreach ($s in $ns.Stores) { ('  - ' + $s.DisplayName) | Add-Content $log }
    }
}
foreach ($st in $stores) {
    if ($found.Count -ge $targetMap.Count) { break }
    $before = $script:scanned
    try {
        $root = $st.GetRootFolder()
        "STORE: $($st.DisplayName)" | Add-Content $log
        # Inbox name varies with the Outlook UI language.
        $inbox = $root.Folders | Where-Object { $_.Name -match '^(Inbox|Bo.te de r.ception|Posteingang|Bandeja de entrada)$' } |
                    Select-Object -First 1
        if ($inbox) {
            ScanFolder $inbox
            foreach ($sub in $inbox.Folders) { ScanFolder $sub; if ($found.Count -ge $targetMap.Count) { break } }
        }
    } catch { "STORE-ERROR $($st.DisplayName)" | Add-Content $log }
    "ITEMS SCANNED ($($st.DisplayName)): $($script:scanned - $before)" | Add-Content $log
}

"ITEMS SCANNED: $scanned" | Add-Content $log
if ($scanned -eq 0) {
    "WARNING: 0 items scanned -- check the dd/MM/yyyy date format of the Restrict filter." | Add-Content $log
}
"SAVED: $($saved.Count)" | Add-Content $log
$saved | Add-Content $log
$missing = @($targetMap.Keys | Where-Object { -not $found.ContainsKey($_) } | ForEach-Object { $targetMap[$_] })
"NOT FOUND: $($missing.Count) -> $($missing -join ', ')" | Add-Content $log
"DONE $(Get-Date -Format 'HH:mm:ss')" | Add-Content $log
Get-Content $log | Select-Object -Last 30
