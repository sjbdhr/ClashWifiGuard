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
    [switch]$AutoProbe,
    [switch]$ToastTest
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
    // 这里刻意不再用 IsWindowVisible 过滤：关窗只是隐藏到托盘，窗口隐藏后
    // 仍必须能被再次双击启动找到，否则用户会以为程序启动不起来。
    public static IntPtr FindByTitle(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
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
        # 两个探测目标：codex 实际走的 API 端点 + 网页端点。
        # 只测网页会选出「网页快但 API 慢」的节点，而 codex 用的是 API。
        TestUrls      = @('https://api.openai.com/v1/models', 'https://chatgpt.com/')
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
        # 旧版配置只存了单个 TestUrl。等于旧默认值说明用户没改过，直接采用新的多目标默认；
        # 改过则迁移成单元素数组，不静默丢掉他的选择。
        if (($obj.PSObject.Properties.Name -contains 'TestUrl') -and
            -not ($obj.PSObject.Properties.Name -contains 'TestUrls')) {
            $legacy = [string]$obj.TestUrl
            if ($legacy -and $legacy -ne 'https://chatgpt.com/') { $def['TestUrls'] = @($legacy) }
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

# 从 URL 取一个短标签用于日志，例如 api.openai.com -> api.openai
function Get-UrlTag {
    param([string]$Url)
    try {
        $h = ([uri]$Url).Host
        if ($h) { return ($h -replace '\.(com|ai|net|org)$', '') }
    } catch { }
    return $Url
}

# 把单个节点的各目标明细格式化成一段，例如 [api.openai=342 chatgpt=285]
function Format-Parts {
    param($Parts)
    $segs = @()
    foreach ($k in $Parts.Keys) {
        $tag = Get-UrlTag -Url $k
        $v = if ($null -eq $Parts[$k]) { 'X' } else { "$($Parts[$k])" }
        $segs += "$tag=$v"
    }
    return '[' + ($segs -join ' ') + ']'
}

# 一个节点在多个探测目标下的综合延迟。
# 每个目标各自取最好样本，再把所有目标里的最大值作为该节点延迟 ——
# 用最慢的目标代表真实体验，避免选出「网页快但 API 慢」的节点。
# 某目标整体失败时按目标数各加 2000ms 惩罚；全部目标都失败才算不可达。
function Get-NodeScore {
    param([string]$Node, [string[]]$TestUrls, [int]$Timeout, [int]$Count)
    $parts = [ordered]@{}
    $vals = @()
    $failed = 0
    foreach ($u in $TestUrls) {
        $d = Get-DelayBest -Node $Node -TestUrl $u -Timeout $Timeout -Count $Count
        $parts[$u] = $d
        if ($null -eq $d) { $failed++ } else { $vals += $d }
        Start-Sleep -Milliseconds 50
    }
    if ($vals.Count -eq 0) { return @{ Score = $null; Parts = $parts } }
    $worst = ($vals | Measure-Object -Maximum).Maximum
    return @{ Score = [int]($worst + 2000 * $failed); Parts = $parts }
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

    # 探测目标：优先多目标；兼容只存了单个 TestUrl 的旧配置
    $targets = @()
    if ($Cfg.TestUrls) { $targets = @($Cfg.TestUrls | Where-Object { $_ }) }
    elseif ($Cfg.TestUrl) { $targets = @([string]$Cfg.TestUrl) }
    if ($targets.Count -eq 0) { $targets = @('https://chatgpt.com/') }

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

    # 逐节点测速：每个节点在所有探测目标上各测一轮
    $table = @{}
    $partTable = @{}
    foreach ($node in $nodes) {
        $sc = Get-NodeScore -Node $node -TestUrls $targets -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples
        $table[$node] = $sc.Score
        $partTable[$node] = $sc.Parts
        Start-Sleep -Milliseconds 60
    }

    # 写入趋势缓冲并落盘。ConcurrentQueue 入队线程安全，界面侧只取快照
    $stamp = (Get-Date).ToString('s')
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($kv in $table.GetEnumerator()) {
        $rec = [pscustomobject]@{ Type = 'sample'; Time = $stamp; Node = $kv.Key; Delay = $kv.Value }
        $recs.Add($rec)
        $Sync.History.Enqueue($rec)
    }
    $overflow = $Sync.History.Count - 4200
    for ($i = 0; $i -lt $overflow; $i++) {
        $drop = $null
        [void]$Sync.History.TryDequeue([ref]$drop)
    }
    try {
        $json = ($recs | ForEach-Object { ($_ | ConvertTo-Json -Compress) }) -join "`r`n"
        [IO.File]::AppendAllText($Sync.HistoryPath, $json + "`r`n", [Text.Encoding]::UTF8)
    } catch { }

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
        "$($_.Key) $v $(Format-Parts $partTable[$_.Key])"
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
        $scNew = Get-NodeScore -Node $best -TestUrls $targets -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples
        $scOld = Get-NodeScore -Node $realCurrent -TestUrls $targets -Timeout $Cfg.TimeoutMs -Count $Cfg.Samples
        $dNew = $scNew.Score
        $dOld = $scOld.Score

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
        Log "复核: $best ${dNew}ms $(Format-Parts $scNew.Parts) vs $realCurrent ${dOld}ms $(Format-Parts $scOld.Parts) -> $reason"
    }

    if ($switch) {
        if ($Sync.DryRun) {
            Log "试运行: 本应切换 -> $best（$reason）" 'warn'
        } elseif (Set-Selection -TargetGroup $Cfg.Group -Node $best) {
            Log "已切换 $($Cfg.Group) : $realCurrent -> $best（$reason）" 'ok'
            $Sync.CurrentNode = $best
            $Sync.PendingNode = $null; $Sync.PendingCount = 0
            $ev = [pscustomobject]@{ Type = 'switch'; Time = (Get-Date).ToString('s'); Node = $best; Delay = $null; From = $realCurrent }
            $Sync.History.Enqueue($ev)
            try {
                [IO.File]::AppendAllText($Sync.HistoryPath, (($ev | ConvertTo-Json -Compress) + "`r`n"), [Text.Encoding]::UTF8)
            } catch { }
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
        $t0 = Get-Date
        try {
            Invoke-Round
            $Sync.LastError = ''
        } catch {
            $Sync.LastError = $_.Exception.Message
            Log "本轮异常: $($_.Exception.Message)" 'err'
            try { $Sync.PipeName = Get-PipeName } catch { }
        }
        # 多目标测速会把单轮时间拉长，打出耗时便于判断是否要调小采样次数
        $secs = [int]((Get-Date) - $t0).TotalSeconds
        Log "本轮耗时 ${secs} 秒"
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

    # 延迟趋势缓冲区。ConcurrentQueue 本身线程安全：引擎只入队，界面只取快照
    History        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    HistoryPath    = ''
})
foreach ($k in $script:Cfg.Keys) { $sync.Config[$k] = $script:Cfg[$k] }
$sync.HistoryPath = Join-Path $script:AppDir 'ClashWifiGuard.history.jsonl'

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

    <ScrollViewer x:Name="MainScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0">
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
              <TextBlock Text="测速目标" Style="{StaticResource Label}" Margin="0,0,8,0"/>
              <TextBox x:Name="TxtTestUrl" Style="{StaticResource Input}" Width="436" Text="https://api.openai.com/v1/models, https://chatgpt.com/"/>
              <TextBlock Text="排除关键词" Style="{StaticResource Label}" Margin="18,0,8,0"/>
              <TextBox x:Name="TxtExclude" Style="{StaticResource Input}" Width="196" Text="高倍,3x流量"/>
            </WrapPanel>
            <TextBlock Text="多个目标用英文逗号分隔。每个节点在每个目标上分别测速，取其中最慢的作为该节点延迟（避免选出网页快但 API 慢的节点）；某个目标整体失败按 +2000ms 计入，全部目标失败才算不可达。"
                       Foreground="#5A6577" FontSize="11.5" Margin="0,8,0,0" TextWrapping="Wrap"/>

            <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
              <Button x:Name="BtnClashToggle" Style="{StaticResource Primary}" Content="启动监控" Width="118"/>
              <Button x:Name="BtnProbe" Style="{StaticResource Ghost}" Content="立即检测一次" Margin="10,0,0,0"/>
              <CheckBox x:Name="ChkDryRun" Content="只测不切" Style="{StaticResource DarkCheck}" Margin="18,0,0,0" VerticalAlignment="Center"/>
              <Button x:Name="BtnSave" Style="{StaticResource Ghost}" Content="保存配置" Margin="18,0,0,0"/>
              <CheckBox x:Name="ChkClashAuto" Content="启动时自动监控" Style="{StaticResource DarkCheck}" Margin="18,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <TextBlock Text="节点延迟" Style="{StaticResource Label}" Margin="0,18,0,8"/>
            <Border Background="#101622" BorderBrush="#1E2739" BorderThickness="1" CornerRadius="9" Padding="10,8">
              <ScrollViewer x:Name="SvNodes" Height="122" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="PnlNodes"/>
              </ScrollViewer>
            </Border>
          </StackPanel>
        </Border>

        <!-- 延迟趋势 -->
        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="3" Height="16" CornerRadius="2" Background="#A78BFA" VerticalAlignment="Center"/>
              <TextBlock Text="延迟趋势" Foreground="#E9EDF5" FontSize="14.5" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtTrendInfo" Text="等待采样" Foreground="#66707F" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <WrapPanel x:Name="PnlLegend" Margin="0,10,0,0"/>

            <Border Background="#101622" BorderBrush="#1E2739" BorderThickness="1" CornerRadius="9" Padding="2" Margin="0,8,0,0">
              <Canvas x:Name="CvTrend" Height="164" Background="Transparent" ClipToBounds="True"/>
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
                   'TxtWifiState','TxtSsid','TxtWifiInterval','BtnWifiToggle','ChkWifiAuto','BtnClearLog','TxtLog',
                   'CvTrend','PnlLegend','TxtTrendInfo','MainScroll','SvNodes')) {
    $ui[$name] = $window.FindName($name)
}

