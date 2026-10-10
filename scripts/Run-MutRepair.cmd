@echo off
setlocal
cd /d "C:\MUT-Install"
echo MUT prerequisite repair
echo This window stays open so you can see the result.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$taskPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if (-not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Please close this window, then right-click Run-MutRepair.cmd and choose Run as administrator.'; exit 5 }; & 'C:\MUT-Install\Repair-MutPrerequisites.ps1'"
set "MUT_REPAIR_EXIT=%ERRORLEVEL%"
echo.
echo Repair exit code: %MUT_REPAIR_EXIT%
if "%MUT_REPAIR_EXIT%"=="3010" echo Windows needs a restart before repair can continue.
if "%MUT_REPAIR_EXIT%"=="0" echo Loader finished. Logs must still be reviewed before installing MUT.
echo Please report this result to the assistant. Logs are in C:\MUT-Install\repair-logs.
pause
exit /b %MUT_REPAIR_EXIT%
