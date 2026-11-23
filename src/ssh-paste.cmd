@echo off
rem ssh-paste launcher. --uninstall deletes this file and --update replaces it, so
rem those first end the batch context with "(goto)": cmd never reads this file again.
if /i "%~1"=="--uninstall" goto detached
if /i "%~1"=="--update" goto detached
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-paste.ps1" %*
exit /b %errorlevel%
:detached
(goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-paste.ps1" %*
