# Interactive setup wizard.
# Run from the repo root: powershell -ExecutionPolicy Bypass -File setup.ps1
#
# What it does:
#   1) Lists your paired Bluetooth devices, you pick the one to toggle.
#   2) Lists your audio Render endpoints, you pick fallback 1 (your other
#      headphones / speakers if you have a second BT device).
#   3) Lists endpoints again, you pick fallback 2 (almost always your
#      built-in PC speakers).
#   4) Writes config.ini.
#   5) Unblocks the bundled binaries so SmartScreen doesn't sandbox them.

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$cfg  = Join-Path $repo 'config.ini'
$bin  = Join-Path $repo 'bin'
$svv  = Join-Path $bin  'SoundVolumeView.exe'

function Read-Choice([string]$prompt, [int]$max) {
    while ($true) {
        $a = Read-Host $prompt
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $max) { return [int]$a }
        Write-Host ("  -> Enter a number between 1 and {0}" -f $max) -ForegroundColor Yellow
    }
}

function Get-PairedBtDevices {
    # PnP devices in the Bluetooth class with a 12-hex-char MAC trailer in InstanceId
    $list = @()
    Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.InstanceId -match '([0-9A-F]{12})$') {
            $mac = $matches[1].ToUpper()
            # Skip the radio/host adapter entries; keep ones with a friendly name
            if ($_.FriendlyName -and $_.FriendlyName -notmatch 'Microsoft|Generic Bluetooth|Bluetooth Radio|Bluetooth\s*\d.*Adapter|Realtek Bluetooth|Intel.*Bluetooth') {
                $list += [pscustomobject]@{
                    Name       = $_.FriendlyName
                    MAC        = $mac
                    Status     = $_.Status
                    InstanceId = $_.InstanceId
                }
            }
        }
    }
    return $list | Sort-Object Name -Unique
}

function Get-RenderEndpoints {
    if (-not (Test-Path $svv)) { throw "Missing $svv. Did you clone the full repo?" }
    $tmp = [System.IO.Path]::GetTempFileName() + '.tsv'
    & $svv /stab "$tmp" | Out-Null
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $tmp)) { throw "SoundVolumeView produced no dump (SmartScreen may be blocking it - run setup.ps1 again or unblock $svv manually)." }

    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    $enc   = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::UTF8 }
    $text  = $enc.GetString($bytes)
    Remove-Item $tmp -Force

    $lines  = $text -split "`r?`n" | Where-Object { $_ -ne '' }
    if ($lines.Count -lt 2) { return @() }
    $header = $lines[0] -split "`t"
    $idxName = [Array]::IndexOf($header, 'Name')
    $idxType = [Array]::IndexOf($header, 'Type')
    $idxDir  = [Array]::IndexOf($header, 'Direction')
    $idxState= [Array]::IndexOf($header, 'Device State')
    $idxCli  = [Array]::IndexOf($header, 'Command-Line Friendly ID')
    if ($idxCli -lt 0) { return @() }

    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $c = $lines[$i] -split "`t"
        if ($c.Count -le $idxCli) { continue }
        if ($c[$idxType] -ne 'Device') { continue }
        if ($c[$idxDir]  -ne 'Render') { continue }
        $rows += [pscustomobject]@{
            Name  = $c[$idxName]
            State = $c[$idxState]
            CliId = $c[$idxCli]
        }
    }
    return $rows
}

function Print-List($items, [string[]]$cols) {
    for ($i = 0; $i -lt $items.Count; $i++) {
        $row = $items[$i]
        $line = "  [{0,2}]  " -f ($i + 1)
        foreach ($c in $cols) { $line += ("{0}: {1}   " -f $c, $row.$c) }
        Write-Host $line
    }
}

function Unblock-Bin {
    Write-Host '`nUnblocking bundled binaries (SmartScreen Mark-of-the-Web)...'
    Get-ChildItem $bin -File | ForEach-Object {
        try { Unblock-File -Path $_.FullName -ErrorAction Stop; Write-Host "  unblocked $($_.Name)" }
        catch { Write-Host "  skip $($_.Name): $_" }
    }
}

