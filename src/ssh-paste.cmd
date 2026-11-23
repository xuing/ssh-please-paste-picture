@echo off
rem ssh-paste launcher. The call and "exit /b" share one line so that cmd never reads
rem this file again after "ssh-paste --uninstall" has deleted it; "exit /b" keeps the exit code.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh-paste.ps1" %* & exit /b
