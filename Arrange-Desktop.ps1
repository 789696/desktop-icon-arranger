<#
    Arrange-Desktop.ps1

    Lays the Windows desktop icons out in four zones, left to right:

      [1] TEMP FILES   - loose files grouped by type; every type is one
                         horizontal row, rows run top-to-bottom in Explorer's
                         natural name order of the extension, items inside a row
                         run left-to-right.  The widest row leaves exactly one
                         free column before the folder block.
      [2] FOLDERS      - real folders and folder shortcuts, vertically centred,
                         immediately to the right of the file rows (one free
                         column between them).
      [3] THIS PC / RECYCLE BIN - one column, vertically centred, with one empty
                         column before the application block.
      [4] APPLICATIONS - shortcuts, hard against the right edge.  Icons are
                         ordered by colour family top-to-bottom in rainbow order:
                             WHITE -> RED -> ORANGE -> YELLOW -> GREEN -> CYAN
                             -> BLUE -> PURPLE -> BLACK
                         and filled left-to-right, row by row, in as few columns
                         as the screen height allows (rows may mix families).
                         Any icon darker than $blackLight is filed as black.

    Usage
      preview only :  powershell -ExecutionPolicy Bypass -File Arrange-Desktop.ps1
      apply        :  powershell -ExecutionPolicy Bypass -File Arrange-Desktop.ps1 -Apply
      apply, quiet :  ... -Apply -Yes
      ...or simply double-click the .cmd files that sit next to this script.

    Portable: uses only Windows PowerShell 5.1 and the .NET Framework, both of
    which ship with Windows 10/11.  No installation, no admin rights, no
    internet.  Copy the whole folder to any Windows PC and run it there - the
    folder name and location do not matter.

    Requirements: explorer.exe running in the current desktop session, and
    "Auto arrange icons" switched off (right-click desktop > View).
    "Align icons to grid" may stay on.
#>
param(
    [switch]$Apply,
    [switch]$Yes        # skip the "press Enter" confirmation when applying
)

$ErrorActionPreference = 'Stop'

# Chinese icon names must survive the console round trip.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

foreach ($src in @('Native.cs', 'IconColor.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $src))) {
        throw "missing $src next to this script. Keep Native.cs, IconColor.cs and the .ps1 files together in one folder."
    }
}
try {
    Add-Type -Path "$PSScriptRoot\Native.cs"
    Add-Type -Path "$PSScriptRoot\IconColor.cs" -ReferencedAssemblies System.Drawing
} catch {
    throw ("could not compile the helper sources (the .NET Framework 4.x C# compiler is needed):`n" + $_.Exception.Message)
}
[void][DeskNative]::SetProcessDPIAware()

try { $shell = New-Object -ComObject WScript.Shell } catch { $shell = $null }

# ------------------------------------------------------------------- settings
$folderCols   = 2          # width of the folder block in columns
$fileRowMax   = 5          # a single file type never spreads wider than this
$neutralCut   = 0.15       # below this colourfulness an icon counts as grey
$whiteLight   = 0.80       # a coloured icon this light is filed as white
$paleLight    = 0.50       # grey icons at least this light are white, else black
$blackLight   = 0.40       # any icon this dark is filed as black, whatever its hue

# rainbow order, white on top and black at the bottom
$familyOrder = @('WHITE', 'RED', 'ORANGE', 'YELLOW', 'GREEN', 'CYAN', 'BLUE', 'PURPLE', 'BLACK')

