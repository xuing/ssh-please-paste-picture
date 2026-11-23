# ssh-please-paste-picture

[![CI](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml/badge.svg)](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xuing/ssh-please-paste-picture)](https://github.com/xuing/ssh-please-paste-picture/releases/latest)
[![License: MIT](https://img.shields.io/github/license/xuing/ssh-please-paste-picture)](LICENSE)

[English](README.md) | 简体中文

在 Windows Terminal 里按 Ctrl+V，把截图粘贴到服务器上的 Claude Code。

项目名就是它做的事：“ssh, please paste picture”，命令叫 `ssh-paste`。它只是 Windows 上的一个 PowerShell 脚本，服务器端不用装任何东西。

## 效果

Windows Terminal 只粘贴文本，服务器上的程序读的是服务器剪贴板，不是本机剪贴板。用 `ssh-paste` 连 SSH 后：

1. 在 Windows 上截图复制（Win+Shift+S 或其他图片程序），或在资源管理器里复制图片文件（png、jpg、jpeg、gif、webp、bmp）。
2. 切回 SSH 终端窗口。
3. `ssh-paste` 把图片传到服务器的 `/tmp/ssh-paste-<hash>.png`。
4. 按 Ctrl+V 粘贴该路径。
5. Claude Code 读取路径并附加图片。

在其他软件里粘贴，得到的仍然是图片。`ssh-paste` 只在该会话打开期间运行。

## 安装

打开 PowerShell（不是 cmd），运行：

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

不需要管理员权限。当前窗口马上可用 `ssh-paste`，其他窗口新开标签页即可。升级也是运行同一行命令。

第一个 release 发布前 `releases/latest` 不存在，上面的命令会失败。这时从 `main` 分支安装：

```powershell
irm https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/main/install.ps1 | iex
```

这行命令装的是 `main` 上最新的 commit，有 release 之后也一样。

Windows 和 SSH 前提见[运行要求](#运行要求)，先下载再运行或装指定版本见[安装选项](#安装选项)。

### 校验下载的文件

每个 release 都附带 `SHA256SUMS` 和 GitHub build attestation，覆盖 `install.ps1`、`ssh-paste.ps1` 和 `ssh-paste.cmd`。从 `main` 装的文件两者都没有。想在运行前检查 release 里的 `install.ps1`，把它和 `SHA256SUMS` 一起下载下来比对哈希：

```powershell
$base = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download'
Invoke-WebRequest -UseBasicParsing -Uri "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile SHA256SUMS
$want = (Select-String -Path SHA256SUMS -Pattern ' install\.ps1$').Line.Split(' ')[0]
(Get-FileHash install.ps1 -Algorithm SHA256).Hash -eq $want
```

文件一致时最后一行输出 `True`。装了 [GitHub CLI](https://cli.github.com/) 的话，再确认文件是本仓库的 release workflow 构建的：

```powershell
gh attestation verify install.ps1 -R xuing/ssh-please-paste-picture
```

然后按[安装选项](#安装选项)里的方式运行检查过的文件。

## 使用

### ssh 模式（推荐）

启用主机一次：

```powershell
ssh-paste --enable myhost
```

之后直接 `ssh myhost` 就能粘贴截图。运行 `ssh myhost` 的 Windows Terminal profile 等交互式会话也一样。参数用 `%USERPROFILE%\.ssh\config` 的 `Host` 别名或纯主机名，不能带 `user@` 或选项。多个主机一起启用：`ssh-paste --enable host1 host2`。

`--enable` 会在 `%USERPROFILE%\.ssh\config` 开头写入并打印以下配置：

```
# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>
Host myhost
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\you\AppData\Local\Programs\ssh-paste\ssh-paste.ps1" --proxy %h %p %n
    ProxyUseFdpass no
Host *
# <<< ssh-paste <<<
```

主机已用 `ProxyJump` 或 `ProxyCommand` 时，`--enable` 会拒绝修改。配置块原理见[ssh 模式和 wrapper 模式](#ssh-模式和-wrapper-模式)。

撤销启用：

```powershell
ssh-paste --disable myhost   # 只撤销一个主机
ssh-paste --disable          # 撤销全部，整段配置删掉
```

`--disable` 只删 `--enable` 加的行。如果 config 文件是 `ssh-paste` 建的且没有其他内容，会一起删掉该文件。如果 `.ssh` 目录随之变空，也会删掉。

### wrapper 模式（零配置）

把 `ssh` 换成 `ssh-paste`：

```powershell
ssh-paste myhost
ssh-paste -p 2222 -J bastion me@myhost
ssh-paste -t myhost claude
```

`ssh-paste` 用相同参数启动 `ssh.exe`，输出 `ssh-paste: screenshot paste is on. Copy a screenshot, come back here, press Ctrl+V.` 后监视剪贴板。所有 `ssh` 参数和跳板机都能用。没加 `-t` 的远程命令（如 `ssh-paste myhost ls`）按普通 `ssh` 运行。

### 检查环境

运行 `--doctor` 检查 PowerShell、剪贴板和窗口 API、`ssh`、终端类型，并向 `myhost` 上传测试小图：

```powershell
ssh-paste --doctor myhost
```

不加 `myhost` 时只查本机。每行以 `ok`、`FAIL` 或 `info` 开头。输出示例：

```
ssh-paste 0.1.0
  ok    PowerShell 5.1.26100.2161 (Desktop)
  ok    clipboard and window APIs available
  ok    ssh: C:\Windows\System32\OpenSSH\ssh.exe (OpenSSH_for_Windows_9.5p1, LibreSSL 3.8.2)
  ok    terminal: Windows Terminal
  ok    clipboard: image, 48213 bytes
  ok    upload to myhost: /tmp/ssh-paste-4f1c0a9e7b2d3c5a8b6f0e1d2c3b4a59.png (0.8 s)
  info  ssh mode is off for myhost. Turn it on: ssh-paste --enable myhost   (or use: ssh-paste myhost)
```

### 粘贴不成功时

按顺序排查：

1. 运行 `ssh-paste --doctor myhost`，`FAIL` 行会指出问题。
2. ssh 模式下，带 `SSH_PASTE_DEBUG=1` 连接。转发会在 stderr 输出 `ssh-paste debug:` 行，包括连上的地址、stdin 和 stdout 的打开方式，以及哪一端关闭了连接。

   ```powershell
   $env:SSH_PASTE_DEBUG = 1; ssh myhost
   Remove-Item Env:SSH_PASTE_DEBUG
   ```

3. 运行 `ssh -v myhost`，看连接停在哪一步。比如卡在 `expecting SSH2_MSG_KEX_ECDH_REPLY`，说明转发停止了。
4. 带上以上输出提交 [bug report](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml)。

### 全部命令

```
ssh-paste --enable HOST [HOST...]   make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)
ssh-paste --disable [HOST...]       undo --enable (all hosts if none given)
ssh-paste [ssh options] HOST        wrapper mode: ssh with screenshot paste, no config
ssh-paste --doctor [HOST]           check this computer and test an upload to HOST
ssh-paste --update                  install the latest release
ssh-paste --uninstall               remove ssh-paste and everything it changed
ssh-paste --version | --help
```

## 运行要求

- **Windows 10 或 11。** 即使装了 PowerShell 7，`ssh-paste` 也始终跑在系统自带的 Windows PowerShell 5.1 上。
- **Windows Terminal。** 推荐 Windows Terminal，传统控制台窗口也行。其他终端见[其他终端和程序](#其他终端和程序)。
- **OpenSSH client。** 新版 Windows 默认自带 `ssh.exe`。没有就在**设置 > 系统 > 可选功能**里装 `"OpenSSH Client"`。找不到 `ssh.exe` 安装会中止。
- **免提示密钥登录。** 上传另开一条非交互式 `ssh` 连接（`BatchMode=yes`），不会提示输密码或口令。请用无口令密钥，或把密钥加到 `ssh-agent`：

  ```powershell
  # 只需一次，在“以管理员身份运行”的 PowerShell 里：立即启动 agent，并设为开机自启
  Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
  # 然后用自己的身份添加密钥（只问一次口令）
  ssh-add
  ```

  只支持密码登录时，SSH 会话能连，上传会失败。
- **服务器工具。** 需要 `sh`、常用命令（`cat`、`wc`、`find`、`cmp`、`mv`、`mktemp`）和可写 `/tmp`，Linux 服务器都自带。登录 shell 支持 `bash`、`zsh`、`fish`、`tcsh`。

## 已知限制

- **焦点按 Windows Terminal 窗口判断，不区分标签页。** Windows 不暴露当前标签页。窗口里只要跑着使用 `ssh-paste` 的会话，所有标签页（含本地标签页）粘贴的都是路径。同一窗口另一个连其他主机的标签页也会上传每张图，先写入的会话决定最终路径。不同主机和本地工作请分窗口。
- **ssh 模式下，会话结束后剪贴板可能留着最后的路径。** 退出时 `ssh` 会结束 `ProxyCommand`，`ssh-paste` 可能来不及还原纯图片。其他软件里粘出仍是图片，下次复制后路径文本就会消失。
- **带 HTML 的图片会丢 HTML。** 比如 Chrome 的**复制图片**会带 HTML 片段，改写后只剩图片和路径。
- **ssh 模式拒绝已配 `ProxyJump` 或 `ProxyCommand` 的主机。** 请改用 wrapper 模式（如 `ssh-paste myhost`）。
- **上传需要免提示密钥或 `ssh-agent`。** 见[运行要求](#运行要求)。
- **ssh 模式下，到已启用主机的每次连接都会多出一次 PowerShell 启动时间，包括 `scp`、`sftp` 和 `git`。**

## 它会改动你电脑上的哪些东西

| 时机 | 改动 | 如何还原 |
|---|---|---|
| 安装 | 目录 `%LOCALAPPDATA%\Programs\ssh-paste`，里面是 `ssh-paste.ps1` 和 `ssh-paste.cmd`（`%LOCALAPPDATA%\Programs` 不存在时会创建） | `--uninstall` 删除这个目录；`%LOCALAPPDATA%\Programs` 如果因此变空，也一起删掉 |
| 安装 | 用户 PATH（`HKCU\Environment\Path`）里的一个条目 | `--uninstall` 删除这个条目；`Path` 里如果什么都不剩，连值一起删掉 |
| `--enable` | `%USERPROFILE%\.ssh\config` 开头上面那段配置（文件和 `.ssh` 目录不存在时会创建） | `--disable` 或 `--uninstall` 删除这段配置；config 是 ssh-paste 创建的且没有别的内容时删除文件，`.ssh` 因此变空时也删掉 |
| 会话运行期间 | 改写剪贴板里那条图片内容：图片、作为文本的路径、私有格式 `SshPaste.Owner`，以及 `ExcludeClipboardContentFromMonitorProcessing`、`CanIncludeInClipboardHistory=0`、`CanUploadToCloudClipboard=0` 这几个标记，让这些改写不进 Win+V 历史，也不同步到云剪贴板 | 路径文本会去掉：切到别的程序或会话结束时，剪贴板里只剩图片（ssh 模式的例外见上面的限制）。这条内容上的 `SshPaste.Owner` 和那三个标记会留到你下次复制别的东西为止 |

除此之外没有服务、计划任务、启动项、profile 或配置文件改动。安装和卸载会临时写删一个用户变量，通知新窗口刷新 `PATH`。服务器上只写 `/tmp/ssh-paste-*.png`。

## 卸载

```powershell
ssh-paste --uninstall
```

这会清掉 `--enable` 配置块、`PATH` 条目和安装目录。`ssh-paste` 用不了时，用安装脚本卸载（任选一行）：

```powershell
$env:SSH_PASTE_UNINSTALL = 1; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
& ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall
```

用了第一行的话，在同一窗口重装前先执行 `Remove-Item Env:SSH_PASTE_UNINSTALL`。

手动卸载步骤：

1. 删掉 `%USERPROFILE%\.ssh\config` 里从 `# >>> ssh-paste` 到 `# <<< ssh-paste <<<` 的行。
2. 开始菜单搜索“编辑账户的环境变量”，选 `Path` 点**编辑**，去掉 `%LOCALAPPDATA%\Programs\ssh-paste`。
3. 运行 `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\ssh-paste"`。

卸载不动服务器。已传图片留在 `/tmp` 等系统清理，详见[服务器上的文件](#服务器上的文件)。立即删掉自己的图片：

```powershell
ssh myhost "rm -f /tmp/ssh-paste-*"
```

## 细节

### 哪些会话会监视剪贴板

只有交互式会话监视剪贴板。到已启用主机的其他连接仍走转发但不监视：

- `ssh -T`、`-N`、`-W`、`-f`、`-n`、`-s`、`-G`、`-V`、`-O`、`-Q`
- 没加 `-t` 的远程命令（如 `ssh myhost ls`、`git` 或 `RemoteCommand`）
- `RequestTTY no`、非 `default` 的 `SessionType`、`StdinNull yes`

`ssh-paste` 用 `ssh -G` 综合读取命令行和 `~/.ssh/config`，因此 `scp`、`sftp`、`git`、VS Code Remote-SSH 都是纯转发。wrapper 模式下遇到已启用 ssh 模式的主机，会直接跑 `ssh`，避免传两次。

### 什么时候上传、重试和报错

`ssh-paste` 每 250 ms 看一次剪贴板。有不超过 64 MB 的图片且会话窗口在前台时立即上传，也就是切回窗口时传，不是按 Ctrl+V 时传。上传期间按 Ctrl+V 会等上传完成（最多 30 秒）再粘贴路径；上传失败则什么也不粘贴。

同一张图每会话只传一次。超过 6 小时再切回该图会重传，防止按天清理删掉待粘贴路径。

上传失败时每张图响一次 Windows 错误音，窗口在前台时按 30 秒、1、2、4 分钟倍增重试，最长 30 分钟一次。会话结束时输出：

```
ssh-paste: 1 screenshot upload(s) failed: ssh exited with 255: me@myhost: Permission denied (publickey).
Run: ssh-paste --doctor myhost
```

ssh 模式下 `ssh` 终止 `ProxyCommand` 可能导致来不及输出汇总。

缺少条件（如策略禁用剪贴板 API）时，输出 `ssh-paste: screenshot paste is off: <原因>` 并降级为普通 `ssh` 或纯转发。

### 服务器上的文件

路径为 `/tmp/ssh-paste-<hash>.png`，`<hash>` 是 PNG 的 SHA-256 前 128 位十六进制。同图同名，已有相同文件直接复用。名字被别人占用时改存 `/tmp/ssh-paste-<hash>-<uid>.png`。权限为 600。

只有同一用户后续往同台服务器上传时才清理，删掉超过一天的 `ssh-paste-<hash>.png` 和残留临时文件。复用文件会刷新时间。上传间隙和卸载后无后台清理，靠系统自行清理 `/tmp`（通常重启时）。

### 剪贴板

Windows 剪贴板条目可含多种格式。`ssh-paste` 同时写入图片和远程路径文本，Windows Terminal 粘文本，看图或聊天软件粘图片，切到别的软件时还原成纯图片。

同时含文本或文件的条目（如 Excel、Word、资源管理器）会被跳过，终端照常粘贴。原截图留在 Win+V 历史里，只有 `ssh-paste` 改写的内容不进历史。

不同窗口的会话会标记目标窗口句柄，前台窗口优先，互不覆盖。同窗口内已有其他会话写入路径时不再改写。

### ssh 模式和 wrapper 模式

ssh 模式下，`ssh` 以 `ProxyCommand` 启动 `ssh-paste` 建立 TCP 连接、原样转发加密的 SSH 数据，并在交互式会话里监视剪贴板。`%h %p %n` 由 `ssh` 填入主机名、端口和别名。`ProxyUseFdpass no` 防止其他地方的 `ProxyUseFdpass yes` 生效。配置块放最前因为 `ssh` 只认首个选项值，末尾 `Host *` 让后续全局配置照常生效。原来没有 `.ssh\config` 时会新建，并在开头标记后加上 `# ssh-paste created this file; it is deleted when the last host is disabled.`。

`ssh-paste` 读取父进程 `ssh.exe` 的命令行解析选项，直连转发的 IP 并用会话使用的名字检查 host key。wrapper 模式由 `ssh-paste` 自己在当前控制台启动 `ssh.exe`。两种模式上传时都保留指定服务器和登录的选项（`-l`、`-p`、`-i`、`-F`、`-o` 等）并加上加固选项。wrapper 模式还保留 `-J`；ssh 模式不保留，因为上传直接连转发已经连上的地址，详见 [SECURITY.md](SECURITY.md)。

### 安装选项

**先下载、审阅、再运行。** 部分杀毒软件会拦截 `irm ... | iex`，因为恶意软件也常这么写：

```powershell
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 -OutFile install.ps1
notepad install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
Remove-Item install.ps1
```

`-ExecutionPolicy Bypass` 只对该进程有效。每个 release 附带 `SHA256SUMS`，包含 `install.ps1`、`ssh-paste.ps1` 和 `ssh-paste.cmd` 的校验和，见[校验下载的文件](#校验下载的文件)。

**选择版本。** 每个 release 附带的 `install.ps1` 默认安装该 release 的文件，`releases/latest` 指最新版。用 `SSH_PASTE_REF` 或 `-Ref` 可指定其他 tag、branch 或 commit：

```powershell
$env:SSH_PASTE_REF = 'v0.1.0'; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

此时从 `raw.githubusercontent.com` 对应 ref 下载。在仓库 clone 里跑 `powershell -ExecutionPolicy Bypass -File install.ps1` 会安装该 clone 的 `src` 目录。

Group Policy 将 execution policy 设为 `AllSigned` 或 `Restricted`，或因 AppLocker、App Control 处于 Constrained Language 模式时，安装会中止。以管理员运行时装给提权账户，脚本会提示它可能不是你的日常账户。

### 其他终端和程序

- **其他终端。** 传统控制台可用。WezTerm、Alacritty 等尽力支持，通过向上查进程树寻找终端。`ssh-paste --doctor` 会打印识别方式 `terminal: ...`。
- **其他 CLI 程序。** 粘贴出的服务器 PNG 路径可用于 Codex CLI、Gemini CLI、aider 等，是否自动附带图片取决于程序本身，Claude Code 支持。
- **换用其他 `ssh.exe`。** 将 `SSH_PASTE_SSH` 设为完整路径，wrapper 模式、`--enable` 和 `--doctor` 会用它。ssh 模式下，上传用的是启动转发的那个 `ssh.exe`。
- **杀毒软件与策略。** 运行时通过 `Add-Type` 编译几行 C# 调剪贴板和窗口 API，可能触发误报。脚本明文存在 `%LOCALAPPDATA%\Programs\ssh-paste`，Microsoft Defender 误报可提交到 <https://www.microsoft.com/en-us/wdsi/filesubmission>。AppLocker 或 App Control 导致的 Constrained Language 模式会禁用剪贴板，`ssh-paste --doctor` 会报告。
- **后台进程。** 没有后台常驻进程，监视器随 SSH 会话一起退出。

## 同类工具对比

| 工具 | Windows 端 | 服务器端 | 后台常驻 | 粘贴方式 |
|---|---|---|---|---|
| ssh-please-paste-picture | 一个 PowerShell 脚本 | 无 | 无，只在会话期间运行 | Ctrl+V |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)（`/rc`） | 无，用 claude.ai/code 或 Claude app | 无需额外安装 | Claude Code 会话本身 | 在浏览器或 app 里附加图片 |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust daemon | xclip / wl-paste shim 和 `clipaste-paste`（需要 curl），ssh config 里加 `RemoteForward` | 本地 daemon | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go 程序，作者标注 Windows 支持为 experimental | Windows 的 hotkey 方式不需要（用 scp 上传）；Ctrl+V 的 shim 加 tunnel 方式在 Windows 上是 experimental | hotkey 进程（可选开机自启） | Alt+Shift+V |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | Go 程序 | 无 | 登录后由计划任务启动的 daemon，复制的每张图片都会上传 | Ctrl+V |
| AutoHotkey 脚本，例如 [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2 和脚本 | 无 | AutoHotkey，拦截 Ctrl+V | Ctrl+V |

Remote Control 只支持 Claude Code，需要 Pro、Max、Ultra、Team 或 Enterprise 订阅（不支持 API key），且要切到浏览器或 Claude app。AutoHotkey 方案只在按 Ctrl+V 时上传，而 `ssh-paste` 会上传你带到会话窗口的每张图片。

## 开发

所有文件保持纯 ASCII，兼容 Windows PowerShell 5.1 和 PowerShell 7：

```
src/ssh-paste.ps1              the program (all logic is in this file)
src/ssh-paste.cmd              the `ssh-paste` command: runs the .ps1 with Windows PowerShell
install.ps1                    installer and uninstaller
tests/ssh-paste.Tests.ps1      Pester tests (tags: Unix, Windows, E2E)
tests/e2e-linux.sh             starts a throwaway sshd and runs the E2E tests against it
tests/footprint.ps1            Windows: install, enable, disable, uninstall leave no trace
tests/lint.ps1                 lint checks that check.ps1 and CI share
check.ps1                      runs the lint checks and unit tests; -E2E and -Footprint add the others
PSScriptAnalyzerSettings.psd1  lint rules
.github/workflows/ci.yml       lint, unit tests (5.1 and 7 on Windows, 7 on Linux), E2E, footprint
.github/workflows/ci.yml       ... and a release of every green push to main that changes src/ or install.ps1
.github/workflows/publish.yml  builds, attests and publishes a release (SHA256SUMS, attestations)
.github/scripts/               the shell steps of a release (next version, notes, version stamp)
```

用 dot-source 加载核心脚本（`. ./src/ssh-paste.ps1`）只定义函数不执行，供测试加载。

每次 commit 前运行 `pwsh ./check.ps1`，它会跑 lint 检查和单元测试。pull request 必须通过的全部检查见 [CONTRIBUTING.md](CONTRIBUTING.md)。单独跑某一组测试用下面的命令：

```powershell
# 单元测试，需要 Pester 5.5 或更新版本。依赖 Windows 或 Unix shell 的测试在其他平台上会自动跳过。
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path tests/ssh-paste.Tests.ps1 -ExcludeTagFilter E2E -Output Detailed
```

```bash
# Linux 上的端到端测试，会在 127.0.0.1 上起一个临时 sshd（需要 pwsh、ssh、sshd、python3）
bash tests/e2e-linux.sh
```

```powershell
# footprint 测试，仅限 Windows。它会改动你真实的用户环境，结束后再还原；CI 里会跑。
powershell -ExecutionPolicy Bypass -File tests\footprint.ps1 -Force
```

`main` 上每个绿色、且改动了 `src/` 或 `install.ps1` 的 commit 都会自动发布为 `v0.1.<n>`。如何查看 release、如何手动发布见 [docs/RELEASING.md](docs/RELEASING.md)。

## 参与贡献

报 bug 请用 [bug report 表单](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml)，并附上 `ssh-paste --doctor` 的输出。提 pull request 前先开 issue。pull request 必须通过的检查和 commit 规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

## License

[MIT](LICENSE)
