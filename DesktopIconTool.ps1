<#
    桌面图标排列工具  DesktopIconTool.ps1

    一个文件的交互式工具，把"排列 / 保存布局 / 应用布局 / 撤销"合在一起。

    用法
      双击同目录的「桌面图标工具.cmd」即可进入交互菜单。
      也可以命令行直接调用：
        powershell -ExecutionPolicy Bypass -File DesktopIconTool.ps1                 (交互菜单)
        ... -Action Info                                                              (只看显示器与图标分布)
        ... -Action Preview -Monitor 1                                                (只看方案，不动图标)
        ... -Action Arrange -Monitor 1 -Yes                                           (直接把全部图标排到 1 号屏)

    设计要点
      · 多显示器：先枚举每块屏幕的工作区，再把网格限制在所选屏幕内，不会排到
        两块屏幕之间的"无显示缝隙"里。
      · 每块屏幕有各自的"对齐网格"锚点（不同 DPI 的副屏常和主屏差几个像素）。
        工具会给每块屏幕单独测出锚点；若某块屏幕当前一个图标都没有，会用一个探针
        图标短暂挪过去量一下（立即还原，图标位置不变）。
      · 每次"排列 / 应用 / 恢复最初"之前都会自动把当前图标位置压入历史栈，
        菜单里的「撤销」可以一键回到操作前的位置（可连续撤销）。
      · 只用 Windows PowerShell 5.1 与 .NET Framework，免安装、免联网、免管理员。
#>
param(
    [ValidateSet('Menu', 'Info', 'Check', 'Preview', 'Arrange', 'Save', 'Apply', 'Undo', 'Original', 'Render')]
    [string]$Action = 'Menu',
    [int]$Monitor = -1,      # 0 基的屏幕序号；-1 = 自动（图标最多的那块屏）
    [switch]$Yes,            # 需要确认的操作不再询问
    [ValidateSet('Strict', 'Compact', 'Packed')]
    [string]$Strategy = 'Compact',  # 应用区策略：Compact=一行一个色系、必要时相邻色系拼行压行数（默认）；Strict=严格一行一个色系；Packed=逐行填满
    [string]$Out = ''              # Render 动作的输出图片路径（留空则写到 snapshots\）
)

$ErrorActionPreference = 'Stop'

# 中文要能正确穿过控制台
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Test-DotNetType([string]$name) {
    return [bool]([System.Management.Automation.PSTypeName]$name).Type
}

# ------------------------------------------------------------ 编译辅助源码
foreach ($src in @('Native.cs', 'IconColor.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:Root $src))) {
        throw "缺少 $src。请把整个文件夹一起复制，不要只拿单个文件。"
    }
}
try {
    if (-not (Test-DotNetType 'DeskNative')) {
        Add-Type -Path (Join-Path $script:Root 'Native.cs')
    }
    if (-not (Test-DotNetType 'IconColorAnalyzer')) {
        Add-Type -Path (Join-Path $script:Root 'IconColor.cs') -ReferencedAssemblies System.Drawing
    }
}
catch {
    throw ("无法编译辅助源码（需要 .NET Framework 4.x 自带的 C# 编译器）：`n" + $_.Exception.Message)
}
[void][DeskNative]::EnableBestDpiAwareness()

try { $script:shell = New-Object -ComObject WScript.Shell } catch { $script:shell = $null }

# ------------------------------------------------------------------- 参数
$folderCols = 2          # 文件夹区宽度（列数）
$fileRowMax = 5          # 单个文件类型最宽占几列
$appMinCols = 3          # 应用区最少占几列（防止高分辨率副屏上被压成又高又窄的两列）
# 颜色分类（v2：面积投票 + 中位色，规则移植自上一版 desktop-icon-arranger 工程）
$whiteAreaCut = 0.50     # 近白像素占比达到此值 → 白色系
$whiteMedCut  = 0.85     # 中位亮度达到此值 → 白色系
$blackAreaCut = 0.50     # 近黑像素占比达到此值 → 黑色系
$dominantCut  = 0.40     # 某色系占面积达到此值，直接采用它
$darkMedCut   = 0.20     # 冷色占主导但中位亮度很低 → 黑色系
$nearGraySat  = 0.12     # 中位色饱和度低于此值视为灰
$darkGrayCut  = 0.25     # 灰且中位亮度很低 → 黑色系
$grayHueCut   = 0.20     # 灰但仍有某色系占比达到此值 → 采用该色系
$vividWeight  = 0.55     # 鲜明度 = 0.55×彩度 + 0.45×中位亮度（每行内左亮右暗）
$marginX = 16            # 网格锚点兜底值（检测不到时使用）
$marginY = 2
$historyKeep = 30        # 历史栈最多保留多少份

# 网格信息：Windows 的"对齐到网格"是"每块屏幕各自一套格子"。不同 DPI 的副屏锚点
# 常常和主屏差几个像素（本机主屏 27,2，副屏 43,197）。若只用一个全局锚点，排到副屏
# 的图标会永远"差一点、对不齐"，撤销也会整屏错位。这里给每块屏幕单独记录锚点，
# 见 Get-AnchorsFromRows / Probe-Lattice / Initialize-GridInfo。
$script:GridInfo = $null

$familyOrder = @('WHITE', 'RED', 'ORANGE', 'YELLOW', 'GREEN', 'CYAN', 'BLUE', 'PURPLE', 'BLACK', 'MIXED')

$desk = [Environment]::GetFolderPath('Desktop')
$pub  = [Environment]::GetFolderPath('CommonDesktopDirectory')

# ------------------------------------------------- 个人分类覆盖（可选文件）
$overrideFile = Join-Path $script:Root ([string]([char]0x5206 + [char]0x7C7B + [char]0x8986 + [char]0x76D6) + '.txt')
$familyOverride = @{}
$kindOverride   = @{}
$overrideNotes  = @()
if (Test-Path -LiteralPath $overrideFile) {
    foreach ($line in @(Get-Content -LiteralPath $overrideFile -Encoding UTF8)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '=', 2
        if ($parts.Count -ne 2) { $overrideNotes += "忽略（缺少 =）：$t"; continue }
        $nm = $parts[0].Trim(); $vl = $parts[1].Trim().ToUpper()
        if (-not $nm -or -not $vl) { $overrideNotes += "忽略（空值）：$t"; continue }
        if ($familyOrder -contains $vl) { $familyOverride[$nm] = $vl }
        elseif (@('FILE', 'FOLDER', 'APP', 'SPECIAL') -contains $vl) { $kindOverride[$nm] = $vl }
        else { $overrideNotes += "忽略（未知取值 $vl）：$t" }
    }
}

# 系统图标（此电脑 / 回收站）：颜色无法通过 SHGetFileInfo 读回，直接钉死
$nameThisPC = [string]([char]0x6B64 + [char]0x7535 + [char]0x8111)
$nameBin    = [string]([char]0x56DE + [char]0x6536 + [char]0x7AD9)
$special = @{}
$special[$nameThisPC] = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
$special[$nameBin]    = '::{645FF040-5081-101B-9F08-00AA002F954E}'
$pinned = @{}
$pinned[$nameThisPC] = @{ Hue = 208.0; CF = 0.55; Light = 0.58; Family = 'BLUE' }
$pinned[$nameBin]    = @{ Hue = $null; CF = 0.05; Light = 0.80; Family = 'WHITE' }

# 快照目录
$snapDir = Join-Path $script:Root 'snapshots'
try { if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null } } catch { }
if (-not (Test-Path -LiteralPath $snapDir)) { $snapDir = Join-Path $env:TEMP 'DesktopIconArranger' }
$histDir = Join-Path $snapDir ("history-$env:COMPUTERNAME")

$script:MyLayout   = Join-Path $snapDir "my-$env:COMPUTERNAME.json"
$script:Original   = Join-Path $snapDir "original-$env:COMPUTERNAME.json"
$script:LastBackup = Join-Path $snapDir "last-$env:COMPUTERNAME.json"

# ================================================================ 基础工具

# Explorer 自己的名称顺序（自然排序："obj_2_20" 排在 "obj_2_111" 前）
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
            if ($script:shell) {
                try {
                    $t = $script:shell.CreateShortcut($lnk).TargetPath
                    if ($t -and (Test-Path -LiteralPath $t -PathType Container)) { return 'FOLDER' }
                } catch { }
            }
            return 'APP'
        }
        if (Test-Path -LiteralPath (Join-Path $d "$name.url") -PathType Leaf) { return 'APP' }
    }
    return 'APP'
}

function Get-HueFamily([double]$h) {
    if ($h -ge 330 -or $h -lt 15) { return 'RED' }
    if ($h -lt 45)  { return 'ORANGE' }
    if ($h -lt 70)  { return 'YELLOW' }
    if ($h -lt 160) { return 'GREEN' }
    if ($h -lt 200) { return 'CYAN' }
    if ($h -lt 255) { return 'BLUE' }
    return 'PURPLE'
}

