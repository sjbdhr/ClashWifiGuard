<#
网络守护台 ClashWifiGuard
------------------------------------------------------------
把「Clash AI 节点自动优选」和「WiFi 自动重连」合成一个桌面应用。

  * Clash 部分：按 ChatGPT 实际域名延迟，在台湾/美国/新加坡节点里挑最快的，
    写回 mihomo 的 AI 策略组；差距不超过阈值、或未连续 N 轮确认，就不切换。
  * WiFi 部分：定时检测是否连着指定 SSID，掉线就 netsh 重新连接。
  * 所有参数在界面上改，保存到 ClashWifiGuard.config.json，下次启动自动载入。

用法
  powershell -ExecutionPolicy Bypass -File .\ClashWifiGuard.ps1
  或用同目录的「启动网络守护台.bat」双击启动（不弹黑框）。

  自检（不显示窗口，只验证界面和依赖）：
  powershell -ExecutionPolicy Bypass -File .\ClashWifiGuard.ps1 -SelfTest

不需要管理员权限。
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$AutoProbe
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ---- 单实例 ---------------------------------------------------------------
# 没有这把锁时每次双击都会再起一个实例：两个窗口、两个 powershell 进程，
# 而且两个引擎同时切节点会互相打架。已有实例时把它的窗口提到前台，本进程直接退出。
if (-not $SelfTest) {
    $script:SingleMutex = New-Object System.Threading.Mutex($false, 'Local\ClashWifiGuard.SingleInstance')
    if (-not $script:SingleMutex.WaitOne(0)) {
        try {
            Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GuardActivate {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    // FindWindow 对本程序的窗口一直返回 0（类名传 null、标题为中文时匹配不上），
    // 改用 EnumWindows 逐个比对标题，实测可靠。
    public static IntPtr FindByTitle(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString() == title) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
            $h = [GuardActivate]::FindByTitle('网络守护台')
            if ($h -ne [IntPtr]::Zero) {
                [void][GuardActivate]::ShowWindow($h, 9)          # SW_RESTORE
                [void][GuardActivate]::SetForegroundWindow($h)
            }
        } catch { }
        exit 0
    }
}

# ---- 目录与配置 -----------------------------------------------------------
$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigPath = Join-Path $script:AppDir 'ClashWifiGuard.config.json'
$script:LaunchBat   = Join-Path $script:AppDir '启动网络守护台.bat'

# 任务栏图标：本进程是 powershell.exe 宿主，不显式设置 AppUserModelID 的话，
# 任务栏会按 powershell.exe 分组并沿用它的图标，窗口自己设的 Icon 不会出现在任务栏上。
Add-Type @'
using System.Runtime.InteropServices;
public class GuardAppId {
    [DllImport("shell32.dll", SetLastError = true)] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
}
'@
try { [void][GuardAppId]::SetCurrentProcessExplicitAppUserModelID('ClashWifiGuard.Desktop') } catch { }

function Get-DefaultConfig {
    [ordered]@{
        Regions       = @('台湾', '美国', '新加坡')
        Tolerance     = 120
        Interval      = 180
        ConfirmRounds = 2
        Group         = 'AI'
        TestUrl       = 'https://chatgpt.com/'
        Exclude       = '高倍,3x流量'
        Samples       = 2
        TimeoutMs     = 3000
        Ssid          = 'ZTE_7EF92F'
        WifiInterval  = 3
        ClashAutoStart = $true
        WifiAutoStart  = $true
    }
}

function Load-Config {
    $def = Get-DefaultConfig
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $def }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json
        foreach ($k in @($def.Keys)) {
            if ($obj.PSObject.Properties.Name -contains $k) { $def[$k] = $obj.$k }
        }
    } catch { }
    return $def
}

function Save-Config {
    param($Cfg)
    try {
        ($Cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
        return $true
    } catch { return $false }
}

$script:Cfg = Load-Config

# ---- 引擎脚本（在两个独立 runspace 里跑，界面不卡） -----------------------
$ClashEngine = @'
param($Sync)

$ErrorActionPreference = 'Stop'
$GroupTypes = @('Selector','URLTest','Fallback','LoadBalance','Direct','Reject','Compatible','Pass','Relay')
$RegionTokens = @{
    '台湾'   = @('台湾','台灣','TW')
    '美国'   = @('美国','美國','US')
    '日本'   = @('日本','JP')
    '新加坡' = @('新加坡','SG')
}

function Log {
    param([string]$Msg, [string]$Level = 'info')
    $item = [pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Msg = $Msg; Level = $Level }
    [void]$Sync.ClashLog.Add($item)
    while ($Sync.ClashLog.Count -gt 600) { $Sync.ClashLog.RemoveAt(0) }
}

function Get-PipeName {
    $files = [System.IO.Directory]::GetFiles('\\.\pipe\')
    $hit = $files | Where-Object { $_ -match 'MihomoParty' -and $_ -match 'mihomo-user-Console' } |
           Select-Object -First 1
    if (-not $hit) { throw '没找到 mihomo 控制管道' }
    return $hit.Substring('\\.\pipe\'.Length)
}

function Invoke-Mihomo {
    param([string]$Method, [string]$Path, $Body = $null)
    if (-not $Sync.PipeName) { $Sync.PipeName = Get-PipeName }

    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Sync.PipeName, 'InOut')
    try {
        $client.Connect(3000)

        $json = $null
        if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 5 -Compress) }

        $head = "$Method $Path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n"
        if ($null -ne $json) {
            $byteLen = [System.Text.Encoding]::UTF8.GetByteCount($json)
            $head += "Content-Type: application/json`r`nContent-Length: $byteLen`r`n"
        }
        $head += "`r`n"

        $payload = [System.Text.Encoding]::UTF8.GetBytes($head)
        if ($null -ne $json) {
            $payload = [byte[]]($payload + [System.Text.Encoding]::UTF8.GetBytes($json))
        }
        $client.Write($payload, 0, $payload.Length)
        $client.Flush()

        $buf = New-Object byte[] 16384
        $acc = New-Object System.Collections.Generic.List[byte]
        while ($true) {
            $n = $client.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            for ($i = 0; $i -lt $n; $i++) { $acc.Add($buf[$i]) }
        }
        $all = $acc.ToArray()
    }
    finally { $client.Dispose() }

    # 分隔符与 chunked 必须在字节层面处理，节点名含中文，字节数与字符数不相等
    $sep = -1
    for ($i = 0; $i -lt $all.Length - 3; $i++) {
        if ($all[$i] -eq 13 -and $all[$i+1] -eq 10 -and $all[$i+2] -eq 13 -and $all[$i+3] -eq 10) { $sep = $i; break }
    }
    $headText = if ($sep -ge 0) { [System.Text.Encoding]::UTF8.GetString($all, 0, $sep) } else { '' }

    $code = 0
    if ($headText -match 'HTTP/1\.\d (\d{3})') { $code = [int]$Matches[1] }

    $bodyText = ''
    if ($sep -ge 0 -and ($sep + 4) -lt $all.Length) {
        if ($headText -match '(?i)transfer-encoding:\s*chunked') {
            $bytes = New-Object System.Collections.Generic.List[byte]
            $pos = $sep + 4
            while ($pos -lt $all.Length) {
                $nl = -1
                for ($i = $pos; $i -lt $all.Length - 1; $i++) {
                    if ($all[$i] -eq 13 -and $all[$i+1] -eq 10) { $nl = $i; break }
                }
                if ($nl -lt 0) { break }
                $sizeText = [System.Text.Encoding]::ASCII.GetString($all, $pos, $nl - $pos)
                if ($sizeText -notmatch '^[0-9a-fA-F]{1,8}$') { break }
                $size = [System.Convert]::ToInt32($sizeText, 16)
                if ($size -le 0) { break }
                $start = $nl + 2
                if ($start + $size -gt $all.Length) { break }
                for ($i = 0; $i -lt $size; $i++) { $bytes.Add($all[$start + $i]) }
                $pos = $start + $size + 2
            }
            if ($bytes.Count -gt 0) { $bodyText = [System.Text.Encoding]::UTF8.GetString($bytes.ToArray()) }
        } else {
            $bodyText = [System.Text.Encoding]::UTF8.GetString($all, $sep + 4, $all.Length - ($sep + 4))
        }
    }

    $data = $null
    if ($bodyText.Trim()) {
        try { $data = $bodyText | ConvertFrom-Json } catch { $data = $null }
    }
    return [pscustomobject]@{ Code = $code; Data = $data }
}

