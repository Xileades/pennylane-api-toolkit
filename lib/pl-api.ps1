<#
    pl-api.ps1 -- Pennylane Company API v2 client for PowerShell 5.1+

    Dot-source it, do not execute it:
        . .\lib\pl-api.ps1

    Tokens are NOT in this file. They live per-user, outside the repo:
        %USERPROFILE%\.pennylane\tokens.json      (or $env:PENNYLANE_HOME)
    See config/tokens.example.json.

    This file is deliberately pure ASCII so that PowerShell 5.1 parses it
    whatever the encoding it is saved with. See docs/PITFALLS.md.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$script:PLBASE = 'https://app.pennylane.com/api/external/v2'

# --- Paths -----------------------------------------------------------------

function PLHome {
    if ($env:PENNYLANE_HOME) { return $env:PENNYLANE_HOME }
    return (Join-Path $env:USERPROFILE '.pennylane')
}

# Where a shared deduplication journal lives, when a team shares one.
# Defaults to the per-user home, so a single operator needs no configuration.
function PLShare {
    if ($env:PENNYLANE_SHARE) { return $env:PENNYLANE_SHARE }
    return (PLHome)
}

# --- Auth ------------------------------------------------------------------

# Two token sources, chosen per user in %USERPROFILE%\.pennylane\config.json:
#   "file"     (default, also when config.json is absent): tokens.json, as before.
#   "keyvault" : tokens are read at run time from an Azure Key Vault with the
#                user's own Windows sign-in (WAM, silent). Nothing secret on disk.
# See config/config.example.json and docs/PITFALLS.md section 24.

function PLConfig {
    if ($script:PLCFG) { return $script:PLCFG }
    $p = Join-Path (PLHome) 'config.json'
    if (Test-Path -LiteralPath $p) {
        $script:PLCFG = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    } else {
        $script:PLCFG = [pscustomobject]@{ source = 'file' }
    }
    return $script:PLCFG
}

