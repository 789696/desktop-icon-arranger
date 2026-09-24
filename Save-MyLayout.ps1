<#
    Save-MyLayout.ps1  -  DesktopIconArranger toolbox

    Remembers the desktop exactly as you have arranged it by hand.
    Writes snapshots\my-<COMPUTERNAME>.json, which "3-apply-my-layout.cmd" replays.

    Use it after nudging icons around manually: the automatic rules cannot know
    your taste, but once you are happy you can freeze the result.

    Usage
        powershell -ExecutionPolicy Bypass -File Save-MyLayout.ps1
        powershell -ExecutionPolicy Bypass -File Save-MyLayout.ps1 -OutFile .\snapshots\other.json
#>
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Native.cs'))) {
    throw "missing Native.cs next to this script. Keep the whole folder together."
}
try {
    Add-Type -Path "$PSScriptRoot\Native.cs"
} catch {
    throw ("could not compile the helper source (the .NET Framework 4.x C# compiler is needed):`n" + $_.Exception.Message)
}
[void][DeskNative]::SetProcessDPIAware()

$snapDir = Join-Path $PSScriptRoot 'snapshots'
if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
if (-not $OutFile) { $OutFile = Join-Path $snapDir "my-$env:COMPUTERNAME.json" }

$view = New-Object DesktopView
try {
    $rows = @()
    for ($i = 0; $i -lt $view.Count; $i++) {
        $p = $view.GetPosition($i)
        $rows += [pscustomobject]@{ Name = $view.GetName($i); X = [int]$p[0]; Y = [int]$p[1] }
    }
}
finally { $view.Dispose() }

$json = if ($rows.Count -eq 1) { ConvertTo-Json -InputObject $rows[0] -Depth 3 } else { ConvertTo-Json -InputObject $rows -Depth 3 }
Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8

"saved $($rows.Count) icon positions to:"
"  $OutFile"
""
"Double-click '3-apply-my-layout.cmd' to put the desktop back exactly like this."
