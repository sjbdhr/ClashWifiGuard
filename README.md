# ClashWifiGuard · 网络守护台

一个 Windows 小工具：

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
5. 点标题栏的 ✕ 只是收起窗口，程序留在托盘里继续工作；要彻底关闭请右键托盘图标选「退出」

> Windows 11 默认把新出现的托盘图标收进 `^` 溢出区。想让它常驻右下角：设置 → 个性化 → 任务栏 → 「其他系统托盘图标」，把「网络守护台」打开。

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
| `ClashWifiGuard.history.jsonl` | 延迟趋势采样，每轮追加一行（已 gitignore） | 否 |
| `取消开机自启.bat` | 移除开机自启项 | 否 |
| `注册本机任务.bat` | 一键注册计划任务 + 开机自启（换机器/换目录后必跑） | 否 |
| `Register-Tasks.ps1` | 上面那个 bat 实际执行的注册脚本 | 否 |
| `看护进程.vbs` | 计划任务用的自愈检查：进程不在就跑起来 | 否 |
| `ClashWifiGuard.stop` | 用户点了「退出」后留下的停机标记，看门狗看到就放手（已 gitignore） | 否 |
| `ClashWifiGuard.log` | 运行日志：启动、心跳、异常、退出（已 gitignore） | 否 |

## 配置字段

| 字段 | 默认 | 含义 |
|---|---|---|
| `Regions` | 台湾 / 美国 / 新加坡 | 参与测速的候选地区 |
| `Tolerance` | 120 | 不切换阈值（ms）：候选必须比当前快超过这个数才切 |
| `Interval` | 90 | 轮询间隔（秒） |
| `ConfirmRounds` | 2 | 连续几轮复核通过才真正切换 |
| `Group` | AI | 要调整的 Clash 策略组名 |
| `TestUrls` | `api.openai.com/v1/models` + `chatgpt.com` | 探测目标数组。每个节点在每个目标上分别测速，取**最慢**的作为节点延迟 |
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

## 换机器 / 换目录

主程序本身不写死任何盘符路径（控制管道靠枚举 `\\.\pipe\` 找、配置读同目录的 json），**整个文件夹拷走就能跑**。但有两样东西不在这个文件夹里：

| 东西 | 存在哪 | 为什么必须重建 |
|---|---|---|
| 计划任务 `ClashWifiGuard Watchdog` | `C:\Windows\System32\Tasks\` | 任务定义里写死了看护脚本的绝对路径 |
| 开机自启 | `%APPDATA%\...\Startup\ClashWifiGuard-autostart.vbs` | 那份 VBS 里写死了主程序的绝对路径 |

所以迁移只有三步：

1. 把整个目录拷到新位置（`ClashWifiGuard.config.json` 可以一起带，省得重填）
2. 双击 **`注册本机任务.bat`**，它按当前实际目录把上面两样重建一遍（可重复执行，每次覆盖）
3. 核对 `ClashWifiGuard.config.json` 里的 `Ssid` 是不是新机器要守的 WiFi 名

新机器的 Clash Party 装在别的盘也没关系——程序不依赖它的安装路径。

## 进程自愈（崩了自己回来）

常驻托盘的代价是：它一旦自己退出，你不会收到任何提示，只是过一阵发现节点不切了、WiFi 不重连了。开机自启只在登录时跑一次，压不住这种情况。

所以另挂一个计划任务，每 5 分钟跑一次 `看护进程.vbs`：

```
schtasks /create /tn "ClashWifiGuard Watchdog" ^
  /tr "wscript.exe \"<本仓库路径>\看护进程.vbs\"" /sc minute /mo 5 /f