function Get-Proxies {
    $r = Invoke-Mihomo -Method 'GET' -Path '/proxies'
    if ($r.Code -ne 200 -or $null -eq $r.Data) { throw "读取 /proxies 失败 (HTTP $($r.Code))" }
    return $r.Data.proxies
}

function Get-Delay {
    param([string]$Node, [string]$TestUrl, [int]$Timeout)
    $path = "/proxies/$([uri]::EscapeDataString($Node))/delay?url=$([uri]::EscapeDataString($TestUrl))&timeout=$Timeout"
    $r = Invoke-Mihomo -Method 'GET' -Path $path
    if ($r.Code -eq 200 -and $null -ne $r.Data -and $null -ne $r.Data.delay) { return [int]$r.Data.delay }
    return $null
}

function Get-DelayBest {
    param([string]$Node, [string]$TestUrl, [int]$Timeout, [int]$Count)
    $vals = @()
    for ($i = 0; $i -lt [Math]::Max(1, $Count); $i++) {
        $d = Get-Delay -Node $Node -TestUrl $TestUrl -Timeout $Timeout
        if ($null -ne $d) { $vals += $d }
        Start-Sleep -Milliseconds 100
    }
    if ($vals.Count -gt 0) { return ($vals | Measure-Object -Minimum).Minimum }
    return $null
}

function Set-Selection {
    param([string]$TargetGroup, [string]$Node)
    $r = Invoke-Mihomo -Method 'PUT' -Path "/proxies/$([uri]::EscapeDataString($TargetGroup))" -Body @{ name = $Node }
    return ($r.Code -eq 204)
}

function Get-Candidates {
    param($Proxies, [string[]]$Regions, [string[]]$Exclude)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Proxies.PSObject.Properties.Name) {
        $info = $Proxies.$name
        if ($GroupTypes -contains $info.type) { continue }
        if ($name -like '支持AI*' -or $name -like '*@*' -or $name -like '*官网*') { continue }

        $skip = $false
        foreach ($tok in $Exclude) { if ($tok -and $name -like "*$tok*") { $skip = $true; break } }
        if ($skip) { continue }

        foreach ($region in $Regions) {
            foreach ($tok in $RegionTokens[$region]) {
                if ($name -like "*$tok*") { [void]$out.Add($name); $skip = $true; break }
            }
            if ($skip) { break }
        }
    }
    return $out.ToArray()
}