# Access token for Key Vault, obtained SILENTLY from the Windows account broker
# (WAM) with the signed-in Entra ID account. No password, no client secret.
# Requires an Entra-joined (or registered) Windows device and an app registration
# with the redirect URI ms-appx-web://microsoft.aad.brokerplugin/<clientId>.
# PITFALL: asking by scope returns Success with an EMPTY token; the v1 "resource"
# property is required, and in PowerShell 5.1 it can only be added by reflection.
function PLVaultToken {
    if ($script:PLKVJ -and $script:PLKVJ.Expires -gt (Get-Date).AddMinutes(5)) { return $script:PLKVJ.Token }
    $kv = (PLConfig).keyvault
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskG = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $await = { param($op, [type]$t)
        $tk = $asTaskG.MakeGenericMethod($t).Invoke($null, @($op)); $tk.Wait(-1) | Out-Null; $tk.Result }
    $null = [Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
    $null = [Windows.Security.Authentication.Web.Core.WebTokenRequestResult, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
    $null = [Windows.Security.Credentials.WebAccountProvider, Windows.Security.Credentials, ContentType = WindowsRuntime]
    $mgr  = [Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager]
    $prov = & $await ($mgr::FindAccountProviderAsync('https://login.microsoft.com', 'organizations')) ([Windows.Security.Credentials.WebAccountProvider])
    $req  = New-Object Windows.Security.Authentication.Web.Core.WebTokenRequest($prov, '', $kv.clientId)
    [void][System.Collections.Generic.IDictionary[string, string]].GetMethod('Add').Invoke($req.Properties, @('resource', 'https://vault.azure.net'))
    $res  = & $await ($mgr::GetTokenSilentlyAsync($req)) ([Windows.Security.Authentication.Web.Core.WebTokenRequestResult])
    if ($res.ResponseStatus -ne 'Success') {
        throw "Key Vault: Windows sign-in refused ($($res.ResponseStatus) $($res.ResponseError.ErrorCode)). Is Windows signed in with your work account?"
    }
    $d = @($res.ResponseData)[0]
    if ([string]::IsNullOrEmpty($d.Token)) { throw 'Key Vault: empty access token (see PITFALLS section 24).' }
    $script:PLKVJ = @{ Token = $d.Token; Account = $d.WebAccount.UserName; Expires = (Get-Date).AddMinutes(50) }
    return $d.Token
}

# Short user id used in secret names: jane.doe@contoso.com -> janedoe
function PLVaultUser {
    if (-not $script:PLKVJ) { [void](PLVaultToken) }
    return (($script:PLKVJ.Account -split '@')[0] -replace '[^a-zA-Z0-9]', '').ToLower()
}

# Same shape in both modes (.<slug>.label / .token / .note): PLEntites, PLHdr and
# the skills do not care where the tokens came from. Key Vault tokens stay in memory.
function PLTokens {
    if ($script:PLTOK) { return $script:PLTOK }
    $cfg = PLConfig
    if ($cfg.source -eq 'keyvault') {
        $kv  = $cfg.keyvault
        $h   = @{ Authorization = 'Bearer ' + (PLVaultToken) }
        $pat = if ($kv.secretName) { $kv.secretName } else { 'pennylane-token-{company}-{user}' }
        $usr = PLVaultUser
        $o = [ordered]@{}
        foreach ($p in $cfg.entites.PSObject.Properties) {
            $tok = $null
            if ($p.Value.api -ne $false) {
                $n = $pat.Replace('{company}', $p.Name).Replace('{user}', $usr)
                try { $tok = (Invoke-RestMethod -Uri "$($kv.vaultUrl.TrimEnd('/'))/secrets/$($n)?api-version=7.4" -Headers $h).value }
                catch { throw "Key Vault: secret '$n' not readable ($($_.Exception.Response.StatusCode)). Missing 'Key Vault Secrets User' role on it?" }
            }
            $o[$p.Name] = [pscustomobject]@{ label = $p.Value.label; token = $tok; note = $p.Value.note }
        }
        $script:PLTOK = [pscustomobject]$o
        return $script:PLTOK
    }
    $p = Join-Path (PLHome) 'tokens.json'
    if (-not (Test-Path -LiteralPath $p)) {
        throw "tokens.json not found: $p`nCopy config/tokens.example.json there and paste your tokens, or use the keyvault source (config/config.example.json)."
    }
    $script:PLTOK = (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).entites
    return $script:PLTOK
}

# Every company slug declared (tokens.json, or config.json in keyvault mode).
function PLEntites { return @((PLTokens).PSObject.Properties.Name) }

# A Company API token is bound to ONE company: pick the right slug per call.
function PLHdr($e) {
    $t = (PLTokens).$e
    if (-not $t)       { throw "Unknown company slug in tokens.json: $e" }
    if (-not $t.token) { throw "Company '$e' ($($t.label)) has no API token -- handle it manually." }
    return @{ Authorization = ("Bearer " + $t.token) }
}

# Pre-flight. Requires no scope. Use it before anything unusual: it tells you
# which company the token really points at, and which scopes it carries.
function PLMe($e) {
    return Invoke-RestMethod -Uri "$script:PLBASE/me" -Headers (PLHdr $e) -Method Get
}

# --- Amounts ---------------------------------------------------------------

# Monetary values must be STRINGS with a DOT.
# '{0:0.00}' -f and '{0:N2}' follow the current culture: in fr-FR they produce
# "1077,79" and "1 077,79". Both corrupt the import. Force InvariantCulture.
function PLNum($v) {
    return ([double]$v).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
}

# --- Rate limiting ---------------------------------------------------------

# Documented limit: 25 requests / 5 s, per token, all endpoints, prod and sandbox.
# 220 ms between calls is ~4.5 req/s = 22 per 5 s, with margin.
# On 429, honour the retry-after header rather than this pause.
function PLThrottle { Start-Sleep -Milliseconds 220 }

# --- Paginated GET ---------------------------------------------------------

<#
    The cursor does NOT carry filter/sort state. Omitting them on page 2
    returns UNFILTERED results from that cursor position, with no error --
    the single most dangerous behaviour of this API. This helper re-sends
    them on every page.

    $filter: array of @{field=..; operator=..; value=..}, combined with AND.
    Operators: eq not_eq lt lteq gt gteq in not_in start_with
               (in/not_in take an array; start_with is a prefix ILIKE)
    Filterable fields vary per endpoint -- check before assuming.
#>
function PLGetAll($e, $path, $filter, $sort, $limit) {
    if (-not $limit) { $limit = 100 }   # API default 20, max 100 on most endpoints
    $hd = PLHdr $e; $out = @(); $cur = $null
    $qs = @("limit=$limit")
    if ($filter) {
        # PS 5.1 has no -AsArray, and ConvertTo-Json unwraps 1-element arrays
        # (a bare hashtable serialises as an object): test the JSON itself,
        # not Count -- on a hashtable, Count returns the number of KEYS.
        $json = $filter | ConvertTo-Json -Depth 5 -Compress
        if ($json -notmatch '^\s*\[') { $json = "[$json]" }
        $qs += 'filter=' + [uri]::EscapeDataString($json)
    }
    if ($sort) { $qs += "sort=$sort" }
    $base = "$script:PLBASE/$($path.TrimStart('/'))?" + ($qs -join '&')
    do {
        $u = $base; if ($cur) { $u += "&cursor=$cur" }
        $r = Invoke-RestMethod -Uri $u -Headers $hd -Method Get
        if ($r.items) { $out += $r.items }
        $cur = $r.next_cursor
        PLThrottle
    } while ($r.has_more -and $cur)
    return $out
}

# --- Suppliers -------------------------------------------------------------

# Loose match on a normalised name, in both directions, to survive the usual
# "ACME" / "ACME SAS" / "Acme, Inc." spread.
function PLFindSup($e, $name) {
    $hd = PLHdr $e; $cur = $null
    $needle = ($name -replace '[^A-Za-z0-9]','').ToLower()
    do {
        $u = "$script:PLBASE/suppliers?limit=100"; if ($cur) { $u += "&cursor=$cur" }
        $r = Invoke-RestMethod -Uri $u -Headers $hd -Method Get
        foreach ($s in $r.items) {
            $n = ($s.name -replace '[^A-Za-z0-9]','').ToLower()
            if ($n -and ($n -like "*$needle*" -or $needle -like "*$n*")) { return @($s.id, $s.name) }
        }
        $cur = $r.next_cursor; PLThrottle
    } while ($cur)
    return $null
}

# Payload is deliberately MINIMAL. Adding vat_number or country returns 400.
function PLNewSup($e, $name) {
    $hd = PLHdr $e
    $b = @{ name = $name } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$script:PLBASE/suppliers" -Headers $hd -Method Post `
            -ContentType 'application/json' -Body $b
    return $r.id
}

# --- File attachments ------------------------------------------------------

<#
    Multipart upload. Invoke-RestMethod -Form exists only on PowerShell 7+,
    so this uses HttpClient, which works on 5.1 too.
    Accepted: PDF, PNG, JPEG, TIFF, BMP, GIF. Max 100 MB. Scope file_attachments:all.
    Re-uploading a file already present in the workspace is REFUSED (409 or 422
    depending on the doc page) -- that is the duplicate guard, not a failure.
#>
function PLUpload($e, $path) {
    $tk = (PLHdr $e).Authorization
    $cli = New-Object System.Net.Http.HttpClient
    $cli.DefaultRequestHeaders.Add('Authorization', $tk)
    $ct = New-Object System.Net.Http.MultipartFormDataContent
    $bytes = [IO.File]::ReadAllBytes($path)
    $bc = New-Object System.Net.Http.ByteArrayContent(,$bytes)
    $bc.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/pdf')
    $ct.Add($bc, 'file', [IO.Path]::GetFileName($path))
    $resp = $cli.PostAsync("$script:PLBASE/file_attachments", $ct).Result
    $body = $resp.Content.ReadAsStringAsync().Result
    $cli.Dispose()
    if (-not $resp.IsSuccessStatusCode) { throw "UPLOAD $([int]$resp.StatusCode) $body" }
    return ($body | ConvertFrom-Json).id
}

# --- Supplier invoice import ----------------------------------------------

<#
    POST /supplier_invoices/import. Amounts as strings, via PLNum.
    The sum of invoice_lines currency_amount MUST equal the total, else 422.
    VAT codes: FR_200 (20%), FR_100 (10%), FR_55 (5.5%), FR_21 (2.1%),
               FR_85 (8.5%), exempt (0%, reverse charge / intra-EU).
    FR_055 does not exist -- the tutorial pages that use it are wrong.
#>
function PLImport($e, $payload) {
    $hd = PLHdr $e
    $b = $payload | ConvertTo-Json -Depth 6 -Compress
    return Invoke-RestMethod -Uri "$script:PLBASE/supplier_invoices/import" -Headers $hd `
              -Method Post -ContentType 'application/json' -Body $b
}

# --- Payment matching ------------------------------------------------------

<#
    One link per request. No batch, no rollback.
    Responses are 204 No Content: no body, no link identifier. A re-read is the
    only proof the link exists -- use PLMatches* below.
    Not applicable to draft invoices (422). On a draft or archived invoice the
    read returns an EMPTY LIST with no error, so empty does not mean failed.
    404 can also mean "belongs to another company", not only "does not exist".
#>
function PLMatchSupplier($e, $invoiceId, $transactionId) {
    $b = @{ transaction_id = $transactionId } | ConvertTo-Json
    Invoke-RestMethod -Uri "$script:PLBASE/supplier_invoices/$invoiceId/matched_transactions" `
        -Headers (PLHdr $e) -Method Post -ContentType 'application/json' -Body $b | Out-Null
}

function PLMatchCustomer($e, $invoiceId, $transactionId) {
    $b = @{ transaction_id = $transactionId } | ConvertTo-Json
    Invoke-RestMethod -Uri "$script:PLBASE/customer_invoices/$invoiceId/matched_transactions" `
        -Headers (PLHdr $e) -Method Post -ContentType 'application/json' -Body $b | Out-Null
}

function PLMatchesSupplier($e, $invoiceId) { return PLGetAll $e "supplier_invoices/$invoiceId/matched_transactions" }
function PLMatchesCustomer($e, $invoiceId) { return PLGetAll $e "customer_invoices/$invoiceId/matched_transactions" }

<#
    Unmatch. The documentation does not say whether {id} is the transaction id
    or a distinct link id -- treat this as UNVERIFIED: read the matches first,
    test on ONE case, confirm by re-reading, then run the batch.
#>
function PLUnmatchSupplier($e, $invoiceId, $matchId) {
    Invoke-RestMethod -Uri "$script:PLBASE/supplier_invoices/$invoiceId/matched_transactions/$matchId" `
        -Headers (PLHdr $e) -Method Delete | Out-Null
}

function PLUnmatchCustomer($e, $invoiceId, $matchId) {
    Invoke-RestMethod -Uri "$script:PLBASE/customer_invoices/$invoiceId/matched_transactions/$matchId" `
        -Headers (PLHdr $e) -Method Delete | Out-Null
}

# --- Analytical categories -------------------------------------------------

<#
    Body is a bare ARRAY of @{id; weight}, not an object wrapper.
    weight is a string between 0 and 1, max 7 decimals.
    Weights within one category group must sum to exactly 1, else 422.
    An empty array clears all categories. Not applicable to draft invoices.
#>
function PLSetCategories($e, $resource, $id, $categories) {
    $b = ConvertTo-Json @($categories) -Depth 4
    return Invoke-RestMethod -Uri "$script:PLBASE/$resource/$id/categories" -Headers (PLHdr $e) `
              -Method Put -ContentType 'application/json' -Body $b
}
