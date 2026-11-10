# ClashWifiGuard · 网络守护台

一个 Windows 深色桌面小工具，把两件原本需要两个窗口处理的事并进同一个界面：

1. **Clash AI 节点优选** —— 定时测速，按「延迟 + 连通性」在台湾 / 美国 / 新加坡的单倍节点之间自动切换，带防抖，不会来回乱跳。
2. **WiFi 掉线自动重连** —— 发现目标 SSID 掉线就自动执行 `netsh wlan connect` 重连。

零依赖：Windows 自带 PowerShell 5.1 + WPF，不需要 Python、不需要 .NET SDK、不需要安装任何东西。

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| PowerShell | **Windows PowerShell 5.1**（系统自带，不要用 PowerShell 7 运行） |
| 代理 | Clash Party 或其他 mihomo 内核，**必须正在运行** |
| 网络 | 目标 WiFi 在本机已连接过一次（配置文件已保存） |

## 快速开始

1. 把本仓库的文件放到任意一个目录（**不要只拷 .ps1**，图标和配置需要与它同级）
2. 把 `ClashWifiGuard.config.example.json` 复制一份改名为 `ClashWifiGuard.config.json`，把 `Ssid` 改成本机的 WiFi 名称
3. 双击 `启动网络守护台.vbs`
4. 窗口出现后两个引擎自动开始运行，日志里会看到 `Clash 引擎就绪` / `WiFi 引擎就绪`

## 文件说明

| 文件 | 作用 | 必需 |
|---|---|---|
| `ClashWifiGuard.ps1` | 主程序（界面 + 两个后台引擎） | 是 |
| `启动网络守护台.vbs` | 推荐启动入口，零控制台窗口 | 是 |
| `启动网络守护台.bat` | 兼容入口，内部转调 vbs | 否 |
| `app.ico` | 窗口 / 任务栏图标 | 是 |
| `app-icon-mark.png` | 标题栏左侧 logo | 是 |
| `app-icon.png` | 图标母版，仅备查 | 否 |
| `ClashWifiGuard.config.example.json` | 配置模板 | 是 |
| `ClashWifiGuard.config.json` | 实际配置，首次保存时生成（已 gitignore） | 否 |
| `取消开机自启.bat` | 移除开机自启项 | 否 |

## 配置字段

| 字段 | 默认 | 含义 |
|---|---|---|
| `Regions` | 台湾 / 美国 / 新加坡 | 参与测速的候选地区 |
| `Tolerance` | 120 | 不切换阈值（ms）：候选必须比当前快超过这个数才切 |
| `Interval` | 90 | 轮询间隔（秒） |
| `ConfirmRounds` | 2 | 连续几轮复核通过才真正切换 |
| `Group` | AI | 要调整的 Clash 策略组名 |
| `TestUrl` | https://chatgpt.com/ | 测速用的 URL |
| `Exclude` | 高倍,3x流量 | 排除关键词，逗号分隔 |
| `Samples` / `TimeoutMs` | 2 / 3000 | 单节点采样次数 / 单次超时 |
| `Ssid` | YOUR_SSID | 要守护的 WiFi 名称 |
| `WifiInterval` | 3 | WiFi 检测间隔（秒） |
| `ClashAutoStart` / `WifiAutoStart` | true | 启动时是否自动开启对应引擎（界面有同名勾选） |

## 换机器要改什么

1. **目标 SSID**：界面里改成新机器的 WiFi 名称，点「保存配置」
2. **候选地区**：按新订阅里实际有的节点勾选
3. **节点命名**：脚本靠名字里的 token 识别地区 —— `台湾/台灣/TW`、`美国/美國/US`、`新加坡/SG`；名字含 `高倍` 或 `3x流量` 的默认排除（3 倍扣量）
4. 其余不用动：mihomo 的控制管道名每次启动自动发现，不写死

## 开机自启

在启动文件夹（`shell:startup`）放一个脚本即可：

```vbs
WScript.Sleep 30000
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""<本仓库路径>\ClashWifiGuard.ps1""", 0, False
```

延迟 30 秒是为了等 Clash Party 先起来，否则第一轮探测连不上控制管道。

## 实现要点

- **两个引擎各跑一个 runspace**，主线程只画界面，探测卡住时 UI 不假死
- **单实例锁**：`Local\ClashWifiGuard.SingleInstance`，重复启动会把已有窗口提到前台而不是再开一个进程
- **AppUserModelID**：`ClashWifiGuard.Desktop`，否则任务栏会沿用 powershell.exe 的分组和图标
- **mihomo 走命名管道**：`external-controller` 为空时只能读 `\\.\pipe\` 找 `MihomoParty` + `mihomo-user-Console`，管道名末段随 PID 变化，一律动态发现
- **chunked 响应必须字节层面解包**：按字符下标切 body 会因为中文节点名的字节数与字符数不等而错位
- **防抖**：候选要比当前快超过 `Tolerance` 毫秒、且连续 `ConfirmRounds` 轮复核都通过才切；当前节点不可达时立即切

## 开发期自检

```
powershell -NoProfile -ExecutionPolicy Bypass -File ClashWifiGuard.ps1 -SelfTest
```

只解析界面不弹窗，输出 `SelfTest OK: XAML 解析成功，控件全部就位` 表示文件完整可运行。另有 `-AutoProbe`：启动即做一次只测不切的探测。

## 已知限制

- 仅支持 Windows（依赖 WPF 与 `netsh wlan`）
- 只对**已经在用的那个** Clash 策略组生效，不修改订阅本身的配置，因此不会被订阅更新覆盖
- 需要 mihomo 暴露命名管道控制口；纯 TCP 模式（`external-controller` 有值）未实测

## License

MIT