function Invoke-Round {
    $Cfg = $Sync.Config
    $proxies = Get-Proxies

    if (-not ($proxies.PSObject.Properties.Name -contains $Cfg.Group)) { throw "找不到策略组 $($Cfg.Group)" }
    $current = $proxies.($Cfg.Group).now

    # Exclude 从界面过来是逗号分隔的字符串，必须拆成多个关键词，否则整串当一个词匹配不到任何节点
    $exTokens = @()
    if ($Cfg.Exclude) {
        $exTokens = @($Cfg.Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $nodes = Get-Candidates -Proxies $proxies -Regions $Cfg.Regions -Exclude $exTokens
    if ($nodes.Count -eq 0) { throw "没有匹配到任何节点（地区: $($Cfg.Regions -join '/')）" }

    $realCurrent = $current
    $guard = 0
    while (($proxies.PSObject.Properties.Name -contains $realCurrent) -and
           ($GroupTypes -contains $proxies.$realCurrent.type) -and
           $proxies.$realCurrent.now -and $guard -lt 10) {
        $realCurrent = $proxies.$realCurrent.now
        $guard++
    }

    # 逐节点测速
    $table = @{}
    foreach ($node in $nodes) {
        $d = Get-DelayBest -Node $node -TestUrl $Cfg.TestUrl -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples
        $table[$node] = $d
        Start-Sleep -Milliseconds 60
    }

    $ok = @{}
    foreach ($kv in $table.GetEnumerator()) { if ($null -ne $kv.Value) { $ok[$kv.Key] = $kv.Value } }

    $Sync.Nodes       = @($table.GetEnumerator() |
                          Sort-Object @{ Expression = { if ($null -eq $_.Value) { [int]::MaxValue } else { $_.Value } } } |
                          ForEach-Object { $_.Key })
    $Sync.NodeDelays  = $table
    $Sync.CurrentNode = $realCurrent
    $Sync.Round++

    if ($ok.Count -eq 0) {
        Log '本轮全部节点不可达，保持现状'
        return
    }

    $best = ($ok.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
    $curDelay = if ($ok.ContainsKey($realCurrent)) { $ok[$realCurrent] } else { $null }
    $Sync.BestNode   = $best
    $Sync.BestDelay  = $ok[$best]
    $Sync.CurrentDelay = $curDelay

    $detail = ($table.GetEnumerator() | ForEach-Object {
        $v = if ($null -eq $_.Value) { '失败' } else { "$($_.Value)ms" }
        "$($_.Key) $v"
    }) -join ' | '
    Log "探测: $detail"

    $switch = $false
    $reason = ''
    $needCheck = $false

    if ($nodes -notcontains $realCurrent) {
        $Sync.PendingNode = $null; $Sync.PendingCount = 0
        $switch = $true; $reason = '当前出口不在候选范围'
    } elseif ($null -eq $curDelay) {
        $Sync.PendingNode = $null; $Sync.PendingCount = 0
        $switch = $true; $reason = '当前节点不可达'
    } elseif ($best -ne $realCurrent) {
        $needCheck = $true
    } else {
        $Sync.PendingNode = $null; $Sync.PendingCount = 0
        $reason = '当前节点已是最优'
    }

    if ($needCheck) {
        $dNew = Get-DelayBest -Node $best -TestUrl $Cfg.TestUrl -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples
        $dOld = Get-DelayBest -Node $realCurrent -TestUrl $Cfg.TestUrl -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples

        if ($null -eq $dNew) {
            $Sync.PendingNode = $null; $Sync.PendingCount = 0
            $switch = $false; $reason = "候选 $best 复核时不可达"
        } elseif ($null -eq $dOld) {
            $Sync.PendingNode = $null; $Sync.PendingCount = 0
            $switch = $true;  $reason = '当前节点复核时不可达'
        } else {
            $gap = $dOld - $dNew
            if ($gap -gt $Cfg.Tolerance) {
                if ($Sync.PendingNode -and $Sync.PendingNode -eq $best) {
                    $Sync.PendingCount++
                } else {
                    $Sync.PendingNode = $best; $Sync.PendingCount = 1
                }
                if ($Cfg.ConfirmRounds -le 1 -or $Sync.PendingCount -ge $Cfg.ConfirmRounds) {
                    $switch = $true
                    $reason = "连续 $($Sync.PendingCount) 轮确认快 ${gap}ms，超过阈值 $($Cfg.Tolerance)ms"
                } else {
                    $switch = $false
                    $reason = "确认 $($Sync.PendingCount)/$($Cfg.ConfirmRounds) 轮（快 ${gap}ms），下一轮再复核"
                }
            } elseif ($gap -le 0) {
                $Sync.PendingNode = $null; $Sync.PendingCount = 0
                $switch = $false; $reason = "复核时 $best 反而慢 $([Math]::Abs($gap))ms，不切"
            } else {
                $Sync.PendingNode = $null; $Sync.PendingCount = 0
                $switch = $false; $reason = "复核仅快 ${gap}ms，未超过阈值 $($Cfg.Tolerance)ms，不切"
            }
        }
        Log "复核: $best ${dNew}ms vs $realCurrent ${dOld}ms -> $reason"
    }

    if ($switch) {
        if ($Sync.DryRun) {
            Log "试运行: 本应切换 -> $best（$reason）" 'warn'
        } elseif (Set-Selection -TargetGroup $Cfg.Group -Node $best) {
            Log "已切换 $($Cfg.Group) : $realCurrent -> $best（$reason）" 'ok'
            $Sync.CurrentNode = $best
            $Sync.PendingNode = $null; $Sync.PendingCount = 0
        } else {
            Log '切换失败，mihomo 拒绝写入' 'err'
        }
    } else {
        Log "保持: $realCurrent — $reason"
    }
}

Log 'Clash 引擎就绪'

while (-not $Sync.Shutdown) {
    if ($Sync.Running -or $Sync.OneShot) {
        $oneShot = $Sync.OneShot
        try {
            Invoke-Round
            $Sync.LastError = ''
        } catch {
            $Sync.LastError = $_.Exception.Message
            Log "本轮异常: $($_.Exception.Message)" 'err'
            try { $Sync.PipeName = Get-PipeName } catch { }
        }
        if ($oneShot) { $Sync.OneShot = $false }

        if ($Sync.Running) {
            $waitSec = [double]$Sync.Config.Interval
            $deadline = (Get-Date).AddSeconds($waitSec)
            while (-not $Sync.Shutdown -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
                if ($Sync.OneShot) { break }
            }
        }
    } else {
        Start-Sleep -Milliseconds 250
    }
}
'@

$WifiEngine = @'
param($Sync)

$ErrorActionPreference = 'Continue'

function Log {
    param([string]$Msg, [string]$Level = 'info')
    $item = [pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Msg = $Msg; Level = $Level }
    [void]$Sync.WifiLog.Add($item)
    while ($Sync.WifiLog.Count -gt 300) { $Sync.WifiLog.RemoveAt(0) }
}

function Get-WifiText {
    try {
        $old = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
        $txt = (& netsh wlan show interfaces 2>&1) -join "`n"
        [Console]::OutputEncoding = $old
        return $txt
    } catch { return '' }
}

function Test-TargetConnected {
    param([string]$Ssid)
    $txt = Get-WifiText
    if (-not $txt) { return $false }
    if ($txt -notmatch 'SSID') { return $false }
    # 只匹配 SSID 行，避免把 BSSID / 其他字段误判成已连接
    $ssidLines = ($txt -split "`n") | Where-Object { $_ -match '^\s*SSID\s*:' -and $_ -notmatch 'BSSID' }
    foreach ($line in $ssidLines) {
        $val = ($line -split ':', 2)[1]
        if ($val -and $val.Trim() -eq $Ssid) { return $true }
    }
    return $false
}

Log 'WiFi 引擎就绪'

while (-not $Sync.Shutdown) {
    if ($Sync.WifiRunning) {
        $ssid = [string]$Sync.Config.Ssid
        try {
            $connected = Test-TargetConnected -Ssid $ssid
            $Sync.WifiConnected = $connected
            $Sync.WifiSsid = $ssid

            if (-not $connected) {
                $Sync.WifiReconnects++
                Log "未连接 $ssid，尝试重连（第 $($Sync.WifiReconnects) 次）" 'warn'
                $res = (& netsh wlan connect name="$ssid" 2>&1) -join ' '
                if ($res -match 'completed successfully|已成功完成|成功') {
                    Log "重连指令已执行" 'ok'
                } else {
                    Log "重连返回: $($res.Trim())" 'warn'
                }
                if (-not $Sync.WifiFirstCheck) {
                    $Sync.WifiFirstCheck = $true
                    Log '注意：目标 SSID 的配置文件必须已存在于本机，否则 netsh 无法连接' 'warn'
                }
            }
            $Sync.WifiLastCheck = (Get-Date).ToString('HH:mm:ss')
        } catch {
            Log "检测异常: $($_.Exception.Message)" 'err'
        }

        $waitMs = [Math]::Max(1, [double]$Sync.Config.WifiInterval) * 1000
        $deadline = (Get-Date).AddMilliseconds($waitMs)
        while (-not $Sync.Shutdown -and (Get-Date) -lt $deadline -and $Sync.WifiRunning) {
            Start-Sleep -Milliseconds 200
        }
    } else {
        Start-Sleep -Milliseconds 250
    }
}
'@

# ---- 同步状态 -------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{
    Shutdown       = $false
    ClashLog       = New-Object System.Collections.ArrayList
    WifiLog        = New-Object System.Collections.ArrayList

    Running        = $false
    OneShot        = $false
    DryRun         = $false
    Round          = 0
    Nodes          = @()
    NodeDelays     = @{}
    CurrentNode    = ''
    CurrentDelay   = $null
    BestNode       = ''
    BestDelay      = $null
    PendingNode    = ''
    PendingCount   = 0
    PipeName       = ''
    LastError      = ''

    WifiRunning    = $false
    WifiConnected  = $false
    WifiSsid       = ''
    WifiReconnects = 0
    WifiLastCheck  = ''
    WifiFirstCheck = $false

    Config         = [hashtable]::Synchronized(@{})
})
foreach ($k in $script:Cfg.Keys) { $sync.Config[$k] = $script:Cfg[$k] }

# ---- 界面 -----------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="网络守护台" Width="1000" Height="915"
        MinWidth="880" MinHeight="620"
        WindowStartupLocation="Manual"
        WindowStyle="None" ResizeMode="CanResize"
        Background="#0B0E14"
        FontFamily="Microsoft YaHei UI, Segoe UI">

  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="46" ResizeBorderThickness="6"
                        GlassFrameThickness="0" CornerRadius="0"
                        UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#141926"/>
      <Setter Property="BorderBrush" Value="#222B3C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#2ED3C6"/>
      <Setter Property="Foreground" Value="#04211F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Background" Value="#1D2536"/>
      <Setter Property="Foreground" Value="#C3CCDA"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" BorderBrush="#2B3547" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#253047"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.75"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A94A6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1E2637"/>
                <Setter Property="Foreground" Value="#E4E8F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#1A2130"/>
      <Setter Property="Foreground" Value="#E4E8F0"/>
      <Setter Property="BorderBrush" Value="#2A3446"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DarkCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C3CCDA"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="17" Height="17" CornerRadius="5" Background="#1A2130" BorderBrush="#2E3849" BorderThickness="1" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M2.5,7 L5.5,10 L10,3.5" Stroke="#2ED3C6" StrokeThickness="1.8"
                      HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#2ED3C6"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#3D4A61"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7C8799"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#2C3648" CornerRadius="4" Margin="2,1,2,1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Value" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E4E8F0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="46"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border x:Name="TitleBar" Grid.Row="0" Background="#0E1219" BorderBrush="#1C2431" BorderThickness="0,0,0,1">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
          <Image x:Name="ImgLogo" Width="26" Height="26" Margin="0,0,9,0" VerticalAlignment="Center"
                 RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock Text="网络守护台" Foreground="#E9EDF5" FontSize="14.5" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <TextBlock Text="Clash 节点优选 · WiFi 自动重连" Foreground="#5A6577" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,6,0">
          <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Content="—" ToolTip="最小化"
                  shell:WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="BtnMax" Style="{StaticResource WinBtn}" Content="□" ToolTip="最大化 / 还原"
                  shell:WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="BtnClose" Style="{StaticResource WinBtn}" Content="✕" ToolTip="关闭"
                  shell:WindowChrome.IsHitTestVisibleInChrome="True"/>
        </StackPanel>
      </Grid>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0">
      <StackPanel Margin="18,16,18,16">

        <!-- 状态总览 -->
        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="1"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Margin="0,0,14,0">
              <TextBlock Text="当前 AI 出口" Style="{StaticResource Label}"/>
              <StackPanel Orientation="Horizontal" Margin="0,7,0,0">
                <TextBlock x:Name="TxtNode" Text="—" Foreground="#E9EDF5" FontSize="19" FontWeight="SemiBold"
                           TextTrimming="CharacterEllipsis" MaxWidth="300" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtNodeDelay" Text="" Foreground="#2ED3C6" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <TextBlock x:Name="TxtNodeSub" Text="Clash 引擎未启动" Foreground="#66707F" FontSize="12" Margin="0,6,0,0"/>
            </StackPanel>

            <Border Grid.Column="1" Background="#222B3C" Margin="0,4,0,4"/>

            <StackPanel Grid.Column="2" Margin="18,0,0,0">
              <TextBlock Text="WiFi 连接" Style="{StaticResource Label}"/>
              <StackPanel Orientation="Horizontal" Margin="0,7,0,0">
                <Border x:Name="DotWifi" Width="9" Height="9" CornerRadius="4.5" Background="#3A4456" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtWifiSsid" Text="未启用" Foreground="#E9EDF5" FontSize="19" FontWeight="SemiBold"
                           Margin="10,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <TextBlock x:Name="TxtWifiSub" Text="WiFi 守护未启动" Foreground="#66707F" FontSize="12" Margin="0,6,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Clash 节点优选 -->
        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="3" Height="16" CornerRadius="2" Background="#2ED3C6" VerticalAlignment="Center"/>
              <TextBlock Text="AI 节点优选" Foreground="#E9EDF5" FontSize="14.5" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtClashState" Text="未运行" Foreground="#66707F" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <WrapPanel Margin="0,16,0,0">
              <TextBlock Text="候选地区" Style="{StaticResource Label}" Margin="0,0,12,0"/>
              <CheckBox x:Name="ChkTW" Content="台湾" Style="{StaticResource DarkCheck}" Margin="0,0,14,0" VerticalAlignment="Center"/>
              <CheckBox x:Name="ChkUS" Content="美国" Style="{StaticResource DarkCheck}" Margin="0,0,14,0" VerticalAlignment="Center"/>
              <CheckBox x:Name="ChkSG" Content="新加坡" Style="{StaticResource DarkCheck}" Margin="0,0,22,0" VerticalAlignment="Center"/>

              <TextBlock Text="不切换阈值" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtTolerance" Style="{StaticResource Input}" Width="66" Text="120"/>
              <TextBlock Text="ms" Style="{StaticResource Label}" Margin="5,0,20,0"/>

              <TextBlock Text="轮询间隔" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtInterval" Style="{StaticResource Input}" Width="66" Text="180"/>
              <TextBlock Text="秒" Style="{StaticResource Label}" Margin="5,0,20,0"/>

              <TextBlock Text="确认轮数" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtConfirm" Style="{StaticResource Input}" Width="52" Text="2"/>
              <TextBlock Text="轮" Style="{StaticResource Label}" Margin="5,0,0,0"/>
            </WrapPanel>

            <WrapPanel Margin="0,14,0,0">
              <TextBlock Text="测速地址" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtTestUrl" Style="{StaticResource Input}" Width="322" Text="https://chatgpt.com/"/>
              <TextBlock Text="排除关键词" Style="{StaticResource Label}" Margin="18,0,8,0"/>
              <TextBox x:Name="TxtExclude" Style="{StaticResource Input}" Width="196" Text="高倍,3x流量"/>
            </WrapPanel>

            <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
              <Button x:Name="BtnClashToggle" Style="{StaticResource Primary}" Content="启动监控" Width="118"/>
              <Button x:Name="BtnProbe" Style="{StaticResource Ghost}" Content="立即检测一次" Margin="10,0,0,0"/>
              <CheckBox x:Name="ChkDryRun" Content="只测不切" Style="{StaticResource DarkCheck}" Margin="18,0,0,0" VerticalAlignment="Center"/>
              <Button x:Name="BtnSave" Style="{StaticResource Ghost}" Content="保存配置" Margin="18,0,0,0"/>
              <CheckBox x:Name="ChkClashAuto" Content="启动时自动监控" Style="{StaticResource DarkCheck}" Margin="18,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <TextBlock Text="节点延迟" Style="{StaticResource Label}" Margin="0,18,0,8"/>
            <Border Background="#101622" BorderBrush="#1E2739" BorderThickness="1" CornerRadius="9" Padding="10,8">
              <ScrollViewer Height="122" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="PnlNodes"/>
              </ScrollViewer>
            </Border>
          </StackPanel>
        </Border>

        <!-- WiFi 守护 -->
        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="3" Height="16" CornerRadius="2" Background="#5B9DF9" VerticalAlignment="Center"/>
              <TextBlock Text="WiFi 自动重连" Foreground="#E9EDF5" FontSize="14.5" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtWifiState" Text="未运行" Foreground="#66707F" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <WrapPanel Margin="0,16,0,0">
              <TextBlock Text="目标 SSID" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtSsid" Style="{StaticResource Input}" Width="220" Text="ZTE_7EF92F"/>
              <TextBlock Text="检测间隔" Style="{StaticResource Label}" Margin="20,0,8,0"/>
              <TextBox x:Name="TxtWifiInterval" Style="{StaticResource Input}" Width="60" Text="3"/>
              <TextBlock Text="秒" Style="{StaticResource Label}" Margin="5,0,20,0"/>
              <Button x:Name="BtnWifiToggle" Style="{StaticResource Ghost}" Content="启动守护" Width="112"/>
              <CheckBox x:Name="ChkWifiAuto" Content="启动时自动守护" Style="{StaticResource DarkCheck}" Margin="18,0,0,0" VerticalAlignment="Center"/>
            </WrapPanel>

            <TextBlock Text="掉线后自动执行 netsh wlan connect 重新连接；该 SSID 的配置文件需已存在于本机。"
                       Foreground="#5A6577" FontSize="12" Margin="0,12,0,0"/>
          </StackPanel>
        </Border>

        <!-- 日志 -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="3" Height="16" CornerRadius="2" Background="#8A94A6" VerticalAlignment="Center"/>
              <TextBlock Text="运行日志" Foreground="#E9EDF5" FontSize="14.5" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
              <Button x:Name="BtnClearLog" Style="{StaticResource Ghost}" Content="清空" Padding="12,4" FontSize="12" Margin="16,0,0,0" Height="28"/>
            </StackPanel>
            <Border BorderBrush="#1E2739" BorderThickness="1" CornerRadius="9" Background="#0F1420" Margin="0,12,0,0">
              <TextBox x:Name="TxtLog" IsReadOnly="True" Background="#0F1420" Foreground="#9BA6B8"
                       BorderThickness="0"
                       FontFamily="Consolas, Microsoft YaHei UI" FontSize="12"
                       TextWrapping="Wrap" AcceptsReturn="True" Height="150"
                       VerticalScrollBarVisibility="Auto" Padding="10,8"/>
            </Border>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

$doc = New-Object System.Xml.XmlDocument
$doc.LoadXml($xaml)
$reader = New-Object System.Xml.XmlNodeReader $doc
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 控件引用
$ui = @{}
foreach ($name in @('TitleBar','BtnMin','BtnMax','BtnClose','ImgLogo','TxtNode','TxtNodeDelay','TxtNodeSub','DotWifi','TxtWifiSsid','TxtWifiSub',
                   'TxtClashState','ChkTW','ChkUS','ChkSG','TxtTolerance','TxtInterval','TxtConfirm',
                   'TxtTestUrl','TxtExclude','BtnClashToggle','BtnProbe','ChkDryRun','BtnSave','ChkClashAuto','PnlNodes',
                   'TxtWifiState','TxtSsid','TxtWifiInterval','BtnWifiToggle','ChkWifiAuto','BtnClearLog','TxtLog')) {
    $ui[$name] = $window.FindName($name)
}

# 窗口图标：与脚本同目录的 app.ico（多尺寸 ICO，取其中最大帧作为窗口/任务栏图标）
$script:IcoPath = Join-Path $script:AppDir 'app.ico'
if (Test-Path -LiteralPath $script:IcoPath) {
    try {
        $icoStream = [System.IO.File]::OpenRead($script:IcoPath)
        $icoOpts = [System.Windows.Media.Imaging.BitmapCreateOptions]::None
        $icoCache = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $icoDecoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create($icoStream, $icoOpts, $icoCache)
        $frames = @($icoDecoder.Frames)
        $bestFrame = $frames[0]
        foreach ($fr in $frames) {
            if ($fr.PixelWidth -gt $bestFrame.PixelWidth) { $bestFrame = $fr }
        }
        $window.Icon = $bestFrame
        $icoStream.Close()
    } catch {
        try { $ui['TxtLog'].AppendText("[图标] 加载失败: $($_.Exception.Message)`r`n") } catch { }
    }
}
# 标题栏 logo：用纯青色线稿版（app-icon-mark.png），深色标题栏上比原图带深底的版本清晰得多
$script:LogoPath = Join-Path $script:AppDir 'app-icon-mark.png'
if (Test-Path -LiteralPath $script:LogoPath) {
    try {
        $logoStream = [System.IO.File]::OpenRead($script:LogoPath)
        $logoImg = New-Object System.Windows.Media.Imaging.BitmapImage
        $logoImg.BeginInit()
        $logoImg.StreamSource = $logoStream
        $logoImg.DecodePixelWidth = 64
        $logoImg.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $logoImg.EndInit()
        $ui['ImgLogo'].Source = $logoImg
        $logoStream.Close()
    } catch {
        try { $ui['TxtLog'].AppendText("[Logo] 加载失败: $($_.Exception.Message)`r`n") } catch { }
    }
}

# ---- 主屏居中定位 -----------------------------------------------------------
# 本机是 2560x1440 主屏 + 右侧副屏、150% DPI，WPF 的 CenterScreen 会把窗口
# 算到 x≈4736（副屏右侧之外）。改用 Win32 拿主屏工作区物理坐标再定位。
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class GuardWin32 {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref RECT rect, uint winIni);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

# 窗口初始位置：PowerShell 宿主里的 WPF 会把「物理像素」当逻辑值参与居中计算
# （本机 150% 缩放 + 双屏时 CenterScreen 会把窗口推到主屏右边缘之外），
# 这里先按 DPI 把屏幕尺寸折算成逻辑尺寸，再算居中，保证整窗落在主屏内。
$window.Add_Loaded({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $dpi = [GuardWin32]::GetDpiForWindow($hwnd)
        if ($dpi -le 0) { $dpi = 96 }
        $s = $dpi / 96.0
        $logW = [System.Windows.SystemParameters]::PrimaryScreenWidth / $s
        $logH = [System.Windows.SystemParameters]::PrimaryScreenHeight / $s
        $l = [Math]::Round(($logW - $window.ActualWidth) / 2)
        $t = [Math]::Round(($logH - $window.ActualHeight) / 2)
        if ($l -lt 0) { $l = 0 }
        if ($t -lt 0) { $t = 0 }
        $window.Left = $l
        $window.Top = $t
    } catch { }
})