# ---- 滚轮透传 ----------------------------------------------------------------
# 嵌套的 ScrollViewer / TextBox 即使内容不满也会把滚轮吃掉，鼠标停在「节点延迟」
# 或日志框上时整页就滚不动。内层滚不了（或已滚到边界）时改为驱动外层主容器。
function Register-WheelPassthrough {
    param($Inner)
    if (-not $Inner) { return }
    $Inner.Add_PreviewMouseWheel({
        param($s, $e)
        try {
            $ext = [double]$s.ExtentHeight
            $vp  = [double]$s.ViewportHeight
            $off = [double]$s.VerticalOffset
        } catch { return }

        $down = ($e.Delta -lt 0)
        $canScroll = ($ext - $vp) -gt 0.5
        $atBottom = (($off + $vp) -ge ($ext - 0.5))
        $atTop = ($off -le 0.5)

        if ((-not $canScroll) -or ($down -and $atBottom) -or ((-not $down) -and $atTop)) {
            $main = $ui['MainScroll']
            if ($main) {
                $target = $main.VerticalOffset - ([double]$e.Delta * 0.5)
                if ($target -lt 0) { $target = 0 }
                $main.ScrollToVerticalOffset($target)
                $e.Handled = $true
            }
        }
    })
}
Register-WheelPassthrough $ui['SvNodes']
Register-WheelPassthrough $ui['TxtLog']

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
$ui['TxtTestUrl'].Text      = (@($script:Cfg.TestUrls) -join ', ')
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

    $urls = @($ui['TxtTestUrl'].Text -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($urls.Count -eq 0) { $urls = @('https://chatgpt.com/') }

    $sync.Config['Regions']       = $regions
    $sync.Config['Tolerance']     = $tol
    $sync.Config['Interval']      = $itv
    $sync.Config['ConfirmRounds'] = $cfm
    $sync.Config['TestUrls']      = $urls
    $sync.Config['Exclude']       = $ui['TxtExclude'].Text.Trim()
    $sync.Config['Ssid']          = $ssid
    $sync.Config['WifiInterval']  = $wi

    $script:Cfg['Regions']       = $regions
    $script:Cfg['Tolerance']     = $tol
    $script:Cfg['Interval']      = $itv
    $script:Cfg['ConfirmRounds'] = $cfm
    $script:Cfg['TestUrls']     = $urls
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
    # 关窗只隐藏：引擎必须继续跑，真正退出走托盘右键菜单
    try {
        $window.Hide()
        if (-not $script:TrayHinted) {
            $script:TrayHinted = $true
            Show-GuardToast '已收起到托盘' '节点监控与 WiFi 重连仍在运行。右键托盘图标 → 退出（停止监控），才会真正关闭。'
        }
    } catch { }
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

# ---- 延迟趋势图 --------------------------------------------------------------
$script:trendPalette = @('#2ED3C6','#5B9DF9','#FBBF24','#A78BFA','#F87171','#34D399','#F472B6')
$script:trendNodeColor = @{}
$script:trendWindowMin = 180
$script:trendCount = -1
$script:trendW = -1.0

function Get-TrendColor {
    param([string]$Node)
    if ($script:trendNodeColor.ContainsKey($Node)) { return $script:trendNodeColor[$Node] }
    $c = $script:trendPalette[$script:trendNodeColor.Count % $script:trendPalette.Count]
    $script:trendNodeColor[$Node] = $c
    return $c
}

function Add-TrendLabel {
    param($Cv, [string]$Text, [double]$Left, [double]$Top, [string]$Color = '#5A6577', [double]$Size = 10)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
    [System.Windows.Controls.Canvas]::SetLeft($tb, $Left)
    [System.Windows.Controls.Canvas]::SetTop($tb, $Top)
    [void]$Cv.Children.Add($tb)
}

function Update-Trend {
    $cv = $ui['CvTrend']
    if (-not $cv) { return }
    $w = [double]$cv.ActualWidth
    $h = [double]$cv.ActualHeight
    if ($w -lt 120 -or $h -lt 70) { return }

    $now = Get-Date
    $from = $now.AddMinutes(-$script:trendWindowMin)

    # 取一份快照后立即释放，不持有队列引用
    $samples = @()
    $switchAt = @()
    foreach ($it in $sync.History.ToArray()) {
        $t = $null
        try { $t = [datetime]$it.Time } catch { continue }
        if ($t -lt $from) { continue }
        if ($it.Type -eq 'switch') { $switchAt += $t; continue }
        $samples += [pscustomobject]@{ T = $t; Node = [string]$it.Node; Delay = $it.Delay }
    }

    $cv.Children.Clear()
    $ui['PnlLegend'].Children.Clear()

    if ($samples.Count -eq 0) {
        $ui['TxtTrendInfo'].Text = '等待采样（每轮检测后更新）'
        Add-TrendLabel -Cv $cv -Text '暂无数据' -Left 14 -Top ($h / 2 - 8) -Color '#3E4759' -Size 12
        return
    }

    $padL = 42.0; $padR = 12.0; $padT = 14.0; $padB = 24.0
    $pw = $w - $padL - $padR
    $ph = $h - $padT - $padB
    if ($pw -lt 40 -or $ph -lt 24) { return }

    $maxD = 0.0
    foreach ($p in $samples) {
        if ($null -ne $p.Delay) { $v = [double]$p.Delay; if ($v -gt $maxD) { $maxD = $v } }
    }
    $axisMax = 400.0
    if ($maxD -gt 400) { $axisMax = [Math]::Ceiling($maxD / 100.0) * 100 }
    if ($axisMax -gt 4000) { $axisMax = 4000 }

    # 横向网格与 Y 轴刻度
    for ($i = 0; $i -le 4; $i++) {
        $y = $padT + $ph * ($i / 4.0)
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $padL; $ln.Y1 = $y; $ln.X2 = ($padL + $pw); $ln.Y2 = $y
        $ln.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1E2739')
        $ln.StrokeThickness = 1
        [void]$cv.Children.Add($ln)
        Add-TrendLabel -Cv $cv -Text ([string][int]($axisMax * (1 - $i / 4.0))) -Left 2 -Top ($y - 8)
    }

    # 切换事件竖线
    foreach ($t in $switchAt) {
        $x = $padL + ((($t - $from).TotalMinutes) / $script:trendWindowMin) * $pw
        if ($x -lt $padL -or $x -gt ($padL + $pw)) { continue }
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $x; $ln.Y1 = $padT; $ln.X2 = $x; $ln.Y2 = ($padT + $ph)
        $ln.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FBBF24')
        $ln.StrokeThickness = 1
        $ln.Opacity = 0.7
        $da = New-Object System.Windows.Media.DoubleCollection
        [void]$da.Add(3); [void]$da.Add(4)
        $ln.StrokeDashArray = $da
        [void]$cv.Children.Add($ln)
    }

    $nodeList = @()
    foreach ($p in $samples) { if ($nodeList -notcontains $p.Node) { $nodeList += $p.Node } }

    # 当前出口放到最后画，端点标记才不会被其他节点的点盖住
    $drawOrder = @()
    foreach ($n in $nodeList) { if ($n -ne $sync.CurrentNode) { $drawOrder += $n } }
    if ($nodeList -contains $sync.CurrentNode) { $drawOrder += $sync.CurrentNode }

    # 逐节点折线：失败点（Delay 为空）断开并把红点压在图底
    foreach ($node in $drawOrder) {
        $col = Get-TrendColor $node
        $brush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($col)
        $isCur = ($node -eq $sync.CurrentNode)
        $thick = if ($isCur) { 2.3 } else { 1.5 }
        $op = if ($isCur) { 1.0 } else { 0.7 }

        $seg = New-Object System.Windows.Media.PointCollection
        $lastPt = $null
        foreach ($p in $samples) {
            if ($p.Node -ne $node) { continue }
            if ($null -eq $p.Delay) {
                if ($seg.Count -ge 2) {
                    $pl = New-Object System.Windows.Shapes.Polyline
                    $pl.Points = $seg.Clone()
                    $pl.Stroke = $brush
                    $pl.StrokeThickness = $thick
                    $pl.Opacity = $op
                    $pl.StrokeLineJoin = 'Round'
                    [void]$cv.Children.Add($pl)
                }
                $seg = New-Object System.Windows.Media.PointCollection
                $lastPt = $null
                $x = $padL + ((($p.T - $from).TotalMinutes) / $script:trendWindowMin) * $pw
                if ($x -ge $padL -and $x -le ($padL + $pw)) {
                    $el = New-Object System.Windows.Shapes.Ellipse
                    $el.Width = 5; $el.Height = 5
                    $el.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#F87171')
                    [System.Windows.Controls.Canvas]::SetLeft($el, ($x - 2.5))
                    [System.Windows.Controls.Canvas]::SetTop($el, ($padT + $ph - 2.5))
                    [void]$cv.Children.Add($el)
                }
            } else {
                $x = $padL + ((($p.T - $from).TotalMinutes) / $script:trendWindowMin) * $pw
                $y = $padT + $ph - ([double]$p.Delay / $axisMax) * $ph
                $pt = New-Object System.Windows.Point($x, $y)
                [void]$seg.Add($pt)
                $lastPt = $pt
            }
        }
        if ($seg.Count -ge 2) {
            $pl = New-Object System.Windows.Shapes.Polyline
            $pl.Points = $seg.Clone()
            $pl.Stroke = $brush
            $pl.StrokeThickness = $thick
            $pl.Opacity = $op
            $pl.StrokeLineJoin = 'Round'
            [void]$cv.Children.Add($pl)
        }
        if ($null -ne $lastPt) {
            # 当前出口画实心点；其余画空心环，延迟相近时两个环叠着也分得出来
            if ($isCur) {
                $el = New-Object System.Windows.Shapes.Ellipse
                $el.Width = 7; $el.Height = 7
                $el.Fill = $brush
                [System.Windows.Controls.Canvas]::SetLeft($el, ($lastPt.X - 3.5))
                [System.Windows.Controls.Canvas]::SetTop($el, ($lastPt.Y - 3.5))
            } else {
                $el = New-Object System.Windows.Shapes.Ellipse
                $el.Width = 7; $el.Height = 7
                $el.Stroke = $brush
                $el.StrokeThickness = 1.6
                [System.Windows.Controls.Canvas]::SetLeft($el, ($lastPt.X - 3.5))
                [System.Windows.Controls.Canvas]::SetTop($el, ($lastPt.Y - 3.5))
            }
            [void]$cv.Children.Add($el)
        }
    }

    Add-TrendLabel -Cv $cv -Text $from.ToString('HH:mm') -Left $padL -Top ($padT + $ph + 6)
    Add-TrendLabel -Cv $cv -Text $now.ToString('HH:mm') -Left ($padL + $pw - 34) -Top ($padT + $ph + 6)
    Add-TrendLabel -Cv $cv -Text 'ms' -Left ($padL + $pw - 18) -Top 1 -Color '#465063'

    $lg = $ui['PnlLegend']
    foreach ($node in $nodeList) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = '0,0,16,4'
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8
        $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom((Get-TrendColor $node))
        $dot.VerticalAlignment = 'Center'
        $dot.Margin = '0,0,5,0'
        [void]$sp.Children.Add($dot)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = (Get-DisplayName $node)
        $tb.FontSize = 11
        $tb.VerticalAlignment = 'Center'
        if ($node -eq $sync.CurrentNode) {
            $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#E9EDF5')
        } else {
            $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#8A94A6')
        }
        [void]$sp.Children.Add($tb)
        [void]$lg.Children.Add($sp)
    }

    $ui['TxtTrendInfo'].Text = "最近 $($script:trendWindowMin) 分钟 · $($nodeList.Count) 个节点 · 峰值 $([int]$maxD) ms"
}

