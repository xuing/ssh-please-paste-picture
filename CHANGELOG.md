# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - Unreleased

First release of ssh-please-paste-picture. The command is `ssh-paste`.

### Added

- Image files copied in File Explorer (png, jpg, jpeg, gif, webp, bmp, up to
  20 at a time) are uploaded with their own extension, and Ctrl+V pastes all
  remote paths separated by spaces. Explorer can still paste the files.
- While an interactive session runs and its terminal window is in front,
  `ssh-paste` uploads copied images to `/tmp/ssh-paste-<hash>.png` on the
  server. Ctrl+V in the terminal pastes that path, while other apps still paste
  the image.
- `ssh-paste --enable HOST [HOST...]` enables ssh mode by adding a marked block
  with `ProxyCommand` and `ProxyUseFdpass no` at the top of `~/.ssh/config`, so
  plain `ssh HOST` pastes screenshots. It refuses hosts using `ProxyJump` or
  `ProxyCommand`. `ssh-paste --disable [HOST...]` removes the block, and deletes
  an `ssh-paste`-created config file and empty `.ssh` folder if nothing else
  remains.
- `ssh-paste [ssh options] HOST` runs `ssh` in wrapper mode with the same
  arguments and the clipboard watcher, without editing config.
- Only interactive sessions run the watcher. Connections using `-T`, `-N`, `-W`,
  `-f`, `-n`, `-s`, a remote command without `-t`, `RequestTTY no`, or
  non-default `SessionType` run as plain relays. Settings from both arguments
  and `~/.ssh/config` apply, so `scp`, `sftp`, `git`, and VS Code Remote-SSH
  work unchanged.
- Failed uploads beep once and retry after 30 seconds, doubling up to 30
  minutes. At exit, `ssh-paste` prints the failed count and last error.
- `ssh-paste --doctor [HOST]` checks this computer and tests an upload.
- `ssh-paste --uninstall` removes the ssh config block, `PATH` entry, install
  folder, and `%LOCALAPPDATA%\Programs` if empty.
- `install.ps1` installs per user via `irm ... | iex` without administrator
  rights. `SSH_PASTE_REF` or `-Ref` picks a tag, branch, or commit.
  `SSH_PASTE_UNINSTALL=1` or `-Uninstall` removes everything, even if the
  installed copy is broken.
- Server files use mode 600, are named by content, are reused when identical,
  and are pruned on later uploads after one day. Nothing is installed on the
  server.
- Clipboard rewrites are excluded from Windows clipboard history and cloud
  clipboard.
- Releases attach `install.ps1` defaulting to the release tag, `ssh-paste.ps1`,
  `ssh-paste.cmd`, and `SHA256SUMS`.