# 初值回填
$ui['ChkTW'].IsChecked = ($script:Cfg.Regions -contains '台湾')
$ui['ChkUS'].IsChecked = ($script:Cfg.Regions -contains '美国')
$ui['ChkSG'].IsChecked = ($script:Cfg.Regions -contains '新加坡')
$ui['TxtTolerance'].Text    = [string]$script:Cfg.Tolerance
$ui['TxtInterval'].Text     = [string]$script:Cfg.Interval
$ui['TxtConfirm'].Text      = [string]$script:Cfg.ConfirmRounds
$ui['TxtTestUrl'].Text      = [string]$script:Cfg.TestUrl
$ui['TxtExclude'].Text      = [string]$script:Cfg.Exclude
$ui['TxtSsid'].Text         = [string]$script:Cfg.Ssid
$ui['TxtWifiInterval'].Text = [string]$script:Cfg.WifiInterval
$ui['ChkClashAuto'].IsChecked = [bool]$script:Cfg.ClashAutoStart
$ui['ChkWifiAuto'].IsChecked  = [bool]$script:Cfg.WifiAutoStart

if ($SelfTest) {
    Write-Host 'SelfTest OK: XAML 解析成功，控件全部就位'
    exit 0
}

# ---- runspace -------------------------------------------------------------
$script:ClashPS = $null
$script:ClashRS = $null
$script:ClashHandle = $null
$script:WifiPS = $null
$script:WifiRS = $null
$script:WifiHandle = $null

