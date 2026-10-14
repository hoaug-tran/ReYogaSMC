@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
    python Scripts\hardware_support.py --windows-live --ec-read %*
) else (
    py -3 Scripts\hardware_support.py --windows-live --ec-read %*
)
set "reyoga_status=%errorlevel%"
if not "%reyoga_status%"=="0" echo Collection reported errors. Read report.json before sharing the export.
pause
exit /b %reyoga_status%
