@echo off
setlocal
cd /d "C:\MUT-Install"
echo Read-only MUT SQL verification after Windows restart.
echo No SQL services are started or stopped. No database settings are changed.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "if ((Get-FileHash -LiteralPath 'C:\MUT-Install\Verify-MutSqlInstallation.ps1' -Algorithm SHA256).Hash -ne '4332F6D0D0FFBFA40D22C869ABFAC209B4AC176F78B6111409DEBFB35735F833') { throw 'Verification helper differs from reviewed file.' }; & 'C:\MUT-Install\Verify-MutSqlInstallation.ps1' -Phase AfterReboot"
set "MUT_VERIFY_EXIT=%ERRORLEVEL%"
echo.
echo Verification exit code: %MUT_VERIFY_EXIT%
echo Reports: C:\MUT-Install\verification-logs
echo Application launch and vehicle or VCI operation are not covered by this report.
pause
exit /b %MUT_VERIFY_EXIT%