function Start-ClashEngine {
    if ($script:ClashPS) { return }
    $script:ClashRS = [runspacefactory]::CreateRunspace()
    $script:ClashRS.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:ClashRS.Open()
    $script:ClashPS = [powershell]::Create()
    $script:ClashPS.Runspace = $script:ClashRS
    [void]$script:ClashPS.AddScript($ClashEngine).AddArgument($sync)
    $script:ClashHandle = $script:ClashPS.BeginInvoke()
}

function Start-WifiEngine {
    if ($script:WifiPS) { return }
    $script:WifiRS = [runspacefactory]::CreateRunspace()
    $script:WifiRS.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:WifiRS.Open()
    $script:WifiPS = [powershell]::Create()
    $script:WifiPS.Runspace = $script:WifiRS
    [void]$script:WifiPS.AddScript($WifiEngine).AddArgument($sync)
    $script:WifiHandle = $script:WifiPS.BeginInvoke()
}

function Read-FormToConfig {
    $regions = @()
    if ($ui['ChkTW'].IsChecked) { $regions += '台湾' }
    if ($ui['ChkUS'].IsChecked) { $regions += '美国' }
    if ($ui['ChkSG'].IsChecked) { $regions += '新加坡' }
    if ($regions.Count -eq 0) { $regions = @('台湾', '美国', '新加坡') }

    $tol = 120
    if ($ui['TxtTolerance'].Text -match '^\d+$') { $tol = [int]$ui['TxtTolerance'].Text }
    $itv = 180
    if ($ui['TxtInterval'].Text -match '^\d+$') { $itv = [Math]::Max(10, [int]$ui['TxtInterval'].Text) }
    $cfm = 2
    if ($ui['TxtConfirm'].Text -match '^\d+$') { $cfm = [Math]::Max(1, [int]$ui['TxtConfirm'].Text) }
    $wi = 3
    if ($ui['TxtWifiInterval'].Text -match '^\d+$') { $wi = [Math]::Max(1, [int]$ui['TxtWifiInterval'].Text) }

    $ssid = $ui['TxtSsid'].Text.Trim()
    if (-not $ssid) { $ssid = 'ZTE_7EF92F' }

    $url = $ui['TxtTestUrl'].Text.Trim()
    if (-not $url) { $url = 'https://chatgpt.com/' }

    $sync.Config['Regions']       = $regions
    $sync.Config['Tolerance']     = $tol
    $sync.Config['Interval']      = $itv
    $sync.Config['ConfirmRounds'] = $cfm
    $sync.Config['TestUrl']       = $url
    $sync.Config['Exclude']       = $ui['TxtExclude'].Text.Trim()
    $sync.Config['Ssid']          = $ssid
    $sync.Config['WifiInterval']  = $wi

    $script:Cfg['Regions']       = $regions
    $script:Cfg['Tolerance']     = $tol
    $script:Cfg['Interval']      = $itv
    $script:Cfg['ConfirmRounds'] = $cfm
    $script:Cfg['TestUrl']       = $url
    $script:Cfg['Exclude']       = $ui['TxtExclude'].Text.Trim()
    $script:Cfg['Ssid']          = $ssid
    $script:Cfg['WifiInterval']  = $wi
    $auto1 = [bool]$ui['ChkClashAuto'].IsChecked
    $auto2 = [bool]$ui['ChkWifiAuto'].IsChecked
    $script:Cfg['ClashAutoStart'] = $auto1
    $script:Cfg['WifiAutoStart']  = $auto2
}