# v2 分类器：先按"面积投票"，再用"中位色"定案（规则移植自上一版工程）。
#  1) 大面积是白，或中位色很亮            -> WHITE
#  2) 大面积是黑                          -> BLACK
#  3) 某一色系占了 ≥40% 面积：
#       暖色（红橙黄）                    -> 就是它（暗底上的暖色很抢眼）
#       冷色但中位色很暗                  -> BLACK（深藏青看上去就是黑）
#       其余                              -> 就是它
#  4) 没有色系占主导                      -> 看中位色的色相
#  5) 中位色偏灰                          -> 若仍有色系占 ≥20% 面积就用它，否则 MIXED（杂色）
function Get-AppFamily([object]$ci) {
    if (-not $ci.Found) { return 'MIXED' }
    if ($ci.WhiteFrac -ge $whiteAreaCut -or $ci.MedLight -ge $whiteMedCut) { return 'WHITE' }
    if ($ci.BlackFrac -ge $blackAreaCut) { return 'BLACK' }
    $names = @('RED', 'ORANGE', 'YELLOW', 'GREEN', 'CYAN', 'BLUE', 'PURPLE')
    if ($ci.TopFamFrac -ge $dominantCut) {
        if ($ci.TopFam -le 2) { return $names[$ci.TopFam] }
        if ($ci.MedLight -le $darkMedCut) { return 'BLACK' }
        return $names[$ci.TopFam]
    }
    if ($ci.MedSat -lt $nearGraySat) {
        if ($ci.MedLight -le $darkGrayCut) { return 'BLACK' }
        if ($ci.TopFamFrac -ge $grayHueCut) { return $names[$ci.TopFam] }
        return 'MIXED'
    }
    return (Get-HueFamily $ci.MedHue)
}

# ================================================================ 快照读写
function Get-IconRows([object]$view) {
    $rows = @()
    for ($i = 0; $i -lt $view.Count; $i++) {
        $p = $view.GetPosition($i)
        $rows += [pscustomobject]@{ Name = $view.GetName($i); X = [int]$p[0]; Y = [int]$p[1] }
    }
    return $rows
}

function Save-Rows([object]$rows, [string]$path) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $arr = @($rows)
    $json = if ($arr.Count -eq 1) { ConvertTo-Json -InputObject $arr[0] -Depth 3 } else { ConvertTo-Json -InputObject $arr -Depth 3 }
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Read-Rows([string]$path) {
    # 注意：Windows PowerShell 5.1 下 ConvertFrom-Json 会把顶层数组当成一个对象，
    # 所以要显式摊平。
    $parsed = Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    $layout = @($parsed | ForEach-Object { $_ })
    if ($layout.Count -eq 1 -and $layout[0] -is [System.Array]) { $layout = @($layout[0] | ForEach-Object { $_ }) }
    $out = @()
    foreach ($e in $layout) {
        if ($null -eq $e -or $null -eq $e.Name) { continue }
        $out += [pscustomobject]@{ Name = [string]$e.Name; X = [int]$e.X; Y = [int]$e.Y }
    }
    return $out
}

# 把当前布局压入历史栈，并维护 original / last 两份便利快照
function Push-History([object]$rows) {
    $arr = @($rows)
    if (-not (Test-Path -LiteralPath $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $script:Original)) { Save-Rows $arr $script:Original }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Save-Rows $arr (Join-Path $histDir "$stamp.json")
    Save-Rows $arr $script:LastBackup
    # 只保留最近 N 份
    $files = @(Get-ChildItem -LiteralPath $histDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $historyKeep) {
        $files | Select-Object -First ($files.Count - $historyKeep) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    }
}