```

它用 WMI 查进程列表，**只有确认没有 `ClashWifiGuard.ps1` 在跑才启动新的**，所以不会叠出多个实例；两次检查之间不留下任何常驻进程（每次唤醒执行约 5 毫秒就退出）。手动双击 `看护进程.vbs` 行为等价。

**它尊重你的「退出」**：托盘菜单里的「退出（停止监控）」会写一个 `ClashWifiGuard.stop` 标记，看门狗看到标记就直接放手，不会几分钟后又把程序拉起来；下次双击启动器时这个标记会被自动清除，兜底重新生效。

界面上也留了入口：主窗口底部有张「进程自愈」卡片，实时显示状态（`未部署` 黄色 / `已部署 · 就绪 · 下次 16:31` 绿色），旁边就是「部署看门狗」按钮，点一下等价于双击 `注册本机任务.bat`，完成后弹提示。状态每 60 秒随心跳刷新，任务被系统禁用时会提示「已注册但被禁用」。

不想要了：

```
schtasks /delete /tn "ClashWifiGuard Watchdog" /f
```

## 关于内存

先说地板。实测**裸 PowerShell 5.1 + WPF 空窗口**（什么都不画）的私有提交就有 **210MB**，加两个 runspace 约 +10~23MB。这是技术栈的固有成本，不是这个工具写得烂——想真降到 100MB 以内只能换 C# 宿主。也正因为 runspace 增量很小，没有为了省这点去把两个引擎合并（合并会让 WiFi 检查被 32 秒的测速阻塞）。

在不能换栈的前提下做了两件事：

**1. 把不活跃页还给系统（工作集裁剪）**

启动 25 秒后先裁一次，之后每 90 秒检查一次、工作集涨过 60MB 就再裁；心跳发现超过 300MB 也会顺手裁一次。实测日志与曲线：

```
16:44:00 裁剪工作集 376.3MB → 12.4MB（私有提交 364.2MB 不变）
16:45:05 裁剪工作集 132.8MB → 6.8MB（私有提交 376.4MB 不变）
16:46:35 裁剪工作集 87.8MB → 6.9MB（私有提交 378.2MB 不变）