# 拖动与四边缩放由 WindowChrome 处理（CaptionHeight=46 / ResizeBorderThickness=6），
# 不再手动 DragMove —— 无边框窗口下 DragMove 与系统标题栏行为容易互相打架
$ui['BtnMin'].Add_Click({ try { $window.WindowState = 'Minimized' } catch { } })
$ui['BtnMax'].Add_Click({
    try {
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
        else { $window.WindowState = 'Maximized' }
    } catch { }
})
$window.Add_StateChanged({
    try {
        if ($window.WindowState -eq 'Maximized') { $ui['BtnMax'].Content = '❐' }
        else { $ui['BtnMax'].Content = '□' }
    } catch { }
})
$ui['BtnClose'].Add_Click({
    $sync.Shutdown = $true
    $sync.Running = $false
    $sync.WifiRunning = $false
    Start-Sleep -Milliseconds 400
    try { if ($script:ClashPS) { $script:ClashPS.Stop() } } catch { }
    try { if ($script:WifiPS) { $script:WifiPS.Stop() } } catch { }
    $window.Close()
})

$ui['BtnSave'].Add_Click({
    Read-FormToConfig
    if (Save-Config $script:Cfg) {
        $ui['TxtNodeSub'].Text = '配置已保存到 ClashWifiGuard.config.json'
    } else {
        $ui['TxtNodeSub'].Text = '配置保存失败，请检查目录写权限'
    }
})