function Pop-History() {
    if (-not (Test-Path -LiteralPath $histDir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $histDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files.Count) { return $null }
    $last = $files[-1]
    $rows = Read-Rows $last.FullName
    Remove-Item -LiteralPath $last.FullName -Force
    return $rows
}

# ================================================================ 屏幕与网格
function Get-MonitorList {
    $mons = [DeskNative]::GetMonitors()
    $dpis = @{}
    try {
        foreach ($d in [DeskNative]::GetMonitorDpis()) { $dpis["$($d[0]),$($d[1])"] = [int]$d[2] }
    }
    catch { }
    $list = @()
    $i = 0
    foreach ($m in $mons) {
        $key = "$([int]$m[0]),$([int]$m[1])"
        $dpi = if ($dpis.ContainsKey($key)) { $dpis[$key] } else { 96 }
        $list += [pscustomobject]@{
            Index  = $i
            Left   = [int]$m[0]; Top    = [int]$m[1]; Right  = [int]$m[2]; Bottom = [int]$m[3]
            WLeft  = [int]$m[4]; WTop   = [int]$m[5]; WRight = [int]$m[6]; WBottom = [int]$m[7]
            Primary = ([int]$m[8] -eq 1)
            Dpi    = $dpi
        }
        $i++
    }
    return $list
}

# ListView 客户区原点在虚拟桌面里的位置（图标坐标 = 虚拟坐标 - 原点）
function Get-ListOrigin([object]$view) {
    $vr = [DeskNative]::GetVirtualRect()
    if ($vr) { return @{ X = [int]$vr[0]; Y = [int]$vr[1] } }
    $wr = $view.WindowRect
    return @{ X = [int]$wr[0]; Y = [int]$wr[1] }
}

# 从"已经落在某块屏幕上"的图标里学出这块屏幕的网格锚点（余数众数）。
# 图标总是落在网格上，所以它们的坐标余数就是锚点。
function Get-AnchorsFromRows {
    param([object[]]$Rows, [object]$Mon, [int]$Cw, [int]$Ch, [object]$Origin)
    if ($Cw -le 0 -or $Ch -le 0) { return $null }
    $rx = @{}; $ry = @{}
    $n = 0; $firstX = 0; $firstY = 0; $haveFirst = $false
    foreach ($r in $Rows) {
        $vx = [int]$r.X + [int]$Origin.X
        $vy = [int]$r.Y + [int]$Origin.Y
        if ($vx -lt $Mon.Left -or $vx -ge $Mon.Right -or $vy -lt $Mon.Top -or $vy -ge $Mon.Bottom) { continue }
        if (-not $haveFirst) { $firstX = [int]$r.X; $firstY = [int]$r.Y; $haveFirst = $true }
        $n++
        $kx = ((([int]$r.X % $Cw) + $Cw) % $Cw)
        $ky = ((([int]$r.Y % $Ch) + $Ch) % $Ch)
        if ($rx.ContainsKey($kx)) { $rx[$kx]++ } else { $rx[$kx] = 1 }
        if ($ry.ContainsKey($ky)) { $ry[$ky]++ } else { $ry[$ky] = 1 }
    }
    if ($n -eq 0) { return $null }
    if ($n -lt 3) {
        return @{ X = ((( $firstX % $Cw) + $Cw) % $Cw); Y = ((( $firstY % $Ch) + $Ch) % $Ch) }
    }
    $need = [int][math]::Max(2, [int][math]::Ceiling($n * 0.5))
    $bx = @($rx.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $by = @($ry.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if (-not $bx.Count -or $bx[0].Value -lt $need) { return $null }
    if (-not $by.Count -or $by[0].Value -lt $need) { return $null }
    return @{ X = [int]$bx[0].Key; Y = [int]$by[0].Key }
}

# 探针挪动图标后，确保把它放回原位（放回的是原格点，通常会精确落回）。
function Restore-Probe {
    param([object]$View, [int[]]$Saved)
    for ($k = 0; $k -lt 4; $k++) {
        $View.SetPosition(0, $Saved[0], $Saved[1])
        Start-Sleep -Milliseconds 150
        $g = $View.GetPosition(0)
        if ($g[0] -eq $Saved[0] -and $g[1] -eq $Saved[1]) { return $true }
    }
    return $false
}

# 当某块屏幕上一个图标都没有时，把一个探针图标临时挪过去、读回它的落点，
# 从而量出这块屏幕的真实网格（挪完立刻还原）。
function Probe-Lattice {
    param([object]$View, [object]$Mon, [int]$Cw, [int]$Ch)
    $saved = $View.GetPosition(0)
    $w = $Mon.WRight - $Mon.WLeft
    $h = $Mon.WBottom - $Mon.WTop
    $offX = [int][math]::Min(3 * $Cw, [math]::Max($Cw, $w - $Cw))
    $offY = [int][math]::Min(3 * $Ch, [math]::Max($Ch, $h - $Ch))
    $px = [int]$Mon.WLeft + $offX
    $py = [int]$Mon.WTop + $offY
    $View.SetPosition(0, $px, $py)
    Start-Sleep -Milliseconds 300
    $View.Refresh()
    Start-Sleep -Milliseconds 150
    $got = $View.GetPosition(0)
    [void](Restore-Probe $View $saved)
    $View.Refresh()
    return @{
        RawX = [int]$got[0]
        RawY = [int]$got[1]
        X = ((([int]$got[0] % $Cw) + $Cw) % $Cw)
        Y = ((([int]$got[1] % $Ch) + $Ch) % $Ch)
        Snapped = ($got[0] -ne $px -or $got[1] -ne $py)
    }
}

# 探测"对齐到网格"是否开启（开启时桌面会自动把图标吸附到最近的格点）。
function Test-SnapToGrid {
    param([object]$View, [object]$Mon, [int]$Cw, [int]$Ch)
    $saved = $View.GetPosition(0)
    $px = [int]$Mon.WLeft + $Cw + 7
    $py = [int]$Mon.WTop + $Ch + 7
    $View.SetPosition(0, $px, $py)
    Start-Sleep -Milliseconds 300
    $View.Refresh()
    Start-Sleep -Milliseconds 150
    $got = $View.GetPosition(0)
    [void](Restore-Probe $View $saved)
    $View.Refresh()
    return (-not ($got[0] -eq $px -and $got[1] -eq $py))
}

# 一次性准备好每块屏幕的网格间距与锚点，并判断是否开启"对齐到网格"。
# 高 DPI 屏幕的图标格更大（例如 192 DPI 的格子是 96 DPI 的两倍），
# 所以按"主屏 DPI/间距"为基准，用每块屏幕自己的 DPI 比例推出各自的格宽格高；
# 否则把 150x198 的间距用到 96 DPI 屏上，每两个图标之间就会空出一格。
function Initialize-GridInfo {
    param([object]$View, [object[]]$Mons, [object[]]$Rows, [object]$Origin, [int]$Cw, [int]$Ch)
    $primary = @($Mons | Where-Object { $_.Primary } | Select-Object -First 1)
    if ($primary.Count -eq 0) { $primary = @($Mons[0]) }
    $dpiBase = [int]$primary[0].Dpi
    if ($dpiBase -le 0) { $dpiBase = 96 }
    $mon = @{}
    $snap = $null
    foreach ($m in $Mons) {
        $ratio = [double]$m.Dpi / [double]$dpiBase
        $mcw = [int][math]::Max(16, [math]::Round($Cw * $ratio))
        $mch = [int][math]::Max(16, [math]::Round($Ch * $ratio))
        $a = Get-AnchorsFromRows $Rows $m $mcw $mch $Origin
        if (-not $a) {
            $p = Probe-Lattice $View $m $mcw $mch
            if ($null -eq $snap) { $snap = $p.Snapped }
            $a = @{
                X = ((([int]$p.RawX % $mcw) + $mcw) % $mcw)
                Y = ((([int]$p.RawY % $mch) + $mch) % $mch)
            }
        }
        $mon[$m.Index] = @{ X = [int]$a.X; Y = [int]$a.Y; Cw = $mcw; Ch = $mch }
    }
    if ($null -eq $snap) { $snap = Test-SnapToGrid $View $primary[0] $Cw $Ch }
    $script:GridInfo = [pscustomobject]@{ BaseCw = $Cw; BaseCh = $Ch; Snap = $snap; Mon = $mon; Origin = $Origin }
}

# 一块屏幕里所有"合法格子"的列/行号（基于该屏幕自己的网格间距，自动避开屏幕缝隙）。
# 锚点与格宽格高都取该屏幕自己的值（见 Initialize-GridInfo）。
function Get-MonitorGeo([object]$mon, [int]$cw, [int]$ch, [int]$ox, [int]$oy) {
    $ax = $marginX; $ay = $marginY
    if ($null -ne $script:GridInfo) {
        if ($script:GridInfo.Mon.ContainsKey($mon.Index)) {
            $g = $script:GridInfo.Mon[$mon.Index]
            $ax = [int]$g.X; $ay = [int]$g.Y
            $cw = [int]$g.Cw; $ch = [int]$g.Ch
        }
        else { $ax = 0; $ay = 0 }
    }
    $localL = $mon.WLeft  - $ox
    $localT = $mon.WTop   - $oy
    $localR = $mon.WRight - $ox
    $localB = $mon.WBottom - $oy
    $kMin = [int][math]::Ceiling(($localL - $ax) / $cw)
    $kMax = [int][math]::Floor(($localR - $ax) / $cw) - 1
    $jMin = [int][math]::Ceiling(($localT - $ay) / $ch)
    $jMax = [int][math]::Floor(($localB - $ay) / $ch) - 1
    return [pscustomobject]@{
        Mon = $mon; Cw = $cw; Ch = $ch; Ox = $ox; Oy = $oy
        AnchorX = $ax; AnchorY = $ay
        KMin = $kMin; KMax = $kMax; JMin = $jMin; JMax = $jMax
        Cols = [int][math]::Max(0, $kMax - $kMin + 1)
        Rows = [int][math]::Max(0, $jMax - $jMin + 1)
    }
}

function Get-CellX([object]$geo, [int]$col) { return [int]($geo.AnchorX + ($geo.KMin + $col) * $geo.Cw) }
function Get-CellY([object]$geo, [int]$row) { return [int]($geo.AnchorY + ($geo.JMin + $row) * $geo.Ch) }

function Get-MonitorOfPoint([object]$mons, [int]$vx, [int]$vy) {
    foreach ($m in $mons) {
        if ($vx -ge $m.Left -and $vx -lt $m.Right -and $vy -ge $m.Top -and $vy -lt $m.Bottom) { return $m.Index }
    }
    return -1
}

function Get-IconCounts([object]$mons, [object]$rows, [object]$origin) {
    $counts = @{}
    foreach ($m in $mons) { $counts[$m.Index] = 0 }
    foreach ($r in $rows) {
        $idx = Get-MonitorOfPoint $mons ($r.X + $origin.X) ($r.Y + $origin.Y)
        if ($idx -ge 0) { $counts[$idx] = $counts[$idx] + 1 }
    }
    return $counts
}

# ================================================================ 生成方案
function Build-Plan {
    param([object]$Raw, [object]$Geo, [object[]]$Monitors, [object]$View)

    $notes = @()
    $kinds = @{}
    foreach ($r in $Raw) {
        $kinds[$r.Name] = if ($kindOverride.ContainsKey($r.Name)) { $kindOverride[$r.Name] } else { Get-Kind $r.Name }
    }

    $fileNames    = Sort-Natural @($Raw | Where-Object { $kinds[$_.Name] -eq 'FILE' }   | ForEach-Object { $_.Name })
    $folderNames  = Sort-Natural @($Raw | Where-Object { $kinds[$_.Name] -eq 'FOLDER' } | ForEach-Object { $_.Name })
    $specialNames = @($Raw | Where-Object { $kinds[$_.Name] -eq 'SPECIAL' } | ForEach-Object { $_.Name } |
            Sort-Object { if ($_ -eq $nameThisPC) { 0 } else { 1 } })
    $appNames     = @($Raw | Where-Object { $kinds[$_.Name] -eq 'APP' } | ForEach-Object { $_.Name })

    # 文件区：按扩展名分行
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

    $rows = $Geo.Rows
    $cols = $Geo.Cols

    $folderZoneCol  = $fileZoneWidth + 1
    $fileTopRow     = [int][math]::Ceiling(($rows - $fileRows.Count) / 2)
    $folderRowsUsed = [int][math]::Ceiling($folderNames.Count / $folderCols)
    $folderTopRow   = [int][math]::Ceiling(($rows - $folderRowsUsed) / 2)

    # ---- 应用区：按颜色系分行，自上而下平滑渐变 ----
    # 规则：①一行尽量同一色系 ②自上而下按色相平滑过渡 ③孤色系/杂色放最底下。
    # 颜色分类（面积投票 + 中位色）与"每行左亮右暗"的排序，沿用上一版
    # desktop-icon-arranger 工程的算法。前三个功能区的位置完全不动。
    $appInfo = foreach ($n in $appNames) {
        $found = $true
        $keyHue = 0.0
        $vivid = 0.0
        if ($pinned.ContainsKey($n)) {
            $fam = [string]$pinned[$n].Family
            if ($null -ne $pinned[$n].Hue) { $keyHue = [double]$pinned[$n].Hue }
            $vivid = 0.55 * [double]$pinned[$n].CF + 0.45 * [double]$pinned[$n].Light
        }
        else {
            $ci = [IconColorAnalyzer]::Analyze((Resolve-IconPath $n))
            $found = [bool]$ci.Found
            $fam = Get-AppFamily $ci
            if ($ci.Found) {
                if ($ci.MedHue -ge 0) { $keyHue = [double]$ci.MedHue }
                # 鲜明度：用中位色的"彩度跨度"，而不是 HSL 饱和度
                #（近白颜色的 HSL 饱和度会虚高）
                $mx = [math]::Max($ci.MedR, [math]::Max($ci.MedG, $ci.MedB)) / 255.0
                $mn = [math]::Min($ci.MedR, [math]::Min($ci.MedG, $ci.MedB)) / 255.0
                $vivid = $vividWeight * ($mx - $mn) + (1 - $vividWeight) * [double]$ci.MedLight
            }
        }
        $forced = $familyOverride.ContainsKey($n)
        if ($forced) { $fam = $familyOverride[$n] }
        if ($fam -eq 'RED' -and $keyHue -ge 330) { $keyHue -= 360 }
        [pscustomobject]@{
            Name   = $n
            Family = $fam
            Found  = $found
            Forced = $forced
            HueKey = $keyHue
            Vivid  = $vivid
        }
    }

    # ① 杂色：算法读不出主色的图标（手动指定过色系的不算）
    $isBottom = @{}
    foreach ($a in $appInfo) {
        if (-not $a.Forced -and $a.Family -eq 'MIXED') { $isBottom[$a.Name] = $true }
    }
    # ② 孤色系：去掉杂色以后，某个色系只剩一个图标，也跟着去底部
    $famLeft = @{}
    foreach ($a in $appInfo) {
        if ($isBottom.ContainsKey($a.Name)) { continue }
        if ($famLeft.ContainsKey($a.Family)) { $famLeft[$a.Family]++ } else { $famLeft[$a.Family] = 1 }
    }
    foreach ($a in $appInfo) {
        if (-not $isBottom.ContainsKey($a.Name) -and $famLeft[$a.Family] -le 1) { $isBottom[$a.Name] = $true }
    }

    # 按色系顺序排出"自上而下的渐变"；每个色系内部再按色相衔接
    function Get-AppOrder([bool]$wantBottom) {
        $out = @()
        foreach ($f in $familyOrder) {
            $m = @($appInfo | Where-Object {
                    (([bool]$isBottom.ContainsKey($_.Name)) -eq $wantBottom) -and $_.Family -eq $f })
            if ($m.Count -eq 0) { continue }
            $out += @($m | Sort-Object @{ Expression = 'HueKey' }, @{ Expression = 'Name' })
        }
        return $out
    }
    $orderedNormal = @(Get-AppOrder $false)
    $orderedBottom = @(Get-AppOrder $true)

    # 把有序的图标切成行：换色系就换行，一行最多 $Width 个。
    # $SingleFamily = 底部杂项桶（孤色系/难分类）整体当作一个色系，不因换色系再断行。
    function Get-AppRowGroups([object[]]$Ordered, [int]$Width, [bool]$SingleFamily) {
        $g = @(); $curFam = $null; $cur = @()
        foreach ($a in $Ordered) {
            $fam = if ($SingleFamily) { 'MISC' } else { $a.Family }
            if ($cur.Count -gt 0 -and ($cur.Count -ge $Width -or $curFam -ne $fam)) {
                $g += , @{ Family = $curFam; Items = @($cur) }
                $cur = @(); $curFam = $null
            }
            if ($null -eq $curFam) { $curFam = $fam }
            $cur += $a
        }
        if ($cur.Count -gt 0) { $g += , @{ Family = $curFam; Items = @($cur) } }
        return $g
    }

    # 紧凑拼行（默认）：按色系顺序逐行填满宽度。
    #   · 某个色系自己一行都放不下（个数 > 宽度）时，才把它拆开续到下一行；
    #   · 只放得下但当前行已经放不进去时，另起一行，保持这个色系完整；
    #   · 于是青色、黑色、孤色系这类小色系会自然拼进邻行的空位，把行数压到最少。
    # 结果：色系带尽量完整，同时整个应用区行数最少、上下留白。
    function Get-CompactRowGroups([object[]]$Ordered, [int]$Width) {
        $g = @(); $curFam = $null; $cur = @()
        $i = 0; $n = @($Ordered).Count
        while ($i -lt $n) {
            $fam = $Ordered[$i].Family
            $run = 0
            while ((($i + $run) -lt $n) -and ($Ordered[$i + $run].Family -eq $fam)) { $run++ }
            if ($run -gt $Width) {
                # 比一整行还长：先补满当前行，再整行整行地放，最后一段留给后面的色系补位
                for ($k = 0; $k -lt $run; $k++) {
                    if ($cur.Count -ge $Width) { $g += , @{ Family = $curFam; Items = @($cur) }; $cur = @(); $curFam = $null }
                    if ($null -eq $curFam) { $curFam = $fam }
                    $cur += $Ordered[$i + $k]
                }
            }
            elseif (($cur.Count -eq 0) -or (($cur.Count + $run) -le $Width)) {
                # 当前行还放得下 → 并进去
                if ($null -eq $curFam) { $curFam = $fam }
                for ($k = 0; $k -lt $run; $k++) { $cur += $Ordered[$i + $k] }
            }
            else {
                # 放不下又不满一行 → 另起一行，不拆色系
                $g += , @{ Family = $curFam; Items = @($cur) }
                $cur = @(); $curFam = $fam
                for ($k = 0; $k -lt $run; $k++) { $cur += $Ordered[$i + $k] }
            }
            $i += $run
        }
        if ($cur.Count -gt 0) { $g += , @{ Family = $curFam; Items = @($cur) } }
        return $g
    }

    # 应用区宽度：先按"塞满屏幕高度所需的最少列数"算，再保证不少于 $appMinCols 列。
    # 行数多的屏（如副屏 14 行）上，最少列数会把 20 个图标压成 2 列 —— 又高又窄，
    # 颜色带还被切成十几行。给个下限，让颜色带保持横向舒展；屏幕太窄时再退回最少列数。
    $appColWidthNeeded = [math]::Max(1, [int][math]::Ceiling($appNames.Count / [math]::Max(1, $rows)))
    $appColWidth = [math]::Max($appMinCols, $appColWidthNeeded)
    $appColWidthLimit = $cols - $folderZoneCol - $folderCols - 2   # 再宽就会撞上文件夹区
    if ($appColWidthLimit -ge 1 -and $appColWidth -gt $appColWidthLimit) { $appColWidth = $appColWidthLimit }

    if ($Strategy -eq 'Compact') {
        # 紧凑拼行：行数已经是最少的；万一还是超过屏幕行数，就加宽一列再试。
        $all = @($orderedNormal) + @($orderedBottom)
        $groups = @()
        while ($true) {
            $groups = @(Get-CompactRowGroups $all $appColWidth)
            if ($groups.Count -le $rows -or $appColWidth -ge $cols) { break }
            $appColWidth++
        }
    }
    elseif ($Strategy -eq 'Packed') {
        # 旧工程的做法：整条颜色带按宽度逐行填满，行尾可以接上下一个色系的开头；
        # 每一行都是满的（只有最后一行可能不满），右边不留缺口。
        $all = @($orderedNormal) + @($orderedBottom)
        $groups = @()
        for ($i = 0; $i -lt $all.Count; $i += $appColWidth) {
            $end = [math]::Min($i + $appColWidth - 1, $all.Count - 1)
            $groups += , @{ Family = 'PACKED'; Items = @($all[$i..$end]) }
        }
    }
    else {
        # Strict：一行一个色系，换色系就换行。
        # 行数超过屏幕时，合并相邻两行（优先合并后仍放得下的最小组合）；
        # 实在合并不了就加宽一列再试，宁可应用区多占一列，也不把两行硬塞。
        $groups = @()
        while ($true) {
            $g = New-Object System.Collections.ArrayList
            foreach ($x in @(Get-AppRowGroups $orderedNormal $appColWidth $false)) { [void]$g.Add($x) }
            foreach ($x in @(Get-AppRowGroups $orderedBottom $appColWidth $true)) { [void]$g.Add($x) }
            while ($g.Count -gt $rows) {
                $bestI = -1; $bestSum = [int]::MaxValue
                for ($i = 0; $i -lt $g.Count - 1; $i++) {
                    $s = @($g[$i].Items).Count + @($g[$i + 1].Items).Count
                    if ($s -le $appColWidth -and $s -lt $bestSum) { $bestSum = $s; $bestI = $i }
                }
                if ($bestI -lt 0) { break }
                $a = $g[$bestI]; $b = $g[$bestI + 1]
                $g[$bestI] = @{ Family = ($a.Family + '+' + $b.Family); Items = @(@($a.Items) + @($b.Items)) }
                $g.RemoveAt($bestI + 1)
            }
            $groups = @($g)
            if ($groups.Count -le $rows -or $appColWidth -ge $cols) { break }
            $appColWidth++
        }
    }

    $appZoneRight  = $cols - 1
    $appRowCount   = $groups.Count
    $appTopRow     = [int][math]::Ceiling(($rows - $appRowCount) / 2)
    $appZoneLeft   = $appZoneRight - $appColWidth + 1
    $specialCol    = $appZoneLeft - 2
    $specialTopRow = [int][math]::Ceiling(($rows - $specialNames.Count) / 2)

    # 装不下就直接报错，绝不乱排
    if ($fileRows.Count -gt $rows)  { throw "文件区需要 $($fileRows.Count) 行，但所选屏幕只有 $rows 行。" }
    if ($folderRowsUsed -gt $rows)  { throw "文件夹区需要 $folderRowsUsed 行，但所选屏幕只有 $rows 行。" }
    if ($appRowCount -gt $rows)     { throw "应用区需要 $appRowCount 行，但所选屏幕只有 $rows 行。" }
    if ($specialCol -le ($folderZoneCol + $folderCols - 1)) {
        throw "横向空间不足：应用区需要 $appColWidth 列，会和文件夹区相撞。减少桌面图标，或选更宽的屏幕。"
    }

    $plan = New-Object System.Collections.ArrayList
    function Add-Cell([string]$n, [int]$col, [int]$row, [string]$zone) {
        [void]$plan.Add([pscustomobject]@{
                Name = $n; Zone = $zone
                X = Get-CellX $Geo $col
                Y = Get-CellY $Geo $row
            })
    }

    for ($r = 0; $r -lt $fileRows.Count; $r++) {
        $items = $fileRows[$r].Items
        for ($i = 0; $i -lt $items.Count; $i++) { Add-Cell $items[$i] $i ($fileTopRow + $r) ('FILE ' + $fileRows[$r].Type) }
    }
    for ($i = 0; $i -lt $folderNames.Count; $i++) {
        Add-Cell $folderNames[$i] ($folderZoneCol + [int][math]::Floor($i / [math]::Max(1, $folderRowsUsed))) ($folderTopRow + ($i % [math]::Max(1, $folderRowsUsed))) 'FOLDER'
    }
    for ($i = 0; $i -lt $specialNames.Count; $i++) {
        Add-Cell $specialNames[$i] $specialCol ($specialTopRow + $i) 'SPECIAL'
    }
    # 逐行落地。每行内按 色系 -> 鲜明度(降) -> 色相 -> 名称 再排一次：
    #   · 一行从左到右 亮/艳 -> 暗/灰，视觉上有干净的横向渐变；
    #   · 相邻两行的同一列落在渐变的同一位置，纵向也接得上（蛇形填充正好相反）。
    for ($r = 0; $r -lt $groups.Count; $r++) {
        $items = @($groups[$r].Items | Sort-Object `
                @{ Expression = { $familyOrder.IndexOf($_.Family) } }, `
                @{ Expression = 'Vivid'; Descending = $true }, `
                @{ Expression = 'HueKey' }, `
                @{ Expression = 'Name' })
        $start = $appZoneRight - $items.Count + 1
        for ($i = 0; $i -lt $items.Count; $i++) {
            Add-Cell $items[$i].Name ($start + $i) ($appTopRow + $r) ('APP ' + $items[$i].Family)
        }
    }

    $appRowsDetail = @()
    for ($r = 0; $r -lt $groups.Count; $r++) {
        $its = @($groups[$r].Items | Sort-Object `
                @{ Expression = { $familyOrder.IndexOf($_.Family) } }, `
                @{ Expression = 'Vivid'; Descending = $true }, `
                @{ Expression = 'HueKey' }, `
                @{ Expression = 'Name' })
        $fams = @($its | ForEach-Object { $_.Family } | Select-Object -Unique)
        $appRowsDetail += [pscustomobject]@{
            Row    = $appTopRow + $r
            Family = ($fams -join '+')
            Names  = @($its | ForEach-Object { $_.Name })
        }
    }

    return [pscustomobject]@{
        Plan = @($plan)
        Notes = $notes
        FileCount = $fileNames.Count
        FolderCount = $folderNames.Count
        SpecialCount = $specialNames.Count
        AppCount = $appNames.Count
        FileRows = $fileRows.Count
        FileZoneWidth = $fileZoneWidth
        FolderZoneCol = $folderZoneCol
        FolderRowsUsed = $folderRowsUsed
        AppColWidth = $appColWidth
        AppZoneLeft = $appZoneLeft
        AppZoneRight = $appZoneRight
        SpecialCol = $specialCol
        AppRows = @($appRowsDetail)
    }
}

# ================================================================ 落地执行
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

# 三阶段落地：先停到临时空列，再逐一就位，最后修补。
# （移动到已被占用的格子会把原主挤开，所以必须先全部腾空。）
function Invoke-PlacePlan {
    param([object]$View, [object[]]$Plan, [object[]]$StageCells)

    $count = $View.Count
    if ($count -ne $Plan.Count) { throw "桌面图标数量在排列过程中发生了变化（$count vs $($Plan.Count)），已放弃。" }

    $map = Get-IndexMap $View $count

    # 阶段 1：先全部停到临时空位
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $c = $StageCells[$i]
        $View.SetPosition($map[$Plan[$i].Name], $c.X, $c.Y)
        Start-Sleep -Milliseconds 20
    }
    Start-Sleep -Milliseconds 500

    # 阶段 2：逐一就位
    $map = Get-IndexMap $View $count
    foreach ($p in $Plan) {
        $View.SetPosition($map[$p.Name], $p.X, $p.Y)
        Start-Sleep -Milliseconds 20
    }
    $View.Refresh()
    Start-Sleep -Milliseconds 800

    # 阶段 3：修补。若系统把图标吸附到该屏自己的格点，偏差只是几个像素；此时直接
    # 把"吸附后的实际位置"认作目标即可（吸附是幂等的，下一轮就能对上）。偏差很大
    # 说明是设置失败，继续重设。
    $cw = [int]$View.Spacing[0]; $ch = [int]$View.Spacing[1]
    $halfW = [int][math]::Max(2, [math]::Floor($cw / 2))
    $halfH = [int][math]::Max(2, [math]::Floor($ch / 2))
    $adopted = @{}
    for ($pass = 1; $pass -le 12; $pass++) {
        $map = Get-IndexMap $View $count
        $bad = @()
        foreach ($p in $Plan) {
            $pos = $View.GetPosition($map[$p.Name])
            if ($pos[0] -ne $p.X -or $pos[1] -ne $p.Y) { $bad += , @($p, $pos) }
        }
        if ($bad.Count -eq 0) { break }
        Write-Host ("  修补第 {0} 轮：还有 {1} 个图标没到位" -f $pass, $bad.Count) -ForegroundColor DarkYellow
        foreach ($item in $bad) {
            $p = $item[0]; $pos = $item[1]
            $dx = [int]($pos[0] - $p.X); $dy = [int]($pos[1] - $p.Y)
            $key = "$($pos[0]),$($pos[1])"
            if ([math]::Abs($dx) -le $halfW -and [math]::Abs($dy) -le $halfH -and -not $adopted.ContainsKey($key)) {
                $adopted[$key] = $true
                $p.X = [int]$pos[0]; $p.Y = [int]$pos[1]
            }
            else {
                $View.SetPosition($map[$p.Name], $p.X, $p.Y)
                Start-Sleep -Milliseconds 20
            }
        }
        $View.Refresh()
        Start-Sleep -Milliseconds 600
    }

    $map = Get-IndexMap $View $count
    return @(Get-OffTarget $View $map $Plan)
}

# 为方案准备"临时停车位"：所选屏幕里没被方案占用的列
function Get-StageCells([object]$Plan, [object]$Geo) {
    $planCols = @($Plan | ForEach-Object { [int][math]::Round(($_.X - $Geo.AnchorX) / $Geo.Cw) } | Sort-Object -Unique)
    $freeCols = @()
    for ($k = $Geo.KMin; $k -le $Geo.KMax; $k++) { if ($planCols -notcontains $k) { $freeCols += $k } }
    $needCols = [int][math]::Ceiling($Plan.Count / [math]::Max(1, $Geo.Rows))
    if ($freeCols.Count -lt $needCols) { throw "没有足够的临时空位来安全地搬运图标（需要 $needCols 列，只有 $($freeCols.Count) 列）。" }
    $cells = @()
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $col = $freeCols[[int][math]::Floor($i / $Geo.Rows)]
        $row = $Geo.JMin + ($i % $Geo.Rows)
        $cells += [pscustomobject]@{ X = [int]($Geo.AnchorX + $col * $Geo.Cw); Y = [int]($Geo.AnchorY + $row * $Geo.Ch) }
    }
    return $cells
}

# ================================================================ 恢复布局
# 在一组格子里找离 (x,y) 最近、且未被占用的那个
function Find-NearestFreeCell([object]$cells, [object]$used, [int]$x, [int]$y) {
    $pick = $null
    $best = [double]::MaxValue
    foreach ($c in $cells) {
        if ($used.ContainsKey("$($c.X),$($c.Y)")) { continue }
        $dx = [double]($c.X - $x); $dy = [double]($c.Y - $y)
        $d = $dx * $dx + $dy * $dy
        if ($d -lt $best) { $best = $d; $pick = $c }
    }
    return $pick
}

# 先算出"要放到哪里"（不改动桌面），再交给 Invoke-PlacePlan 落地。
function Build-RestorePlan {
    param([object]$View, [object[]]$Layout, [object[]]$Monitors, [object]$Origin, [int]$Cw, [int]$Ch)

    $map = Get-IndexMap $View $View.Count
    $snapOn = if ($null -ne $script:GridInfo) { [bool]$script:GridInfo.Snap } else { $true }

    # 当前每块屏幕上的合法格子（同一块屏幕内按列优先排序，便于就近吸附）
    $cellsByMon = @{}
    $allCells = New-Object System.Collections.ArrayList
    foreach ($m in $Monitors) {
        $geo = Get-MonitorGeo $m $Cw $Ch $Origin.X $Origin.Y
        $list = New-Object System.Collections.ArrayList
        for ($c = 0; $c -lt $geo.Cols; $c++) {
            for ($r = 0; $r -lt $geo.Rows; $r++) {
                $cell = [pscustomobject]@{ X = Get-CellX $geo $c; Y = Get-CellY $geo $r }
                [void]$list.Add($cell)
                [void]$allCells.Add($cell)
            }
        }
        $cellsByMon[$m.Index] = $list
    }

    # 逐条把快照坐标吸附到"离它最近的、还没被占用的当前格子"。
    # 优先吸附到图标原来所在的那块屏幕，这样换分辨率 / 改图标大小后也能大致还原，
    # 而不会因为像素对不上就把整屏图标全部重排。
    $plan = New-Object System.Collections.ArrayList
    $used = @{}
    $placedNames = @{}
    $missing = 0
    $snapped = 0
    foreach ($e in $Layout) {
        if (-not $map.ContainsKey($e.Name)) { $missing++; continue }
        $vx = [int]$e.X + $Origin.X
        $vy = [int]$e.Y + $Origin.Y
        $monIdx = Get-MonitorOfPoint $Monitors $vx $vy

        $pick = $null
        # 关闭"对齐到网格"时，快照坐标本身就是能落地的确切位置，优先原样还原。
        if (-not $snapOn) {
            $c = [pscustomobject]@{ X = [int]$e.X; Y = [int]$e.Y }
            if (-not $used.ContainsKey("$($c.X),$($c.Y)")) { $pick = $c }
        }
        if ($null -eq $pick -and $monIdx -ge 0) { $pick = Find-NearestFreeCell $cellsByMon[$monIdx] $used $e.X $e.Y }
        if ($null -eq $pick) { $pick = Find-NearestFreeCell $allCells $used $e.X $e.Y }
        if ($null -eq $pick) { continue }

        $used["$($pick.X),$($pick.Y)"] = $true
        $placedNames[$e.Name] = $true
        if ($pick.X -ne [int]$e.X -or $pick.Y -ne [int]$e.Y) { $snapped++ }
        [void]$plan.Add([pscustomobject]@{ Name = $e.Name; X = $pick.X; Y = $pick.Y })
    }

    # 快照里没有的新图标，塞进剩下的空格子
    $extra = @()
    foreach ($n in $map.Keys) { if (-not $placedNames.ContainsKey($n)) { $extra += $n } }
    $free = @($allCells | Where-Object { -not $used.ContainsKey("$($_.X),$($_.Y)") })
    $leftover = 0
    $placedExtras = 0
    for ($i = 0; $i -lt $extra.Count; $i++) {
        if ($i -ge $free.Count) { $leftover++; continue }
        $p = $free[$i]
        $used["$($p.X),$($p.Y)"] = $true
        [void]$plan.Add([pscustomobject]@{ Name = $extra[$i]; X = $p.X; Y = $p.Y })
        $placedExtras++
    }

    # 临时车位：所有合法格子里没被方案占用的
    $stage = @($allCells | Where-Object { -not $used.ContainsKey("$($_.X),$($_.Y)") })
    $stageCells = @()
    $n = [int][math]::Min(@($plan).Count, $stage.Count)
    for ($i = 0; $i -lt $n; $i++) { $stageCells += $stage[$i] }

    return [pscustomobject]@{
        Plan       = @($plan)
        StageCells = $stageCells
        ValidCells = $allCells.Count
        FreeCells  = $free.Count
        Kept       = (@($plan).Count - $placedExtras - $snapped)
        Missing    = $missing
        Relocated  = $snapped
        Extra      = @($extra).Count
        Leftover   = $leftover
    }
}

function Invoke-RestoreLayout {
    param([object]$View, [object[]]$Layout, [object[]]$Monitors, [object]$Origin, [int]$Cw, [int]$Ch)
    $rp = Build-RestorePlan $View $Layout $Monitors $Origin $Cw $Ch
    if (@($rp.StageCells).Count -lt @($rp.Plan).Count) {
        throw "没有足够的临时空位来安全地恢复（需要 $(@($rp.Plan).Count) 个，只有 $(@($rp.StageCells).Count) 个）。"
    }
    $bad = Invoke-PlacePlan -View $View -Plan $rp.Plan -StageCells $rp.StageCells
    return @{ Bad = $bad; Count = @($rp.Plan).Count; Extra = $rp.Extra; Free = $rp.FreeCells }
}

# ================================================================ 各动作
# 只检查快照能否在当前屏幕配置下还原，不动图标（诊断用）。
function Invoke-Check {
    $targets = @()
    if (Test-Path -LiteralPath $script:MyLayout)   { $targets += [pscustomobject]@{ Label = '我的布局'; Path = $script:MyLayout } }
    if (Test-Path -LiteralPath $script:Original)   { $targets += [pscustomobject]@{ Label = '最初布局'; Path = $script:Original } }
    if (Test-Path -LiteralPath $script:LastBackup) { $targets += [pscustomobject]@{ Label = '上次备份'; Path = $script:LastBackup } }
    if (-not $targets.Count) { Write-Host "还没有任何快照可检查。" -ForegroundColor DarkYellow; return }

    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        Initialize-GridInfo $view $mons @(Get-IconRows $view) $origin $cw $ch
        Write-Host ""
        foreach ($t in $targets) {
            $layout = @(Read-Rows $t.Path)
            $rp = Build-RestorePlan $view $layout $mons $origin $cw $ch
            Write-Host ("[{0}] {1}" -f $t.Label, (Split-Path -Leaf $t.Path)) -ForegroundColor Cyan
            Write-Host ("   快照 {0} 项：原样还原 {1}，就近对齐 {2}，图标已不在桌面 {3}，桌面新增图标 {4}（放不下 {5}）" -f `
                    $layout.Count, $rp.Kept, $rp.Relocated, $rp.Missing, $rp.Extra, $rp.Leftover)
            Write-Host ("   当前合法格 {0}，空位 {1}，可用于临时搬运 {2}；落地需要 {3}" -f `
                    $rp.ValidCells, $rp.FreeCells, @($rp.StageCells).Count, @($rp.Plan).Count) -ForegroundColor DarkGray
        }
    }
    finally { $view.Dispose() }
}

