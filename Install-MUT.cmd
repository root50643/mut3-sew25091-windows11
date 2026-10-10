@echo off
setlocal
set "MUT_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "MUT_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0scripts\Install-Mut.ps1" (
  echo Missing scripts\Install-Mut.ps1. Extract the complete project first.
  pause
  exit /b 1
)
"%MUT_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Mut.ps1" -Mode Auto
set "MUT_RESULT=%ERRORLEVEL%"
if not "%MUT_RESULT%"=="0" echo MUT installer exit code: %MUT_RESULT%
if not "%MUT_RESULT%"=="0" pause
exit /b %MUT_RESULT%