# ------------------------------------------------- personal overrides (optional)
# "分类覆盖.txt" - one rule per line, "icon name = VALUE", # starts a comment.
# VALUE is either a colour family (WHITE..BLACK) or a zone (FILE/FOLDER/APP/SPECIAL)
# so the automatic classification can be corrected without editing this script.
$overrideFile = Join-Path $PSScriptRoot ([string]([char]0x5206 + [char]0x7C7B + [char]0x8986 + [char]0x76D6) + '.txt')
$familyOverride = @{}
$kindOverride   = @{}
$overrideNotes  = @()
if (Test-Path -LiteralPath $overrideFile) {
    foreach ($line in @(Get-Content -LiteralPath $overrideFile -Encoding UTF8)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '=', 2
        if ($parts.Count -ne 2) { $overrideNotes += "ignored (no '='): $t"; continue }
        $nm = $parts[0].Trim(); $vl = $parts[1].Trim().ToUpper()
        if (-not $nm -or -not $vl) { $overrideNotes += "ignored (empty): $t"; continue }
        if ($familyOrder -contains $vl) { $familyOverride[$nm] = $vl }
        elseif (@('FILE', 'FOLDER', 'APP', 'SPECIAL') -contains $vl) { $kindOverride[$nm] = $vl }
        else { $overrideNotes += "ignored (unknown value '$vl'): $t" }
    }
}

$desk  = [Environment]::GetFolderPath('Desktop')
$pub   = [Environment]::GetFolderPath('CommonDesktopDirectory')

# Shell namespace items are addressed by CLSID; their icons cannot be read back
# through SHGetFileInfo, so their measured colours are pinned here.
$special = @{}
$special[[string]([char]0x6B64 + [char]0x7535 + [char]0x8111)] = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'  # This PC
$special[[string]([char]0x56DE + [char]0x6536 + [char]0x7AD9)] = '::{645FF040-5081-101B-9F08-00AA002F954E}'  # Recycle Bin
$pinned = @{}
$pinned[[string]([char]0x6B64 + [char]0x7535 + [char]0x8111)] = @{ Hue = 208.0; CF = 0.55; Light = 0.58 }
$pinned[[string]([char]0x56DE + [char]0x6536 + [char]0x7AD9)] = @{ Hue = $null; CF = 0.05; Light = 0.80 }