function Show-Info {
    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        $rows = Get-IconRows $view
        Initialize-GridInfo $view $mons $rows $origin $cw $ch
        $counts = Get-IconCounts $mons $rows $origin
        Write-Host ""
        Write-Host "显示器" -ForegroundColor Cyan
        foreach ($m in $mons) {
            $tag = if ($m.Primary) { '主屏' } else { '副屏' }
            $geo = Get-MonitorGeo $m $cw $ch $origin.X $origin.Y
            Write-Host ("  屏幕{0}（{1}） {2}×{3}   工作区 {4}×{5}   {6} DPI   图标 {7} 个   可用格 {8} 列 × {9} 行" -f `
                    ($m.Index + 1), $tag, ($m.Right - $m.Left), ($m.Bottom - $m.Top), `
                    ($m.WRight - $m.WLeft), ($m.WBottom - $m.WTop), $m.Dpi, $counts[$m.Index], $geo.Cols, $geo.Rows)
        }
        $anchorText = @($mons | ForEach-Object {
                $a = $script:GridInfo.Mon[$_.Index]
                "屏幕{0} {1},{2}（格 {3}×{4}）" -f ($_.Index + 1), $a.X, $a.Y, $a.Cw, $a.Ch
            }) -join '   '
        $snapText = if ($script:GridInfo.Snap) { '开启' } else { '关闭' }
        Write-Host ("  桌面图标共 {0} 个；主屏网格单元 {1}×{2} 像素；对齐到网格：{3}" -f $rows.Count, $cw, $ch, $snapText) -ForegroundColor DarkGray
        Write-Host ("  每块屏幕的网格锚点：" + $anchorText) -ForegroundColor DarkGray
        $outside = 0
        foreach ($r in $rows) {
            if ((Get-MonitorOfPoint $mons ($r.X + $origin.X) ($r.Y + $origin.Y)) -lt 0) { $outside++ }
        }
        if ($outside -gt 0) { Write-Host ("  ! 有 {0} 个图标不在任何屏幕范围内" -f $outside) -ForegroundColor DarkYellow }
    }
    finally { $view.Dispose() }

    Write-Host ""
    Write-Host ("历史快照：{0} 份   我的布局：{1}   最初布局：{2}" -f `
            (@(Get-ChildItem -LiteralPath $histDir -Filter *.json -ErrorAction SilentlyContinue).Count), `
            (Test-Path -LiteralPath $script:MyLayout), (Test-Path -LiteralPath $script:Original)) -ForegroundColor DarkGray
}

