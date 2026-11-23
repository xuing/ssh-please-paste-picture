@echo off
rem ssh-paste launcher. --uninstall deletes this file, so that case first ends the
rem batch context with "(goto)": cmd then never reads this file again.
if /i "%~1"=="--uninstall" goto uninstall
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-paste.ps1" %*
exit /b %errorlevel%
:uninstall
(goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-paste.ps1" %*
