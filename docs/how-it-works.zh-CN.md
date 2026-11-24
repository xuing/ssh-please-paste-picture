# ssh-paste 是怎么工作的

[English](how-it-works.md) | 简体中文

## 要解决的问题

Claude Code（或 Codex CLI、Gemini CLI、aider）跑在你通过 SSH 连上的服务器上。你在自己电脑上截了一张图，图在本机剪贴板里，可服务器上的程序只能读服务器上的文件，终端通过 SSH 也只传文字、不传图片。所以按 Ctrl+V，程序拿不到任何能用的东西。

## 思路

先把图片放到服务器上，粘贴的时候贴它的路径，而不是图片本身。

```
your computer                                  the server
-------------                                  ----------
1. copy a screenshot
2. switch to the ssh window  ── upload ──►     /tmp/ssh-paste-<hash>.png
   ssh-paste puts that path
   on the clipboard, next to the image
3. press Ctrl+V              ── the path ──►   Claude Code opens the file
```

在终端以外的程序里粘贴，得到的仍然是图片：剪贴板里同时有图片和路径，每个程序取自己认识的那一种。

## 一步步发生了什么

1. **只在你连着的时候工作。** 交互式 `ssh` 会话开始时，ssh-paste 开始留意剪贴板；会话结束就停。`scp`、`sftp`、`git` 走 SSH 时不会用到它：在 ssh 模式下，它们的连接只经过 ssh-paste 的转发，字节原样通过。
2. **等你切到那个窗口才上传。** 所以按 Ctrl+V 是即时的：通常在你按下之前就传完了；上传途中按粘贴，会等它传完（最多 30 秒）。
3. **用另一条独立的 ssh 连接上传**，用的是你自己的密钥和配置，连的是同一台服务器。只传图片的字节，别的什么都不传。服务器上只需要 `sh` 和几个标准工具，什么都不用装。
4. **文件按内容命名**（图片的 hash），同一张截图只传一次；两个用户传了同一张图，也不会互相覆盖。
5. **切走或断开时**，剪贴板恢复成原来的纯图片。（Windows 上的 ssh 模式里，`ssh` 会立刻结束转发进程，所以路径可能留到你下次复制。）

有两种启动方式：

- **ssh 模式**（`ssh-paste --enable myhost`）：在 `~/.ssh/config` 里加一段带标记的配置，之后普通的 `ssh myhost` 就会经过 ssh-paste，连接内容原样转发。
- **wrapper 模式**（`ssh-paste myhost`）：由它替你运行 `ssh`，不改任何配置。

## 它不做什么

- 不在服务器上安装任何东西，两次上传之间在服务器上什么都不运行。
- 不在你电脑上装后台服务、计划任务、launch agent 或登录项。没有连着的会话时，它的任何部分都不在运行。
- 只上传图片，只传给前台窗口里那些会话对应的服务器，而且只在会话进行中。剪贴板里的文字永远不会被发出去。
- 不保存密码或密钥，不发送遥测；唯一的设置就是 ssh 配置里那段带标记的内容。只从 GitHub 下载，而且只在你安装或升级时。
- 不需要管理员权限。

## 在你的电脑上保持干净