function Select-MonitorForArrange {
    param([object[]]$Monitors, [object]$Rows, [object]$Origin)
    if ($Monitors.Count -le 1) { return $Monitors[0].Index }

    $counts = Get-IconCounts $Monitors $Rows $Origin
    Write-Host ""
    Write-Host "检测到多块屏幕。要把全部图标排列到哪一块？" -ForegroundColor Cyan
    $best = $Monitors[0].Index
    $bestN = -1
    foreach ($m in $Monitors) {
        $tag = if ($m.Primary) { '主屏' } else { '副屏' }
        Write-Host ("  [{0}] 屏幕{0}（{1}） {2}×{3}   当前图标 {4} 个" -f ($m.Index + 1), $tag, ($m.Right - $m.Left), ($m.Bottom - $m.Top), $counts[$m.Index])
        if ($counts[$m.Index] -gt $bestN) { $bestN = $counts[$m.Index]; $best = $m.Index }
    }
    $ans = "$(Read-Host ("请输入屏幕编号（直接回车 = 屏幕" + ($best + 1) + "）"))"
    if (-not $ans.Trim()) { return $best }
    $n = 0
    if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Monitors.Count) { return ($n - 1) }
    Write-Host "输入无效，默认用图标最多的那块屏。" -ForegroundColor DarkYellow
    return $best
}

