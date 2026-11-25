# ssh-please-paste-picture

[![CI](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml/badge.svg)](https://github.com/xuing/ssh-please-paste-picture/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/xuing/ssh-please-paste-picture)](https://github.com/xuing/ssh-please-paste-picture/releases/latest)
[![License: MIT](https://img.shields.io/github/license/xuing/ssh-please-paste-picture)](LICENSE)

[English](README.md) | 简体中文

在 Windows Terminal 里按 Ctrl+V，或在 macOS 的终端里按 Cmd+V，通过 SSH 把截图粘贴到远程 Claude Code。本机上就一个脚本（`ssh-paste`），服务器端什么都不用装。

它怎么工作、哪些事它从不做、和同类工具有什么不同：[docs/how-it-works.zh-CN.md](docs/how-it-works.zh-CN.md)。

## 快速开始

**1. 安装**。Windows 上打开 PowerShell（不是 cmd，不需要管理员权限）运行：

```powershell
irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

当前窗口马上可用，其他窗口新开标签页即可。也可以用 [Scoop](https://scoop.sh)：

```powershell
scoop bucket add xuing https://github.com/xuing/scoop-bucket
scoop install xuing/ssh-paste
```

macOS 上用 [Homebrew](https://brew.sh)：

```sh
brew install xuing/tap/ssh-paste
```

不用 Homebrew 的话（装完新开一个标签页，或者运行安装程序打印的那行 `export PATH=...`）：

```sh
curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh
```

<details>
<summary>更多安装方式</summary>

装 main 分支的最新提交（Windows）：

```powershell
irm https://raw.githubusercontent.com/xuing/ssh-please-paste-picture/main/install.ps1 | iex
```

如果杀毒软件拦截 `irm ... | iex`，见[校验下载的文件](#校验下载的文件)。

指定 tag、分支或 commit（`SSH_PASTE_REF`、`-Ref` 或 `--ref <tag|branch|commit>`）：

```powershell
$env:SSH_PASTE_REF = 'v0.1.0'; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
```

在仓库 clone 里运行 `powershell -ExecutionPolicy Bypass -File install.ps1` 或 `sh install.sh`，装的是它自己的 `src` 目录（`-Help`、`--help` 列出全部选项）。以管理员身份运行时，install.ps1 装给的是那个提权后的账户。

</details>

**2. 启用一台主机**：

```powershell
ssh-paste --enable myhost
```

**3. 用 `ssh myhost` 连上，然后粘贴：**

1. 复制截图（Win+Shift+S；macOS 上 Cmd+Ctrl+Shift+4），或者复制图片文件（`png`、`jpg`、`jpeg`、`gif`、`webp`、`bmp`）。
2. 切到 SSH 窗口，`ssh-paste` 会把图片上传到 `/tmp/ssh-paste-<hash>.png`。
3. 按 Ctrl+V（macOS 上 Cmd+V），把这个路径粘进 Claude Code。

在其他程序里粘贴的仍然是图片。没有连着的会话时，它什么都不做。

## 使用

### ssh 模式（推荐）

`--enable` 会在 `~/.ssh/config`（`%USERPROFILE%\.ssh\config`）开头写入一段配置。参数传 Host 别名或主机名，不能带 `user@` 或选项（`ssh-paste --enable host1 host2`）。已经用了 `ProxyJump` 或 `ProxyCommand` 的主机会被拒绝，这种主机请用 wrapper 模式。

```powershell
ssh-paste --disable myhost   # one host
ssh-paste --disable          # all hosts: removes the whole block
```

<details>
<summary>~/.ssh/config 里的那段配置</summary>

```
# >>> ssh-paste (managed by ssh-paste --enable / --disable) >>>
Host myhost
    ProxyCommand C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\you\AppData\Local\Programs\ssh-paste\ssh-paste.ps1" --proxy %h %p %n
    ProxyUseFdpass no
Host *
# <<< ssh-paste <<<
```

`ssh-paste` 原样转发 SSH 字节流，同时识别交互式会话（配置块以 `Host *` 结束）。上传时沿用你的 `ssh.exe` 选项，直连转发连上的 IP 地址，并按会话用的名字校验 host key；`-J` 只在 wrapper 模式下可用。详见 [SECURITY.md](SECURITY.md)。

</details>

### wrapper 模式（零配置）

```powershell
ssh-paste myhost
ssh-paste -p 2222 -J bastion me@myhost
ssh-paste -t myhost claude
```

带着你的全部选项运行 `ssh`，`-J` 也可以用。不带 `-t` 的远程命令（`ssh-paste myhost ls`）按普通 `ssh` 运行。

### 全部命令

```
ssh-paste --enable [OPTIONS] HOST...    make plain "ssh HOST" paste screenshots (edits ~/.ssh/config)
ssh-paste --disable [HOST...]           undo --enable (all hosts if none given)
ssh-paste [OPTIONS] [ssh options] HOST  wrapper mode: ssh with screenshot paste, no config
ssh-paste --doctor [HOST]               check this computer and test an upload to HOST
ssh-paste --update                      install the latest release
ssh-paste --uninstall                   remove ssh-paste and everything it changed
ssh-paste --version | --help

OPTIONS (images on the server; per host for --enable):
  --keep TIME   delete them when older than TIME: 30m, 2h, 7d (default 1d), or never
  --dir DIR     keep them in DIR: /tmp (default), any /path, or ~/path (quote the ~)
```

### 服务器上图片存在哪、留多久

默认存到 `/tmp`，每次上传时会顺手删掉你在那里超过一天的图片。两样都可以按主机设置：

```sh
ssh-paste --enable --keep 7d --dir '~/screenshots' myhost   # keep a week, in your home folder
ssh-paste --enable --keep never myhost                      # never delete
ssh-paste --keep 2h myhost                                  # wrapper mode, this session only
```

`--keep` 可以写至少 10 分钟的时间（`30m`、`2h`、`7d`）或 `never`；`--dir` 可以写 `/path` 或 `~/path`（`~` 要加引号，免得被本机 shell 展开成你电脑上的家目录）。`~` 指服务器上的家目录：`--enable` 时会连一次服务器问清楚，把完整路径写进 ssh 配置（wrapper 模式在会话开始时问）。如果 ssh-paste 登录不上去问，就请直接写完整路径。`/tmp` 以外的目录不存在时会自动创建（权限 700），而且必须只属于你：归你所有、不是链接、组和其他人都不可写、没有 ACL（服务器看不出来的时候，就当作不安全，拒绝使用）。它只检查这个目录本身，不检查上级目录，所以请选一个上级目录只有你和 root 能改的位置，比如你的家目录下面。对同一台主机再次 `--enable` 时，只改你这次给出的选项。每次上传只删和自己同一种 `--keep`、并且超过这个时间的图；文件名会标明是哪一种（`ssh-paste-k7d-<hash>.png`，默认的不加标记），所以一台主机想多留的图，不会被另一台主机删掉。删除发生在上传的时候，所以图片至少会留这么久。


### 服务器要密码怎么办

上传是在后台自己登录的，不能弹出密码提示，所以服务器得接受你的 key。`--enable` 会检查这一点：服务器拒绝上传登录的主机不会被启用，并打印下面这些命令，主机名已填好（`--doctor` 也会打印）。配置 key（只需一次；第二条命令最后一次问你密码）：

```powershell
# Windows, in PowerShell
ssh-keygen -t ed25519
Get-Content $HOME\.ssh\id_ed25519.pub | ssh myhost "umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; echo >> .ssh/authorized_keys; tr -d '\r\000' >> .ssh/authorized_keys"
ssh-paste --doctor myhost
```

```sh
# macOS
ssh-keygen -t ed25519
ssh-copy-id -i ~/.ssh/id_ed25519.pub myhost
ssh-paste --doctor myhost
```

`ssh-keygen` 的每个问题直接按回车；如果提示 key 文件已经存在，回答 `n` 跳过即可。Windows 上的 key 不设 passphrase，因为 `ssh-agent` 服务默认关闭，要管理员才能打开（以管理员身份运行 `Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service`，再以自己的身份运行 `ssh-add`）。如果你平时用 `ssh -i KEY` 登录，或者 `~/.ssh/config` 里给这台主机指定了 `IdentityFile`，就换用那把 key，并在 `Host` 配置里用 `IdentityFile` 写明，这样 ssh 模式也会用它。macOS 上可以设 passphrase，再运行 `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`（重启后怎么保持加载，见 [GitHub 的说明](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)）。macOS 上还有一个不用 key 的办法：`ssh-paste myhost`（wrapper 模式）会让你的会话同时充当一条私有的"主连接"（如果你自己已经在配置里用了 `ControlMaster`/`ControlPath`，或者用了 `-S`、`-M`，就保持你的设置，不这样做），上传共用你登录的那条连接，密码或验证码照常只输一次。ssh 模式和 Windows（自带的 OpenSSH 不支持共用连接）需要 key；只接受密码或一次性验证码、不接受 key 的服务器，在这两种情况下没法上传。

### 升级与卸载

| 安装方式 | 升级 | 卸载 |
|---|---|---|
| `install.ps1` 或 `install.sh` | `ssh-paste --update`，或重新运行安装命令 | `ssh-paste --uninstall` |
| Scoop | `scoop update ssh-paste` | `scoop uninstall ssh-paste` |
| Homebrew | `brew upgrade ssh-paste` | 先 `ssh-paste --uninstall`，再 `brew uninstall ssh-paste` |

用 Scoop 或 Homebrew 装的，`--update` 和 `--uninstall` 只会打印对应的包管理器命令；`--enable` 写入的路径升级后依然有效（`apps\ssh-paste\current`，或 Homebrew 的 `opt` 路径）。`scoop uninstall` 会自己运行 `--disable`；Homebrew 做不到，所以要先运行 `ssh-paste --uninstall`，否则 ssh 连那些主机时还会去调用已经删掉的命令。开了 Scoop 的 `no_junction` 设置时，`--enable` 会拒绝，请用 wrapper 模式。

上传的图片会留在服务器的 `/tmp`（或你设的 `--dir` 目录）里。要删掉你在 `/tmp` 里的图片：

```powershell
ssh myhost "rm -f /tmp/ssh-paste-*"
```

<details>
<summary>ssh-paste 运行不了，或者想手动卸载</summary>

Windows 上通过安装程序卸载（之后要在同一个窗口重新安装的话，先运行 `Remove-Item Env:SSH_PASTE_UNINSTALL`）：

```powershell
$env:SSH_PASTE_UNINSTALL = 1; irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1 | iex
& ([scriptblock]::Create((irm https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.ps1))) -Uninstall
```

在仓库 clone 里：`powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall`。

macOS：`sh ~/.local/share/ssh-paste/install.sh --uninstall`，或 `curl -fsSL https://github.com/xuing/ssh-please-paste-picture/releases/latest/download/install.sh | sh -s -- --uninstall`。`SSH_PASTE_UNINSTALL=1` 的作用和 `--uninstall` 相同，重新安装前记得 unset。

手动删除：删掉 `~/.ssh/config` 里 `# >>> ssh-paste` 开头的那段。Windows 上把 `%LOCALAPPDATA%\Programs\ssh-paste` 从 `Path` 里去掉（开始菜单 > `"编辑帐户的环境变量"`），再运行 `Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\ssh-paste"`。macOS 上删掉 profile 里 `# >>> ssh-paste PATH` 开头的那段，以及 `~/.local/share/ssh-paste`。

</details>

## 运行要求

- **Windows 10 或 11**，自带的 PowerShell 5.1 即可（和 PowerShell 7 共存没问题），配 Windows Terminal（推荐）或经典控制台。
- **OpenSSH 客户端**（`ssh.exe` / `ssh`），安装程序会检查。Windows 上在 **设置 > 系统 > 可选功能** 里添加 `"OpenSSH Client"`，或以管理员身份运行 `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`。
- **用 key 登录**：上传在后台自己登录、不弹提示（`BatchMode=yes`），所以服务器得接受你的 key，见[服务器要密码怎么办](#服务器要密码怎么办)。

- **服务器**：`sh`、`cat`、`wc`、`find`、`cmp`、`mv`、`mktemp`，以及可写的 `/tmp`（登录 shell 可以是 `bash`、`zsh`、`fish` 或 `tcsh`）。

## macOS

命令完全一样，粘贴键换成 Cmd+V。它由一个 zsh 启动脚本（`ssh-paste-mac`）和一个由 `osascript` 运行的 JavaScript 文件（`ssh-paste.js`）组成，除了 macOS 自带的东西（`ssh`、`nc`、`curl`、`shasum`）什么都不需要。安装改动了哪些东西，见[它会改动你电脑上的哪些东西](#它会改动你电脑上的哪些东西)。

- **ssh 模式**：`ProxyCommand` 是 `'~/.local/share/ssh-paste/bin/ssh-paste' --proxy '%h' %p '%n'`（家目录会写成完整路径；Homebrew 安装的是 `'/opt/homebrew/opt/ssh-paste/libexec/bin/ssh-paste'`，`brew upgrade` 后不变），用 `nc` 转发连接。会话的 `ssh` 选项是从 `ps` 读的，所以选项值里带空格时（`-i "/path/with space"`）请用 wrapper 模式。上传连接的是转发时用的主机名；图片字节先放在 `$TMPDIR` 里一个权限为 700 的目录中。watcher 忽略 `SIGHUP`，这样终端关闭时它能把剪贴板恢复成纯图片。
- **剪贴板条目**：图片、路径（上传途中按 Cmd+V 会等上传完成）、`com.github.xuing.ssh-paste.owner`，以及 `org.nspasteboard.TransientType` 和 `org.nspasteboard.AutoGeneratedType`，遵循 nspasteboard.org 约定的剪贴板管理器会跳过它。在 Finder 里复制的图片文件，会变成第一张图片加远程路径；粘到其他程序时仍然是文件。
- **终端**：通过进程树找到，找不到时用 `__CFBundleIdentifier` 或 `TERM_PROGRAM`。如果 `ssh-paste --doctor` 认不出终端，把 `SSH_PASTE_TERMINAL` 设成它的 bundle id（比如 `com.googlecode.iterm2`）。
- **已测试**：CI 上用 Terminal.app 在 macOS 15 和 26 上测试。**未测试**：真人日常用的 Mac、其他终端（iTerm2、Ghostty、WezTerm），以及剪贴板隐私提示（开了这个设置的 Mac 可能会弹）。

## 已知限制

- **iTerm2 和 Terminal.app 按标签页判断焦点，其他终端按窗口判断。** 在 iTerm2 和 Terminal.app 里，只有会话自己的标签页（iTerm2 里是它自己的分屏）粘贴的是路径，旁边的本地标签页粘贴的仍是图片。为此 ssh-paste 会问终端哪个标签页在前台：这是终端发给它自己的只读 Apple event，macOS 不会弹权限框。终端没有应答时、在其他终端里、在 Windows Terminal 里、以及在 tmux 或 screen 里，焦点按窗口判断：会话运行期间，同一窗口里的每个标签页粘贴的都是路径，同一窗口里的另一个 SSH 标签页也可能先写入路径。这些情况下请分开用不同的窗口。
- **只接受密码或一次性验证码、不接受 key 的服务器**没法上传。
- **Windows 上的 ssh 模式退出后，剪贴板里可能还是路径**，因为 `ssh` 会直接结束 `ProxyCommand`；下次复制就恢复正常。
- **带 HTML 的图片会丢掉 HTML**：Chrome 的 **复制图片** 只留下图片和路径。
- **Windows 上的 ssh 模式会给每次连接已启用的主机增加 PowerShell 启动时间**（`scp`、`sftp`、`git` 也一样）。

## 问题排查

1. 运行 `ssh-paste --doctor myhost`（不带 `myhost` 只做本机检查），`FAIL` 开头的行会指出问题。
2. ssh 模式下设置 `SSH_PASTE_DEBUG=1` 打开日志。Windows 上转发进程会往 stderr 写 `ssh-paste debug:` 开头的行（地址、stdin/stdout、哪一端先关闭）：

   ```powershell
   $env:SSH_PASTE_DEBUG = 1; ssh myhost
   Remove-Item Env:SSH_PASTE_DEBUG
   ```

   macOS 上 `SSH_PASTE_DEBUG=1 ssh myhost` 会把 watcher 的每个判断记到 `$TMPDIR/ssh-paste-debug.log`。
3. 运行 `ssh -v myhost`；卡在 `expecting SSH2_MSG_KEX_ECDH_REPLY` 说明转发停了。
4. 带上输出提交 [bug report](https://github.com/xuing/ssh-please-paste-picture/issues/new?template=bug_report.yml)。

## 细节

- **其他终端**：经典控制台可以用；WezTerm 和 Alacritty 尽力支持（`ssh-paste --doctor` 会打印 `terminal: ...`）。
- **其他 CLI**：Codex CLI、Gemini CLI 和 aider 也会收到 PNG 路径；能不能作为附件取决于程序本身（Claude Code 可以）。
- **语言**：提示信息是英文或简体中文，判断方式和 git 一样：先看 `SSH_PASTE_LANG`，再看 `LANGUAGE`、`LC_ALL`、`LC_MESSAGES`、`LANG`，最后看系统的显示语言。想用英文就设 `SSH_PASTE_LANG=en`；`C` 或 `POSIX` 也表示英文。Windows 上如果控制台的代码页显示不了中文，就用英文。安装脚本和 macOS 启动器的少数提示仍是英文。译文在 `src/locale/` 里（每种语言一个 JSON 文件，英文原句对应译文）。
- **别的 `ssh`**：把 `SSH_PASTE_SSH` 设成它的完整路径，wrapper 模式、`--enable` 和 `--doctor` 都会用它（Windows 上 ssh 模式的上传用的是启动转发的那个 `ssh.exe`）。

<details>
<summary>会话识别、上传、重试、剪贴板</summary>

- **会话识别**：只有交互式会话才会监视剪贴板（根据参数和 `ssh -G` 判断）；`scp`、`sftp`、`git` 和 VS Code Remote-SSH 直接放行。以下情况跳过：`-T`、`-N`、`-W`、`-f`、`-n`、`-s`、`-G`、`-V`、`-O`、`-Q`，不带 `-t` 的远程命令（`ssh myhost ls`、`git`、`RemoteCommand`），`RequestTTY no`，`SessionType` 不是 `default`，`StdinNull yes`；对已启用的主机用 wrapper 模式时直接运行 `ssh`。
- **上传**：最大 64 MB，在会话窗口切到前台时上传（每 250 ms 检查一次），不是在粘贴时。上传途中粘贴最多等 30 秒。同一张图每个会话只传一次，6 小时后再传（`--keep` 的一半更短时，按那个时间）。失败时播放一次 Windows 错误提示音，窗口在前台时每 30 秒重试（最多 30 分钟），退出时汇总。缺少或被拦截的 API 会打印 `ssh-paste: screenshot paste is off: <reason>`，`ssh` 照常运行。
- **剪贴板**：同时含图片和文本或文件的条目（Excel、Word、资源管理器）会跳过。原始截图仍在 Win+V 历史里，只有 `ssh-paste` 改写的内容被排除。

</details>

## 安全

### 校验下载的文件

每个 release 都带 `SHA256SUMS`，以及 `install.ps1`、`ssh-paste.ps1`、`ssh-paste.cmd`、`install.sh`、`ssh-paste-mac`、`ssh-paste.js`、`SHA256SUMS` 的 GitHub build attestation（从 `main` 安装的两样都没有）。release 安装会按 `SHA256SUMS` 校验文件，Scoop 和 Homebrew 也一样。

<details>
<summary>运行 install.ps1 之前先校验它</summary>

SHA-256（输出 `True` 表示一致）：

```powershell
$base = 'https://github.com/xuing/ssh-please-paste-picture/releases/latest/download'
Invoke-WebRequest -UseBasicParsing -Uri "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile SHA256SUMS
$want = (Select-String -Path SHA256SUMS -Pattern ' install\.ps1$').Line.Split(' ')[0]
(Get-FileHash install.ps1 -Algorithm SHA256).Hash -eq $want
```

用 [GitHub CLI](https://cli.github.com/) 校验 attestation：

```powershell
gh attestation verify install.ps1 -R xuing/ssh-please-paste-picture
```

然后用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` 运行（Bypass 只对这个进程生效）。

</details>

### 它会改动你电脑上的哪些东西

| 步骤 | 改动 | 由谁撤销 |
|---|---|---|
| `install.ps1` | `%LOCALAPPDATA%\Programs\ssh-paste`（`ssh-paste.ps1`、`ssh-paste.cmd`；`Programs` 不存在时会创建），以及 `HKCU\Environment\Path` 里的一条 | `--uninstall`，`Programs` 或 `Path` 变空时一并删除 |
| Scoop | 它的应用目录和 shim | `scoop uninstall ssh-paste` |
| `install.sh` | `~/.local/share/ssh-paste`（`bin/ssh-paste`、`ssh-paste.js`、`install.sh`），以及 `~/.zprofile` 开头一段带标记的 `PATH` 配置（登录 shell 是 bash 时还有 `~/.bash_profile`、`~/.bash_login` 或 `~/.profile`） | `--uninstall`，变空的 `~/.local/share`、`~/.local` 和它创建的 profile 一并删除 |
| Homebrew | 它的 keg 和 `$(brew --prefix)/bin/ssh-paste` | `brew uninstall ssh-paste` |
| `--enable` | `~/.ssh/config`（`%USERPROFILE%\.ssh\config`）开头的一段配置（文件和 `.ssh` 不存在时会创建） | `--disable` 或 `--uninstall`；如果 config 和 `.ssh` 是 `ssh-paste` 创建的且已变空，一并删除 |
| Windows 剪贴板 | 图片、路径、`SshPaste.Owner`、`ExcludeClipboardContentFromMonitorProcessing`、`CanIncludeInClipboardHistory=0`、`CanUploadToCloudClipboard=0` | 切走或退出时恢复成纯图片（见[已知限制](#已知限制)）；这些标记留到你下次复制 |

除此之外没有任何改动：不需要管理员权限，没有服务、计划任务、launch agent、登录项、守护进程，不改 PowerShell profile，也没有配置文件（`--keep` 和 `--dir` 记在 `--enable` 那段配置里）。Windows 上安装和卸载会临时设置一个用户变量，让新开的窗口拿到新的 `Path`。不保存密码或密钥，不发送遥测；只从 `github.com` 和 `raw.githubusercontent.com` 下载。服务器上只在 `/tmp` 或你的 `--dir` 目录里写 `ssh-paste-*` 文件。

### 服务器上的文件

`/tmp/ssh-paste-<hash>.png`（PNG 的 SHA-256 前 128 位，十六进制），或 `--dir` 目录下的同名文件，权限 600；`--keep` 不是默认值时，hash 前面会加上 `k<keep>-`；这个名字被别的用户占用时改用 `ssh-paste-<hash>-<uid>.png`。内容相同的文件会直接复用。每次上传会删掉你自己同一种 `--keep`、超过这个时间（默认一天）的这类文件。上传之间和卸载之后什么都不运行；`/tmp` 由系统清理（通常在重启时）。

<details>
<summary>杀毒软件与策略限制</summary>

- 在组策略（`AllSigned` 或 `Restricted`）和 Constrained Language 模式（AppLocker 或 App Control）下无法运行；`ssh-paste --doctor` 会报告。
- 运行时由 `Add-Type` 编译的 C# 代码可能触发扫描；纯文本脚本在 `%LOCALAPPDATA%\Programs\ssh-paste`。
- Defender 误报可以提交到：<https://www.microsoft.com/en-us/wdsi/filesubmission>。

</details>

安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 同类工具对比

| 工具 | 需要什么 | 粘贴方式 |
|---|---|---|
| ssh-please-paste-picture | 一个脚本，只在会话期间工作；服务器上什么都不装 | Ctrl+V / Cmd+V，切换窗口时上传 |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)（`/rc`） | Claude Code，需要 Pro、Max、Ultra、Team 或 Enterprise（不支持 API key）；在浏览器或 Claude app 里用 | 在浏览器或 app 里添加附件 |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust 守护进程；服务器上要有 xclip / wl-paste shim、`clipaste-paste` 和 curl；`RemoteForward` | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go 热键进程（Windows 支持为实验性） | Alt+Shift+V（scp） |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | 登录时启动的 Go 守护进程，复制的每张图都会上传 | Ctrl+V |
| [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2，拦截 Ctrl+V | Ctrl+V，粘贴时上传 |

<details>
<summary>开发</summary>

所有文件只用 ASCII，并且要在 PowerShell 5.1 和 7 上都能运行。提 pull request 之前请先开 issue。macOS 客户端的逻辑用 `node --test tests/mac/unit.test.js` 测试，`tests/mac` 里其余的测试在 macOS CI 上跑。详见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [docs/RELEASING.md](docs/RELEASING.md)。每次 commit 前运行：

```powershell
pwsh ./check.ps1
```

</details>

## 许可证

[MIT](LICENSE)