# 启动时载入历史尾部，让曲线跨重启延续
if (Test-Path -LiteralPath $sync.HistoryPath) {
    try {
        $tail = Get-Content -LiteralPath $sync.HistoryPath -Tail 1200 -Encoding utf8
        foreach ($ln in $tail) {
            if (-not $ln.Trim()) { continue }
            try {
                $o = $ln | ConvertFrom-Json
                if ($o.Type -and $o.Time) { $sync.History.Enqueue($o) }
            } catch { }
        }
    } catch { }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
  try {
    Update-Status

    # 数据量或画布宽度变化时才重绘趋势图
    $cw = [double]$ui['CvTrend'].ActualWidth
    if ($sync.History.Count -ne $script:trendCount -or $cw -ne $script:trendW) {
        $script:trendCount = $sync.History.Count
        $script:trendW = $cw
        Update-Trend
    }

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

# ---- 系统托盘 ----------------------------------------------------------------
# 关窗只隐藏、进程继续跑，所以必须有托盘图标作为唯一的"重新打开"入口：
# 双击图标 = 呼出窗口；右键 = 打开主界面 / 立即检测 / 退出。
Add-Type -AssemblyName System.Windows.Forms

# ---- 运行日志 ----------------------------------------------------------------
# 这个程序是"窗口一关就藏起来"的常驻进程，一旦静默消失，用户只会发现"它自己退了"，
# 却拿不到任何线索。所以启动、心跳、异常、退出都落一行到文件，
# 下次再出现同样的消失，能直接区分是崩溃、被系统结束、还是正常退出。
$script:GuardLogPath = Join-Path $PSScriptRoot 'ClashWifiGuard.log'

function Write-GuardLog {
    param([string]$Text)
    try {
        [IO.File]::AppendAllText(
            $script:GuardLogPath,
            '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Text + "`r`n",
            (New-Object Text.UTF8Encoding $false))
    } catch { }
}

# 日志超过 512KB 就滚一份，常驻进程不能把日志撑成几十兆
try {
    if (Test-Path -LiteralPath $script:GuardLogPath) {
        if ((Get-Item -LiteralPath $script:GuardLogPath).Length -gt 524288) {
            Move-Item -LiteralPath $script:GuardLogPath -Destination ($script:GuardLogPath + '.1') -Force
        }
    }
} catch { }

Write-GuardLog "启动 PID=$PID 参数=[$(($PSBoundParameters.Keys) -join ',')]"

$script:TrayHinted = $false
$script:ReallyExit = $false

function Show-GuardWindow {
    try {
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
        }
        # 对 ShowDialog 打开的窗口调 Show() 会抛异常，改设 Visibility 更稳
        $window.Visibility = [System.Windows.Visibility]::Visible
        $window.Activate()
        [void]$window.Focus()
    } catch { }
}

$script:TrayMenuWin = $null

# 托盘右键菜单用 WPF 自绘：WinForms 的 ContextMenuStrip 做不出大圆角和柔和
# 投影，只能是方形卡片 + 系统阴影。这里起一个无边框透明窗口充当菜单，
# 样式对齐系统流行的浅色极简菜单（近白底、大圆角、大字距、细分割线）。
function Add-TrayMenuItem {
    param($Parent, [string]$Text, [scriptblock]$Action)

    $item = New-Object System.Windows.Controls.Border
    $item.Background = [System.Windows.Media.Brushes]::Transparent
    $item.CornerRadius = New-Object System.Windows.CornerRadius 8
    $item.Padding = New-Object System.Windows.Thickness 18, 10, 18, 10
    $item.Cursor = [System.Windows.Input.Cursors]::Hand
    $item.Tag = $Action

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI'
    $t.FontSize = 13
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1F2329'))
    $item.Child = $t

    $item.Add_MouseEnter({
        param($s, $e)
        $s.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#EFF2F6'))
    })
    $item.Add_MouseLeave({
        param($s, $e)
        $s.Background = [System.Windows.Media.Brushes]::Transparent
    })
    $item.Add_MouseLeftButtonUp({
        param($s, $e)
        try { if ($script:TrayMenuWin) { $script:TrayMenuWin.Close(); $script:TrayMenuWin = $null } } catch { }
        try { $act = $s.Tag; if ($act) { & $act } } catch { }
    })
    [void]$Parent.Children.Add($item)
}

function Show-GuardTrayMenu {
    try {
        if ($script:TrayMenuWin) { try { $script:TrayMenuWin.Close() } catch { }; $script:TrayMenuWin = $null }

        $w = New-Object System.Windows.Window
        $w.WindowStyle = [System.Windows.WindowStyle]::None
        $w.AllowsTransparency = $true
        $w.Background = [System.Windows.Media.Brushes]::Transparent
        $w.ShowInTaskbar = $false
        $w.Topmost = $true
        $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $w.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
        $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $w.Opacity = 0

        $card = New-Object System.Windows.Controls.Border
        $card.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FBFCFD'))
        $card.CornerRadius = New-Object System.Windows.CornerRadius 14
        $card.Padding = New-Object System.Windows.Thickness 7
        $card.MinWidth = 198

        $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $shadow.BlurRadius = 26
        $shadow.Opacity = 0.34
        $shadow.ShadowDepth = 5
        $shadow.Color = [System.Windows.Media.Colors]::Black
        $card.Effect = $shadow

        $sp = New-Object System.Windows.Controls.StackPanel
        Add-TrayMenuItem $sp '打开主界面' { Show-GuardWindow }
        Add-TrayMenuItem $sp '立即检测一次' {
            Show-GuardWindow
            try {
                $arg = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
                $ui['BtnProbe'].RaiseEvent($arg)
            } catch { }
        }

        $line = New-Object System.Windows.Controls.Border
        $line.Height = 1
        $line.Margin = New-Object System.Windows.Thickness 16, 7, 16, 7
        $line.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E9ECF1'))
        [void]$sp.Children.Add($line)

        Add-TrayMenuItem $sp '退出（停止监控）' { Exit-Guard }

        $card.Child = $sp
        $w.Content = $card
        $w.Show()
        $w.UpdateLayout()

        # 贴光标左上方展开，再夹进所在屏幕的工作区，避免压到任务栏或跑出屏幕
        $scale = 1.0
        try {
            $psrc = [System.Windows.PresentationSource]::FromVisual($window)
            $scale = $psrc.CompositionTarget.TransformToDevice.M11
        } catch { }

        $mp = [System.Windows.Forms.Cursor]::Position
        $wa = [System.Windows.Forms.Screen]::FromPoint($mp).WorkingArea
        $cx = $mp.X / $scale
        $cy = $mp.Y / $scale
        $mw = $w.ActualWidth
        $mh = $w.ActualHeight
        $wl = $wa.Left / $scale
        $wt = $wa.Top / $scale
        $ww = $wa.Width / $scale
        $wh = $wa.Height / $scale
        $left = [Math]::Min([Math]::Max($cx - $mw + 18, $wl + 6), $wl + $ww - $mw - 6)
        $top = [Math]::Min([Math]::Max($cy - $mh - 12, $wt + 6), $wt + $wh - $mh - 6)

        $w.Left = $left
        $w.Top = $top
        $w.Opacity = 1
        $w.Activate()

        $script:TrayMenuWin = $w
        $w.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                try { if ($script:TrayMenuWin) { $script:TrayMenuWin.Close(); $script:TrayMenuWin = $null } } catch { }
            }
        })
        # 点到菜单外面就收起，行为对齐系统菜单
        $w.Add_Deactivated({
            try {
                if ($script:TrayMenuWin) { $script:TrayMenuWin.Close(); $script:TrayMenuWin = $null }
            } catch { }
        })
    } catch { }
}