稳态采样：83.3 / 61.3 / 86.6 / 58.3 MB
```

任务管理器「内存」那一列看的就是工作集，所以会稳定在 60~90 MB 之间波动（偶尔冲到 130MB 再被裁回个位数）。**这不等于是「程序只用了 7MB」**——私有提交量始终在 370MB 左右没变，这是把不活跃页让给系统，其他程序需要内存时确实有页可用，代价是切回这个窗口时会有极短的重载。

**2. 给缓存设上限 + 主动回收**

- 趋势缓冲 2400 条（180 分钟窗口够用，之前是 4200）
- Clash 日志 400 条、WiFi 日志 200 条（之前 600 / 300）
- 心跳发现工作集超过 500MB 时 `[GC]::Collect()` 三次并记一行日志

真要长期跑，最终的兜底还是看门狗：出问题就重启，而不是追求内存曲线绝对平坦。

## 实现要点

- **两个引擎各跑一个 runspace**，主线程只画界面，探测卡住时 UI 不假死
- **多目标测速**：`codex` 实际走 `api.openai.com` 而不是网页，只测 `chatgpt.com` 会选出「网页快但 API 慢」的节点。现在每个节点在全部目标上分别测速（每目标取最好样本），再把各目标里的**最大值**作为该节点延迟 —— 用最慢的目标代表真实体验；某目标整体失败按 2000ms 惩罚计入，全部目标都失败才算不可达。日志里每个节点后面跟 `[api.openai=342 chatgpt=285]` 这样的明细
- **关窗不退出必须靠 Application.Run**：`ShowDialog()` 的模态循环在窗口 `Hide()` 之后会返回，脚本一路跑到末尾进程就没了 —— 看上去像收进了托盘，其实已经退出。改用 `Application.Run` + `ShutdownMode=OnExplicitShutdown`，只有托盘菜单里的「退出」才会显式 `Shutdown()`
- **Closing 里不能同步 Hide**：在 `Closing` 里 `Cancel = true` 之后直接 `Hide()`，窗口会被框架重新显示回来；要用 `Dispatcher.BeginInvoke` 把隐藏推迟到事件结束之后
- **单实例锁**：`Local\ClashWifiGuard.SingleInstance`，重复启动会把已有窗口提到前台而不是再开一个进程。窗口收起后 `IsWindowVisible` 为假，所以激活逻辑不能再按可见性过滤，否则找不到收起的窗口、用户会以为启动没反应
- **AppUserModelID**：`ClashWifiGuard.Desktop`，否则任务栏会沿用 powershell.exe 的分组和图标
- **mihomo 走命名管道**：`external-controller` 为空时只能读 `\\.\pipe\` 找 `MihomoParty` + `mihomo-user-Console`，管道名末段随 PID 变化，一律动态发现
- **chunked 响应必须字节层面解包**：按字符下标切 body 会因为中文节点名的字节数与字符数不等而错位
- **防抖**：候选要比当前快超过 `Tolerance` 毫秒、且连续 `ConfirmRounds` 轮复核都通过才切；当前节点不可达时立即切
- **延迟趋势用 ConcurrentQueue 跨 runspace**：引擎每轮 `Enqueue` 样本，界面只 `ToArray()` 取快照画图，不共享可变集合，也不加锁。容量上限 4200 条（约 1400 轮），超出自动出队。采样同时追加到 `ClashWifiGuard.history.jsonl`，启动时读尾部 1200 行，所以重启后曲线还在
- **嵌套滚动容器会吞滚轮**：WPF 里内层的 `ScrollViewer` / `TextBox` 即使内容不满也照样吃掉 `MouseWheel`，鼠标停在「节点延迟」列表或日志框上时整页就滚不动。处理方式是在内层挂 `PreviewMouseWheel`，判断「内层滚不了」或「已滚到顶/底」时手动驱动外层 `MainScroll`，并把事件标记为已处理
- **折线图是纯 WPF 自绘**：Canvas + `Polyline` / `Line` / `Ellipse`，没有第三方图表库。窗口只有 180 分钟的时间窗（`$script:trendWindowMin`），Y 轴上界按峰值自动取整；失败样本断线并在底部压红点，切换事件画黄色竖虚线；延迟相近的节点端点画成空心环，否则会互相盖住看不出是两个
- **托盘菜单不能靠 ContextMenuStrip 做大圆角**：WinForms 的菜单只能是方形卡片 + 系统阴影，用 `Region` 硬裁圆角还会有锯齿。这里改成起一个 `WindowStyle=None` + `AllowsTransparency=true` + `SizeToContent=WidthAndHeight` 的透明窗口当菜单，首帧 `Opacity=0`、定位完再置 1，避免左上角闪一下；`Deactivated` 负责点外部收起，`Esc` 也能关
- **提示浮层不要用 `ShowBalloonTip`**：Win11 下它已经不走传统气泡而是进通知中心，标题栏显示的是**进程身份**而不是代码传进去的字符串，中文就成了乱码方块。改为自绘 WPF 浮层（`ShowActivated=false` + `Topmost` + 定时自动关闭 + 180ms 淡入）
- **浮层定位不能拿主窗口当基准**：窗口一旦被拖动或没铺满屏幕，按 `$window.Left + ActualWidth` 算出来的位置就跑到屏幕中间去了。要以所在屏幕的工作区右下角为基准
- **`Screen.WorkingArea` 在这个进程里被 DPI 虚拟化过一遍**：150% 缩放下实测返回 `3840×2088`，而真实物理只有 `2560×1392`；WPF 的 `Left/Top` 单位是 DIP，所以折回去要除以 `scale` **两次**（`scale²`），只除一次会算到屏幕右边界之外——表现就是提示窗口存在、但永远看不见。核对办法：枚举窗口取 `GetWindowRect`，看浮层的实际物理坐标是否落在屏内
- **`DropShadowEffect` 的位移属性叫 `ShadowDepth`**：误写成 `ShiftDepth` 会抛异常，而这段代码外层套着 `catch {}`，结果就是提示永远不弹、却一点报错都没有。凡是这种"静默无效果"的写法，`catch` 里至少要落一行日志
- **`New-Object` 的括号写法不合法**：`New-Object System.Windows.Forms.Padding(14,8,30,8)` 会被解析成类型名的一部分，必须写成 `-ArgumentList 14,8,30,8`

## 开发期自检

```
powershell -NoProfile -ExecutionPolicy Bypass -File ClashWifiGuard.ps1 -SelfTest
```

只解析界面不弹窗，输出 `SelfTest OK: XAML 解析成功，控件全部就位` 表示文件完整可运行。另有 `-AutoProbe`：启动即做一次只测不切的探测；`-ToastTest`：启动后自动弹一次托盘提示（停留 9 秒），用来核对浮层是不是落在屏幕右下角。

## 已知限制

- 仅支持 Windows（依赖 WPF 与 `netsh wlan`）
- 只对**已经在用的那个** Clash 策略组生效，不修改订阅本身的配置，因此不会被订阅更新覆盖
- 需要 mihomo 暴露命名管道控制口；纯 TCP 模式（`external-controller` 有值）未实测

## License

MIT