$ui['BtnClashToggle'].Add_Click({
    if (-not $sync.Running) {
        Read-FormToConfig
        Start-ClashEngine
        $sync.Running = $true
        $ui['BtnClashToggle'].Content = '停止监控'
        $ui['TxtClashState'].Text = '运行中'
    } else {
        $sync.Running = $false
        $ui['BtnClashToggle'].Content = '启动监控'
        $ui['TxtClashState'].Text = '已停止'
    }
})

$ui['BtnProbe'].Add_Click({
    Read-FormToConfig
    Start-ClashEngine
    $sync.DryRun = [bool]$ui['ChkDryRun'].IsChecked
    $sync.OneShot = $true
    $ui['TxtClashState'].Text = '单次检测中...'
})

$ui['BtnWifiToggle'].Add_Click({
    if (-not $sync.WifiRunning) {
        Read-FormToConfig
        Start-WifiEngine
        $sync.WifiRunning = $true
        $sync.WifiReconnects = 0
        $sync.WifiFirstCheck = $false
        $ui['BtnWifiToggle'].Content = '停止守护'
        $ui['TxtWifiState'].Text = '运行中'
    } else {
        $sync.WifiRunning = $false
        $ui['BtnWifiToggle'].Content = '启动守护'
        $ui['TxtWifiState'].Text = '已停止'
    }
})

$ui['BtnClearLog'].Add_Click({
    try { $sync.ClashLog.Clear() } catch { }
    try { $sync.WifiLog.Clear() } catch { }
    $ui['TxtLog'].Text = ''
    $script:logShown = 0
})

# ---- 界面刷新 -------------------------------------------------------------
$script:logShown = 0
$script:lastRound = -1

# Windows 字体渲染不了国旗 emoji（会变成 TW / SG 两个字母），显示时去掉代理对
function Get-DisplayName {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name -replace '[\uD800-\uDBFF][\uDC00-\uDFFF]', '').Trim()
}