# -----------------------------------------------------------------------------
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  BT Audio Toggle - first-time setup wizard"   -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# --- 1. Pick the BT device to toggle ---
Write-Host "`nStep 1/4: which Bluetooth device should the hotkey toggle?"
$bt = Get-PairedBtDevices
if (-not $bt -or $bt.Count -eq 0) {
    Write-Host "No paired Bluetooth devices found. Pair your headphones in Windows Settings first." -ForegroundColor Red
    exit 1
}
Print-List $bt @('Name','MAC','Status')
$pick = Read-Choice "Pick the device #" $bt.Count
$btDev = $bt[$pick - 1]

# --- 2. Pick fallback1 (preferred fallback when toggling away from BT) ---
Write-Host "`nStep 2/4: pick FALLBACK 1 - the device to switch to when you toggle"
Write-Host "AWAY from your BT headphones. Usually your secondary headphones, or"
Write-Host "your speakers if you only have one BT pair. Make sure the device is"
Write-Host "currently powered on and connected so it shows up below."
$ep = Get-RenderEndpoints
if (-not $ep -or $ep.Count -eq 0) {
    Write-Host "No audio Render endpoints found. Is anything plugged in?" -ForegroundColor Red
    exit 1
}
Print-List $ep @('Name','State','CliId')
$pick = Read-Choice "Pick fallback 1 #" $ep.Count
$fb1 = $ep[$pick - 1]

# --- 3. Pick fallback2 (always-present backup) ---
Write-Host "`nStep 3/4: pick FALLBACK 2 - the always-present backup. Almost always"
Write-Host "your built-in PC speakers - this kicks in when fallback 1 is offline."
Print-List $ep @('Name','State','CliId')
$pick = Read-Choice "Pick fallback 2 #" $ep.Count
$fb2 = $ep[$pick - 1]

# --- 4. Friendly label for tray notifications ---
Write-Host "`nStep 4/4: short label for tray notifications (e.g. 'XM4', 'Buds')"
$label = Read-Host "  Label"
if (-not $label) { $label = $btDev.Name }

# --- Build primary_match ---
# Prefix-match on '<Friendly Name>\Device\' so we tolerate the middle Device
# Name component flipping after profile re-init. Find the user's BT device
# in the endpoint list to determine the Friendly Name part.
$friendlyName = $null
foreach ($r in $ep) {
    if ($r.CliId -match "^([^\\]+)\\Device\\") {
        $candidate = $matches[1]
        # match by likeness to BT device name
        if ($candidate -match [regex]::Escape($btDev.Name) -or $btDev.Name -match [regex]::Escape($candidate)) {
            $friendlyName = $candidate
            break
        }
    }
}
if (-not $friendlyName) {
    Write-Host "`nCouldn't auto-detect the BT device's audio endpoint Friendly Name." -ForegroundColor Yellow
    Write-Host "Make sure the BT device is connected RIGHT NOW (you should hear it"
    Write-Host "as a Render endpoint above), then re-run setup.ps1. For now I'll guess"
    Write-Host "based on the device's PnP name."
    $friendlyName = $btDev.Name
}
$primaryMatch = "$friendlyName\Device\"

# --- Write config.ini ---
$ini = @"
; Generated by setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')

[devices]
primary_match = $primaryMatch
primary_mac   = $($btDev.MAC)
primary_label = $label
fallback1     = $($fb1.CliId)
fallback2     = $($fb2.CliId)

[ui]
toast        = 1
hotkey       = ~Space & s
hotkey_guard = Control
"@

Set-Content -Path $cfg -Value $ini -Encoding UTF8
Write-Host "`nWrote $cfg" -ForegroundColor Green
Write-Host "  primary_match = $primaryMatch"
Write-Host "  primary_mac   = $($btDev.MAC)"
Write-Host "  primary_label = $label"
Write-Host "  fallback1     = $($fb1.Name)  ($($fb1.CliId))"
Write-Host "  fallback2     = $($fb2.Name)  ($($fb2.CliId))"

Unblock-Bin

Write-Host "`nDone. To start the toggle now:" -ForegroundColor Green
Write-Host "  start.cmd"
Write-Host "Default hotkey: Ctrl + Space + S (edit config.ini [ui] hotkey to change)"
Write-Host "`nFor login autostart: copy start.cmd into shell:startup folder."