function Invoke-Arrange {
    param([int]$MonitorIndex = -1, [switch]$NoConfirm)

    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        $raw = @(Get-IconRows $view)
        if ($raw.Count -eq 0) { Write-Host "桌面上没有图标，无需排列。" -ForegroundColor DarkYellow; return }
        Initialize-GridInfo $view $mons $raw $origin $cw $ch
        $raw = @(Get-IconRows $view)   # 探针还原后重新确认一次

        if ($MonitorIndex -lt 0 -or $MonitorIndex -ge $mons.Count) {
            $MonitorIndex = Select-MonitorForArrange $mons $raw $origin
        }
        $mon = $mons | Where-Object { $_.Index -eq $MonitorIndex }
        $geo = Get-MonitorGeo $mon $cw $ch $origin.X $origin.Y

        $built = Build-Plan $raw $geo $mons $view

        $tag = if ($mon.Primary) { '主屏' } else { '副屏' }
        Write-Host ""
        Write-Host ("目标屏幕：屏幕{0}（{1}）  {2}×{3}   可用格 {4} 列 × {5} 行" -f ($mon.Index + 1), $tag, ($mon.Right - $mon.Left), ($mon.Bottom - $mon.Top), $geo.Cols, $geo.Rows) -ForegroundColor Cyan
        Write-Host ("  区域统计：文件 {0}（{1} 行）  文件夹 {2}  此电脑/回收站 {3}  应用 {4}" -f $built.FileCount, $built.FileRows, $built.FolderCount, $built.SpecialCount, $built.AppCount)
        Write-Host ("  文件区占 {0} 列，文件夹区第 {1} 列起，应用区第 {2}~{3} 列" -f $built.FileZoneWidth, ($built.FolderZoneCol + 1), ($built.AppZoneLeft + 1), ($built.AppZoneRight + 1)) -ForegroundColor DarkGray
        if ($built.AppRows.Count) {
            Write-Host "  应用区配色（自上而下）：" -ForegroundColor DarkGray
            foreach ($row in $built.AppRows) {
                Write-Host ("    第 {0} 行  {1}：{2}" -f ($row.Row + 1), $row.Family, (@($row.Names) -join '、')) -ForegroundColor DarkGray
            }
        }
        if ($overrideNotes.Count) { foreach ($n in $overrideNotes) { Write-Host "  $n" -ForegroundColor DarkYellow } }

        if ($Action -eq 'Preview') {
            Write-Host ""
            Write-Host "预览模式：没有移动任何图标。" -ForegroundColor Green
            return
        }

        if (-not $NoConfirm) {
            $ans = Read-Host "回车开始排列（会先自动备份当前位置，可一键撤销）；输入 N 取消"
            if ($ans -match '^\s*(n|no)\s*$') { Write-Host "已取消，没有移动任何图标。" -ForegroundColor DarkYellow; return }
        }

        # 先记录当前位置
        Push-History $raw
        Write-Host ("已备份 {0} 个图标的当前位置。" -f $raw.Count) -ForegroundColor DarkGray

        $stage = Get-StageCells $built.Plan $geo
        $bad = Invoke-PlacePlan -View $view -Plan $built.Plan -StageCells $stage
        Write-Host ""
        if ($bad.Count -eq 0) {
            Write-Host ("完成：{0} 个图标已排到屏幕{1}的指定区域。" -f $built.Plan.Count, ($mon.Index + 1)) -ForegroundColor Green
            Write-Host "如需回到排列前：菜单选 4（撤销）。" -ForegroundColor DarkGray
        }
        else {
            Write-Host ("有 {0} 个图标没能到位：" -f $bad.Count) -ForegroundColor DarkYellow
            $bad | ForEach-Object { Write-Host ("  {0} -> {1},{2}" -f $_.Name, $_.X, $_.Y) -ForegroundColor DarkYellow }
        }
    }
    finally { $view.Dispose() }
}

