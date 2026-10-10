@echo off
setlocal
cd /d "C:\MUT-Install"
echo Remove the two reviewed failed MUT SQL engines using original SQL Setup.
echo A restart or error stops this procedure. Windows is never restarted automatically.
echo After verified removal, the original MUT installer will start with the scoped ACL watcher.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "if ((Get-FileHash -LiteralPath 'C:\MUT-Install\Remove-FailedMutSqlInstances.ps1' -Algorithm SHA256).Hash -ne 'FE8BD71A1EADA858E14E14D939B56104DBB91574C5E4C9A3071789EE3203C4ED') { throw 'Removal helper differs from reviewed file.' }; & 'C:\MUT-Install\Remove-FailedMutSqlInstances.ps1'"
set "MUT_CLEAN_RETRY_EXIT=%ERRORLEVEL%"
if not "%MUT_CLEAN_RETRY_EXIT%"=="0" goto removal_stopped
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "if ((Get-FileHash -LiteralPath 'C:\MUT-Install\Start-MutInstallWithSqlAcl.ps1' -Algorithm SHA256).Hash -ne '8973CBEF15303AB10AD05C2A4976021BBF33066CFF3DAD2DC61F228816DAC000') { throw 'Coordinator differs from reviewed file.' }; & 'C:\MUT-Install\Start-MutInstallWithSqlAcl.ps1'"
set "MUT_CLEAN_RETRY_EXIT=%ERRORLEVEL%"
echo.
echo Installation watcher exit code: %MUT_CLEAN_RETRY_EXIT%
echo Review C:\MUT-Install\sql-acl-coordinator-status.json
echo Both MUT application launches must still be verified after installation and restart.
goto finish
:removal_stopped
echo.
echo SQL removal stopped with exit code: %MUT_CLEAN_RETRY_EXIT%
echo Review C:\MUT-Install\sql-instance-removal-status.json
echo No new MUT installation was started.
:finish
pause
exit /b %MUT_CLEAN_RETRY_EXIT%
