# dsh-desktop

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）的 Web 界面
装进一个独立的桌面窗口：双击桌面图标即可开始对话，不必再打开终端 `cd` 到仓库敲 `pnpm dsh web`。

不修改 Harness 的任何代码，也不改动仓库的 git 状态。

## 它做什么

安装后你会得到：

- 一个**桌面快捷方式**（位置由你选，默认桌面）；
- 一份**附带文件**（放在你选的专属目录里）：启动器、配置、图标、浏览器数据目录、卸载程序。

两者是**分开的两件事**，安装时会分别询问——快捷方式通常放桌面，附带文件不该堆在桌面上。

启动时它会在你的 Harness 仓库里执行 `pnpm dsh web --no-open`，抓取服务打印的带
token 的认证 URL，然后用 Chrome 的应用窗口模式（`--app=`）打开——没有地址栏、标签页
和书签栏，看起来就是一个独立软件窗口。

## 环境要求

| 依赖 | 要求 |
| --- | --- |
| Windows | 10 / 11 |
| Node.js | 22.19+ 或 24+（与 Harness 自身的要求一致） |
| pnpm | 已安装并在 PATH 中 |
| 浏览器 | Google Chrome 或 Microsoft Edge（用其应用窗口模式） |
| Harness 仓库 | 已 `pnpm install` 且已 `pnpm run build` |

安装程序会逐项检查这些条件，缺哪项就直接告诉你要跑什么命令，不会含糊失败。

## 使用

### 安装

从 [Releases](../../releases) 或 `dist/` 目录下载两个文件到同一个文件夹：

```
dsh-desktop-setup.cmd
dsh-desktop-setup.ps1
```

双击 `dsh-desktop-setup.cmd`（`.ps1` 必须放在它旁边）。它会依次询问四件事：

1. **Harness 仓库的本地路径** —— 你 clone 的 deepseek-harness 目录；
2. **自定义图标文件** —— 任意图片（png / jpg / bmp / gif / ico），建议正方形，会自动居中裁切；
3. **附带文件存放目录** —— 默认 `%LOCALAPPDATA%\dsh-desktop`；
4. **快捷方式放哪个文件夹** —— 默认桌面。

也可以用命令行一次给全，适合脚本化或批量安装：

```bat
dsh-desktop-setup.cmd ^
  -RepoPath   "D:\path\to\deepseek-harness" ^
  -IconFile   "D:\path\to\icon.png" ^
  -InstallDir "%LOCALAPPDATA%\dsh-desktop" ^
  -ShortcutDir "%USERPROFILE%\Desktop" ^
  -Port 3080 -ShortcutName "My DSH" -Silent
```

| 参数 | 说明 |
| --- | --- |
| `-RepoPath` | Harness 仓库路径 |
| `-IconFile` | 自定义图标；留空则用系统默认图标 |
| `-InstallDir` | 附带文件目录（启动器、配置、图标、浏览器数据） |
| `-ShortcutDir` | 快捷方式放在哪个文件夹 |
| `-Port` | 监听端口，默认 3080；同机装多份时用不同端口 |
| `-ShortcutName` | 快捷方式名称，默认 `DeepSeek Harness` |
| `-Force` | 覆盖已存在的文件（默认保留现有） |
| `-NoLaunch` | 装完不自动打开窗口 |
| `-Silent` | 不交互（配合上面的参数使用） |

### 日常使用

- **启动**：双击图标。首次启动需 20~45 秒（`dsh web` 要用 tsx 实时编译 TS），
  等待期间没有任何窗口，属正常，别重复点击。
- **关闭**：点窗口右上角 `×`，等同于原来的 `Ctrl+C` —— 启动器会停掉服务。
  正在跑的任务会随之中断，和以前在终端里 `Ctrl+C` 的行为一致。
- **重复双击**：窗口已开着时，再双击只会把它切到前台，不会重复起服务。
- **改端口 / 换仓库**：编辑附带文件目录里的 `dsh-web.config.json`，重新双击图标即可。

### 卸载

双击附带文件目录里的 `dsh-web-uninstall.cmd`，输入 `y` 确认。

它删除的只有这个桌面版引入的内容：桌面快捷方式 + 附带文件目录。
**不会碰**：Harness 仓库里的任何代码、Harness 数据目录 `~/.dsh`（会话、设置、凭据）、
以及命令行用法。

## 几处刻意的设计

**只停自己起的服务。** 如果 `dsh web` 是你自己在终端里启动的，桌面版只会复用它，
绝不会去杀掉它。判断依据是端口探测 + 一个记录自身进程号的锁文件。