# 右下角提示改用自绘浮层：系统气泡在 Win11 会走通知中心，标题取的是进程身份
# 而不是这里传的字符串，中英混排时标题栏会出现乱码方块。自己画一个可控。
function Show-GuardToast {
    param([string]$Title, [string]$Message, [int]$Ms = 2800)
    try {
        if ($script:ToastWin) { try { $script:ToastWin.Close() } catch { } }

        $toast = New-Object System.Windows.Window
        $toast.WindowStyle = [System.Windows.WindowStyle]::None
        $toast.AllowsTransparency = $true
        $toast.Background = [System.Windows.Media.Brushes]::Transparent
        $toast.ShowInTaskbar = $false
        $toast.ShowActivated = $false
        $toast.Topmost = $true
        $toast.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $toast.Width = 340
        $toast.SizeToContent = [System.Windows.SizeToContent]::Height

        $border = New-Object System.Windows.Controls.Border
        $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#161C2A'))
        $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#2ED3C6'))
        $border.BorderThickness = New-Object System.Windows.Thickness 3, 0, 0, 0
        $border.CornerRadius = New-Object System.Windows.CornerRadius 10
        $border.Padding = New-Object System.Windows.Thickness 16, 12, 16, 13

        $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $shadow.BlurRadius = 22
        $shadow.Opacity = 0.55
        $shadow.ShadowDepth = 3
        $shadow.Color = [System.Windows.Media.Colors]::Black
        $border.Effect = $shadow

        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = $Title
        $t1.FontSize = 14
        $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
        $t1.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E4E8F0'))
        [void]$sp.Children.Add($t1)

        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = $Message
        $t2.FontSize = [double]11.5
        $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t2.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#8B96A8'))
        $t2.Margin = New-Object System.Windows.Thickness 0, 5, 0, 0
        [void]$sp.Children.Add($t2)

        $border.Child = $sp
        $toast.Content = $border
        $toast.Show()

        # 定位到所在屏幕的工作区右下角（任务栏之上），不能拿主窗口当基准：
        # 窗口一旦被拖动或缩小，按窗口右下角算出来的位置就跑到屏幕中间去了。
        $scale = 1.0
        try {
            $psrc = [System.Windows.PresentationSource]::FromVisual($window)
            $scale = $psrc.CompositionTarget.TransformToDevice.M11
        } catch { }

        $tw = $toast.ActualWidth
        $th = $toast.ActualHeight
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        # 注意 Screen.WorkingArea 在这个进程里已被 DPI 虚拟化放大过一遍：
        # 实测返回 3840×2088，而物理只有 2560×1392（150% 缩放），
        # 所以要折回 DIP 得除以 scale 两次，只除一次会算到屏幕右边界之外。
        $k = $scale * $scale
        $sl = $wa.Left / $k
        $st = $wa.Top / $k
        $sw = $wa.Width / $k
        $sh = $wa.Height / $k

        if ($sw -gt ($tw + 40) -and $sh -gt ($th + 40)) {
            $toast.Left = $sl + $sw - $tw - 26
            $toast.Top = $st + $sh - $th - 18
        } else {
            # 折算异常时退而求其次，贴主窗口右下
            $aw = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
            $ah = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { $window.Height }
            $toast.Left = $window.Left + $aw - $tw - 24
            $toast.Top = $window.Top + $ah - $th - 30
        }

        # 淡入 180ms，整块深色突然弹出会有点生硬
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = 0.0
        $fade.To = 1.0
        $fade.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(180))
        $toast.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)

        $script:ToastWin = $toast
        if ($ToastTest) {
            try {
                $pt = $toast.PointToScreen([System.Windows.Point]::new(0, 0))
                [IO.File]::AppendAllText("$env:TEMP\guard-ui-err.log", "[$(Get-Date -Format HH:mm:ss.fff)] scale=$scale wa=$($wa.Width)x$($wa.Height) size=$([int]$tw)x$([int]$th) left=$([int]$toast.Left) top=$([int]$toast.Top) screen=$([int]$pt.X),$([int]$pt.Y) visible=$($toast.IsVisible)`r`n")
            } catch {
                [IO.File]::AppendAllText("$env:TEMP\guard-ui-err.log", "定位日志失败: $($_.Exception.Message)`r`n")
            }
        }
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
        $timer.Add_Tick({
            param($s, $e)
            try { $s.Stop() } catch { }
            try {
                if ($script:ToastWin) { $script:ToastWin.Close(); $script:ToastWin = $null }
            } catch { }
        })
        $timer.Start()
        $script:ToastTimer = $timer
    } catch {
        # 以前这里是空 catch，出问题完全静默；改成落盘，异常能查到
        try {
            $d = "Toast 失败: $($_.Exception.Message)"
            try {
                $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                $d = "$d | wa=$($wa2.X),$($wa2.Y),$($wa2.Width),$($wa2.Height)"
            } catch { }
            [IO.File]::AppendAllText("$env:TEMP\guard-ui-err.log", $d + "`r`n")
        } catch { }
    }
}

