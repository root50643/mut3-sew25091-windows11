@echo off
setlocal
cd /d "C:\MUT-Install"
echo MUT installation with a scoped SQL registry permission repair
echo Complete the original UNINST.BAT procedure before using this helper.
echo Original installer dialogs still require normal interaction.
echo The watcher is limited to 45 minutes and does not restart Windows itself.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$taskPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if (-not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Close this window, then right-click Run-MutInstallWithSqlAcl.cmd and choose Run as administrator.'; exit 5 }; & 'C:\MUT-Install\Start-MutInstallWithSqlAcl.ps1'"
set "MUT_INSTALL_WATCH_EXIT=%ERRORLEVEL%"
echo.
echo Watcher exit code: %MUT_INSTALL_WATCH_EXIT%
if "%MUT_INSTALL_WATCH_EXIT%"=="0" echo Both SQL engines passed. The original installer may still be completing other components.
if not "%MUT_INSTALL_WATCH_EXIT%"=="0" echo Review C:\MUT-Install\sql-acl-coordinator-status.json before retrying.
echo This result does not replace verification of both MUT applications after restarting Windows.
pause
exit /b %MUT_INSTALL_WATCH_EXIT%