**浏览器数据是隔离的。** 登录态 cookie（30 天）存在附带文件目录里的 `browser-data/`，
和你日常用的 Chrome / Edge 完全无关，互不影响。

**安装与卸载对称。** 卸载会删掉哪些文件，安装就会补齐哪些文件——包括卸载程序自身和
说明文档。这条规则写进了构建期断言，避免出现"卸载后再装就少了东西"。

**地址栏之外的窗口边界。** 同一时刻只有一个进程能占用 3080 端口，所以在同一台机器上
装第二份时必须换端口（`-Port 3081`）。

## 安全性

安装目录会被卸载程序**整个删掉**，所以对"目录选在哪"做了两处防护：

- **安装时**拒绝把附带文件目录设为桌面、用户主目录、文档、盘符根目录、
  Windows / Program Files / ProgramData，或任何"非空且不是本桌面版安装"的目录；
- **卸载时**只有在能确认"本目录确实是本桌面版的安装目录"（配置文件存在、且其中记录的
  路径就是这里）时才执行删除，否则直接拒绝。这道闸同样拒绝在输入被重定向（非交互）时
  执行卸载——否则一次被截断的管道调用就可能静默删除。

这两道闸的由来是：曾经把附带文件目录选成了桌面，而卸载逻辑会清空该目录——
桌面上全部文件都在删除范围内。

## 从源码构建

仓库里 `dist/` 下的产物是**生成出来的**，不要手改。改 `src/` 后运行：

```bash
python build.py
```

`build.py` 会把 `src/` 下的启动器、VBS 入口、卸载脚本和说明文档嵌进
`dist/dsh-desktop-setup.ps1` 的 here-string 里，输出可直接分发的成品。

### 项目结构

```
build.py                    构建脚本
src/
  setup.ps1                 安装程序（含 @@占位符@@）
  setup.cmd                 双击入口
  launcher.mjs              启动逻辑：起服务 → 抓 token URL → 开窗 → 关窗停服务
  dsh-web.vbs               隐藏控制台拉起启动器
  uninstall.ps1             卸载逻辑（含安全闸）
  uninstall.cmd             双击入口
  desktop-README.md         装好后随附带文件一起放置的说明
dist/
  dsh-desktop-setup.ps1     生成的成品（自包含）
  dsh-desktop-setup.cmd     生成的成品
```

构建脚本带两类断言，防止曾经发生过的两类事故重新出现：

- 嵌入的内容不得含 here-string 终止符（`'@` 开头的行），否则生成物会被静默截断；
- 启动器必须包含配置读取能力（`readConfig` / `cwd: REPO_DIR`）——安装程序曾长期
  内嵌一个不支持外部配置的旧启动器，装出来的桌面版会在安装目录里找 `dsh` 脚本、
  启动即失败。

### 几个编码坑（都踩过）

在 Windows 上生成 PowerShell / batch 脚本时：

- 含中文的 `.ps1` **必须**写成带 BOM 的 UTF-8，否则 Windows PowerShell 5.1 按 ANSI 读，
  中文变乱码并直接语法报错；
- 读回自己写的**无 BOM** UTF-8 JSON 时要显式 `-Encoding UTF8`，否则同样按 ANSI 解码，
  路径里只要含中文就会解析失败；
- `.cmd` 必须用 CRLF，LF 换行会让 cmd.exe 在 `( )` 块里解析错乱，且必须保持纯 ASCII；
- Python 读取带 BOM 的源文件用 `utf-8-sig`，否则 BOM 会作为字符混进内嵌内容，
  写出去变成双 BOM —— 而双 BOM 会让 PowerShell 停止解析脚本；
- PowerShell here-string 不含结尾换行，落盘时要补回恰好一个。

## 已知限制

- **任务栏图标**：桌面图标用的是你提供的图片，但**运行中窗口的任务栏图标**由网页自身的
  favicon 决定，无法在不改用 Electron 的情况下修改。
- **首次启动慢**：因为 `dsh web` 每次都要用 tsx 编译 TS。保持服务常驻可以秒开，
  但那意味着后台常驻一个进程——本项目选择了关窗即停。
- **仅 Windows**：依赖 VBS + Chrome `--app` + 本机 .NET。

## 许可

MIT，见 [LICENSE](LICENSE)。

本项目不包含 DeepSeek Harness 的任何代码，它只是调用你本地已安装的 `dsh`。