- **一个小而可读的程序。** Windows 上是一个 PowerShell 脚本（约 2,300 行）加一个 9 行的启动文件；macOS 上是一个由系统自带的 `osascript` 运行的 JavaScript 文件（约 2,000 行）加一个 zsh 启动脚本。没有编译产物，运行的就是你能读到的代码。
- **只用系统自带的工具。** Windows 上是 Windows PowerShell 5.1 和 OpenSSH；macOS 上是 zsh、`osascript`、`ssh` 和 `nc`。
- **每一处改动都列得出来，也能原样撤销。** 安装程序只加一个目录和一条 `PATH`；`--enable` 只在 ssh 配置里加一段带标记的内容。`--uninstall` 恰好删掉这些，你 ssh 配置和 profile 里的其他内容保持原样（唯一的例外：如果 ssh 配置里 CRLF 和 LF 两种换行混用，会统一成 CRLF）。CI 会在 Windows 和 macOS 的 runner 上完整走一遍安装、启用、停用、卸载，并核对用户目录和装之前完全一样。
- **安装方式任选：** 一行脚本、[Homebrew](https://brew.sh) 或 [Scoop](https://scoop.sh)。

## 在服务器上保持干净和安全

- 一张图一个文件，只有你能读（权限 600），放在 `/tmp` 或你用 `--dir` 指定的目录里。
- `/tmp` 以外的目录必须只属于你（归你所有、不是链接、别人不可写），否则服务器在写任何东西之前就会拒绝。
- 每次上传只删你自己同一种 `--keep`、超过这个时间的旧图（默认一天，也可以设成别的时间或 `never`）；文件名标明了是哪种 `--keep`，所以一台主机想多留的图，不会被另一台主机提前删掉。别的用户的文件、不是它起名的文件，它一概不碰。
- 在共享的 `/tmp` 里，别的用户最多只能让一次上传失败：ssh-paste 不跟随别人的符号链接，不往别人的文件里写，还会核对服务器回传的路径是不是它预期的那个。

细节见 [SECURITY.md](../SECURITY.md)。

## 怎么测试的

每次改动在能发版之前，都要在 GitHub Actions 上通过这些检查：

- 单元测试（Windows 脚本约 700 个，分别在 Windows PowerShell 5.1、Windows 上的 PowerShell 7 和 Linux 上运行；macOS 的逻辑约 240 个）；
- 对真实 `sshd` 的端到端测试，在 Linux 和 macOS 15、26 上跑，另外用真实的 Windows OpenSSH 测转发；
- 上面说的安装/卸载"不留痕迹"检查（Windows 和 macOS），以及一次真实的 Scoop 安装、升级和卸载；
- 剪贴板监视逻辑的 [TLA+](https://lamport.azurewebsites.net/tla/tla.html) 模型，由模型检查器逐个状态穷举，确保在模型里，粘贴出来的路径一定属于这台服务器、指向的文件一定已经传完。

每个 release 的文件都附带 SHA-256 校验和与 GitHub build attestation。每次发版后，CI 还会在 Mac 上从 Homebrew tap、在 Windows 上从 Scoop bucket 真的装一遍。

## 和同类工具对比

| 工具 | 你电脑上要什么 | 服务器上要什么 | 粘贴方式 |
|---|---|---|---|
| **ssh-paste** | 一个脚本，只在会话期间工作 | 什么都不用 | Ctrl+V / Cmd+V，切到窗口时上传 |
| [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)（`/rc`） | claude.ai/code 或 Claude app；只支持 Claude Code，需要 Pro、Max、Ultra、Team 或 Enterprise（不支持 API key） | 不用额外的东西 | 在浏览器或 app 里添加附件 |
| [clipaste](https://github.com/hqhq1025/clipaste) | Rust 守护进程 | xclip / wl-paste shim、`clipaste-paste` 和 curl；`RemoteForward` | Ctrl+V |
| [cc-clip](https://github.com/ShunmeiCho/cc-clip) | Go 热键进程（Windows 支持为实验性） | Windows 热键方式下不用（走 scp） | Alt+Shift+V |
| [img2ssh](https://github.com/bulletsrip/img2ssh) | 登录时启动的 Go 守护进程，复制的每张图都会上传 | 什么都不用 | Ctrl+V |
| [claude-ssh-image-paste](https://github.com/devonjones/claude-ssh-image-paste) | AutoHotkey v2，拦截 Ctrl+V | 什么都不用 | Ctrl+V，粘贴时上传 |

如果你想继续用自己的终端和普通的 `ssh`、不在服务器上装东西、不连的时候本机也什么都不跑，ssh-paste 适合你。它的局限写在 README 的[已知限制](../README.zh-CN.md#已知限制)里。
