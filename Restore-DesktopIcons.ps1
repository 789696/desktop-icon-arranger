<#
    Restore-DesktopIcons.ps1  -  DesktopIconArranger toolbox

    Puts the desktop icons back on the coordinates stored in a layout snapshot.

    Without -LayoutFile it picks, for THIS computer:
        1. snapshots\last-<COMPUTERNAME>.json      (written by every arrange run)
        2. snapshots\original-<COMPUTERNAME>.json  (the very first snapshot)

    Icons that are not in the snapshot (you added some since) are laid out in the
    leftover free cells instead of being left behind in the staging area.

    Usage
        powershell -ExecutionPolicy Bypass -File Restore-DesktopIcons.ps1
        powershell -ExecutionPolicy Bypass -File Restore-DesktopIcons.ps1 -LayoutFile .\snapshots\original-PC.json
        ...or double-click the restore .cmd next to this script.
#>
param(
    [string]$LayoutFile
)

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

foreach ($src in @('Native.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $src))) {
        throw "missing $src next to this script. Keep Native.cs and the .ps1 files together in one folder."
    }
}
try {
    Add-Type -Path "$PSScriptRoot\Native.cs"
} catch {
    throw ("could not compile the helper source (the .NET Framework 4.x C# compiler is needed):`n" + $_.Exception.Message)
}
[void][DeskNative]::SetProcessDPIAware()

# ------------------------------------------------------------- find a snapshot
$snapDir = Join-Path $PSScriptRoot 'snapshots'
if (-not (Test-Path -LiteralPath $snapDir)) { $snapDir = Join-Path $env:TEMP 'DesktopIconArranger' }