# ================================================================ 效果预览图
# 把"现在的排列 / 紧凑拼行 / 严格分行"三种画法画成一张对比图，不动真实图标。

function Get-ShIconBitmap([string]$path) {
    if (-not (Test-DotNetType 'ShIconDump')) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class ShIconDump {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO {
        public IntPtr hIcon; public int iIcon; public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string pszPath, uint dwAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr hIcon);
    public static Bitmap Get(string p) {
        if (string.IsNullOrEmpty(p)) return null;
        SHFILEINFO f = new SHFILEINFO();
        IntPtr r = SHGetFileInfo(p, 0, ref f, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x100);
        if (r == IntPtr.Zero || f.hIcon == IntPtr.Zero) return null;
        try { using (Icon ic = Icon.FromHandle(f.hIcon)) { return new Bitmap(ic.ToBitmap()); } }
        finally { DestroyIcon(f.hIcon); }
    }
}
'@
    }
    return [ShIconDump]::Get($path)
}

function New-DesktopPanel {
    param([object]$Plan, [object]$Geo, [object]$Mon, [double]$Scale)
    $w = $Mon.WRight - $Mon.WLeft
    $h = $Mon.WBottom - $Mon.WTop
    $pw = [int]($w * $Scale); $ph = [int]($h * $Scale)
    $cellW = [single]($Geo.Cw * $Scale); $cellH = [single]($Geo.Ch * $Scale)
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $pw, $ph
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::FromArgb(252, 252, 254))

        $gpen = New-Object -TypeName System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(234, 237, 243)), 1
        for ($c = 0; $c -lt $Geo.Cols; $c++) {
            for ($r = 0; $r -lt $Geo.Rows; $r++) {
                $x = [single]((Get-CellX $Geo $c) + $Geo.Ox - $Mon.WLeft) * $Scale
                $y = [single]((Get-CellY $Geo $r) + $Geo.Oy - $Mon.WTop) * $Scale
                $g.DrawRectangle($gpen, $x, $y, $cellW, $cellH)
            }
        }

        $font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Microsoft YaHei', 7
        $brush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(45, 45, 55))
        $fmt = New-Object -TypeName System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $iconW = $cellW * 0.62
        $iconH = $cellH * 0.50

        foreach ($p in $Plan) {
            $sx = $p.X + $Geo.Ox
            $sy = $p.Y + $Geo.Oy
            if ($sx -lt $Mon.WLeft -or $sx -ge $Mon.WRight) { continue }
            $x = [single]($sx - $Mon.WLeft) * $Scale
            $y = [single]($sy - $Mon.WTop) * $Scale
            $ix = $x + ($cellW - $iconW) / 2
            $ib = Get-ShIconBitmap (Resolve-IconPath $p.Name)
            if ($ib) {
                try { $g.DrawImage($ib, $ix, ($y + $cellH * 0.06), $iconW, $iconH) }
                finally { $ib.Dispose() }
            }
            else {
                $b2 = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(192, 197, 207))
                $g.FillRectangle($b2, $ix, ($y + $cellH * 0.06), $iconW, $iconH)
                $b2.Dispose()
            }
            $rect = New-Object -TypeName System.Drawing.RectangleF -ArgumentList ([single]($x - $cellW * 0.2)), ([single]($y + $cellH * 0.60)), ([single]($cellW * 1.4)), ([single]($cellH * 0.36))
            $g.DrawString($p.Name, $font, $brush, $rect, $fmt)
        }
        $font.Dispose(); $brush.Dispose(); $fmt.Dispose(); $gpen.Dispose()
    }
    finally { $g.Dispose() }
    return $bmp
}

function Invoke-Render {
    param([int]$MonitorIndex = -1, [string]$OutPath = '')
    Add-Type -AssemblyName System.Drawing
    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        $raw = @(Get-IconRows $view)
        if ($raw.Count -eq 0) { Write-Host "桌面上没有图标，无法生成效果图。" -ForegroundColor DarkYellow; return }
        Initialize-GridInfo $view $mons $raw $origin $cw $ch
        $raw = @(Get-IconRows $view)

        if ($MonitorIndex -lt 0 -or $MonitorIndex -ge $mons.Count) {
            $cnt = Get-IconCounts $mons $raw $origin
            $bestI = 0; $bestN = -1
            foreach ($k in $cnt.Keys) { if ($cnt[$k] -gt $bestN) { $bestN = $cnt[$k]; $bestI = $k } }
            $MonitorIndex = $bestI
        }
        $mon = @($mons | Where-Object { $_.Index -eq $MonitorIndex })[0]
        $geo = Get-MonitorGeo $mon $cw $ch $origin.X $origin.Y

        $now = @($raw | ForEach-Object { [pscustomobject]@{ Name = $_.Name; X = $_.X; Y = $_.Y } })
        $panels = @()
        $panels += @{ Title = 'A. 现在（你的桌面）'; Plan = $now }

        $savedStrategy = $Strategy
        foreach ($st in @('Compact', 'Strict')) {
            $script:Strategy = $st
            $b = Build-Plan $raw $geo $mons $view
            $title = if ($st -eq 'Compact') { 'B. 紧凑拼行：一行一个色系，必要时拼行（默认）' } else { 'C. 严格分行：一行一个色系，不拼行' }
            $panels += @{ Title = $title; Plan = @($b.Plan) }
            Write-Host ""
            Write-Host ("[{0}] 应用区配色（自上而下）：" -f $st) -ForegroundColor Cyan
            foreach ($row in $b.AppRows) {
                Write-Host ("    第 {0} 行  {1}：{2}" -f ($row.Row + 1), $row.Family, (@($row.Names) -join '、')) -ForegroundColor DarkGray
            }
        }
        $script:Strategy = $savedStrategy

        $w = $mon.WRight - $mon.WLeft
        $scale = [math]::Min(1.0, 1180.0 / $w)
        $panelW = [int]($w * $scale)
        $panelH = [int](($mon.WBottom - $mon.WTop) * $scale)
        $gap = 16; $barH = 34
        $totalW = $panelW * $panels.Count + $gap * ($panels.Count + 1)
        $totalH = $barH + $panelH + $gap * 2
        $canvas = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $totalW, $totalH
        $cg = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $cg.Clear([System.Drawing.Color]::FromArgb(236, 239, 245))
            $tfont = New-Object -TypeName System.Drawing.Font -ArgumentList 'Microsoft YaHei', 12, ([System.Drawing.FontStyle]::Bold)
            $tbrush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(28, 30, 40))
            $bpen = New-Object -TypeName System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(198, 203, 214)), 1
            $x = $gap
            foreach ($pn in $panels) {
                $cg.DrawString($pn.Title, $tfont, $tbrush, [single]$x, 8)
                $pb = New-DesktopPanel $pn.Plan $geo $mon $scale
                $cg.DrawImage($pb, $x, ($barH + $gap))
                $cg.DrawRectangle($bpen, $x, ($barH + $gap), $panelW, $panelH)
                $pb.Dispose()
                $x += $panelW + $gap
            }
            $tfont.Dispose(); $tbrush.Dispose(); $bpen.Dispose()
        }
        finally { $cg.Dispose() }

        if (-not $OutPath) { $OutPath = Join-Path $snapDir ("preview-m{0}.png" -f ($mon.Index + 1)) }
        $canvas.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $canvas.Dispose()
        Write-Host ""
        Write-Host ("效果图已生成：{0}" -f $OutPath) -ForegroundColor Green
    }
    finally { $view.Dispose() }
}