function Exit-Guard {
    Write-GuardLog "用户从托盘选择退出，开始停止引擎"
    $script:ReallyExit = $true
    try { $sync.Shutdown = $true; $sync.Running = $false; $sync.WifiRunning = $false } catch { }
    try {
        if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }
    } catch { }
    Start-Sleep -Milliseconds 350
    try { if ($script:ClashPS) { $script:ClashPS.Stop() } } catch { }
    try { if ($script:WifiPS) { $script:WifiPS.Stop() } } catch { }
    try {
        if ($script:App) { $script:App.Shutdown() } else { $window.Close() }
    } catch { try { $window.Close() } catch { } }
}

if (-not $SelfTest) {
    try {
        $icoFile = Join-Path $PSScriptRoot 'app.ico'
        $trayIcon = if (Test-Path -LiteralPath $icoFile) {
            New-Object System.Drawing.Icon -ArgumentList $icoFile
        } else {
            [System.Drawing.SystemIcons]::Application
        }

        $script:Tray = New-Object System.Windows.Forms.NotifyIcon
        $script:Tray.Icon = $trayIcon
        $script:Tray.Text = '网络守护台 · 节点优选 + WiFi 重连'
        $script:Tray.Visible = $true

        # 右键菜单由 Show-GuardTrayMenu 自绘，不再给 NotifyIcon 挂 ContextMenuStrip
        $script:Tray.Add_MouseDoubleClick({ Show-GuardWindow })
        $script:Tray.Add_MouseUp({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-GuardTrayMenu }
        })

        # Alt+F4 / 任务管理器之外的一切关闭途径都要被拦下，否则引擎会被连带停掉
        $window.Add_Closing({
            param($s, $e)
            if (-not $script:ReallyExit) {
                $e.Cancel = $true
                # 在 Closing 处理里直接 Hide 会被框架重新显示回来，推到事件结束之后再做
                [void]$window.Dispatcher.BeginInvoke(
                    [System.Action]{ $window.Hide() },
                    [System.Windows.Threading.DispatcherPriority]::Background)
            }
        })

        # 真退出时收掉托盘，避免右下角留一个点不动的幽灵图标
        $window.Add_Closed({
            try {
                if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }
            } catch { }
        })
    } catch {
        try { $ui['TxtLog'].AppendText("[托盘] 初始化失败: $($_.Exception.Message)`r`n") } catch { }
    }
}