if (-not $LayoutFile) {
    foreach ($cand in @(
        (Join-Path $snapDir "last-$env:COMPUTERNAME.json"),
        (Join-Path $snapDir "original-$env:COMPUTERNAME.json"))) {
        if (Test-Path -LiteralPath $cand) { $LayoutFile = $cand; break }
    }
}
if (-not $LayoutFile) {
    $have = @()
    if (Test-Path -LiteralPath $snapDir) {
        $have = @(Get-ChildItem -LiteralPath $snapDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    throw ("no snapshot found for computer '$env:COMPUTERNAME' in $snapDir.`n" +
           "Snapshots present: " + $(if ($have.Count) { $have -join ', ' } else { '(none)' }) + "`n" +
           "Use -LayoutFile <path> to pick one explicitly.")
}
if (-not (Test-Path -LiteralPath $LayoutFile)) { throw "layout file not found: $LayoutFile" }

# NOTE: in Windows PowerShell 5.1 ConvertFrom-Json writes a top level array as a
# single pipeline object, so "@(... | ConvertFrom-Json)" would collapse to one
# item.  Read it raw and flatten explicitly.
$parsed = Get-Content -LiteralPath $LayoutFile -Encoding UTF8 -Raw | ConvertFrom-Json
if ($null -eq $parsed) { throw "layout file is empty or not valid JSON: $LayoutFile" }
$layout = @($parsed | ForEach-Object { $_ })
if ($layout.Count -eq 1 -and $layout[0] -is [System.Array]) { $layout = @($layout[0] | ForEach-Object { $_ }) }
"restoring from : $LayoutFile"
"snapshot holds : $($layout.Count) icons"

$view = New-Object DesktopView
try {
    $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
    $cs = $view.ClientSize
    $marginX = 16; $marginY = 2
    $count = $view.Count

    $usableW = $cs[0]; $usableH = $cs[1]
    $wa = [DeskNative]::GetWorkArea()
    if ($wa) {
        if (($wa[2] - $wa[0]) -gt 0 -and ($wa[2] - $wa[0]) -lt $usableW) { $usableW = $wa[2] - $wa[0] }
        if (($wa[3] - $wa[1]) -gt 0 -and ($wa[3] - $wa[1]) -lt $usableH) { $usableH = $wa[3] - $wa[1] }
    }
    $rows   = [int][math]::Floor(($usableH - $marginY) / $ch)
    $maxCol = [int][math]::Floor(($usableW - $marginX) / $cw) - 1

    function Get-IndexMap([object]$v, [int]$n) {
        $m = @{}
        for ($i = 0; $i -lt $n; $i++) { $m[$v.GetName($i)] = $i }
        return $m
    }
    function Get-OffTarget([object]$v, [object]$m, [object]$pl) {
        $bad = @()
        foreach ($p in $pl) {
            if (-not $m.ContainsKey($p.Name)) { continue }
            $pos = $v.GetPosition($m[$p.Name])
            if ($pos[0] -ne $p.X -or $pos[1] -ne $p.Y) { $bad += $p }
        }
        return $bad
    }

    $map = Get-IndexMap $view $count

    # Snapshot entries whose icon still exists, clamped onto the current grid.
    $plan = @()
    $used = @{}
    foreach ($e in $layout) {
        if (-not $map.ContainsKey($e.Name)) { continue }
        $col = [int][math]::Floor(([int]$e.X - $marginX) / $cw)
        $row = [int][math]::Floor(([int]$e.Y - $marginY) / $ch)
        if ($col -lt 0 -or $col -gt $maxCol -or $row -lt 0 -or $row -gt $rows - 1) { continue }
        $x = [int]($marginX + $col * $cw); $y = [int]($marginY + $row * $ch)
        $key = "$x,$y"
        if ($used.ContainsKey($key)) { continue }
        $used[$key] = $true
        $plan += [pscustomobject]@{ Name = $e.Name; X = $x; Y = $y }
    }

    # Icons that are not in the snapshot: park them in the leftover free cells.
    $extra = @()
    $planned = @{}
    foreach ($p in $plan) { $planned[$p.Name] = $true }
    foreach ($n in $map.Keys) { if (-not $planned.ContainsKey($n)) { $extra += $n } }

    $free = New-Object System.Collections.ArrayList
    for ($c = 0; $c -le $maxCol; $c++) {
        for ($r = 0; $r -lt $rows; $r++) {
            $x = [int]($marginX + $c * $cw); $y = [int]($marginY + $r * $ch)
            if (-not $used.ContainsKey("$x,$y")) { [void]$free.Add(@($x, $y)) }
        }
    }
    "matched $($plan.Count) snapshot icon(s); $($extra.Count) extra icon(s); $($free.Count) free cell(s)"
    for ($i = 0; $i -lt $extra.Count; $i++) {
        if ($i -ge $free.Count) { "  ! no free cell left for $($extra[$i]) - left where it is"; break }
        $plan += [pscustomobject]@{ Name = $extra[$i]; X = $free[$i][0]; Y = $free[$i][1] }
    }

    # Staging columns: everything the plan does not touch.
    $planCols = @($plan | ForEach-Object { [int](($_.X - $marginX) / $cw) } | Sort-Object -Unique)
    $stageCols = @(0..$maxCol | Where-Object { $planCols -notcontains $_ })
    if ($stageCols.Count * $rows -lt $plan.Count) { throw "not enough free columns to stage $($plan.Count) icons safely" }

    # Phase A - park everything in the free columns so no target slot is occupied.
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $col = $stageCols[[int][math]::Floor($i / $rows)]
        $view.SetPosition($map[$plan[$i].Name], [int]($marginX + $col * $cw), [int]($marginY + ($i % $rows) * $ch))
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 500

    # Phase B - place every icon on its slot.
    $map = Get-IndexMap $view $count
    foreach ($p in $plan) {
        $view.SetPosition($map[$p.Name], $p.X, $p.Y)
        Start-Sleep -Milliseconds 25
    }
    $view.Refresh()
    Start-Sleep -Milliseconds 800

    # Phase C - repair passes.
    for ($pass = 1; $pass -le 8; $pass++) {
        $map = Get-IndexMap $view $count
        $bad = @(Get-OffTarget $view $map $plan)
        if ($bad.Count -eq 0) { break }
        "repair pass $pass : $($bad.Count) icon(s) off target"
        foreach ($p in $bad) {
            $view.SetPosition($map[$p.Name], $p.X, $p.Y)
            Start-Sleep -Milliseconds 25
        }
        $view.Refresh()
        Start-Sleep -Milliseconds 600
    }

    $map = Get-IndexMap $view $count
    $bad = @(Get-OffTarget $view $map $plan)
    ""
    if ($bad.Count -eq 0) { "OK - desktop restored to the saved layout." }
    else { "$($bad.Count) icon(s) could not be restored." }
}
finally { $view.Dispose() }