function Resolve-IconPath([string]$name) {
    if ($special.ContainsKey($name)) { return $special[$name] }
    foreach ($p in @(
        (Join-Path $desk "$name.lnk"), (Join-Path $desk "$name.url"), (Join-Path $desk $name),
        (Join-Path $pub  "$name.lnk"), (Join-Path $pub  "$name.url"), (Join-Path $pub  $name))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

function Get-Kind([string]$name) {
    if ($special.ContainsKey($name)) { return 'SPECIAL' }
    foreach ($d in @($desk, $pub)) {
        $p = Join-Path $d $name
        if (Test-Path -LiteralPath $p -PathType Container) { return 'FOLDER' }
        if (Test-Path -LiteralPath $p -PathType Leaf)      { return 'FILE' }
        $lnk = Join-Path $d "$name.lnk"
        if (Test-Path -LiteralPath $lnk -PathType Leaf) {
            if ($shell) {
                try {
                    $t = $shell.CreateShortcut($lnk).TargetPath
                    if ($t -and (Test-Path -LiteralPath $t -PathType Container)) { return 'FOLDER' }
                } catch { }
            }
            return 'APP'
        }
        if (Test-Path -LiteralPath (Join-Path $d "$name.url") -PathType Leaf) { return 'APP' }
    }
    return 'APP'
}

# Explorer's own natural name order (so "file2" sorts before "file10").
function Sort-Natural([string[]]$names) {
    $a = @($names)
    for ($i = 1; $i -lt $a.Count; $i++) {
        $j = $i
        while ($j -gt 0 -and [DeskNative]::StrCmpLogicalW($a[$j - 1], $a[$j]) -gt 0) {
            $t = $a[$j]; $a[$j] = $a[$j - 1]; $a[$j - 1] = $t
            $j--
        }
    }
    return $a
}

function Get-AppFamily([object]$hue, [double]$cf, [double]$light) {
    if ($light -lt $blackLight) { return 'BLACK' }      # dark icons read as black
    if ($cf -lt $neutralCut -or $null -eq $hue) {
        if ($light -ge $paleLight) { return 'WHITE' } else { return 'BLACK' }
    }
    if ($light -ge $whiteLight) { return 'WHITE' }
    $h = [double]$hue
    if ($h -ge 330 -or $h -lt 15) { return 'RED' }
    if ($h -lt 45)  { return 'ORANGE' }
    if ($h -lt 70)  { return 'YELLOW' }
    if ($h -lt 160) { return 'GREEN' }
    if ($h -lt 200) { return 'CYAN' }
    if ($h -lt 255) { return 'BLUE' }
    return 'PURPLE'
}

# ---------------------------------------------------------------- read desktop
$raw = @()
$view = New-Object DesktopView
try {
    $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
    $cs = $view.ClientSize
    for ($i = 0; $i -lt $view.Count; $i++) {
        $pos = $view.GetPosition($i)
        $raw += [pscustomobject]@{ Name = $view.GetName($i); X = $pos[0]; Y = $pos[1] }
    }
}
finally { $view.Dispose() }

$marginX = 16; $marginY = 2
# Use the primary monitor work area so the bottom row never hides behind the
# taskbar - the taskbar can be taller or the scaling different on another PC.
$usableW = $cs[0]; $usableH = $cs[1]
$wa = [DeskNative]::GetWorkArea()
if ($wa) {
    if (($wa[2] - $wa[0]) -gt 0 -and ($wa[2] - $wa[0]) -lt $usableW) { $usableW = $wa[2] - $wa[0] }
    if (($wa[3] - $wa[1]) -gt 0 -and ($wa[3] - $wa[1]) -lt $usableH) { $usableH = $wa[3] - $wa[1] }
}
$rows   = [int][math]::Floor(($usableH - $marginY) / $ch)
$maxCol = [int][math]::Floor(($usableW - $marginX) / $cw) - 1
if ($rows -lt 1 -or $maxCol -lt 1) { throw "could not measure the desktop grid (rows=$rows columns=$($maxCol + 1))" }

# ------------------------------------------------------------------ classify
$kinds = @{}
foreach ($r in $raw) {
    $kinds[$r.Name] = if ($kindOverride.ContainsKey($r.Name)) { $kindOverride[$r.Name] } else { Get-Kind $r.Name }
}

$fileNames    = Sort-Natural @($raw | Where-Object { $kinds[$_.Name] -eq 'FILE' }   | ForEach-Object { $_.Name })
$folderNames  = Sort-Natural @($raw | Where-Object { $kinds[$_.Name] -eq 'FOLDER' } | ForEach-Object { $_.Name })
$specialNames = @($raw | Where-Object { $kinds[$_.Name] -eq 'SPECIAL' } | ForEach-Object { $_.Name } |
                  Sort-Object { if ($_ -eq [string]([char]0x6B64 + [char]0x7535 + [char]0x8111)) { 0 } else { 1 } })
$appNames     = @($raw | Where-Object { $kinds[$_.Name] -eq 'APP' } | ForEach-Object { $_.Name })

# ------------------------------------------------- file zone: one row per type
$fileRows = @()
$fileTypes = Sort-Natural @($fileNames | ForEach-Object { [System.IO.Path]::GetExtension($_).ToLower() } | Sort-Object -Unique)
foreach ($t in $fileTypes) {
    $members = @($fileNames | Where-Object { [System.IO.Path]::GetExtension($_).ToLower() -eq $t })
    for ($i = 0; $i -lt $members.Count; $i += $fileRowMax) {
        $fileRows += , @{ Type = $t; Items = @($members[$i..([int][math]::Min($i + $fileRowMax - 1, $members.Count - 1))]) }
    }
}
$fileZoneWidth = 0
foreach ($fr in $fileRows) { if ($fr.Items.Count -gt $fileZoneWidth) { $fileZoneWidth = $fr.Items.Count } }

# ------------------------------------------------------------- zone geometry
# the folder block sits exactly one free column right of the widest file row,
# and every zone except the full-height application block is vertically centred
$folderZoneCol  = $fileZoneWidth + 1
$fileTopRow     = [int][math]::Ceiling(($rows - $fileRows.Count) / 2)
$folderRowsUsed = [int][math]::Ceiling($folderNames.Count / $folderCols)
$folderTopRow   = [int][math]::Ceiling(($rows - $folderRowsUsed) / 2)

$appZoneRight  = $maxCol
$appColWidth   = [math]::Max(1, [int][math]::Ceiling($appNames.Count / $rows))   # fewest columns that fit
$appRowCount   = if ($appNames.Count -gt 0) { [int][math]::Ceiling($appNames.Count / $appColWidth) } else { 0 }
$appTopRow     = [int][math]::Ceiling(($rows - $appRowCount) / 2)                # keep clear of the top edge
$appZoneLeft   = $appZoneRight - $appColWidth + 1
$specialCol    = $appZoneLeft - 2                                                # one empty gap column
$specialTopRow = [int][math]::Ceiling(($rows - $specialNames.Count) / 2)

# --- fit checks: fail with a clear message instead of scrambling the desktop
if ($fileRows.Count -gt $rows)  { throw "the file rows need $($fileRows.Count) rows but only $rows fit on this screen" }
if ($folderRowsUsed -gt $rows)  { throw "the folder block needs $folderRowsUsed rows but only $rows fit on this screen" }
if ($appRowCount -gt $rows)     { throw "the application block needs $appRowCount rows but only $rows fit on this screen" }
if ($specialCol -le ($folderZoneCol + $folderCols - 1)) {
    throw "not enough room across the screen: the application block needs $appColWidth column(s) and would collide with the folder block. Remove some desktop icons or use a wider screen."
}

"screen $($cs[0])x$($cs[1])   usable $($usableW)x$($usableH)   grid $cw x $ch   columns 0..$maxCol   rows/column $rows"
"zones: FILE $($fileNames.Count)   FOLDER $($folderNames.Count)   SPECIAL $($specialNames.Count)   APP $($appNames.Count)"
if ($familyOverride.Count -or $kindOverride.Count) {
    $ov = @()
    foreach ($k in $familyOverride.Keys) { $ov += "$k=$($familyOverride[$k])" }
    foreach ($k in $kindOverride.Keys)   { $ov += "$k=$($kindOverride[$k])" }
    "personal overrides applied: " + ($ov -join ', ')
}
foreach ($n in $overrideNotes) { "  override $n" }
"  FILE    : columns 0..$($fileZoneWidth - 1)  ($($fileRows.Count) type rows, widest $fileZoneWidth), rows $fileTopRow..$($fileTopRow + $fileRows.Count - 1) (vertically centred)"
"            types: " + (($fileTypes | ForEach-Object { "$_" }) -join ' ')
"            gap before the folder block: $($folderZoneCol - $fileZoneWidth) column (k$fileZoneWidth)"
"  FOLDER  : columns $folderZoneCol..$($folderZoneCol + $folderCols - 1)  (x $($marginX + $folderZoneCol * $cw)..$($marginX + ($folderZoneCol + $folderCols) * $cw) = $([int](100 * ($marginX + $folderZoneCol * $cw) / $cs[0]))%-$([int](100 * ($marginX + ($folderZoneCol + $folderCols) * $cw) / $cs[0]))% of the width)"
"            rows $folderTopRow..$($folderTopRow + $folderRowsUsed - 1), vertically centred"
"  SPECIAL : column $specialCol, rows $specialTopRow..$($specialTopRow + $specialNames.Count - 1) (vertically centred), gap column $($specialCol + 1)"
"  APP     : columns $appZoneLeft..$appZoneRight  ($appColWidth columns, right aligned, rows may mix families)"
"            rows $appTopRow..$($appTopRow + $appRowCount - 1) (vertically centred)"
""

# ------------------------------------------------------------ colour of apps
$appInfo = foreach ($n in $appNames) {
    if ($pinned.ContainsKey($n)) {
        $h = $pinned[$n].Hue; $cf = [double]$pinned[$n].CF; $lt = [double]$pinned[$n].Light
    }
    else {
        $ci = [IconColorAnalyzer]::Analyze((Resolve-IconPath $n))
        $h  = if ($ci.Found -and $ci.Hue -ge 0) { [double]$ci.Hue } else { $null }
        $cf = if ($ci.Found) { [double]$ci.Colorfulness } else { 0.0 }
        $lt = if ($ci.Found) { [double]$ci.Lightness } else { 0.5 }
    }
    $fam = Get-AppFamily $h $cf $lt
    if ($familyOverride.ContainsKey($n)) { $fam = $familyOverride[$n] }
    [pscustomobject]@{
        Name  = $n
        Family = $fam
        HueKey   = if ($null -ne $h -and $h -ge 330 -and $fam -eq 'RED') { [double]$h - 360 }
                   else { if ($null -eq $h) { 0.0 } else { [double]$h } }
        LightKey = -1 * $lt
    }
}

# colour order top-to-bottom; inside a family the hue runs as a gradient
$appSorted = @()
foreach ($f in $familyOrder) {
    $members = @($appInfo | Where-Object { $_.Family -eq $f })
    if ($members.Count -eq 0) { continue }
    if ($f -eq 'WHITE' -or $f -eq 'BLACK') { $members = @($members | Sort-Object LightKey, Name) }
    else                                   { $members = @($members | Sort-Object HueKey, Name) }
    $appSorted += $members
}

# ------------------------------------------------------------------ build plan
$script:cw = $cw; $script:ch = $ch; $script:marginX = $marginX; $script:marginY = $marginY
$script:plan = @()
function Add-Plan([string]$name, [int]$col, [int]$row, [string]$zone) {
    $script:plan += [pscustomobject]@{
        Name = $name; Zone = $zone
        X = [int]($script:marginX + $col * $script:cw)
        Y = [int]($script:marginY + $row * $script:ch)
    }
}

for ($r = 0; $r -lt $fileRows.Count; $r++) {
    $items = $fileRows[$r].Items
    for ($i = 0; $i -lt $items.Count; $i++) { Add-Plan $items[$i] $i ($fileTopRow + $r) ('FILE ' + $fileRows[$r].Type) }
}
for ($i = 0; $i -lt $folderNames.Count; $i++) {
    Add-Plan $folderNames[$i] ($folderZoneCol + [int][math]::Floor($i / $folderRowsUsed)) ($folderTopRow + ($i % $folderRowsUsed)) 'FOLDER'
}
for ($i = 0; $i -lt $specialNames.Count; $i++) {
    Add-Plan $specialNames[$i] $specialCol ($specialTopRow + $i) 'SPECIAL'
}
for ($i = 0; $i -lt $appSorted.Count; $i++) {
    $r = $appTopRow + [int][math]::Floor($i / $appColWidth)
    $inRow = [int][math]::Min($appColWidth, $appSorted.Count - ($r - $appTopRow) * $appColWidth)
    Add-Plan $appSorted[$i].Name ($appZoneRight - $inRow + 1 + ($i % $appColWidth)) $r ('APP ' + $appSorted[$i].Family)
}
if ($appRowCount -gt 0 -and $appTopRow + $appRowCount - 1 -ge $rows) {
    throw "the app zone needs more rows than the screen has"
}

# ------------------------------------------------------------------- print it
$grid = @{}
foreach ($p in $plan) { $grid["$($p.X),$($p.Y)"] = $p }
$planCols = @($plan | ForEach-Object { [int](($_.X - $marginX) / $cw) } | Sort-Object -Unique)
"columns used: " + ($planCols -join ', ')
""
for ($r = 0; $r -lt $rows; $r++) {
    $y = $marginY + $r * $ch
    $line = @()
    foreach ($col in $planCols) {
        $c = $grid["$([int]($marginX + $col * $cw)),$y"]
        $line += ('{0,-26}' -f $(if ($c) { "$($c.Name) <$($c.Zone)>" } else { '.' }))
    }
    $line -join '| '
}

if (-not $Apply) {
    ""
    "DRY RUN - nothing moved. Re-run with -Apply to apply, or double-click the .cmd file."
    return
}

if (-not $Yes) {
    $interactive = $false
    try { $interactive = -not [Console]::IsInputRedirected } catch { }
    if ($interactive) {
        ""
        $answer = Read-Host "Press Enter to arrange the desktop now, or type N then Enter to cancel"
        if ($answer -match '^\s*(n|no)\s*$') { "cancelled - nothing was moved."; return }
    }
}

# ---------------------------------------------------------------------- apply
# Snapshot of the current layout, so "restore" can undo this run.  The file name
# carries the computer name, so one shared folder stays clean across machines.
$snapDir = Join-Path $PSScriptRoot 'snapshots'
try {
    if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
} catch { }
if (-not (Test-Path -LiteralPath $snapDir)) { $snapDir = Join-Path $env:TEMP 'DesktopIconArranger' }

$backup = Join-Path $snapDir "last-$env:COMPUTERNAME.json"
try {
    @($raw) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backup -Encoding UTF8
} catch {
    $backup = Join-Path $env:TEMP "desktop-layout-$env:COMPUTERNAME.json"
    @($raw) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backup -Encoding UTF8
}

$freeCols  = @(0..$maxCol | Where-Object { $planCols -notcontains $_ })
$stageCols = @($freeCols | Select-Object -First ([int][math]::Ceiling($plan.Count / $rows)))

$view = New-Object DesktopView
try {
    $count = $view.Count
    if ($count -ne $plan.Count) { throw "desktop icon count changed ($count vs $($plan.Count)); aborting" }

    function Get-IndexMap([object]$v, [int]$n) { $m = @{}; for ($i = 0; $i -lt $n; $i++) { $m[$v.GetName($i)] = $i }; return $m }
    function Get-OffTarget([object]$v, [object]$m, [object]$pl) {
        $bad = @()
        foreach ($p in $pl) {
            if (-not $m.ContainsKey($p.Name)) { continue }
            $pos = $v.GetPosition($m[$p.Name])
            if ($pos[0] -ne $p.X -or $pos[1] -ne $p.Y) { $bad += $p }
        }
        return $bad
    }

    # Phase A - park everything in free columns, so no final slot is occupied when
    # it is filled (moving onto an occupied slot makes explorer push the occupant).
    $map = Get-IndexMap $view $count
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $col = $stageCols[[int][math]::Floor($i / $rows)]
        $view.SetPosition($map[$plan[$i].Name], [int]($marginX + $col * $cw), [int]($marginY + ($i % $rows) * $ch))
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 500

    # Phase B - fill the planned slots.
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
        foreach ($p in $bad) { $view.SetPosition($map[$p.Name], $p.X, $p.Y); Start-Sleep -Milliseconds 25 }
        $view.Refresh(); Start-Sleep -Milliseconds 600
    }

    $map = Get-IndexMap $view $count
    $bad = @(Get-OffTarget $view $map $plan)
    ""
    "layout before this run saved to: $backup"
    if ($bad.Count -eq 0) {
        "OK - all $($plan.Count) icons are in their planned zone slot."
        "To undo this, run Restore-DesktopIcons.ps1 (or the restore .cmd)."
    }
    else { "$($bad.Count) icon(s) off target:"; $bad | ForEach-Object { "  $($_.Name) -> $($_.X),$($_.Y)" } }
}
finally { $view.Dispose() }