# 关窗只隐藏、进程必须继续跑，所以不能用 ShowDialog：它的模态循环在窗口 Hide()
# 之后会返回，脚本跑到末尾进程就没了 —— 表现像"最小化到托盘"，实际是退出。
# 改用 Application.Run + OnExplicitShutdown，只有托盘里的「退出」才会真正结束。
try {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

    # UI 线程兜底：异常记下来并继续跑，不让它把常驻进程悄悄带走
    $script:App.Add_DispatcherUnhandledException({
        param($s, $e)
        try {
            Write-GuardLog "UI 线程异常: $($e.Exception.Message) @ $($e.Exception.StackTrace)"
            $e.Handled = $true
        } catch { }
    })

    # 每 60 秒一行心跳，能看出进程在哪一刻停止呼吸、停之前内存多大
    $hb = New-Object System.Windows.Threading.DispatcherTimer
    $hb.Interval = [TimeSpan]::FromSeconds(60)
    $hb.Add_Tick({
        try {
            $mem = [math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64) / 1MB, 1)
            $hcount = 0
            try { $hcount = $sync.History.Count } catch { }
            $cs = if ($sync.Running) { 'on' } else { 'off' }
            $ws = if ($sync.WifiRunning) { 'on' } else { 'off' }
            $wv = if ($window.WindowState -eq [System.Windows.WindowState]::Minimized -or -not $window.IsVisible) { 'hidden' } else { 'shown' }
            Write-GuardLog "心跳 内存=${mem}MB 采样=${hcount}条 Clash=$cs WiFi=$ws 窗口=$wv"
        } catch { }
    })
    $hb.Start()

    # -ToastTest：启动后自动弹一次提示（停留久一点），用来核对右下角定位是否准确
    if ($ToastTest) {
        [void]$window.Dispatcher.BeginInvoke(
            [System.Action]{ Show-GuardToast '已收起到托盘' '节点监控与 WiFi 重连仍在运行。右键托盘图标 → 退出（停止监控），才会真正关闭。' 9000 },
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    }

    [void]$script:App.Run($window)
} catch {
    # Application 起不来的极端情况退回模态窗口，至少程序还能用
    try { $ui['TxtLog'].AppendText("[启动] Application.Run 失败，回退模态窗口: $($_.Exception.Message)`r`n") } catch { }
    try { [void]$window.ShowDialog() } catch { }
}

# 收尾
Write-GuardLog "窗口已关闭，进入收尾流程"
$sync.Shutdown = $true
Start-Sleep -Milliseconds 300
try { if ($script:ClashPS) { $script:ClashPS.Stop() } } catch { }
try { if ($script:WifiPS) { $script:WifiPS.Stop() } } catch { }
Write-GuardLog "进程正常退出"
