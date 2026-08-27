<#
    outlook-classer.ps1 -- file processed mails into a destination folder of the
    mailbox they belong to. Windows + Outlook desktop (COM) only.

    .\outlook-classer.ps1 -Targets .\to-file.json -Folder 'Accounting/Supplier invoices' -Test
    .\outlook-classer.ps1 -Targets .\to-file.json -Folder 'Accounting/Supplier invoices'
    .\outlook-classer.ps1 -Targets .\to-file.json -Folder 'Accounting/Supplier invoices' -Store 'MERCADO'

    -Store (alias -Boite): only scan stores whose DisplayName contains one of
    the values (case-insensitive) -- same filter as outlook-extract.ps1.

    targets.json maps message-id to a label, same shape as outlook-extract.ps1.
    Put in it ONLY documents that were imported successfully, or whose duplicate
    status was confirmed. Never a failure, never a doubtful case, never a
    non-invoice.

    MOVE ONLY, NEVER DELETE. Always run -Test on one mail before the batch.

    Pure ASCII on purpose -- see docs/PITFALLS.md.
#>
param(
    [Parameter(Mandatory=$true)][string]$Targets,
    [Parameter(Mandatory=$true)][string]$Folder,   # 'Parent/Child' or just 'Child'
    [string]$Since = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd'),
    [Alias('Boite')][string[]]$Store,
    [switch]$Test
)
$ErrorActionPreference = 'SilentlyContinue'

$log = Join-Path ([IO.Path]::GetTempPath()) ('outlook-classer-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
"START $(Get-Date -Format 'HH:mm:ss') test=$Test folder=$Folder" | Set-Content $log

$moveMap = @{}
(Get-Content -LiteralPath $Targets -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $moveMap[$_.Name] = $_.Value }
if ($moveMap.Count -eq 0) { throw "No targets in $Targets" }

$parts = $Folder -split '/'

# Resolve (and create if missing) the destination inside a given store root.
function DestFolder($root) {
    $cur = $root
    foreach ($p in $parts) {
        $next = $cur.Folders | Where-Object { $_.Name -eq $p } | Select-Object -First 1
        if (-not $next) { $next = $cur.Folders.Add($p) }
        $cur = $next
    }
    return $cur
}

# Locale-proof date filter -- see docs/PITFALLS.md #22.
$flt = "[ReceivedTime] >= '" + ([datetime]$Since).ToString('dd/MM/yyyy HH:mm') + "'"
$MSGID = 'http://schemas.microsoft.com/mapi/proptag/0x1035001F'
$done = @{}; $limit = if ($Test) { 1 } else { $moveMap.Count }

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
    if ($done.Count -ge $limit) { break }
    try {
        $root = $st.GetRootFolder()
        $inbox = $root.Folders | Where-Object { $_.Name -match '^(Inbox|Bo.te de r.ception|Posteingang|Bandeja de entrada)$' } |
                    Select-Object -First 1
        if (-not $inbox) { continue }
        $recent = $inbox.Items.Restrict($flt)
        $toMove = @()
        foreach ($it in $recent) {
            if ($it.MessageClass -notlike 'IPM.Note*') { continue }
            $mid = $null
            try { $mid = $it.PropertyAccessor.GetProperty($MSGID) } catch {}
            if ($mid -and $moveMap.ContainsKey($mid) -and -not $done.ContainsKey($mid)) { $toMove += ,@($it, $mid) }
        }
        if ($toMove.Count -gt 0) {
            $dest = DestFolder $root
            "STORE $($st.DisplayName): dest=$($dest.FolderPath)" | Add-Content $log
            foreach ($pair in $toMove) {
                if ($done.Count -ge $limit) { break }
                $it = $pair[0]; $mid = $pair[1]
                try {
                    $eid = $it.EntryID
                    $it.Move($dest) | Out-Null
                    $done[$mid] = $true
                    "MOVED $($moveMap[$mid]) entryid=$eid" | Add-Content $log
                } catch { "MOVE-ERROR $($moveMap[$mid])" | Add-Content $log }
            }
        }
    } catch { "STORE-ERROR $($st.DisplayName)" | Add-Content $log }
}

$missing = @($moveMap.Keys | Where-Object { -not $done.ContainsKey($_) } | ForEach-Object { $moveMap[$_] })
"MOVED: $($done.Count)" | Add-Content $log
"NOT MOVED: $($missing.Count) -> $($missing -join ', ')" | Add-Content $log
"DONE $(Get-Date -Format 'HH:mm:ss')" | Add-Content $log
Get-Content $log
