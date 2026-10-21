@echo off
setlocal EnableExtensions
if /i "%~1"=="/check" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Android16Merge.ps1" -Check
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Android16Merge.ps1"
)
exit /b %ERRORLEVEL%