function Invoke-SaveMine {
    $view = New-Object DesktopView
    try { $rows = @(Get-IconRows $view) } finally { $view.Dispose() }
    Save-Rows $rows $script:MyLayout
    Write-Host ""
    Write-Host ("已把当前 {0} 个图标的位置保存为「我的布局」：" -f $rows.Count) -ForegroundColor Green
    Write-Host ("  {0}" -f $script:MyLayout) -ForegroundColor DarkGray
    Write-Host "以后菜单选 3 即可一键回到这个样子。" -ForegroundColor DarkGray
}

function Invoke-Apply {
    param([switch]$NoConfirm)
    if (-not (Test-Path -LiteralPath $script:MyLayout)) {
        Write-Host "还没有保存过「我的布局」。请先手动摆好，再选菜单 2 保存。" -ForegroundColor DarkYellow
        return
    }
    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        $raw = @(Get-IconRows $view)
        Initialize-GridInfo $view $mons $raw $origin $cw $ch
        $raw = @(Get-IconRows $view)
        $layout = @(Read-Rows $script:MyLayout)

        if (-not $NoConfirm) {
            $ans = Read-Host ("要把桌面恢复到「我的布局」（{0} 个图标）吗？回车继续，输入 N 取消" -f $layout.Count)
            if ($ans -match '^\s*(n|no)\s*$') { Write-Host "已取消。" -ForegroundColor DarkYellow; return }
        }
        Push-History $raw
        $res = Invoke-RestoreLayout $view $layout $mons $origin $cw $ch
        Write-Host ""
        if ($res.Bad.Count -eq 0) { Write-Host ("完成：{0} 个图标已回到保存的位置。" -f $res.Count) -ForegroundColor Green }
        else { Write-Host ("有 {0} 个图标没能回到原位。" -f $res.Bad.Count) -ForegroundColor DarkYellow }
    }
    finally { $view.Dispose() }
}

function Invoke-Undo {
    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        Initialize-GridInfo $view $mons @(Get-IconRows $view) $origin $cw $ch
        $layout = Pop-History
        if ($null -eq $layout -or @($layout).Count -eq 0) {
            Write-Host "没有可撤销的历史了。可以试试「恢复到最初布局」。" -ForegroundColor DarkYellow
            return
        }
        $res = Invoke-RestoreLayout $view @($layout) $mons $origin $cw $ch
        Write-Host ""
        if ($res.Bad.Count -eq 0) { Write-Host ("已撤销：桌面回到上一次操作前的位置（{0} 个图标）。" -f $res.Count) -ForegroundColor Green }
        else { Write-Host ("撤销完成，但有 {0} 个图标没能回到原位。" -f $res.Bad.Count) -ForegroundColor DarkYellow }
    }
    finally { $view.Dispose() }
}

function Invoke-Original {
    if (-not (Test-Path -LiteralPath $script:Original)) {
        Write-Host "还没有「最初布局」快照（会在第一次排列时自动生成）。" -ForegroundColor DarkYellow
        return
    }
    $mons = Get-MonitorList
    $view = New-Object DesktopView
    try {
        $origin = Get-ListOrigin $view
        $cw = $view.Spacing[0]; $ch = $view.Spacing[1]
        $raw = @(Get-IconRows $view)
        Initialize-GridInfo $view $mons $raw $origin $cw $ch
        $raw = @(Get-IconRows $view)
        $layout = @(Read-Rows $script:Original)
        $ans = Read-Host "要恢复到「最初布局」吗？回车继续，输入 N 取消"
        if ($ans -match '^\s*(n|no)\s*$') { Write-Host "已取消。" -ForegroundColor DarkYellow; return }
        Push-History $raw
        $res = Invoke-RestoreLayout $view $layout $mons $origin $cw $ch
        Write-Host ""
        if ($res.Bad.Count -eq 0) { Write-Host ("完成：桌面已回到最初布局（{0} 个图标）。" -f $res.Count) -ForegroundColor Green }
        else { Write-Host ("有 {0} 个图标没能回到原位。" -f $res.Bad.Count) -ForegroundColor DarkYellow }
    }
    finally { $view.Dispose() }
}

# ================================================================ 菜单
function Show-Menu {
    while ($true) {
        try { Clear-Host } catch { }
        Write-Host "================================================================" -ForegroundColor DarkCyan
        Write-Host "                      桌面图标排列工具" -ForegroundColor Cyan
        Write-Host "================================================================" -ForegroundColor DarkCyan

        try {
            $mons = Get-MonitorList
            $view = New-Object DesktopView
            try {
                $origin = Get-ListOrigin $view
                $counts = Get-IconCounts $mons @(Get-IconRows $view) $origin
            }
            finally { $view.Dispose() }
            $parts = @()
            foreach ($m in $mons) {
                $tag = if ($m.Primary) { '主' } else { '副' }
                $parts += ("屏幕{0}[{1}] {2}图标" -f ($m.Index + 1), $tag, $counts[$m.Index])
            }
            Write-Host ("  显示器：" + ($parts -join '   ')) -ForegroundColor DarkGray
        }
        catch {
            Write-Host ("  读取桌面失败：" + $_.Exception.Message) -ForegroundColor Red
        }

        Write-Host "----------------------------------------------------------------"
        Write-Host "  1) 自动排列桌面" -ForegroundColor White
        Write-Host "     （多块屏幕时会先让你选择排到哪一块；排列前自动备份）" -ForegroundColor DarkGray
        Write-Host "  2) 保存当前布局为「我的布局」" -ForegroundColor White
        Write-Host "  3) 应用「我的布局」（一键回到保存的样子）" -ForegroundColor White
        Write-Host "  4) 撤销上一次操作（回到操作前的图标位置）" -ForegroundColor White
        Write-Host "  5) 恢复到「最初布局」" -ForegroundColor White
        Write-Host "  6) 查看显示器与图标分布" -ForegroundColor White
        Write-Host "  0) 退出" -ForegroundColor White
        Write-Host "----------------------------------------------------------------"
        $choice = "$(Read-Host '请输入选项')"

        switch ($choice.Trim()) {
            '1' { try { Invoke-Arrange }  catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '2' { try { Invoke-SaveMine } catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '3' { try { Invoke-Apply }    catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '4' { try { Invoke-Undo }     catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '5' { try { Invoke-Original } catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '6' { try { Show-Info }       catch { Write-Host ("出错：" + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
            '0' { return }
            default { Write-Host "请输入 0~6。" -ForegroundColor DarkYellow; Start-Sleep -Milliseconds 700 }
        }
    }
}

function Pause-Any {
    Write-Host ""
    [void](Read-Host "按回车返回菜单")
}

# ================================================================ 入口
switch ($Action) {
    'Menu'     { Show-Menu }
    'Info'     { Show-Info }
    'Check'    { Invoke-Check }
    'Preview'  { Invoke-Arrange -MonitorIndex $Monitor -NoConfirm }
    'Arrange'  { Invoke-Arrange -MonitorIndex $Monitor -NoConfirm:$Yes }
    'Save'     { Invoke-SaveMine }
    'Apply'    { Invoke-Apply -NoConfirm:$Yes }
    'Undo'     { Invoke-Undo }
    'Original' { Invoke-Original }
    'Render'   { Invoke-Render -MonitorIndex $Monitor -OutPath $Out }
}