function Update-Nodes {
    $pnl = $ui['PnlNodes']
    $pnl.Children.Clear()

    $nodes = $sync.Nodes
    if (-not $nodes -or $nodes.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '等待首次检测...'
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#4E5867')
        $tb.FontSize = 12
        $tb.Margin = '2,6,0,0'
        [void]$pnl.Children.Add($tb)
        return
    }

    foreach ($n in $nodes) {
        $d = $null
        if ($sync.NodeDelays -and $sync.NodeDelays.Contains($n)) { $d = $sync.NodeDelays[$n] }

        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = '0,2,0,2'
        $row.LastChildFill = $true

        $tag = New-Object System.Windows.Controls.TextBlock
        $tag.FontSize = 11
        $tag.Width = 74
        $tag.TextAlignment = 'Right'
        $tag.VerticalAlignment = 'Center'
        if ($sync.CurrentNode -eq $n) {
            $tag.Text = '当前出口'
            $tag.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#2ED3C6')
        } elseif ($sync.PendingNode -and $sync.PendingNode -eq $n) {
            $tag.Text = "待确认 $($sync.PendingCount)"
            $tag.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FBBF24')
        } elseif ($sync.BestNode -eq $n) {
            $tag.Text = '最快'
            $tag.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#5B9DF9')
        } else {
            $tag.Text = ''
        }
        [System.Windows.Controls.DockPanel]::SetDock($tag, 'Right')
        [void]$row.Children.Add($tag)

        $delay = New-Object System.Windows.Controls.TextBlock
        $delay.FontSize = 12.5
        $delay.Width = 84
        $delay.TextAlignment = 'Right'
        $delay.VerticalAlignment = 'Center'
        $delay.Margin = '0,0,10,0'
        if ($null -eq $d) {
            $delay.Text = '失败'
            $delay.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F87171')
        } else {
            $delay.Text = "$d ms"
            if ($d -le 350) { $delay.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#34D399') }
            elseif ($d -le 600) { $delay.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FBBF24') }
            else { $delay.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F87171') }
        }
        [System.Windows.Controls.DockPanel]::SetDock($delay, 'Right')
        [void]$row.Children.Add($delay)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = Get-DisplayName $n
        $name.FontSize = 12.5
        $name.TextTrimming = 'CharacterEllipsis'
        $name.VerticalAlignment = 'Center'
        $name.Margin = '2,0,8,0'
        $name.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#C3CCDA')
        if ($sync.CurrentNode -eq $n) { $name.FontWeight = 'SemiBold' }
        [void]$row.Children.Add($name)

        [void]$pnl.Children.Add($row)
    }
}

function Update-Status {
    if ($sync.CurrentNode) {
        $ui['TxtNode'].Text = Get-DisplayName $sync.CurrentNode
        if ($null -ne $sync.CurrentDelay) {
            $ui['TxtNodeDelay'].Text = "$($sync.CurrentDelay) ms"
        } else {
            $ui['TxtNodeDelay'].Text = '延迟未知'
        }
    }

    if ($sync.LastError) {
        $ui['TxtNodeSub'].Text = "上次异常: $($sync.LastError)"
    } elseif ($sync.PendingNode) {
        $ui['TxtNodeSub'].Text = "候选 $(Get-DisplayName $sync.PendingNode) 已确认 $($sync.PendingCount)/$($sync.Config.ConfirmRounds) 轮，继续观察"
    } elseif ($sync.Round -gt 0) {
        $ui['TxtNodeSub'].Text = "已完成 $($sync.Round) 轮检测"
    }

    if ($sync.WifiRunning) {
        $ui['TxtWifiSsid'].Text = $sync.WifiSsid
        if ($sync.WifiConnected) {
            $ui['DotWifi'].Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#34D399')
            $ui['TxtWifiSub'].Text = "已连接 · 上次检测 $($sync.WifiLastCheck)"
        } else {
            $ui['DotWifi'].Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F87171')
            $ui['TxtWifiSub'].Text = "未连接 · 已尝试重连 $($sync.WifiReconnects) 次"
        }
    } elseif (-not $sync.WifiSsid) {
        $ui['TxtWifiSsid'].Text = '未启用'
    }

    if ($sync.Round -ne $script:lastRound) {
        $script:lastRound = $sync.Round
        Update-Nodes
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
  try {
    Update-Status

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($it in $sync.ClashLog) {
        $colorTag = switch ($it.Level) {
            'err'  { '× ' }
            'warn' { '! ' }
            'ok'   { '✓ ' }
            default { '' }
        }
        $lines.Add("[$($it.Time)] $colorTag$($it.Msg)")
    }
    foreach ($it in $sync.WifiLog) {
        $colorTag = switch ($it.Level) {
            'err'  { '× ' }
            'warn' { '! ' }
            'ok'   { '✓ ' }
            default { '' }
        }
        $lines.Add("[$($it.Time)] [WiFi] $colorTag$($it.Msg)")
    }

    if ($lines.Count -ne $script:logShown) {
        $text = $lines -join "`r`n"
        if ($text -ne $ui['TxtLog'].Text) {
            $ui['TxtLog'].Text = $text
            $ui['TxtLog'].ScrollToEnd()
        }
        $script:logShown = $lines.Count
    }
  } catch {
    try { $ui['TxtNodeSub'].Text = "界面刷新异常: $($_.Exception.Message)" } catch { }
  }
})
$timer.Start()

# 启动时按配置自动开启
if ($AutoProbe) {
    $sync.DryRun = $true
    $sync.OneShot = $true
    $ui['TxtClashState'].Text = '单次检测中...'
    Start-ClashEngine
}
if ($script:Cfg.ClashAutoStart) {
    $sync.Running = $true
    $ui['BtnClashToggle'].Content = '停止监控'
    $ui['TxtClashState'].Text = '运行中'
    Start-ClashEngine
}
if ($script:Cfg.WifiAutoStart) {
    $sync.WifiRunning = $true
    $sync.WifiReconnects = 0
    $sync.WifiFirstCheck = $false
    $ui['BtnWifiToggle'].Content = '停止守护'
    $ui['TxtWifiState'].Text = '运行中'
    Start-WifiEngine
}

[void]$window.ShowDialog()

# 收尾
$sync.Shutdown = $true
Start-Sleep -Milliseconds 300
try { if ($script:ClashPS) { $script:ClashPS.Stop() } } catch { }
try { if ($script:WifiPS) { $script:WifiPS.Stop() } } catch { }
