@echo off
rem Compatibility entry: prerequisites only. The vendor application is installed manually.
call "%~dp0Install-Prerequisites.cmd"
exit /b %ERRORLEVEL%
